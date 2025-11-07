#!/bin/bash
# ------------------------------------------------------------------
# [LT User Data V2] 모니터링 서버(Ubuntu) 자동화 스크립트
# (Git Clone + EBS 볼륨 영속화)
# ------------------------------------------------------------------

# 1. 루트 권한 획득
sudo -i

# 2. 시스템 업데이트
apt-get update -y
apt-get upgrade -y

# 3. Docker, Docker Compose, AWS CLI, jq, Git, XFS 설치
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
apt-get install -y awscli jq git xfsprogs # (EBS 포맷용 xfsprogs 추가)

# 4. (필수) EBS 볼륨 자동 감지 및 마운트
# T3/M5 (NVMe)는 /dev/nvme1n1, T2(Xen)는 /dev/xvdf 등으로 이름이 다릅니다.
# 루트 볼륨(/)이 아닌, LT 1.6단계에서 추가한 EBS 볼륨('/dev/sdf')을 자동으로 찾습니다.
MOUNT_POINT="/data" # (docker-compose.yml 파일에 지정된 경로)

# 루트 파티션의 디바이스 이름 찾기 (예: /dev/nvme0n1p1 또는 /dev/xvda1)
ROOT_DEV=$(df / | tail -1 | awk '{print $1}')
# 루트 파티션의 부모 디스크 이름 찾기 (예: nvme0n1 또는 xvda)
ROOT_DISK=$(lsblk -no pkname $ROOT_DEV)

# 루트 디스크가 아닌 다른 'disk' 타입의 디바이스 이름 찾기 (예: nvme1n1 또는 xvdf)
DATA_VOL_NAME=$(lsblk -no NAME,TYPE | grep 'disk' | grep -v $ROOT_DISK | awk '{print $1}')

if [ -z "$DATA_VOL_NAME" ]; then
    echo "FATAL: Could not find attached data volume. Root disk is $ROOT_DISK." >> /var/log/cloud-init-output.log
    exit 1
fi

DATA_VOL="/dev/${DATA_VOL_NAME}"
echo "Found data volume at $DATA_VOL (Root disk was $ROOT_DISK)" >> /var/log/cloud-init-output.log

# 4-1. 마운트 포인트 생성
mkdir -p $MOUNT_POINT

# 4-2. 디바이스가 포맷 안 됐는지 확인 후 포맷 (새 인스턴스)
# (ASG가 V2->V3로 복구 시, 이미 포맷된 볼륨을 재사용하므로 이 if문은 skip됨)
if ! file -s $DATA_VOL | grep -q "filesystem"; then
    echo "Formatting $DATA_VOL..." >> /var/log/cloud-init-output.log
    mkfs -t xfs $DATA_VOL
fi

# 4-3. 마운트
mount $DATA_VOL $MOUNT_POINT
# (fstab에 등록하여 재부팅 시에도 자동 마운트되도록 설정)
UUID=$(blkid -s UUID -o value $DATA_VOL)
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
fi

# 4-4. Docker Compose가 사용할 데이터 디렉토리 생성 (EBS 볼륨 내부)
mkdir -p $MOUNT_POINT/prometheus
mkdir -p $MOUNT_POINT/grafana
echo "EBS Volume mounted to $MOUNT_POINT" >> /var/log/cloud-init-output.log

# 5. 설정 파일 디렉토리 정의
CONFIG_DIR="/app/monitoring" # 최종 설정 파일이 위치할 디렉토리
TEMP_CLONE_DIR="/tmp/prod-docker-infra" # Git을 임시로 복제할 디렉토리

mkdir -p $CONFIG_DIR
mkdir -p $TEMP_CLONE_DIR
cd $CONFIG_DIR # .env 파일과 docker-compose.yml이 위치할 곳으로 이동

# 6. AWS 리전 설정 (메타데이터에서 자동 감지)
EC2_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
export AWS_REGION=$EC2_REGION

# 7. Parameter Store에서 비밀 정보(.env 파일) 가져오기
echo "Fetching secrets from Parameter Store..."
ENV_FILE_PATH="$CONFIG_DIR/.env" # .env 파일을 최종 위치에 생성

# 7-1. GitHub Deploy Token
GIT_TOKEN=$(aws ssm get-parameter --name "/couponpop/prod/github-deploy-token" --with-decryption --query "Parameter.Value" --output text)
if [ -z "$GIT_TOKEN" ]; then
    echo "FATAL: GitHub Deploy Token not found." >> /var/log/cloud-init-output.log
    exit 1
fi

# 7-2. 나머지 비밀 정보(.env)
PARAM_NAMES=(
    "/couponpop/prod/grafana-admin-pass"
    "/couponpop/prod/db-host"
    "/couponpop/prod/db-port"
    "/couponpop/prod/mysqld-exporter-user"
    "/couponpop/prod/mysqld-exporter-pass"
)
declare -A PARAM_MAP
PARAM_MAP["/couponpop/prod/grafana-admin-pass"]="GRAFANA_ADMIN_PASSWORD"
PARAM_MAP["/couponpop/prod/db-host"]="DB_HOST"
PARAM_MAP["/couponpop/prod/db-port"]="DB_PORT"
PARAM_MAP["/couponpop/prod/mysqld-exporter-user"]="MYSQLD_EXPORTER_USERNAME"
PARAM_MAP["/couponpop/prod/mysqld-exporter-pass"]="MYSQLD_EXPORTER_PASSWORD"

rm -f $ENV_FILE_PATH
touch $ENV_FILE_PATH

for PARAM_NAME in "${PARAM_NAMES[@]}"; do
    VALUE=$(aws ssm get-parameter --name "$PARAM_NAME" --with-decryption --query "Parameter.Value" --output text)
    if [ $? -ne 0 ]; then
        echo "FATAL: Parameter $PARAM_NAME not found." >> /var/log/cloud-init-output.log
        exit 1
    fi
    ENV_KEY=${PARAM_MAP[$PARAM_NAME]}
    echo "$ENV_KEY=$VALUE" >> $ENV_FILE_PATH
done

# .env 파일에 포트 변수 추가
echo "PROMETHEUS_PORT=9090" >> $ENV_FILE_PATH
echo "GRAFANA_PORT=3000" >> $ENV_FILE_PATH
echo "MYSQLD_EXPORTER_PORT=9104" >> $ENV_FILE_PATH

echo "Successfully created .env file at $ENV_FILE_PATH" >> /var/log/cloud-init-output.log

# 8. GitHub 리포지토리 Clone (임시 디렉토리에)
GIT_REPO_URL="https://github.com/CouponPop/prod-docker-infra.git"
CLONE_URL="https://oauth2:${GIT_TOKEN}@${GIT_REPO_URL#https://}"

echo "Cloning config repository into $TEMP_CLONE_DIR..." >> /var/log/cloud-init-output.log
git clone $CLONE_URL $TEMP_CLONE_DIR

if [ $? -ne 0 ]; then
    echo "FATAL: Failed to clone repository." >> /var/log/cloud-init-output.log
    exit 1
fi

# 9. (중요) 필요한 파일들만 최종 위치로 이동
# Git 구조 ('monitoring/root/')에 맞춰 파일 이동
echo "Moving files from $TEMP_CLONE_DIR/monitoring/root/ to $CONFIG_DIR/" >> /var/log/cloud-init-output.log
if [ ! -d "$TEMP_CLONE_DIR/monitoring/root" ]; then
    echo "FATAL: Directory $TEMP_CLONE_DIR/monitoring/root/ not found in repository." >> /var/log/cloud-init-output.log
    exit 1
fi
mv $TEMP_CLONE_DIR/monitoring/root/* $CONFIG_DIR/
mv $TEMP_CLONE_DIR/monitoring/root/.* $CONFIG_DIR/ 2>/dev/null

# 10. Docker Compose 실행
# (docker-compose.monitoring.yml 파일이 $CONFIG_DIR에 있다고 가정)
echo "Starting Docker Compose stack from $CONFIG_DIR..." >> /var/log/cloud-init-output.log
# .env 파일은 같은 디렉토리에 있으므로 docker compose가 자동으로 읽음
docker compose -f $CONFIG_DIR/docker-compose.monitoring.yml up -d

# 11. 임시 Clone 디렉토리 삭제 (보안 및 용량 확보)
rm -rf $TEMP_CLONE_DIR
echo "Removed temporary clone directory." >> /var/log/cloud-init-output.log

echo "Monitoring Stack Auto-Deployment Complete (V2 with EBS & Git)." >> /var/log/cloud-init-output.log