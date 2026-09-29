# GCE CoreMark-O-Matic

[English](#english) | [한국어](#korean)

<a name="english"></a>
## English

Lightweight orchestration scripts to automate **CoreMark benchmarking across Google Cloud Platform (GCE) VM machine types**, inspired by [PerfKitBenchmarker](https://github.com/GoogleCloudPlatform/PerfKitBenchmarker).

It runs from a local machine (macOS/Linux) or a dedicated GCE controller VM, automatically creating temporary GCE instances, executing multi-threaded and single-threaded CoreMark tests, recording metrics into CSV and JSON, and tearing down instances upon completion.

### Architecture Workflow

```
[Local Machine / Controller VM] --(gcloud)--> Target VM Created
       |                                             |
       |  gcloud compute scp/ssh                     |  Runs coremark_remote.sh
       |-------------------------------------------->|  - Installs build-essential & wget
       |                                             |  - Builds CoreMark v1.01 (linux64)
       |   Collects stdout results                   |  - Runs MT & ST benchmarks
       |<--------------------------------------------|  - Parses score from run1.log
       |                                             |
       |---- Deletes Target VM (cleanup) ----------->X
       v
   results/coremark-<timestamp>.csv / .json
```

- **CoreMark Source**: `eembc/coremark` v1.01 (`make PORT_DIR=linux64`)
- **Single-Thread (ST)**: Core performance benchmark for architecture comparison
- **Multi-Thread (MT)**: Saturated vCPU performance (`-DMULTITHREAD=$(nproc) -DUSE_PTHREAD`)
- **Auto-Calibration**: Measures speed via an initial probe run (`PROBE_ITERATIONS`) and calibrates iterations to guarantee execution time exceeds `TARGET_SECONDS` (CoreMark validity requires >= 10s).
- **Security & Isolation**: Target VMs are spawned with `--no-service-account --no-scopes` to prevent credential exposure.

### Prerequisites

1. **Environment**: macOS or Linux with `bash` (4+ recommended), `curl`, and `gcloud` CLI installed.
2. **GCP IAM Permissions**:
   - `compute.instances.create` / `delete` / `get`
   - `compute.machineTypes.get`
   - SSH access (via OS Login or project metadata SSH keys)
   - Typically satisfied by `roles/compute.instanceAdmin.v1`.
   - If using IAP (`USE_IAP=true`), requires `roles/iap.tunnelResourceAccessor` and an ingress firewall rule for `35.235.240.0/20` on TCP:22.
3. **Target Image**: Debian-based image supporting `apt-get` for `build-essential` and `wget` (default: `debian-12`).

### Quick Start

```bash
# 1. Configure target machine types and GCP parameters
vi config.sh

# 2. Run the benchmark orchestrator
./run_coremark.sh
```

If `PROJECT` and `ZONE` are left empty, they will be automatically resolved from the local `gcloud` config or GCE instance metadata.

### Configuration (`config.sh`)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `MACHINE_TYPES` | List of GCE machine types to benchmark | `("e2-standard-2" "n2-standard-2" "c2-standard-4")` |
| `PROJECT`, `ZONE` | GCP project ID and zone (auto-detected if empty) | `""` |
| `NETWORK`, `SUBNET` | Custom VPC network / subnet (uses default VPC if empty) | `""` |
| `USE_SPOT` | Use Spot (Preemptible) instances to minimize costs | `false` |
| `IMAGE_FAMILY`, `IMAGE_PROJECT` | Base boot image | `debian-12` / `debian-cloud` |
| `COREMARK_MODE` | Benchmark mode: `both`, `mt`, or `st` | `both` |
| `PROBE_ITERATIONS`, `TARGET_SECONDS` | Calibration parameters | `30000` / `12` |
| `DELETE_AFTER` | Automatically delete target VM after test | `true` |
| `USE_IAP` | Connect via Identity-Aware Proxy (IAP) tunnel | `false` |

### Output Metrics

Results are saved to `results/coremark-<timestamp>.csv` and `.json`.

| Field | Description |
|-------|-------------|
| `machine_type`, `zone`, `image` | GCE instance profile |
| `arch`, `cpu_platform`, `cpu_model` | Architecture, Google Cloud CPU platform, and CPU model |
| `vcpus` | Number of vCPUs |
| `coremark_mt` | Multi-threaded CoreMark score (throughput) |
| `coremark_per_core_mt` | Score per vCPU (`coremark_mt / vcpus`) |
| `coremark_st` | Single-threaded CoreMark score |
| `iter_*`, `time_*` | Executed iterations and runtime in seconds |
| `status` | Execution status (`SUCCESS`, `CREATE_FAILED`, `SSH_TIMEOUT`, `BENCH_FAILED`) |

### Repository Structure

- `config.sh`: User parameters and GCP configurations.
- `run_coremark.sh`: Orchestrator handling instance lifecycle, SCP, SSH, and data aggregation.
- `coremark_remote.sh`: Target VM script that compiles and executes CoreMark v1.01.
- `LICENSE`: MIT License.

---

<div style="page-break-before: always;"></div>

<a name="korean"></a>
## 한국어

[PerfKitBenchmarker](https://github.com/GoogleCloudPlatform/PerfKitBenchmarker)의 CoreMark 벤치마크 방식을 참조하여, **Google Cloud GCE VM 인스턴스의 CPU 성능을 CoreMark로 자동 측정**하는 경량 셸 스크립트 도구입니다.

로컬 워크스테이션(macOS/Linux) 또는 서비스 계정이 부여된 컨트롤러 GCE VM에서 실행하면, 정의된 머신 타입마다 임시 인스턴스를 순차적으로 생성하여 싱글/멀티스레드 CoreMark 점수를 측정하고 결과를 CSV/JSON으로 저장한 후 VM을 안전하게 자동 정리합니다.

### 동작 구조

```
[로컬 머신 / 컨트롤러 VM] --(gcloud)--> 타깃 VM 생성
        |                                       |
        |  gcloud compute scp/ssh               |  coremark_remote.sh 원격 실행
        |-------------------------------------->|  - build-essential, wget 설치
        |                                       |  - CoreMark v1.01 빌드 (linux64)
        |   stdout 결과 수집                    |  - 멀티스레드 / 싱글스레드 실행
        |<--------------------------------------|  - run1.log 파싱 및 수치 출력
        |                                       |
        |---- 타깃 VM 삭제 (클린업) ----------->X
        v
    results/coremark-<timestamp>.csv / .json
```

- **CoreMark 소스**: `eembc/coremark` v1.01 (`make PORT_DIR=linux64`)
- **싱글스레드**: 코어 1개 순수 연산 성능 비교
- **멀티스레드**: 전체 vCPU 병렬 처리량 측정 (`-DMULTITHREAD=$(nproc) -DUSE_PTHREAD`)
- **자동 캘리브레이션**: 사전 탐색(`PROBE_ITERATIONS`)으로 속도를 측정한 후, 실행 시간이 `TARGET_SECONDS`(기본 12초) 이상이 되도록 반복 횟수를 자동 보정 (CoreMark 공식 유효 결과 요건: 실행시간 >= 10초)
- **보안 격리**: 타깃 인스턴스 생성 시 `--no-service-account --no-scopes` 옵션을 적용하여 VM 권한 유출을 차단

### 사전 요건

1. **실행 환경**: `bash`(4 이상 권장), `curl`, `gcloud` CLI가 구성된 macOS 또는 Linux.
2. **GCP IAM 권한**:
   - `compute.instances.create` / `delete` / `get`
   - `compute.machineTypes.get`
   - SSH 접속 권한 (OS Login 또는 메타데이터 SSH 키)
   - 일반적으로 **`roles/compute.instanceAdmin.v1`** 역할이면 충분합니다.
   - IAP 터널링(`USE_IAP=true`) 사용 시 `roles/iap.tunnelResourceAccessor` 권한 및 `35.235.240.0/20` 대역 인바운드 방화벽(TCP:22)이 필요합니다.
3. **타깃 부팅 이미지**: `apt-get`으로 빌드 도구 설치가 가능한 Debian/Ubuntu 계열 (기본: `debian-12`).

### 실행 방법

```bash
# 1. 머신 타입 및 실행 파라미터 설정
vi config.sh

# 2. 오케스트레이터 실행
./run_coremark.sh
```

`PROJECT`와 `ZONE`을 비워둘 경우, 로컬 `gcloud` 활성 설정 또는 GCE 컨트롤러 메타데이터에서 자동으로 감지합니다.

### 주요 설정 (`config.sh`)

| 변수 | 설명 | 기본값 |
|------|------|--------|
| `MACHINE_TYPES` | 측정할 GCE 머신 타입 배열 | `("e2-standard-2" "n2-standard-2" "c2-standard-4")` |
| `PROJECT`, `ZONE` | 대상 GCP 프로젝트 및 존 (비우면 자동 감지) | `""` |
| `NETWORK`, `SUBNET` | 커스텀 VPC 및 서브넷 (비우면 기본 default VPC) | `""` |
| `USE_SPOT` | 비용 절감을 위한 Spot (Preemptible) 인스턴스 사용 여부 | `false` |
| `IMAGE_FAMILY`, `IMAGE_PROJECT` | 타깃 VM 부팅 이미지 | `debian-12` / `debian-cloud` |
| `COREMARK_MODE` | 측정 모드: `both`, `mt`, `st` | `both` |
| `PROBE_ITERATIONS`, `TARGET_SECONDS` | 자동 캘리브레이션 파라미터 | `30000` / `12` |
| `DELETE_AFTER` | 측정 후 타깃 VM 자동 삭제 여부 | `true` |
| `USE_IAP` | 외부 IP 없이 IAP 터널을 통한 SSH 접속 | `false` |

### 결과 파일 (`results/`)

`results/coremark-<timestamp>.csv` 및 `.json` 파일로 저장됩니다.

| 항목 | 설명 |
|------|------|
| `machine_type`, `zone`, `image` | 인스턴스 사양 및 환경 |
| `arch`, `cpu_platform`, `cpu_model` | CPU 아키텍처, GCP CPU 플랫폼, 프로세서 모델명 |
| `vcpus` | vCPU 개수 |
| `coremark_mt` | 멀티스레드 CoreMark 점수 (전체 처리량) |
| `coremark_per_core_mt` | vCPU당 CoreMark 점수 (`coremark_mt / vcpus`) |
| `coremark_st` | 싱글스레드 CoreMark 점수 |
| `iter_*`, `time_*` | 실제 수행된 반복 횟수 및 소요 시간(초) |
| `status` | 실행 결과 (`SUCCESS`, `CREATE_FAILED`, `SSH_TIMEOUT`, `BENCH_FAILED`) |

개별 인스턴스에서 오류가 발생하더라도 전체 프로세스는 중단 없이 다음 머신 타입 측정을 이어가며, 비정상 종료 시에도 `DELETE_AFTER=true` 설정에 따라 생성된 VM을 안전하게 삭제합니다.

### 라이선스

이 프로젝트는 [MIT License](LICENSE)를 따릅니다.
