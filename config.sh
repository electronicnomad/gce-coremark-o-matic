# config.sh - gce-coremark 사용자 설정
#
# 이 파일은 run_coremark.sh 에서 source 됩니다. 값을 수정한 뒤 ./run_coremark.sh 를 실행하세요.
# 빈 값으로 두면(예: PROJECT/ZONE) 컨트롤러 VM 의 메타데이터에서 자동으로 감지합니다.

# 측정할 머신 타입 목록. 원하는 GCE VM type 들을 나열하세요.
# (참고: c3 계열 등 최신 머신 타입은 특정 리전/존에서만 지원되므로 실행 리전에 맞춰 선택하세요)
MACHINE_TYPES=(
  "e2-standard-2"
  "n2-standard-2"
  "c2-standard-4"
)

# GCP 프로젝트 / zone. 비워두면 컨트롤러 VM 의 메타데이터 또는 gcloud 설정에서 자동 감지합니다.
PROJECT=""
ZONE=""

# VPC 네트워크 / 서브넷 (비워두면 기본 'default' VPC 사용)
# 커스텀 VPC를 사용하는 경우 해당 네트워크/서브넷 이름을 지정하세요.
NETWORK=""
SUBNET=""

# 비용 절감을 위한 Spot (Preemptible) 인스턴스 사용 여부 (true / false)
USE_SPOT=false

# 타깃 VM 의 부팅 이미지 (Debian 계열 권장 - apt 로 build-essential 설치)
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
BOOT_DISK_SIZE="20GB"

# 생성되는 타깃 VM 이름 접두어 (소문자/숫자/하이픈)
INSTANCE_NAME_PREFIX="cm-bench"

# 측정 모드: both | mt | st
#   both = 멀티스레드(전체 vCPU) + 싱글스레드 모두 측정
#   mt   = 멀티스레드만,  st = 싱글스레드만
COREMARK_MODE="both"

# 자동 캘리브레이션: 짧은 탐색 실행(PROBE_ITERATIONS) 으로 속도를 측정한 뒤
# 실제 실행 시간이 TARGET_SECONDS 이상이 되도록 반복 횟수를 자동 조정합니다.
# (CoreMark 규칙상 유효 결과는 실행시간 >= 10초)
PROBE_ITERATIONS=30000
TARGET_SECONDS=12

# 결과 파일 출력 디렉토리
RESULTS_DIR="./results"

# 벤치마크 완료 후 타깃 VM 자동 삭제 여부 (true 권장 - 비용 절감)
DELETE_AFTER=true

# 외부 IP 없이 IAP 터널로 SSH 접속할지 여부.
#   false = 타깃 VM 에 임시 외부 IP 를 부여하고 일반 SSH 접속 (기본)
#   true  = 외부 IP 없이 IAP 터널 사용 (IAP 방화벽/권한 사전 구성 필요)
USE_IAP=false

# 타깃 VM 이 SSH 준비될 때까지 대기 (최대 시도 횟수 x 간격(초))
SSH_MAX_TRIES=20
SSH_RETRY_INTERVAL=5
