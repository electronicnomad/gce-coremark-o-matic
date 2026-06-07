# GCE CoreMark-O-Matic

[PerfKitBenchmarker](https://github.com/GoogleCloudPlatform/PerfKitBenchmarker) 의
CoreMark 벤치마크 방식을 참조하여, **Google Cloud GCE VM 인스턴스의 CPU 성능을
CoreMark 로 측정**하는 경량 셸 스크립트입니다.

서비스 계정이 부여된 **컨트롤러 GCE VM** 에서 실행하면, 사용자가 정의한 VM 타입마다
임시 인스턴스를 생성하여 CoreMark 점수를 측정하고 결과를 파일로 기록합니다.

## 동작 방식

```
[컨트롤러 VM] --(gcloud)--> 타깃 VM 생성
      |                         |
      |  gcloud compute scp/ssh |  coremark_remote.sh 실행
      |------------------------>|  - build-essential/wget 설치
      |                         |  - CoreMark v1.01 다운로드/빌드
      |   stdout 결과 수집       |  - 싱글/멀티스레드 측정
      |<------------------------|  - run1.log 파싱 → 점수 출력
      |                         |
      |---- 타깃 VM 삭제 -------->X
      v
  results/coremark-<timestamp>.csv / .json
```

- **CoreMark 소스**: `eembc/coremark` v1.01 (`make PORT_DIR=linux64`)
- **싱글스레드**: 코어 1개 성능 (머신 타입 간 코어 성능 순수 비교용)
- **멀티스레드**: 전체 vCPU 사용 (`-DMULTITHREAD=$(nproc) -DUSE_PTHREAD`) — VM 처리량
- **자동 캘리브레이션**: 짧은 탐색 실행으로 속도를 측정한 뒤, 실제 실행시간이
  `TARGET_SECONDS`(기본 12초) 이상이 되도록 반복 횟수를 자동 조정 (CoreMark 유효
  결과 요건: 실행시간 ≥ 10초)

## 사전 요건

1. **컨트롤러 VM**: gcloud SDK 가 설치된 GCE Linux VM (Debian/Ubuntu 권장, bash 4+)
2. **서비스 계정 권한**: 컨트롤러 VM 에 연결된 서비스 계정에 아래 권한 필요
   - `compute.instances.create` / `delete` / `get`
   - `compute.machineTypes.get`
   - SSH 접속을 위한 OS Login 또는 메타데이터 기반 SSH (gcloud 가 자동 처리)
   - 대략 **`roles/compute.instanceAdmin.v1`** 수준이면 충분
3. **타깃 이미지**: `apt` 로 `build-essential`/`wget` 설치 가능한 Debian 계열 (기본 `debian-12`)

> `USE_IAP=true` 로 외부 IP 없이 IAP 터널 SSH 를 쓰려면, IAP 방화벽 규칙
> (`35.235.240.0/20` 의 tcp:22 허용)과 `roles/iap.tunnelResourceAccessor` 권한이
> 추가로 필요합니다.

## 사용법

```bash
# 1) 측정할 머신 타입과 옵션 설정
vi config.sh        # MACHINE_TYPES, IMAGE_FAMILY, COREMARK_MODE 등

# 2) 실행 (컨트롤러 GCE VM 에서)
./run_coremark.sh
```

`PROJECT` 와 `ZONE` 을 비워두면 컨트롤러 VM 의 메타데이터에서 자동 감지합니다.

## 주요 설정 (`config.sh`)

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `MACHINE_TYPES` | 측정할 GCE 머신 타입 목록 | e2/n2/c3 예시 |
| `PROJECT`, `ZONE` | 비우면 메타데이터 자동 감지 | (auto) |
| `IMAGE_FAMILY`, `IMAGE_PROJECT` | 타깃 VM 부팅 이미지 | debian-12 / debian-cloud |
| `COREMARK_MODE` | `both` / `mt` / `st` | both |
| `PROBE_ITERATIONS`, `TARGET_SECONDS` | 자동 캘리브레이션 파라미터 | 30000 / 12 |
| `DELETE_AFTER` | 측정 후 타깃 VM 자동 삭제 | true |
| `USE_IAP` | 외부 IP 없이 IAP 터널 SSH | false |

## 출력

`results/coremark-<timestamp>.csv` 와 동일 내용의 `.json` 이 생성됩니다.

| 컬럼 | 의미 |
|------|------|
| `machine_type`, `zone`, `image`, `vcpus` | 측정 대상 정보 |
| `coremark_mt` | 멀티스레드(전체 vCPU) CoreMark 점수 (처리량) |
| `coremark_per_core_mt` | `coremark_mt / vcpus` (코어당 환산) |
| `coremark_st` | 싱글스레드 CoreMark 점수 |
| `iter_*`, `time_*` | 실제 사용된 반복 횟수와 실행시간(초) |
| `status` | `SUCCESS` / `CREATE_FAILED` / `SSH_TIMEOUT` / `BENCH_FAILED` 등 |

한 머신 타입의 측정이 실패해도 나머지는 계속 진행되며, 실패 상태가 결과 파일에
기록됩니다. 실행 중단/오류 시에도 `DELETE_AFTER=true` 이면 생성된 타깃 VM 은
정리됩니다.

## 파일 구성

| 파일 | 역할 |
|------|------|
| `config.sh` | 사용자 설정 |
| `run_coremark.sh` | 컨트롤러 오케스트레이터 (VM 생성/SSH/결과 기록/삭제) |
| `coremark_remote.sh` | 타깃 VM 에서 실행되는 CoreMark 빌드/측정 스크립트 |
