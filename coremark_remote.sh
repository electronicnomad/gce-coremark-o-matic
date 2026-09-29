#!/usr/bin/env bash
#
# coremark_remote.sh - 타깃 GCE VM 안에서 실행되는 CoreMark 벤치마크 스크립트.
# run_coremark.sh 가 이 파일을 타깃 VM 으로 복사한 뒤 SSH 로 실행합니다.
#
# 사용법: bash coremark_remote.sh <PROBE_ITERATIONS> <TARGET_SECONDS> <MODE>
#   MODE = both | mt | st
#
# 표준출력으로 KEY=VALUE 형태의 파싱 가능한 결과를 출력하고,
# 진행 로그는 표준에러로 출력합니다.
set -euo pipefail

PROBE_ITER="${1:-30000}"
TARGET_SECS="${2:-12}"
MODE="${3:-both}"

WORK="/tmp/coremark-bench"
SRC_TAR="v1.01.tar.gz"
SRC_URL="https://github.com/eembc/coremark/archive/${SRC_TAR}"
SRC_DIR="coremark-1.01"

log() { echo "[remote] $*" >&2; }

# --- 빌드 의존성 설치 (gcc/make/wget) ---
if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1; then
  log "Installing build dependencies (build-essential, wget)..."
  export DEBIAN_FRONTEND=noninteractive
  sudo apt-get -o DPkg::Lock::Timeout=120 update -qq
  sudo apt-get -o DPkg::Lock::Timeout=120 install -y -qq build-essential wget >/dev/null
fi

# --- CoreMark v1.01 다운로드 및 압축 해제 ---
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
if [ -f "/tmp/${SRC_TAR}" ]; then
  log "Using uploaded CoreMark v1.01 archive..."
  cp "/tmp/${SRC_TAR}" "$SRC_TAR"
else
  log "Downloading CoreMark v1.01..."
  wget -q "$SRC_URL" -O "$SRC_TAR"
fi
tar xzf "$SRC_TAR"
cd "$SRC_DIR"

# 멀티스레드(pthread) 빌드를 위해 링크 단계에 -lpthread 추가
echo 'LFLAGS_END += -lpthread' >> linux64/core_portme.mak

NPROC="$(nproc)"
ARCH="$(uname -m)"
CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[ \t]*//' || true)"
[ -n "$CPU_MODEL" ] || CPU_MODEL="$(lscpu 2>/dev/null | grep -m1 'Model name:' | cut -d: -f2- | sed 's/^[ \t]*//' || echo "$ARCH")"

echo "NPROC=${NPROC}"
echo "ARCH=${ARCH}"
echo "CPU_MODEL=${CPU_MODEL}"
echo "COREMARK_VERSION=1.01"

# run_mode <extra_xcflags>
#   주어진 컴파일 플래그로 CoreMark 를 빌드/실행한다. 짧은 탐색(probe) 실행으로
#   실행시간을 측정한 뒤, TARGET_SECS 미만이면 반복 횟수를 키워 재실행한다.
#   성공 시 "score time iterations" 한 줄을 표준출력으로 반환한다.
run_mode() {
  local extra_flags="$1"
  local tsecs iters score

  # 1) probe 실행
  make -s clean PORT_DIR=linux64 >/dev/null 2>&1 || true
  make -s PORT_DIR=linux64 ITERATIONS="$PROBE_ITER" XCFLAGS="$extra_flags" >/dev/null 2>&1
  tsecs="$(grep 'Total time' run1.log | awk '{print $4}')"

  # 2) 목표 시간에 맞춰 반복 횟수 산정 후 필요시 재실행
  iters="$(awk -v it="$PROBE_ITER" -v t="$tsecs" -v tgt="$TARGET_SECS" \
    'BEGIN{ if (t<=0) t=0.001; n=int(it*tgt/t)+1; if (n<it) n=it; print n }')"
  if awk -v t="$tsecs" -v tgt="$TARGET_SECS" 'BEGIN{ exit !(t < tgt) }'; then
    make -s clean PORT_DIR=linux64 >/dev/null 2>&1 || true
    make -s PORT_DIR=linux64 ITERATIONS="$iters" XCFLAGS="$extra_flags" >/dev/null 2>&1
  fi

  # 3) 검증 및 결과 파싱
  if ! grep -q "Correct operation validated" run1.log; then
    log "Validation failed (flags: '${extra_flags}'). run1.log:"; cat run1.log >&2
    return 1
  fi
  score="$(grep 'CoreMark 1.0' run1.log | head -1 | awk -F: '{print $2}' | awk '{print $1}')"
  tsecs="$(grep 'Total time' run1.log | awk '{print $4}')"
  iters="$(grep '^Iterations ' run1.log | head -1 | awk '{print $3}')"
  echo "${score} ${tsecs} ${iters}"
}

if [ "$MODE" = "both" ] || [ "$MODE" = "st" ]; then
  log "Running single-thread benchmark..."
  out="$(run_mode "")" || exit 1
  read -r st_score st_time st_iter <<<"$out"
  echo "COREMARK_ST=${st_score}"
  echo "COREMARK_TIME_ST=${st_time}"
  echo "COREMARK_ITER_ST=${st_iter}"
fi

if [ "$MODE" = "both" ] || [ "$MODE" = "mt" ]; then
  log "Running multi-thread benchmark (MULTITHREAD=${NPROC})..."
  out="$(run_mode "-DMULTITHREAD=${NPROC} -DUSE_PTHREAD")" || exit 1
  read -r mt_score mt_time mt_iter <<<"$out"
  echo "COREMARK_MT=${mt_score}"
  echo "COREMARK_TIME_MT=${mt_time}"
  echo "COREMARK_ITER_MT=${mt_iter}"
fi

log "Done."
