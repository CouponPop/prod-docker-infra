#!/bin/bash
# ------------------------------------------------------------------
# [User Data Script] RabbitMQ Server (ASG + EBS Persistence)
# ------------------------------------------------------------------

# 1. 루트 권한 획득
sudo -i

# [!!] CRITICAL FIX: AWS Region 변수를 최상단에서 확보 및 export
set -e
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
if [ -z "$IMDS_TOKEN" ]; then
    echo "FATAL: Could not get IMDS token." >> /var/log/cloud-init-output.log
    exit 1
fi
export AZ=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
export AWS_REGION=$(echo $AZ | sed 's/[a-z]$//')
export INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
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
systemctl start docker
systemctl enable docker
echo "Docker service started and enabled." >> /var/log/cloud-init-output.log

# 4. 기존 EBS 볼륨 자동 재연결 및 마운트 로직 (NVMe 호환)
echo "Starting EBS volume auto-reconnection and mount (NVMe Compatible)..." >> /var/log/cloud-init-output.log
MOUNT_POINT="/data"
LOGICAL_DEVICE_NAME="/dev/sdf"
ACTUAL_DEVICE_NAME="/dev/nvme1n1"
EBS_TAG_NAME="couponpop-rabbitmq-data" # RabbitMQ 볼륨 태그

# 볼륨이 'available' 상태가 될 때까지 최대 5분(300초)간 대기
echo "Waiting for persistent volume (Tag: $EBS_TAG_NAME) to become available in $AZ..." >> /var/log/cloud-init-output.log
TARGET_VOLUME_ID=""
WAIT_SECONDS=300
ELAPSED=0
while [ $ELAPSED -lt $WAIT_SECONDS ]; do
    TARGET_VOLUME_ID=$(aws ec2 describe-volumes \
        --region $AWS_REGION \
        --filters Name=availability-zone,Values=$AZ \
                    Name=tag:Name,Values=$EBS_TAG_NAME \
                    Name=status,Values=available \
        --query "Volumes[0].VolumeId" --output text)
    if [ ! -z "$TARGET_VOLUME_ID" ] && [ "$TARGET_VOLUME_ID" != "None" ]; then
        echo "Found available persistent volume: $TARGET_VOLUME_ID" >> /var/log/cloud-init-output.log
        break
    fi
    echo "Volume not available yet. Waiting 20 seconds... ($ELAPSED / $WAIT_SECONDS)" >> /var/log/cloud-init-output.log
    sleep 20
    ELAPSED=$((ELAPSED + 20))
done

if [ -z "$TARGET_VOLUME_ID" ] || [ "$TARGET_VOLUME_ID" == "None" ]; then
    echo "FATAL: Persistent volume (Tag: $EBS_TAG_NAME) not found after $WAIT_SECONDS seconds." >> /var/log/cloud-init-output.log
    exit 1 # 볼륨을 못 찾으면 스크립트 실패
else
    VOLUME_ID=$TARGET_VOLUME_ID
    echo "Attempting attachment of $VOLUME_ID as $LOGICAL_DEVICE_NAME..." >> /var/log/cloud-init-output.log
    aws ec2 attach-volume \
        --region $AWS_REGION \
        --volume-id "$VOLUME_ID" \
        --instance-id "$INSTANCE_ID" \
        --device "$LOGICAL_DEVICE_NAME"
    aws ec2 wait volume-in-use --volume-ids "$VOLUME_ID" --region $AWS_REGION
    echo "Volume $VOLUME_ID successfully attached. Proceeding to mount $ACTUAL_DEVICE_NAME." >> /var/log/cloud-init-output.log
fi

# 3. 파일 시스템 확인 및 마운트 로직
echo "Waiting 10 seconds for device $ACTUAL_DEVICE_NAME to appear..." >> /var/log/cloud-init-output.log
sleep 10
if ls "$ACTUAL_DEVICE_NAME" 1> /dev/null 2>&1; then
    mkdir -p $MOUNT_POINT
    if ! file -s $ACTUAL_DEVICE_NAME | grep -q "filesystem"; then
        echo "Volume has no filesystem. Formatting with xfs." >> /var/log/cloud-init-output.log
        mkfs -t xfs $ACTUAL_DEVICE_NAME
    fi
    mount $ACTUAL_DEVICE_NAME $MOUNT_POINT

    # RabbitMQ 데이터 디렉토리 생성
    mkdir -p $MOUNT_POINT/rabbitmq-data

    # RabbitMQ 컨테이너 사용자(UID 999)에 맞게 권한 설정
    chown -R 999:999 $MOUNT_POINT/rabbitmq-data

    UUID=$(blkid -s UUID -o value $ACTUAL_DEVICE_NAME)
    if ! grep -q "$UUID" /etc/fstab; then
        echo "UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
    fi
    echo "Volume $ACTUAL_DEVICE_NAME successfully mounted to $MOUNT_POINT with permissions set." >> /var/log/cloud-init-output.log
else
    echo "FATAL: Device $ACTUAL_DEVICE_NAME not found. Check Start Template device mapping." >> /var/log/cloud-init-output.log
    exit 1
fi

# 5. 사용되지 않는 새 EBS 볼륨 자동 삭제 (시작 템플릿에서 볼륨을 생성하지 않도록 변경)
echo "Skipping deletion of unused EBS volume (ensure Launch Template does not create one)." >> /var/log/cloud-init-output.log

# 6. 설정 디렉토리 정의
CONFIG_DIR="/app/rabbitmq" # [수정]
TEMP_CLONE_DIR="/tmp/prod-docker-infra"
mkdir -p $CONFIG_DIR
cd $CONFIG_DIR

# 7. Parameter Store에서 .env 파일 가져오기
echo "Fetching secrets from Parameter Store for RabbitMQ..." >> /var/log/cloud-init-output.log
ENV_FILE_PATH="$CONFIG_DIR/.env"
GIT_TOKEN=$(aws ssm get-parameter --name "/couponpop/prod/github-deploy-token" --with-decryption --region $AWS_REGION --query "Parameter.Value" --output text)

# RabbitMQ에 필요한 변수 목록
declare -A PARAM_MAP
PARAM_MAP["/couponpop/prod/rabbitmq/HOSTNAME"]="RABBITMQ_HOSTNAME"
PARAM_MAP["/couponpop/prod/rabbitmq/DEFAULT_USER"]="RABBITMQ_DEFAULT_USER"
PARAM_MAP["/couponpop/prod/rabbitmq/DEFAULT_PASS"]="RABBITMQ_DEFAULT_PASS"
PARAM_MAP["/couponpop/prod/rabbitmq/ERLANG_COOKIE"]="RABBITMQ_ERLANG_COOKIE"

rm -f $ENV_FILE_PATH
touch $ENV_FILE_PATH
for PARAM_NAME in "${!PARAM_MAP[@]}"; do
    VALUE=$(aws ssm get-parameter --name "$PARAM_NAME" --with-decryption --region $AWS_REGION --query "Parameter.Value" --output text)
    ENV_KEY=${PARAM_MAP[$PARAM_NAME]}
    echo "$ENV_KEY=$VALUE" >> $ENV_FILE_PATH
done

# [수정] RabbitMQ 포트 변수 (기본값 설정)
echo "RABBITMQ_PORT=5672" >> $ENV_FILE_PATH
echo "RABBITMQ_MANAGEMENT_PORT=15672" >> $ENV_FILE_PATH
echo "RABBITMQ_PMETRICS=15692" >> $ENV_FILE_PATH
echo "Successfully created .env file for RabbitMQ." >> /var/log/cloud-init-output.log

# 8. GitHub 리포지토리 Clone
GIT_REPO_URL="https://github.com/CouponPop/prod-docker-infra.git"
CLONE_URL="https://oauth2:${GIT_TOKEN}@${GIT_REPO_URL#https://}"
echo "Cloning config repository from GitHub..." >> /var/log/cloud-init-output.log
git clone $CLONE_URL $TEMP_CLONE_DIR

# 9. 필요한 설정 파일들 최종 위치로 이동
echo "Moving RabbitMQ config files..." >> /var/log/cloud-init-output.log
# [수정] Git 리포지토리의 'rabbitmq/root' 디렉토리에서 설정을 복사한다고 가정
if [ ! -d "$TEMP_CLONE_DIR/rabbitmq/root" ]; then
    echo "FATAL: RabbitMQ config directory (rabbitmq/root) not found in repository." >> /var/log/cloud-init-output.log
    exit 1
fi
cp -r $TEMP_CLONE_DIR/rabbitmq/root/. $CONFIG_DIR/

# 10. Prometheus 설정 파일 수정 (RabbitMQ 서버에 불필요)
echo "Skipping Prometheus config modification." >> /var/log/cloud-init-output.log

# 11. Docker Compose 실행 전 ECR 로그인 (필요시)
echo "Logging into ECR (if needed)..." >> /var/log/cloud-init-output.log
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin 802318301972.dkr.ecr.ap-northeast-2.amazonaws.com

# 12. Docker Compose 실행 직전 권한 최종 확보
echo "Finalizing RabbitMQ directory ownership before startup..." >> /var/log/cloud-init-output.log
# (4번 섹션에서 이미 수행했지만, 안전을 위해 한 번 더)
chown -R 999:999 /data/rabbitmq-data

# 13. Docker Compose 실행
echo "Starting RabbitMQ Docker Compose stack..." >> /var/log/cloud-init-output.log
# docker-compose.rabbitmq.yml 파일을 실행한다고 가정
docker compose -f $CONFIG_DIR/docker-compose.rabbitmq.yml up -d

# 14. (ALB 등록) Target Group IP 등록
echo "Registering RabbitMQ Private IP to Target Groups..." >> /var/log/cloud-init-output.log
for i in {1..15}; do
    PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
    if [ ! -z "$PRIVATE_IP" ]; then break; fi
    sleep 1
done
if [ -z "$PRIVATE_IP" ]; then exit 1; fi

# RabbitMQ 타겟 그룹 ARN 가져오기
RABBITMQ_MGMT_TG_ARN=$(aws ssm get-parameter --name "/couponpop/prod/rabbitmq-mgmt-tg-arn" --region $AWS_REGION --query "Parameter.Value" --output text)
RABBITMQ_METRICS_TG_ARN=$(aws ssm get-parameter --name "/couponpop/prod/rabbitmq-metrics-tg-arn" --region $AWS_REGION --query "Parameter.Value" --output text)

# 관리자 UI (15672) 및 Prometheus 메트릭 (15692) 포트 등록
aws elbv2 register-targets --target-group-arn $RABBITMQ_MGMT_TG_ARN --targets Id=$PRIVATE_IP,Port=15672 --region $AWS_REGION
aws elbv2 register-targets --target-group-arn $RABBITMQ_METRICS_TG_ARN --targets Id=$PRIVATE_IP,Port=15692 --region $AWS_REGION
echo "RabbitMQ Target registration complete for $PRIVATE_IP." >> /var/log/cloud-init-output.log

# 15. 임시 Clone 디렉토리 삭제
rm -rf $TEMP_CLONE_DIR
echo "Removed temporary clone directory." >> /var/log/cloud-init-output.log

echo "RabbitMQ Server Auto-Deployment Complete." >> /var/log/cloud-init-output.log