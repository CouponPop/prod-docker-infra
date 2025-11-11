#!/bin/bash
# ------------------------------------------------------------------
# [Final User Data Script] ECS Monitoring Stack Deployment (ECS Discovery)
# - Prometheus, Grafana, MySQL Exporter, Custom ECS Discovery
# ------------------------------------------------------------------

# 1. 루트 권한 획득
sudo -i

# [!!] CRITICAL FIX: AWS Region 변수를 최상단에서 확보 및 export
# 토큰 획득
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
if [ -z "$IMDS_TOKEN" ]; then
    echo "FATAL: Could not get IMDS token." >> /var/log/cloud-init-output.log
    exit 1
fi
# AZ 및 Region 획득
export AZ=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
export AWS_REGION=$(echo $AZ | sed 's/[a-z]$//')
export INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

if [ -z "$AWS_REGION" ]; then
    echo "FATAL: Could not determine AWS region." >> /var/log/cloud-init-output.log
    exit 1
fi
echo "Region set to $AWS_REGION, AZ set to $AZ." >> /var/log/cloud-init-output.log

# 2. 시스템 업데이트 및 필수 패키지 설치
echo "Starting system update and package installation..." >> /var/log/cloud-init-output.log
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg jq git xfsprogs

# 3. Docker 설치 및 AWS CLI v2 설치
echo "Installing Docker and AWS CLI v2..." >> /var/log/cloud-init-output.log
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
snap install aws-cli --classic
ln -s /snap/bin/aws /usr/bin/aws 2>/dev/null
echo "AWS CLI v2 and Docker installed." >> /var/log/cloud-init-output.log

# 4. 기존 EBS 볼륨 자동 재연결 및 마운트 로직 (NVMe 호환)

echo "Starting EBS volume auto-reconnection and mount (NVMe Compatible)..." >> /var/log/cloud-init-output.log
# 변수 정의
MOUNT_POINT="/data"

# ASG 시작 템플릿에 지정된 논리적 장치 이름
LOGICAL_DEVICE_NAME="/dev/sdf"
# NVMe 기반 EC2 인스턴스에서 추가 볼륨이 실제로 나타나는 장치 이름
ACTUAL_DEVICE_NAME="/dev/nvme1n1"
# (lsblk 출력 결과에 따라 이 이름으로 고정하여 진행합니다.)
# 1. [CRITICAL FIX] 보존된 (tag:Name 일치) 볼륨을 검색합니다. (상태 조건 제거)
#    스크립트가 기존 볼륨을 찾는 데 실패한 주 원인이므로, 상태 필터링을 제거하고 태그만으로 검색합니다.
TARGET_VOLUME_ID=$(aws ec2 describe-volumes \
    --region $AWS_REGION \
    --filters Name=availability-zone,Values=$AZ \
                Name=tag:Name,Values=couponpop-monitoring-data \
    --query "Volumes[?State!='in-use' && State!='deleting' && State!='detaching'].[VolumeId]" --output text)

# 2. [CRITICAL FIX] 보존된 볼륨이 발견되지 않았거나 (None), 쿼리 결과가 복수일 경우 첫 번째 볼륨만 사용
if [ -z "$TARGET_VOLUME_ID" ] || [ "$TARGET_VOLUME_ID" == "None" ]; then
    echo "No available, detached volume found. This is a fresh deployment or volume not tagged." >> /var/log/cloud-init-output.log
    VOLUME_ID="" # 연결할 볼륨이 없음을 명시
else
    # 쿼리가 여러 볼륨을 반환할 수 있으므로, 첫 번째 볼륨만 사용
    VOLUME_ID=$(echo "$TARGET_VOLUME_ID" | head -n 1)
    echo "Found detached volume: $VOLUME_ID in AZ $AZ. Attempting attachment as $LOGICAL_DEVICE_NAME..." >> /var/log/cloud-init-output.log

    # AWS CLI를 사용하여 볼륨 연결 (논리적 장치 이름 사용)
    aws ec2 attach-volume \
        --region $AWS_REGION \
        --volume-id "$VOLUME_ID" \
        --instance-id "$INSTANCE_ID" \
        --device "$LOGICAL_DEVICE_NAME"

    # 볼륨 연결이 완료될 때까지 대기 (최대 60초)
    aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID" --region $AWS_REGION || { echo "FATAL: Volume attachment failed or timed out." >> /var/log/cloud-init-output.log; exit 1; }

    echo "Volume $VOLUME_ID successfully attached. Proceeding to mount $ACTUAL_DEVICE_NAME." >> /var/log/cloud-init-output.log
fi


# 3. 파일 시스템 확인 및 마운트 로직 (재연결/신규 생성 모두 /dev/nvme1n1 이름으로 처리)
if ls "$ACTUAL_DEVICE_NAME" 1> /dev/null 2>&1; then
    mkdir -p $MOUNT_POINT

    # 파일 시스템이 없으면 포맷 (최초 배포 시 새로 생성된 볼륨 포맷)
    if ! file -s $ACTUAL_DEVICE_NAME | grep -q "filesystem"; then
        echo "Volume has no filesystem. Formatting with xfs." >> /var/log/cloud-init-output.log
        mkfs -t xfs $ACTUAL_DEVICE_NAME
    fi

    # 마운트 실행
    mount $ACTUAL_DEVICE_NAME $MOUNT_POINT

    # 마운트 성공 후 하위 디렉토리 생성
    mkdir -p $MOUNT_POINT/grafana
    mkdir -p $MOUNT_POINT/prometheus

    # 권한 설정 (마운트 후 필수)
    chown -R 472:472 $MOUNT_POINT/grafana
    chown -R 65534:65534 $MOUNT_POINT/prometheus

    # fstab에 추가 (재부팅 시 자동 마운트)
    UUID=$(blkid -s UUID -o value $ACTUAL_DEVICE_NAME)
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
    fi

    echo "Volume $ACTUAL_DEVICE_NAME successfully mounted to $MOUNT_POINT with permissions set." >> /var/log/cloud-init-output.log
else
    echo "FATAL: Device $ACTUAL_DEVICE_NAME not found. Check Start Template device mapping." >> /var/log/cloud-init-output.log
    exit 1
fi

# 5. 사용되지 않는 새 EBS 볼륨 자동 삭제
echo "Checking for and deleting unused new volume..." >> /var/log/cloud-init-output.log

# 1. AWS가 시작 템플릿에 의해 새로 생성한 볼륨을 찾습니다.
#    - 태그가 'couponpop-monitoring-data'와 일치하고
#    - 상태가 'available' (스크립트가 재연결하지 않은) 상태여야 합니다.
UNUSED_VOLUME_ID=$(aws ec2 describe-volumes \
    --region $AWS_REGION \
    --filters Name=availability-zone,Values=$AZ \
                Name=tag:Name,Values=couponpop-monitoring-data \
                Name=status,Values=available \
    --query "Volumes[0].VolumeId" --output text)

if [ "$UNUSED_VOLUME_ID" != "None" ] && [ ! -z "$UNUSED_VOLUME_ID" ]; then
    echo "Found unused temporary volume: $UNUSED_VOLUME_ID. Deleting it..." >> /var/log/cloud-init-output.log

    # 2. 볼륨 삭제 (DeleteVolume)
    aws ec2 delete-volume --region $AWS_REGION --volume-id "$UNUSED_VOLUME_ID"

    echo "Unused volume $UNUSED_VOLUME_ID successfully deleted." >> /var/log/cloud-init-output.log
else
    echo "No unused volume found to delete." >> /var/log/cloud-init-output.log
fi

# 6. 설정 디렉토리 정의 및 AWS 리전 정의
CONFIG_DIR="/app/monitoring"
TEMP_CLONE_DIR="/tmp/prod-docker-infra"
mkdir -p $CONFIG_DIR
cd $CONFIG_DIR

# 7. Parameter Store에서 .env 파일 가져오기
echo "Fetching secrets from Parameter Store..." >> /var/log/cloud-init-output.log
ENV_FILE_PATH="$CONFIG_DIR/.env"
GIT_TOKEN=$(aws ssm get-parameter --name "/couponpop/prod/github-deploy-token" --with-decryption --region $AWS_REGION --query "Parameter.Value" --output text)
if [ -z "$GIT_TOKEN" ]; then exit 1; fi
declare -A PARAM_MAP
PARAM_MAP["/couponpop/prod/grafana-admin-pass"]="GRAFANA_ADMIN_PASSWORD"
PARAM_MAP["/couponpop/prod/db-host"]="DB_HOST"
PARAM_MAP["/couponpop/prod/db-host/master"]="DB_HOST_MASTER"
PARAM_MAP["/couponpop/prod/db-host/slave"]="DB_HOST_SLAVE"
PARAM_MAP["/couponpop/prod/db-port"]="DB_PORT"
PARAM_MAP["/couponpop/prod/mysqld-exporter-user"]="MYSQLD_EXPORTER_USERNAME"
PARAM_MAP["/couponpop/prod/mysqld-exporter-pass"]="MYSQLD_EXPORTER_PASSWORD"
rm -f $ENV_FILE_PATH
touch $ENV_FILE_PATH
for PARAM_NAME in "${!PARAM_MAP[@]}"; do
    VALUE=$(aws ssm get-parameter --name "$PARAM_NAME" --with-decryption --region $AWS_REGION --query "Parameter.Value" --output text)
    if [ $? -ne 0 ]; then exit 1; fi
    ENV_KEY=${PARAM_MAP[$PARAM_NAME]}
    echo "$ENV_KEY=$VALUE" >> $ENV_FILE_PATH
done
echo "PROMETHEUS_PORT=9090" >> $ENV_FILE_PATH
echo "GRAFANA_PORT=3000" >> $ENV_FILE_PATH
echo "MYSQLD_EXPORTER_PORT=9104" >> $ENV_FILE_PATH
echo "Successfully created .env file." >> /var/log/cloud-init-output.log


# 8. GitHub 리포지토리 Clone
GIT_REPO_URL="https://github.com/CouponPop/prod-docker-infra.git"
CLONE_URL="https://oauth2:${GIT_TOKEN}@${GIT_REPO_URL#https://}"
echo "Cloning config repository from GitHub..." >> /var/log/cloud-init-output.log
git clone $CLONE_URL $TEMP_CLONE_DIR
if [ $? -ne 0 ]; then exit 1; fi


# 9. 필요한 설정 파일들 최종 위치로 이동 및 권한 설정
echo "Moving config files and setting up targets directory..." >> /var/log/cloud-init-output.log
if [ ! -d "$TEMP_CLONE_DIR/monitoring/root" ]; then
    echo "FATAL: Monitoring config directory not found in repository." >> /var/log/cloud-init-output.log
    exit 1
fi
# 설정 파일 이동 (docker-compose.monitoring.yml, prometheus.yml 등)
cp -r $TEMP_CLONE_DIR/monitoring/root/. $CONFIG_DIR/

# targets 디렉토리 생성 및 ECS-Discovery 쓰기 권한 설정
mkdir -p $CONFIG_DIR/targets
# targets 디렉토리는 ECS-Discovery(nobody)가 파일을 생성하므로 nobody 소유권 부여
chown -R 65534:65534 $CONFIG_DIR/targets
echo "Targets directory created and ownership set to nobody (65534)." >> /var/log/cloud-init-output.log


# 10. Service Connect 프록시 필터링 규칙 삽입 (prometheus.yml 수정)
echo "Applying Prometheus Service Connect relabeling fix..." >> /var/log/cloud-init-output.log
PROM_CONFIG="$CONFIG_DIR/prometheus.yml"
if ! grep -q "relabel_configs" "$PROM_CONFIG"; then
    # 'metrics_path: /actuator/prometheus' 다음에 relabel_configs 삽입
    sed -i '/metrics_path: \/actuator\/prometheus/a\    relabel_configs:\n      - source_labels: [container_name]\n        regex: '"'ecs-service-connect-.*'"'\n        action: drop' "$PROM_CONFIG"
    echo "Relabeling config applied successfully." >> /var/log/cloud-init-output.log
else
    echo "Relabeling config might already exist or insertion failed. Check prometheus.yml manually." >> /var/log/cloud-init-output.log
fi


# 11. Docker Compose 실행 전 ECR 로그인
echo "Logging into ECR..." >> /var/log/cloud-init-output.log
# AWS CLI를 사용하여 ECR 로그인 토큰을 가져와 Docker에 전달합니다.
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin 802318301972.dkr.ecr.ap-northeast-2.amazonaws.com
if [ $? -ne 0 ]; then
    echo "FATAL: ECR login failed. Check IAM permissions for ecr:GetAuthorizationToken." >> /var/log/cloud-init-output.log
    exit 1
fi

# 12. Docker Compose 실행 직전 권한 최종 확보
# targets와 prometheus 데이터 디렉토리의 소유권을 강제로 nobody에게 부여
echo "Finalizing Prometheus/Grafana directory ownership before startup..." >> /var/log/cloud-init-output.log
chown -R 65534:65534 $CONFIG_DIR/targets
chown -R 65534:65534 /data/prometheus
chown -R 472:472 /data/grafana

# 13. Docker Compose 실행
echo "Starting Docker Compose stack..." >> /var/log/cloud-init-output.log
docker compose -f $CONFIG_DIR/docker-compose.monitoring.yml up -d


# 14. (ALB 등록) Target Group IP 등록
echo "Registering Private IP to Target Groups..." >> /var/log/cloud-init-output.log
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
for i in {1..15}; do
    PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
    if [ ! -z "$PRIVATE_IP" ]; then break; fi
    sleep 1
done
if [ -z "$PRIVATE_IP" ]; then exit 1; fi
GRAFANA_TG_ARN=$(aws ssm get-parameter --name "/couponpop/prod/grafana-tg-arn" --region $AWS_REGION --query "Parameter.Value" --output text)
PROMETHEUS_TG_ARN=$(aws ssm get-parameter --name "/couponpop/prod/prometheus-tg-arn" --region $AWS_REGION --query "Parameter.Value" --output text)
if [ -z "$GRAFANA_TG_ARN" ] || [ -z "$PROMETHEUS_TG_ARN" ]; then exit 1; fi
aws elbv2 register-targets --target-group-arn $GRAFANA_TG_ARN --targets Id=$PRIVATE_IP,Port=3000 --region $AWS_REGION
aws elbv2 register-targets --target-group-arn $PROMETHEUS_TG_ARN --targets Id=$PRIVATE_IP,Port=9090 --region $AWS_REGION
echo "Target registration complete for $PRIVATE_IP." >> /var/log/cloud-init-output.log

# 15. 임시 Clone 디렉토리 삭제
rm -rf $TEMP_CLONE_DIR
echo "Removed temporary clone directory." >> /var/log/cloud-init-output.log

echo "Monitoring Stack Auto-Deployment Complete." >> /var/log/cloud-init-output.log