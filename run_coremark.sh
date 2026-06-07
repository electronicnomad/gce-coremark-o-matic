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

cleanup() {
  if [ "${DELETE_AFTER}" = "true" ] && [ "${#CREATED_INSTANCES[@]}" -gt 0 ]; then
    err "정리: 남은 인스턴스 삭제 - ${CREATED_INSTANCES[*]}"
    for inst in "${CREATED_INSTANCES[@]}"; do
      gcloud compute instances delete "$inst" --project="$PROJECT" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

# ------------------------------------------------------------------ 사전 점검
command -v gcloud >/dev/null 2>&1 || { err "gcloud 를 찾을 수 없습니다."; exit 1; }
command -v curl   >/dev/null 2>&1 || { err "curl 을 찾을 수 없습니다."; exit 1; }

ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)"
[ -n "$ACTIVE_ACCT" ] || { err "활성화된 gcloud 인증 계정이 없습니다 (서비스 계정 확인)."; exit 1; }
log "인증 계정: ${ACTIVE_ACCT}"

# project / zone 자동 감지 (config 에서 비어있을 때)
[ -n "${PROJECT}" ] || PROJECT="$(get_metadata project/project-id)"
[ -n "${PROJECT}" ] || PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [ -z "${ZONE}" ]; then
  z="$(get_metadata instance/zone)"   # projects/NUM/zones/ZONE 형태
  ZONE="${z##*/}"
fi
[ -n "${PROJECT}" ] || { err "PROJECT 를 결정할 수 없습니다. config.sh 에 설정하세요."; exit 1; }
[ -n "${ZONE}" ]    || { err "ZONE 을 결정할 수 없습니다. config.sh 에 설정하세요."; exit 1; }
[ "${#MACHINE_TYPES[@]}" -gt 0 ] || { err "MACHINE_TYPES 가 비어 있습니다."; exit 1; }

log "프로젝트=${PROJECT}  zone=${ZONE}  이미지=${IMAGE_FAMILY}"
log "측정 대상 머신 타입: ${MACHINE_TYPES[*]}"

# SSH/SCP 공통 플래그 (IAP 사용 시 터널 경유)
SSH_EXTRA=()
[ "${USE_IAP}" = "true" ] && SSH_EXTRA=(--tunnel-through-iap)

# ------------------------------------------------------------------ 결과 파일 준비
RUN_ID="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${RESULTS_DIR}"
CSV="${RESULTS_DIR}/coremark-${RUN_ID}.csv"
JSON="${RESULTS_DIR}/coremark-${RUN_ID}.json"

echo "run_id,timestamp,machine_type,zone,image,vcpus,coremark_mt,coremark_per_core_mt,coremark_st,iter_mt,time_mt,iter_st,time_st,coremark_version,status" > "$CSV"
echo "[" > "$JSON"
JSON_FIRST=true

# ------------------------------------------------------------- 머신 타입별 측정
# 결과는 전역 변수 R_* 에 채워진다.
benchmark_machine_type() {
  local mt="$1"
  local inst="${INSTANCE_NAME_PREFIX}-${mt}-${RUN_ID##*-}"
  inst="$(echo "$inst" | tr '[:upper:]' '[:lower:]' | cut -c1-62)"

  R_VCPUS="" R_MT="" R_ST="" R_ITER_MT="" R_TIME_MT="" R_ITER_ST="" R_TIME_ST="" R_VER="1.01" R_STATUS=""

  log "[$mt] 인스턴스 생성: ${inst}"
  local create_args=(
    "$inst" --project="$PROJECT" --zone="$ZONE"
    --machine-type="$mt"
    --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT"
    --boot-disk-size="$BOOT_DISK_SIZE" --quiet
  )
  [ "${USE_IAP}" = "true" ] && create_args+=(--no-address)

  if ! gcloud compute instances create "${create_args[@]}" >/dev/null 2>&1; then
    err "[$mt] 인스턴스 생성 실패 (머신 타입/쿼터/zone 가용성 확인)."
    R_STATUS="CREATE_FAILED"; return 1
  fi
  CREATED_INSTANCES+=("$inst")

  # vCPU 수 조회
  R_VCPUS="$(gcloud compute instances describe "$inst" --project="$PROJECT" --zone="$ZONE" \
    --format='value(guestCpus)' 2>/dev/null)"
  [ -n "$R_VCPUS" ] || R_VCPUS="$(gcloud compute machine-types describe "$mt" --project="$PROJECT" --zone="$ZONE" \
    --format='value(guestCpus)' 2>/dev/null)"

  # SSH 준비 대기
  log "[$mt] SSH 준비 대기..."
  local ready=false i
  for ((i=1; i<=SSH_MAX_TRIES; i++)); do
    if gcloud compute ssh "$inst" --project="$PROJECT" --zone="$ZONE" "${SSH_EXTRA[@]}" \
         --command="true" --ssh-flag="-o ConnectTimeout=10" --quiet >/dev/null 2>&1; then
      ready=true; break
    fi
    sleep "${SSH_RETRY_INTERVAL}"
  done
  if [ "$ready" != true ]; then
    err "[$mt] SSH 접속 실패 (시간 초과)."
    R_STATUS="SSH_TIMEOUT"; delete_instance "$inst"; return 1
  fi

  # 원격 스크립트 전송 및 실행
  log "[$mt] CoreMark 실행 중 (모드=${COREMARK_MODE})..."
  if ! gcloud compute scp "${SCRIPT_DIR}/coremark_remote.sh" "${inst}:/tmp/coremark_remote.sh" \
        --project="$PROJECT" --zone="$ZONE" "${SSH_EXTRA[@]}" --quiet >/dev/null 2>&1; then
    err "[$mt] 스크립트 전송 실패."
    R_STATUS="SCP_FAILED"; delete_instance "$inst"; return 1
  fi

  local out
  out="$(gcloud compute ssh "$inst" --project="$PROJECT" --zone="$ZONE" "${SSH_EXTRA[@]}" --quiet \
        --command="bash /tmp/coremark_remote.sh ${PROBE_ITERATIONS} ${TARGET_SECONDS} ${COREMARK_MODE}" 2>/dev/null)"
  local rc=$?
  if [ $rc -ne 0 ]; then
    err "[$mt] CoreMark 실행 실패 (rc=$rc)."
    R_STATUS="BENCH_FAILED"; delete_instance "$inst"; return 1
  fi

  # 결과 파싱
  parse_val() { echo "$out" | grep "^$1=" | head -1 | cut -d= -f2-; }
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
  [ "${DELETE_AFTER}" = "true" ] || { log "[$inst] DELETE_AFTER=false → VM 유지"; return; }
  log "[$inst] 인스턴스 삭제..."
  gcloud compute instances delete "$inst" --project="$PROJECT" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
  # 추적 목록에서 제거
  local remaining=()
  for x in "${CREATED_INSTANCES[@]}"; do [ "$x" = "$inst" ] || remaining+=("$x"); done
  CREATED_INSTANCES=("${remaining[@]}")
}

# 빈 값을 "NA" 로, 숫자 나눗셈 도우미
na() { [ -n "$1" ] && echo "$1" || echo "NA"; }
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
  echo "${RUN_ID},${ts},${mt},${ZONE},${IMAGE_FAMILY},$(na "$R_VCPUS"),$(na "$R_MT"),${pc_mt},$(na "$R_ST"),$(na "$R_ITER_MT"),$(na "$R_TIME_MT"),$(na "$R_ITER_ST"),$(na "$R_TIME_ST"),${R_VER},${R_STATUS}" >> "$CSV"

  # JSON 객체
  [ "$JSON_FIRST" = true ] && JSON_FIRST=false || echo "," >> "$JSON"
  cat >> "$JSON" <<EOF
  {
    "run_id": "${RUN_ID}",
    "timestamp": "${ts}",
    "machine_type": "${mt}",
    "zone": "${ZONE}",
    "image": "${IMAGE_FAMILY}",
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

  log "[$mt] 결과: status=${R_STATUS} vcpus=$(na "$R_VCPUS") MT=$(na "$R_MT") ST=$(na "$R_ST")"
done

echo "" >> "$JSON"
echo "]" >> "$JSON"

# ------------------------------------------------------------------ 요약 출력
log "완료. 결과 파일:"
log "  CSV : ${CSV}"
log "  JSON: ${JSON}"
echo
column -t -s, "$CSV"
