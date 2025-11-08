#!/bin/bash
# ------------------------------------------------------------------
# [Final User Data Script] ECS Monitoring Stack Deployment (ECS Discovery)
# - Prometheus, Grafana, MySQL Exporter, Custom ECS Discovery
# ------------------------------------------------------------------

# 1. 루트 권한 획득
sudo -i

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


# 4. EBS 볼륨 자동 마운트 및 데이터 디렉토리 권한 설정
MOUNT_POINT="/data"
ROOT_DEV=$(df / | tail -1 | awk '{print $1}')
ROOT_DISK=$(lsblk -no pkname $ROOT_DEV)
DATA_VOL_NAME=$(lsblk -no NAME,TYPE | grep 'disk' | grep -v $ROOT_DISK | awk '{print $1}')

if [ -z "$DATA_VOL_NAME" ]; then
    echo "FATAL: Could not find attached data volume." >> /var/log/cloud-init-output.log
    exit 1
fi

DATA_VOL="/dev/${DATA_VOL_NAME}"
mkdir -p $MOUNT_POINT
if ! file -s $DATA_VOL | grep -q "filesystem"; then
    mkfs -t xfs $DATA_VOL
fi
mount $DATA_VOL $MOUNT_POINT
UUID=$(blkid -s UUID -o value $DATA_VOL)
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
fi

# Grafana 권한 설정 (UID 472)
mkdir -p $MOUNT_POINT/grafana
chown -R 472:472 $MOUNT_POINT/grafana
# Prometheus 권한 설정 (UID 65534 - nobody)
mkdir -p $MOUNT_POINT/prometheus
chown -R 65534:65534 $MOUNT_POINT/prometheus
echo "EBS Volume mounted and data directory permissions set." >> /var/log/cloud-init-output.log

# 5. 설정 디렉토리 정의 및 AWS 리전 정의
CONFIG_DIR="/app/monitoring"
TEMP_CLONE_DIR="/tmp/prod-docker-infra"
mkdir -p $CONFIG_DIR
cd $CONFIG_DIR
export AWS_REGION="ap-northeast-2"

# 6. Parameter Store에서 .env 파일 가져오기
echo "Fetching secrets from Parameter Store..." >> /var/log/cloud-init-output.log
ENV_FILE_PATH="$CONFIG_DIR/.env"
GIT_TOKEN=$(aws ssm get-parameter --name "/couponpop/prod/github-deploy-token" --with-decryption --region $AWS_REGION --query "Parameter.Value" --output text)
if [ -z "$GIT_TOKEN" ]; then exit 1; fi
declare -A PARAM_MAP
PARAM_MAP["/couponpop/prod/grafana-admin-pass"]="GRAFANA_ADMIN_PASSWORD"
PARAM_MAP["/couponpop/prod/db-host"]="DB_HOST"
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


# 7. GitHub 리포지토리 Clone
GIT_REPO_URL="https://github.com/CouponPop/prod-docker-infra.git"
CLONE_URL="https://oauth2:${GIT_TOKEN}@${GIT_REPO_URL#https://}"
echo "Cloning config repository from GitHub..." >> /var/log/cloud-init-output.log
git clone $CLONE_URL $TEMP_CLONE_DIR
if [ $? -ne 0 ]; then exit 1; fi


# 8. 필요한 설정 파일들 최종 위치로 이동 및 권한 설정
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


# 9. [CRITICAL FIX] Service Connect 프록시 필터링 규칙 삽입
# GitHub에서 가져온 prometheus.yml에 릴레이블링 규칙을 추가하여 프록시 대상 제거
echo "Applying Prometheus Service Connect relabeling fix..." >> /var/log/cloud-init-output.log
PROM_CONFIG="$CONFIG_DIR/prometheus.yml"
if ! grep -q "relabel_configs" "$PROM_CONFIG"; then
    # 'metrics_path: /actuator/prometheus' 다음에 relabel_configs 삽입
    sed -i '/metrics_path: \/actuator\/prometheus/a\    relabel_configs:\n      - source_labels: [container_name]\n        regex: '"'ecs-service-connect-.*'"'\n        action: drop' "$PROM_CONFIG"
    echo "Relabeling config applied successfully." >> /var/log/cloud-init-output.log
else
    echo "Relabeling config might already exist or insertion failed. Check prometheus.yml manually." >> /var/log/cloud-init-output.log
fi


# 10. Docker Compose 실행
echo "Starting Docker Compose stack..." >> /var/log/cloud-init-output.log
docker compose -f $CONFIG_DIR/docker-compose.monitoring.yml up -d


# 11. (ALB 등록) Target Group IP 등록
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

# 12. 임시 Clone 디렉토리 삭제
rm -rf $TEMP_CLONE_DIR
echo "Removed temporary clone directory." >> /var/log/cloud-init-output.log

echo "Monitoring Stack Auto-Deployment Complete." >> /var/log/cloud-init-output.log