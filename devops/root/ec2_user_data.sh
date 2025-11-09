#!/bin/bash
# ------------------------------------------------------------------
# [User Data Script] DevOps Toolchain (Jenkins, SonarQube, PostgreSQL) ASG Deployment
# ------------------------------------------------------------------

# 1. 루트 권한 획득
sudo -i

# AWS Region 변수를 최상단에서 확보 및 export
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
# Jenkinsfile 배포 스크립트에 필요한 jq 패키지 설치
apt-get install -y ca-certificates curl gnupg git xfsprogs jq

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

# ==========================================================
# 4GB 스왑 파일 생성 및 적용 (Jenkins 메모리 부족 대비)
# ==========================================================
if [ ! -f /swapfile ]; then
    echo "Creating 4GB swapfile..." >> /var/log/cloud-init-output.log
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    # 재부팅 시에도 스왑 유지
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swapfile created and enabled." >> /var/log/cloud-init-output.log
else
    echo "Swapfile already exists." >> /var/log/cloud-init-output.log
    swapon /swapfile # (혹시 비활성화 상태일 수 있으니)
fi
# ==========================================================

# 4. 기존 EBS 볼륨 자동 재연결 및 마운트 로직 (NVMe 호환)
echo "Starting EBS volume auto-reconnection and mount (NVMe Compatible)..." >> /var/log/cloud-init-output.log
# 변수 정의
MOUNT_POINT="/data"

# ASG 시작 템플릿에 지정된 논리적 장치 이름
LOGICAL_DEVICE_NAME="/dev/sdf"
# NVMe 기반 EC2 인스턴스에서 추가 볼륨이 실제로 나타나는 장치 이름
ACTUAL_DEVICE_NAME="/dev/nvme1n1"

# 1. 보존된 (tag:Name 일치) 볼륨을 검색합니다. (태그 이름 변경: couponpop-devops-data)
TARGET_VOLUME_ID=$(aws ec2 describe-volumes \
    --region $AWS_REGION \
    --filters Name=availability-zone,Values=$AZ \
                Name=tag:Name,Values=couponpop-devops-data \
    --query "Volumes[?State!='in-use' && State!='deleting' && State!='detaching'].[VolumeId]" --output text)

# 2. 보존된 볼륨이 발견되지 않았거나 (None), 쿼리 결과가 복수일 경우 첫 번째 볼륨만 사용
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

    # 마운트 성공 후 하위 디렉토리 생성 (DevOps 툴체인 데이터 경로)
    echo "Creating persistent directories for DevOps tools..." >> /var/log/cloud-init-output.log
    mkdir -p $MOUNT_POINT/jenkins_home
    mkdir -p $MOUNT_POINT/sonarqube/data
    mkdir -p $MOUNT_POINT/sonarqube/extensions
    mkdir -p $MOUNT_POINT/sonarqube/logs
    mkdir -p $MOUNT_POINT/postgres/data

    # 권한 설정 (마운트 후 필수)
    # Jenkins 및 SonarQube 컨테이너의 내부 사용자 ID(UID) 1000을 가정하고 설정
    chown -R 1000:1000 $MOUNT_POINT/jenkins_home
    chown -R 1000:1000 $MOUNT_POINT/sonarqube
    # PostgreSQL 컨테이너의 내부 사용자 ID(UID) 999를 가정하고 설정 (Postgres 기본)
    chown -R 999:999 $MOUNT_POINT/postgres/data

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

# 6. 설정 디렉토리 정의 및 AWS 리전 정의
CONFIG_DIR="/app/devops" # 디렉토리 이름 변경
TEMP_CLONE_DIR="/tmp/prod-docker-infra"
mkdir -p $CONFIG_DIR
cd $CONFIG_DIR

# 7. Parameter Store에서 .env 파일 가져오기 (DevOps 환경 변수)
echo "Fetching secrets from Parameter Store..." >> /var/log/cloud-init-output.log
ENV_FILE_PATH="$CONFIG_DIR/.env"
GIT_TOKEN=$(aws ssm get-parameter --name "/couponpop/prod/github-deploy-token" --with-decryption --region $AWS_REGION --query "Parameter.Value" --output text)
if [ -z "$GIT_TOKEN" ]; then exit 1; fi
declare -A PARAM_MAP
# SonarQube DB 인증 정보 및 기타 환경 변수
PARAM_MAP["/couponpop/prod/sonarqube-db-url"]="SONARQUBE_JDBC_URL"
PARAM_MAP["/couponpop/prod/sonarqube-db-user"]="SONARQUBE_JDBC_USERNAME"
PARAM_MAP["/couponpop/prod/sonarqube-db-pass"]="SONARQUBE_JDBC_PASSWORD"
PARAM_MAP["/couponpop/prod/postgres-db"]="POSTGRES_DB"
PARAM_MAP["/couponpop/prod/postgres-user"]="POSTGRES_USER"
PARAM_MAP["/couponpop/prod/postgres-pass"]="POSTGRES_PASSWORD"

rm -f $ENV_FILE_PATH
touch $ENV_FILE_PATH
for PARAM_NAME in "${!PARAM_MAP[@]}"; do
    VALUE=$(aws ssm get-parameter --name "$PARAM_NAME" --with-decryption --region $AWS_REGION --query "Parameter.Value" --output text)
    if [ $? -ne 0 ]; then exit 1; fi
    ENV_KEY=${PARAM_MAP[$PARAM_NAME]}
    echo "$ENV_KEY=$VALUE" >> $ENV_FILE_PATH
done
echo "JENKINS_PORT=8080" >> $ENV_FILE_PATH
echo "SONARQUBE_PORT=9000" >> $ENV_FILE_PATH
echo "Successfully created .env file." >> /var/log/cloud-init-output.log


# 8. GitHub 리포지토리 Clone (URL 유지)
GIT_REPO_URL="https://github.com/CouponPop/prod-docker-infra.git"
CLONE_URL="https://oauth2:${GIT_TOKEN}@${GIT_REPO_URL#https://}"
echo "Cloning config repository from GitHub..." >> /var/log/cloud-init-output.log
git clone $CLONE_URL $TEMP_CLONE_DIR
if [ $? -ne 0 ]; then exit 1; fi


# 9. 필요한 설정 파일들 최종 위치로 이동 및 권한 설정
echo "Moving config files and setting up target directory..." >> /var/log/cloud-init-output.log
# 리포지토리 내 경로를 devops/root로 가정하고 수정
if [ ! -d "$TEMP_CLONE_DIR/devops/root" ]; then
    echo "FATAL: DevOps config directory not found in repository. Using monitoring as fallback." >> /var/log/cloud-init-output.log
    # 만약 devops 디렉토리가 없다면, monitoring 디렉토리를 사용하는 로직이 추가로 필요할 수 있으나, 여기서는 devops로 명확히 수정
    exit 1
fi
# 설정 파일 이동 (docker-compose.toolchain.yml 등)
cp -r $TEMP_CLONE_DIR/devops/root/. $CONFIG_DIR/


# 10. (불필요) Service Connect 프록시 필터링 규칙 삽입 (DevOps 스택에는 해당 없음)
echo "Skipping Service Connect Prometheus relabeling fix (DevOps stack)." >> /var/log/cloud-init-output.log


# 11. Docker Compose 실행 전 ECR 로그인
echo "Logging into ECR..." >> /var/log/cloud-init-output.log
# AWS CLI를 사용하여 ECR 로그인 토큰을 가져와 Docker에 전달합니다. (ECR 주소 유지)
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin 802318301972.dkr.ecr.ap-northeast-2.amazonaws.com
if [ $? -ne 0 ]; then
    echo "FATAL: ECR login failed. Check IAM permissions for ecr:GetAuthorizationToken." >> /var/log/cloud-init-output.log
    exit 1
fi

# 12. Docker Compose 실행 직전 권한 최종 확보
# 컨테이너 사용자 ID에 맞게 최종적으로 디렉토리 소유권 재설정
echo "Finalizing DevOps directory ownership before startup..." >> /var/log/cloud-init-output.log
chown -R root:root /data/jenkins_home
chown -R 1000:1000 /data/sonarqube
chown -R 999:999 /data/postgres/data


# 13. Docker Compose 실행 (파일 이름 변경)
echo "Starting Docker Compose stack..." >> /var/log/cloud-init-output.log
docker compose -f $CONFIG_DIR/docker-compose.toolchain.yml up -d


# 14. (ALB 등록) Target Group IP 등록 (Jenkins, SonarQube Target Group)
echo "Registering Private IP to Target Groups..." >> /var/log/cloud-init-output.log
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
for i in {1..15}; do
    PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
    if [ ! -z "$PRIVATE_IP" ]; then break; fi
    sleep 1
done
if [ -z "$PRIVATE_IP" ]; then exit 1; fi

# Jenkins 및 SonarQube Target Group ARN 가져오기 (Parameter Store에서 ARN 키 변경)
JENKINS_TG_ARN=$(aws ssm get-parameter --name "/couponpop/prod/jenkins-tg-arn" --region $AWS_REGION --query "Parameter.Value" --output text)
SONARQUBE_TG_ARN=$(aws ssm get-parameter --name "/couponpop/prod/sonarqube-tg-arn" --region $AWS_REGION --query "Parameter.Value" --output text)
if [ -z "$JENKINS_TG_ARN" ] || [ -z "$SONARQUBE_TG_ARN" ]; then exit 1; fi

# Jenkins (8080) Target 등록
aws elbv2 register-targets --target-group-arn $JENKINS_TG_ARN --targets Id=$PRIVATE_IP,Port=8080 --region $AWS_REGION
# SonarQube (9000) Target 등록
aws elbv2 register-targets --target-group-arn $SONARQUBE_TG_ARN --targets Id=$PRIVATE_IP,Port=9000 --region $AWS_REGION
echo "Target registration complete for $PRIVATE_IP." >> /var/log/cloud-init-output.log

# 15. 임시 Clone 디렉토리 삭제
rm -rf $TEMP_CLONE_DIR
echo "Removed temporary clone directory." >> /var/log/cloud-init-output.log

echo "DevOps Toolchain Auto-Deployment Complete." >> /var/log/cloud-init-output.log