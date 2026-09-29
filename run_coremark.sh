#!/usr/bin/env bash
#
# run_coremark.sh - GCE VM 성능을 CoreMark 로 측정하는 오케스트레이터.
#
# 서비스 계정이 부여된 GCE 컨트롤러 VM 에서 실행합니다. config.sh 에 정의된
# 머신 타입마다 임시 VM 을 생성하고, SSH 로 CoreMark 벤치마크를 실행한 뒤
# 결과를 CSV / JSON 파일로 기록하고 VM 을 삭제합니다.
#
# 사용법: ./run_coremark.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

log()  { echo -e "[$(date +%H:%M:%S)] $*"; }
err()  { echo -e "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

get_metadata() {
  curl -s -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null
}

# 생성했지만 아직 삭제하지 않은 인스턴스 추적 (오류 시 정리)
declare -a CREATED_INSTANCES=()

JSON_CLOSED=false

cleanup() {
  # 스크립트 중단 시 미완성 JSON 파일 유효성 보장
  if [ "${JSON_CLOSED:-true}" = false ] && [ -f "${JSON:-}" ]; then
    # 마지막 항목의 trailing comma 제거 후 배열 닫기
    if [ "$IS_DARWIN" = true ]; then
      sed -i '' -e '$s/,$//' "$JSON" 2>/dev/null || true
    else
      sed -i -e '$s/,$//' "$JSON" 2>/dev/null || true
    fi
    echo "" >> "$JSON"
    echo "]" >> "$JSON"
    JSON_CLOSED=true
  fi

  if [ "${DELETE_AFTER}" = "true" ] && [ "${#CREATED_INSTANCES[@]}" -gt 0 ]; then
    err "Cleanup: deleting remaining instances - ${CREATED_INSTANCES[*]}"
    for inst in "${CREATED_INSTANCES[@]+"${CREATED_INSTANCES[@]}"}"; do
      gcloud compute instances delete "$inst" --project="$PROJECT" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ 사전 점검 및 환경 감지
command -v gcloud >/dev/null 2>&1 || { err "gcloud command not found."; exit 1; }
command -v curl   >/dev/null 2>&1 || { err "curl command not found."; exit 1; }

# OS 및 Bash 버전 감지
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
BASH_MINOR="${BASH_VERSINFO[1]:-0}"
BASH_PATCH="${BASH_VERSINFO[2]:-0}"
BASH_VER="${BASH_MAJOR}.${BASH_MINOR}.${BASH_PATCH}"

IS_DARWIN=false
IS_LINUX=false
case "$OS_TYPE" in
  darwin*) IS_DARWIN=true ;;
  linux*)  IS_LINUX=true ;;
  *)       log "Warning: Unverified operating system (${OS_TYPE}). Continuing anyway." ;;
esac

# GCE 환경 여부 확인 (Linux 환경에서 메타데이터 서버 응답 확인)
IS_GCE=false
if [ "$IS_LINUX" = true ]; then
  if curl --connect-timeout 1 -s -m 1 -H "Metadata-Flavor: Google" \
       "http://metadata.google.internal/computeMetadata/v1/instance/id" >/dev/null 2>&1; then
    IS_GCE=true
  fi
fi

ENV_DESC="OS=${OS_TYPE} / Bash=${BASH_VER}"
if [ "$IS_GCE" = true ]; then
  ENV_DESC="${ENV_DESC} (GCE controller VM)"
else
  ENV_DESC="${ENV_DESC} (local workstation)"
fi
log "Environment: ${ENV_DESC}"

ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)"
[ -n "$ACTIVE_ACCT" ] || { err "No active gcloud authentication found (check account or service account)."; exit 1; }
log "Active account: ${ACTIVE_ACCT}"

# project / zone 자동 감지 (config 에서 비어있을 때)
if [ "$IS_GCE" = true ]; then
  [ -n "${PROJECT}" ] || PROJECT="$(get_metadata project/project-id)"
  if [ -z "${ZONE}" ]; then
    z="$(get_metadata instance/zone)"   # projects/NUM/zones/ZONE 형태
    [ -n "$z" ] && ZONE="${z##*/}"
  fi
fi
# 로컬 워크스테이션(macOS 포함)이거나 메타데이터에서 미조회 시 gcloud config 로 fallback
[ -n "${PROJECT}" ] || PROJECT="$(gcloud config get-value project 2>/dev/null)"
[ -n "${ZONE}" ]    || ZONE="$(gcloud config get-value compute/zone 2>/dev/null)"

[ -n "${PROJECT}" ] || { err "Unable to determine PROJECT. Please specify it in config.sh."; exit 1; }
[ -n "${ZONE}" ]    || { err "Unable to determine ZONE. Please specify it in config.sh."; exit 1; }
[ "${#MACHINE_TYPES[@]}" -gt 0 ] || { err "MACHINE_TYPES is empty."; exit 1; }

log "Project=${PROJECT}  Zone=${ZONE}  Network=${NETWORK:-default}  Image=${IMAGE_FAMILY}"
log "Target machine types: ${MACHINE_TYPES[*]}"

# 타깃 VPC 방화벽 사전 점검 (SSH 포트 개방 여부 확인)
TARGET_NET="${NETWORK:-default}"
fw_rules="$(gcloud compute firewall-rules list --project="$PROJECT" \
  --filter="network:${TARGET_NET}" --format="value(allowed)" 2>/dev/null || true)"
if ! echo "$fw_rules" | grep -Eq "('22'|'all')"; then
  err "Warning: No inbound firewall rule allowing SSH (tcp:22) found in network '${TARGET_NET}'!"
  err "         SSH connection may time out. Please check the NETWORK setting in config.sh."
fi

# SSH/SCP 플래그 설정
SSH_EXTRA=()
SCP_EXTRA=()
if [ "${USE_IAP}" = "true" ]; then
  SSH_EXTRA=(--tunnel-through-iap)
  SCP_EXTRA=(--tunnel-through-iap)
else
  # 관리형 네트워크 환경이나 로컬 SSH config의 ProxyCommand 간섭을 방지하기 위해 ProxyCommand 비활성화
  SSH_EXTRA=(--ssh-flag="-o ProxyCommand=none")
  SCP_EXTRA=(--scp-flag="-o ProxyCommand=none")
fi

# CoreMark 소스 아카이브 로컬 캐싱 (컨트롤러에서 사전 다운로드 후 타깃 VM에 SCP 전송)
SRC_TAR="v1.01.tar.gz"
SRC_URL="https://github.com/eembc/coremark/archive/${SRC_TAR}"
LOCAL_SRC="${SCRIPT_DIR}/${SRC_TAR}"
if [ ! -f "${LOCAL_SRC}" ]; then
  log "Downloading CoreMark source archive (${LOCAL_SRC})..."
  if curl -sSL -f "$SRC_URL" -o "${LOCAL_SRC}"; then
    log "CoreMark source archive cached."
  else
    log "Warning: Local download failed. The target VM will attempt to download it directly."
    rm -f "${LOCAL_SRC}"
  fi
fi

# ------------------------------------------------------------------ 결과 파일 준비
RUN_ID="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${RESULTS_DIR}"
CSV="${RESULTS_DIR}/coremark-${RUN_ID}.csv"
JSON="${RESULTS_DIR}/coremark-${RUN_ID}.json"

echo "run_id,timestamp,machine_type,zone,image,arch,cpu_platform,cpu_model,vcpus,coremark_mt,coremark_per_core_mt,coremark_st,iter_mt,time_mt,iter_st,time_st,coremark_version,status" > "$CSV"
echo "[" > "$JSON"
JSON_FIRST=true

# ------------------------------------------------------------- 머신 타입별 측정
# 결과는 전역 변수 R_* 에 채워진다.
benchmark_machine_type() {
  local mt="$1"
  local inst="${INSTANCE_NAME_PREFIX}-${mt}-${RUN_ID##*-}"
  inst="$(echo "$inst" | tr '[:upper:]' '[:lower:]' | cut -c1-62)"
  inst="${inst%-}"

  R_ARCH="" R_CPU_PLATFORM="" R_CPU_MODEL=""
  R_VCPUS="" R_MT="" R_ST="" R_ITER_MT="" R_TIME_MT="" R_ITER_ST="" R_TIME_ST="" R_VER="1.01" R_STATUS=""

  log "[$mt] Creating instance: ${inst}"
  local create_args=(
    "$inst" --project="$PROJECT" --zone="$ZONE"
    --machine-type="$mt"
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT"
    --boot-disk-size="$BOOT_DISK_SIZE"
    --no-service-account --no-scopes
    --quiet
  )
  [ "${USE_IAP}" = "true" ] && create_args+=(--no-address)
  [ -n "${NETWORK:-}" ] && create_args+=(--network="$NETWORK")
  [ -n "${SUBNET:-}" ] && create_args+=(--subnet="$SUBNET")
  [ "${USE_SPOT:-false}" = "true" ] && create_args+=(--provisioning-model=SPOT --instance-termination-action=DELETE)

  local create_err
  if ! create_err="$(gcloud compute instances create "${create_args[@]}" 2>&1 >/dev/null)"; then
    err "[$mt] Failed to create instance (check machine type, quota, or zone availability):\n${create_err}"
    R_STATUS="CREATE_FAILED"; return 1
  fi
  CREATED_INSTANCES+=("$inst")

  # vCPU 수 및 cpuPlatform 조회
  R_VCPUS="$(gcloud compute instances describe "$inst" --project="$PROJECT" --zone="$ZONE" \
    --format='value(guestCpus)' 2>/dev/null)"
  [ -n "$R_VCPUS" ] || R_VCPUS="$(gcloud compute machine-types describe "$mt" --project="$PROJECT" --zone="$ZONE" \
    --format='value(guestCpus)' 2>/dev/null)"

  R_CPU_PLATFORM="$(gcloud compute instances describe "$inst" --project="$PROJECT" --zone="$ZONE" \
    --format='value(cpuPlatform)' 2>/dev/null || echo "Unknown")"

  # SSH 준비 대기
  log "[$mt] Waiting for SSH to become ready..."
  local ready=false i last_ssh_err=""
  for ((i=1; i<=SSH_MAX_TRIES; i++)); do
    if last_ssh_err="$(gcloud compute ssh "$inst" --project="$PROJECT" --zone="$ZONE" "${SSH_EXTRA[@]+"${SSH_EXTRA[@]}"}" \
         --command="true" --ssh-flag="-o ConnectTimeout=10" --quiet 2>&1)"; then
      ready=true; break
    fi
    sleep "${SSH_RETRY_INTERVAL}"
  done
  if [ "$ready" != true ]; then
    err "[$mt] SSH connection timed out."
    [ -n "$last_ssh_err" ] && err "Last SSH error:\n${last_ssh_err}"
    R_STATUS="SSH_TIMEOUT"; delete_instance "$inst"; return 1
  fi

  # 원격 스크립트 및 소스 전송
  log "[$mt] Transferring CoreMark source and scripts..."
  local scp_files=("${SCRIPT_DIR}/coremark_remote.sh")
  [ -f "${LOCAL_SRC}" ] && scp_files+=("${LOCAL_SRC}")

  if ! gcloud compute scp "${scp_files[@]}" "${inst}:/tmp/" \
        --project="$PROJECT" --zone="$ZONE" "${SCP_EXTRA[@]+"${SCP_EXTRA[@]}"}" --quiet; then
    err "[$mt] File transfer failed (SCP)."
    R_STATUS="SCP_FAILED"; delete_instance "$inst"; return 1
  fi

  local out
  out="$(gcloud compute ssh "$inst" --project="$PROJECT" --zone="$ZONE" "${SSH_EXTRA[@]+"${SSH_EXTRA[@]}"}" --quiet \
        --command="bash /tmp/coremark_remote.sh ${PROBE_ITERATIONS} ${TARGET_SECONDS} ${COREMARK_MODE}")"
  local rc=$?
  if [ $rc -ne 0 ]; then
    err "[$mt] CoreMark execution failed (rc=$rc)."
    R_STATUS="BENCH_FAILED"; delete_instance "$inst"; return 1
  fi

  # 결과 파싱
  parse_val() { echo "$out" | grep "^$1=" | head -1 | cut -d= -f2-; }
  R_ARCH="$(parse_val ARCH)"
  R_CPU_MODEL="$(parse_val CPU_MODEL)"
  R_MT="$(parse_val COREMARK_MT)";       R_ST="$(parse_val COREMARK_ST)"
  R_ITER_MT="$(parse_val COREMARK_ITER_MT)"; R_TIME_MT="$(parse_val COREMARK_TIME_MT)"
  R_ITER_ST="$(parse_val COREMARK_ITER_ST)"; R_TIME_ST="$(parse_val COREMARK_TIME_ST)"
  R_VER="$(parse_val COREMARK_VERSION)"; [ -n "$R_VER" ] || R_VER="1.01"
  R_STATUS="SUCCESS"

  delete_instance "$inst"
  return 0
}

delete_instance() {
  local inst="$1"
  [ "${DELETE_AFTER}" = "true" ] || { log "[$inst] DELETE_AFTER=false -> keeping VM"; return; }
  log "[$inst] Deleting instance..."
  gcloud compute instances delete "$inst" --project="$PROJECT" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
  # 추적 목록에서 제거
  local remaining=()
  for x in "${CREATED_INSTANCES[@]+"${CREATED_INSTANCES[@]}"}"; do [ "$x" = "$inst" ] || remaining+=("$x"); done
  if [ "${#remaining[@]}" -gt 0 ]; then
    CREATED_INSTANCES=("${remaining[@]}")
  else
    CREATED_INSTANCES=()
  fi
}

# 빈 값을 "NA" 로, 숫자 나눗셈 도우미, CSV/JSON 이스케이프 도우미
na() { [ -n "$1" ] && echo "$1" || echo "NA"; }
csv_str() { echo "\"$(echo "$1" | sed 's/"/""/g')\""; }
json_str() { [ -n "$1" ] && echo "\"$(echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')\"" || echo null; }
per_core() {
  local total="$1" cpus="$2"
  if [ -n "$total" ] && [ -n "$cpus" ] && [ "$cpus" -gt 0 ] 2>/dev/null; then
    awk -v t="$total" -v c="$cpus" 'BEGIN{ printf "%.2f", t/c }'
  else
    echo "NA"
  fi
}

# ------------------------------------------------------------------ 메인 루프
for mt in "${MACHINE_TYPES[@]}"; do
  benchmark_machine_type "$mt"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  pc_mt="$(per_core "$R_MT" "$R_VCPUS")"

  # CSV 한 줄
  echo "${RUN_ID},${ts},${mt},${ZONE},${IMAGE_FAMILY},$(na "$R_ARCH"),$(csv_str "$R_CPU_PLATFORM"),$(csv_str "$R_CPU_MODEL"),$(na "$R_VCPUS"),$(na "$R_MT"),${pc_mt},$(na "$R_ST"),$(na "$R_ITER_MT"),$(na "$R_TIME_MT"),$(na "$R_ITER_ST"),$(na "$R_TIME_ST"),${R_VER},${R_STATUS}" >> "$CSV"

  # JSON 객체
  [ "$JSON_FIRST" = true ] && JSON_FIRST=false || echo "," >> "$JSON"
  cat >> "$JSON" <<EOF
  {
    "run_id": "${RUN_ID}",
    "timestamp": "${ts}",
    "machine_type": "${mt}",
    "zone": "${ZONE}",
    "image": "${IMAGE_FAMILY}",
    "arch": $(json_str "$R_ARCH"),
    "cpu_platform": $(json_str "$R_CPU_PLATFORM"),
    "cpu_model": $(json_str "$R_CPU_MODEL"),
    "vcpus": $( [ -n "$R_VCPUS" ] && echo "$R_VCPUS" || echo null ),
    "coremark_mt": $( [ -n "$R_MT" ] && echo "$R_MT" || echo null ),
    "coremark_per_core_mt": $( [ "$pc_mt" != "NA" ] && echo "$pc_mt" || echo null ),
    "coremark_st": $( [ -n "$R_ST" ] && echo "$R_ST" || echo null ),
    "iter_mt": $( [ -n "$R_ITER_MT" ] && echo "$R_ITER_MT" || echo null ),
    "time_mt": $( [ -n "$R_TIME_MT" ] && echo "$R_TIME_MT" || echo null ),
    "iter_st": $( [ -n "$R_ITER_ST" ] && echo "$R_ITER_ST" || echo null ),
    "time_st": $( [ -n "$R_TIME_ST" ] && echo "$R_TIME_ST" || echo null ),
    "coremark_version": "${R_VER}",
    "status": "${R_STATUS}"
  }
EOF

  log "[$mt] Result: status=${R_STATUS} cpu=${R_CPU_PLATFORM:-NA} vcpus=$(na "$R_VCPUS") MT=$(na "$R_MT") ST=$(na "$R_ST")"
done

echo "" >> "$JSON"
echo "]" >> "$JSON"
JSON_CLOSED=true

# ------------------------------------------------------------------ 요약 출력
log "Benchmark completed. Output files:"
log "  CSV : ${CSV}"
log "  JSON: ${JSON}"
echo
if command -v column >/dev/null 2>&1; then
  column -t -s, "$CSV"
else
  cat "$CSV"
fi
