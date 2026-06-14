# MemoryReset

> Windows 의 RAM 가용량을 **재부팅 없이** 회수하는 PowerShell 스크립트.
> Claude Code 와 Antigravity (Google 의 VS Code fork) 의 다중 세션 점유를 안전하게 해소합니다.

[한국어](#korean) · [English](#english)

---

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows 10/11](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D6?logo=windows)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Status: stable](https://img.shields.io/badge/Status-stable-success)

## 실측 결과 (Real-world result)

| 측정 시점 | 메모리 사용률 | 상황 |
|-----------|---------------|------|
| 실행 전 | **95%** | Antigravity 32 + Claude CLI 67 + helpers = 101 프로세스, ~39 GB 점유 |
| 실행 후 | **31%** | Antigravity·Claude CLI 완전 종료 + Standby/File Cache 회수 |
| **회수량** | **−64%p (~40 GB)** | 재부팅 없이, 다른 앱(브라우저·메신저 등) 영향 없이 |

> **측정 환경**: Windows 10 LTSC 2021 (build 19044, 21H2 기반) · DDR4 64 GB RAM
> **실행 시간**: 약 15초 (graceful 8초 + 회수 7초)

---

<a id="korean"></a>
## 🇰🇷 한국어

### 왜 필요한가

- **현상**: Antigravity 가 phase 마다 12 세션을 spawn 하면서 100+ `claude.exe` 프로세스가 누적 → 가용 RAM 5% 이하로 떨어짐
- **Windows 의 한계**: Linux/macOS 와 달리 종료된 프로세스의 메모리를 즉시 free list 로 반환하지 않고 Standby List / File Cache 에 유지 → 가용량 회복이 더딤
- **기존 해결책의 단점**: 재부팅은 모든 작업을 강제 종료시킴

### 어떻게 동작하나 (5 단계 파이프라인)

| 단계 | 동작 | API |
|------|------|-----|
| 1 | Claude CLI / Antigravity 의 graceful 종료 | `CloseMainWindow()` + 대기 |
| 2 | 잔존 프로세스 트리 강제 종료 | `taskkill /F /T` |
| 3 | 모든 프로세스의 Working Set 비우기 | `EmptyWorkingSet` (psapi) |
| 4 | System File Cache 트림 | `SetSystemFileCacheSize(-1, -1, 0)` |
| 5 | Modified Page List flush → Standby List 정리 | `NtSetSystemInformation` (ntdll) |

**핵심**: 5단계의 `MemoryFlushModifiedList` 를 standby purge 직전에 호출 → dirty 페이지가 standby 로 이동 후 함께 회수되어 효율 추가 향상.

### 안전성

- **Claude Desktop 앱은 절대 종료하지 않음** — 다중 설치 경로 블랙리스트 (`\WindowsApps\Claude_*`, `\AnthropicClaude\*\Claude.exe`, `\Programs\claude-desktop\*`, `\Program Files\Claude\Claude.exe`) 로 보존
- **자기 자신 PID 제외** — 스크립트가 자신을 죽이지 않도록 PID 필터
- **Graceful 우선** — 8초간 정상 종료 기회 제공 후에만 force kill
- **드라이런 모드** — `Run-DryRun.bat` 으로 어떤 프로세스가 종료될지만 미리 확인

### 빠른 시작

```cmd
:: 1. 사전 확인 (실제 종료 없음)
Run-DryRun.bat

:: 2. 본 실행 (UAC 프롬프트 → 승인)
Run.bat

:: 3. 깊은 회수 [v1.1+] — Memory Compression flush + System WS + 네트워크 캐시
Run-Deep.bat

:: 진단만 [v1.1+] — 메모리 분포/상위 점유 프로세스 보기
Run-Diagnose.bat

:: 트레이 데몬 시작 [v1.2+] — 시스템 트레이에 상주, 90% 도달 시 알림
Tray.bat

:: Windows 부팅 시 트레이 자동 시작 등록 (UAC 불필요)
Tray-AutoStart-Register.bat
```

또는 PowerShell 에서 직접:

```powershell
# 일반 실행
.\MemoryReset.ps1

# 깊은 회수 — 재부팅과의 격차 최소화
.\MemoryReset.ps1 -Deep

# 최대 회수 — Tier A + 셸 재시작 (데스크톱 1~2초 깜빡임)
.\MemoryReset.ps1 -Deep -IncludeShell

# 자동화/스케줄러용
.\MemoryReset.ps1 -Deep -SkipConfirmation -KeepAlive

# 진단만
.\MemoryReset.ps1 -Diagnose
```

| 옵션 | 의미 | 기본값 |
|------|------|--------|
| `-GracefulTimeoutSec <n>` | CloseMainWindow 후 대기 (초) | `8` |
| `-DryRun` | 종료/회수 없이 대상만 표시 (UAC 불필요) | off |
| `-Deep` | **[v1.1+]** Memory Compression flush + System WS empty + DNS/NetBIOS/ARP 캐시 | off |
| `-IncludeShell` | **[v1.1+]** Explorer + Windows Search 재시작 (`-Deep` 자동 활성) | off |
| `-Diagnose` | **[v1.1+]** 메모리 분포 진단만 (UAC 불필요) | off |
| `-SkipConfirmation` | Y/n 프롬프트 생략 | off |
| `-KeepAlive` | 완료 후 키 입력 대기 없이 즉시 종료 | off |

#### 모드별 권장 시나리오

| 상황 | 권장 명령 |
|------|-----------|
| 일반적인 메모리 회복 | `Run.bat` |
| 며칠간 켜둔 PC 의 누적 캐시까지 정리 | `Run-Deep.bat` |
| 재부팅 직전까지 짜낸 듯한 경험 원할 때 | `MemoryReset.ps1 -Deep -IncludeShell` |
| 회수 전 무엇이 점유 중인지 보기 | `Run-Diagnose.bat` |
| 어떤 프로세스가 종료될지만 미리 보기 | `Run-DryRun.bat` |

> **참고**: Memory Compression Store 와 Standby List 는 며칠간 켜둔 PC 에서 수 GB까지 누적될 수 있습니다. `-Deep` 은 이 둘을 모두 flush 해서 재부팅과의 격차를 좁힙니다. 단, 커널 pool / GPU 드라이버 / 페이지 파일 영역의 누수는 본질적으로 재부팅이 필요합니다 (주간 1회 권장).

### 종료 대상 식별 규칙

**Claude Code CLI** (다음 경로의 `claude.exe` 또는 `node.exe` 만):
- `%USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\`
- `%USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\`
- `%APPDATA%\Claude\claude-code\<version>\`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\`
- `--output-format stream-json` 인수를 가진 `claude.exe`
- `@anthropic-ai/claude-code` 가 커맨드라인에 포함된 `node.exe`

**Antigravity** (다음 경로의 모든 `*.exe`):
- `%LOCALAPPDATA%\Programs\Antigravity\`
- `%LOCALAPPDATA%\Google\Antigravity\`
- → Electron 의 GPU/Renderer/Utility helper, language server 모두 자동 포함

**절대 종료하지 않음** (Claude Desktop 앱):
- `\WindowsApps\Claude_*` (MSIX 설치)
- `\AnthropicClaude\app-*\Claude.exe` (Squirrel 설치)
- `\Programs\claude-desktop\*\Claude.exe` (직접 설치)
- `\Program Files\Claude\Claude.exe` (OS-wide 설치)

### 요구사항

- Windows 10 / 11
- PowerShell 5.1 이상 (Windows 기본 포함)
- 관리자 권한 (스크립트가 자동으로 UAC 승격 시도)

### 트러블슈팅

| 증상 | 원인 / 해결 |
|------|-------------|
| `NTSTATUS=0xC0000061` (Standby Purge) | `SeProfileSingleProcessPrivilege` 미보유 → 로컬 보안 정책 확인 (`secpol.msc` → 로컬 정책 → 사용자 권한 할당) |
| `NTSTATUS=0xC0000022` | 관리자 권한 미승격 → UAC 다시 승인 |
| 회수량이 작음 | Antigravity / Claude Code 외 다른 앱이 점유 중 → `Run-DryRun.bat` 으로 점유 프로세스 확인 |
| 한글 깨짐 | 콘솔 폰트를 `Consolas` / `D2Coding` 등 유니코드 폰트로 변경 |
| 스크립트가 안 뜸 | 파일이 차단됨 — 파일 우클릭 → 속성 → "차단 해제" 체크 |

### 시스템 트레이 데몬 [v1.2+]

```cmd
Tray.bat                          :: 트레이 시작 (숨김 창)
Tray-AutoStart-Register.bat       :: 부팅 시 자동 시작 등록
Tray-AutoStart-Unregister.bat     :: 자동 시작 해제
```

- **항상 상주**: 시계 옆 알림 영역에 메모리 사용률 아이콘
- **임계치 알림**: 메모리 사용률이 임계치 (기본 90%) 도달 시 BalloonTip — **자동 회수는 하지 않음** (사용자 결정 보장, 작업 손실 방지)
- **우클릭 메뉴**: 기본/깊은/최대 회수 / 진단 / 드라이런 / 회수 이력 / 임계치 설정 / 종료
- **단일 인스턴스**: mutex 로 중복 실행 방지
- **설정 저장**: `tray-settings.json` (임계치/폴링 주기/쿨다운)
- **데몬 자체는 관리자 권한 불필요** — 회수 트리거 시 UAC 자동 승격

### 회수 이력 (CSV) [v1.2+]

회수 실행 시마다 `recovery-history.csv` 에 자동 기록:

| 컬럼 | 의미 |
|------|------|
| Timestamp | yyyy-MM-dd HH:mm:ss |
| Mode | basic / deep / deep+shell |
| BeforeFreeMB / AfterFreeMB | 회수 전/후 가용 MB |
| RecoveredMB | 회수량 (음수 가능 — 다른 앱이 점유한 경우) |
| BeforePctFree / AfterPctFree | 회수 전/후 가용 % |
| ProcessesKilled | 종료된 Claude/Antigravity 프로세스 개수 |
| RuntimeSec | 실행 소요 시간 |

트레이 메뉴 → "회수 이력 보기" 로 Excel/메모장에서 열기. 어떤 모드가 본인 시스템에서 효과가 큰지 데이터 기반 판단 가능.

### 활동 추적 + idle 정리 [v1.4+]

**문제**: `-OrphansOnly` 는 부모 IDE 가 죽은 좀비만 잡지만, Windows 에서는 **IDE extension host 가 살아있는 채로 idle `claude.exe` 가 쌓이는** 경우가 더 흔합니다 (창/탭을 닫아도 자식이 cascade 종료되지 않음). v1.4 는 **"미사용 시간"** 기준으로 이들을 안전하게 회수합니다.

**핵심 안전 원리**: claude 활성 세션도 입력 대기 중엔 CPU 0% 입니다. 그래서 "지금 CPU 낮음"만으로 죽이면 활성 세션을 죽입니다. v1.4 는 **활동 이력을 시간에 걸쳐 누적**해서 `idleMinutes` **연속 무활동**인 것만 정리합니다 — 활성 세션은 그 안에 반드시 CPU 를 쓰므로 보존됩니다.

**1) 백그라운드 추적 등록** (기본 5분 간격, CPU 스냅샷만 기록 — 절대 종료 안 함):

```cmd
Track-Register.bat            :: 작업 스케줄러에 -TrackActivity 등록 (UAC 승격)
Track-Unregister.bat          :: 해제
```

**2) 임계 초과 시 텔레그램 알림**: `tracker-settings.json` 에 봇 토큰/chat_id 를 넣으면, idle/orphan 프로세스가 임계(개수/메모리/RAM%)를 넘을 때 텔레그램으로 알림이 옵니다. **알림만 보내고 종료는 하지 않습니다** (작업 손실 방지).

**3) 알림을 받으면 수동 정리**:

```cmd
Run-IdleDryRun.bat            :: idle/orphan 정리 대상 미리보기 (종료 없음)
Run-IdleCleanup.bat           :: 실제 종료 + 메모리 회수
```

| 설정 (`tracker-settings.json`) | 의미 | 기본값 |
|---|---|---|
| `idleMinutes` | 이 시간(분) 연속 무활동 + CPU 율 미만이면 idle 판정 | `60` |
| `cpuThresholdPct` | 활동으로 간주할 CPU 율(%) 하한 | `0.5` |
| `trackIntervalMin` | 추적(스냅샷) 주기(분) | `5` |
| `alert.idleCountThreshold` | idle/orphan 개수 ≥ 이 값이면 알림 | `10` |
| `alert.idleMemMBThreshold` | idle/orphan 메모리합(MB) ≥ 이 값이면 알림 | `4096` |
| `alert.ramPctThreshold` | idle/orphan 이 전체 RAM 의 ≥ 이 % 면 알림 | `10` |
| `alert.cooldownMin` | 재알림 최소 간격(분) | `30` |

> **보안**: `tracker-settings.json` 은 봇 토큰을 담으므로 `.gitignore` 로 커밋 차단됩니다. 템플릿은 `tracker-settings.example.json` 을 복사해서 채우세요. 소스/CLI 에는 토큰을 하드코딩하지 않습니다.
>
> `-TrackActivity` 는 read-only(CPU 조회 + 알림)라 **관리자 권한 없이 무인 실행**됩니다. `-IdleOnly` 정리는 종료+회수를 위해 UAC 승격합니다.

### 원클릭 전체 청소 (부산물 포함) [v1.4.1+]

```cmd
Run-PurgeAll.bat              :: 모든 claude/Antigravity + 자손 부산물 종료 + standby purge
```

`-IncludeDescendants` 는 종료 대상 claude/Antigravity 의 **자손 프로세스 트리**(세션이 띄운 `conhost`·`bash`·`node`·`pwsh`·`python`·`cmd` 등 부산물)를 함께 종료합니다. `Run-PurgeAll.bat` 은 여기에 깊은 회수(`-Deep`: working set + file cache + Memory Compression flush + standby purge)를 더해 **재부팅에 가까운 청소**를 한 번에 수행합니다.

> 사용자가 직접 띄운 셸은 claude 자손이 아니므로 **건드리지 않습니다**. 특정 세션을 살리려면 `-Interactive` 또는 `-KeepPids "PID"` 와 함께 쓰면 보존된 세션의 자손까지 자동 제외됩니다(보존 claude 는 트리 root 가 아니므로).
>
> ⚠ `Run-PurgeAll.bat` 단독 실행은 **작업 중인 claude 세션도 모두 종료**합니다 — 종료 전 Y/n 확인이 표시됩니다.

### 향후 개선 (Roadmap)

- [ ] 트레이 아이콘 커스텀 디자인 (현재는 Windows 기본 아이콘)
- [ ] 회수 이력 트렌드 차트 (PowerShell + Chart.js)
- [ ] PID/제목 화이트리스트로 특정 세션만 살리는 옵션
- [ ] 영문 메시지 i18n
- [ ] CI: PSScriptAnalyzer + 자동 PARSE 검증

### 기여 / 보안 보고

- 기여 가이드: [CONTRIBUTING.md](CONTRIBUTING.md)
- 취약점 보고: [SECURITY.md](SECURITY.md)
- 개발 일지: [docs/2026-04-19-initial-development.md](docs/2026-04-19-initial-development.md)

---

<a id="english"></a>
## 🇺🇸 English

### Why

- **Problem**: Antigravity spawns 12 sessions per phase, accumulating 100+ `claude.exe` processes → free RAM drops below 5%
- **Windows constraint**: Unlike Linux/macOS, Windows retains memory in Standby List / File Cache after process termination → free memory recovers slowly
- **Status quo limit**: Reboot forces termination of all work

### How it works (5-stage pipeline)

| Stage | Action | API |
|-------|--------|-----|
| 1 | Graceful close of Claude CLI / Antigravity | `CloseMainWindow()` + wait |
| 2 | Force-kill surviving process trees | `taskkill /F /T` |
| 3 | Empty working set of all processes | `EmptyWorkingSet` (psapi) |
| 4 | Trim system file cache | `SetSystemFileCacheSize(-1, -1, 0)` |
| 5 | Flush Modified Page List → purge Standby List | `NtSetSystemInformation` (ntdll) |

**Key insight**: Stage 5 calls `MemoryFlushModifiedList` *before* the standby purge, so dirty pages are flushed to standby and reclaimed together.

### Safety

- **Claude Desktop app is never terminated** — multi-path blacklist preserves it (MSIX / Squirrel / direct install / OS-wide)
- **Self-PID exclusion** — script never kills itself
- **Graceful first** — 8-second window for normal save/cleanup before force kill
- **Dry-run mode** — preview targets via `Run-DryRun.bat`

### Quick start

```cmd
:: Preview (no termination, no admin required)
Run-DryRun.bat

:: Real run (UAC prompt → approve)
Run.bat
```

Or directly via PowerShell:

```powershell
# Interactive
.\MemoryReset.ps1

# Deep recovery — narrows the gap with a fresh reboot
.\MemoryReset.ps1 -Deep

# Maximum recovery — Tier A + shell restart (desktop briefly flickers)
.\MemoryReset.ps1 -Deep -IncludeShell

# Automation / scheduler
.\MemoryReset.ps1 -Deep -SkipConfirmation -KeepAlive

# Diagnostics only (no UAC required)
.\MemoryReset.ps1 -Diagnose
```

| Option | Meaning | Default |
|--------|---------|---------|
| `-GracefulTimeoutSec <n>` | Wait time after `CloseMainWindow` (seconds) | `8` |
| `-DryRun` | List targets only, no termination/recovery (no UAC needed) | off |
| `-Deep` | **[v1.1+]** Memory Compression flush + System WS empty + DNS/NetBIOS/ARP cache | off |
| `-IncludeShell` | **[v1.1+]** Restart Explorer + Windows Search (auto-implies `-Deep`) | off |
| `-Diagnose` | **[v1.1+]** Memory distribution analysis only (no UAC needed) | off |
| `-SkipConfirmation` | Skip Y/n prompt | off |
| `-KeepAlive` | Exit immediately on completion (no keypress wait) | off |

#### Mode recommendations

| Situation | Recommended command |
|-----------|---------------------|
| Routine memory recovery | `Run.bat` |
| Cumulative caches after days of uptime | `Run-Deep.bat` |
| Want a near-reboot experience | `MemoryReset.ps1 -Deep -IncludeShell` |
| See what is currently holding memory | `Run-Diagnose.bat` |
| Preview which processes will be terminated | `Run-DryRun.bat` |

> **Note**: Memory Compression Store and Standby List can accumulate several GB on a system that has been on for days. `-Deep` flushes both, narrowing the gap with a reboot. Kernel pool / GPU driver / page file fragmentation is fundamentally only fixable by reboot — a weekly reboot is still recommended.

### Requirements

- Windows 10 / 11
- PowerShell 5.1+ (built-in)
- Administrator privileges (script auto-elevates via UAC)

### Target identification rules

**Claude Code CLI** — `claude.exe` or `node.exe` from these paths only:
- `%USERPROFILE%\.antigravity\extensions\anthropic.claude-code-*\`
- `%USERPROFILE%\.cursor\extensions\anthropic.claude-code-*\`
- `%APPDATA%\Claude\claude-code\<version>\`
- `%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\`
- Any `claude.exe` invoked with `--output-format stream-json`
- Any `node.exe` whose command line contains `@anthropic-ai/claude-code`

**Antigravity** — all `*.exe` from these paths (covers GPU/Renderer/Utility helpers and language servers):
- `%LOCALAPPDATA%\Programs\Antigravity\`
- `%LOCALAPPDATA%\Google\Antigravity\`

**Never terminated** (Claude Desktop app):
- `\WindowsApps\Claude_*` (MSIX install)
- `\AnthropicClaude\app-*\Claude.exe` (Squirrel install)
- `\Programs\claude-desktop\*\Claude.exe` (direct install)
- `\Program Files\Claude\Claude.exe` (OS-wide install)

### Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `NTSTATUS=0xC0000061` | Missing `SeProfileSingleProcessPrivilege` → check local security policy (`secpol.msc`) |
| `NTSTATUS=0xC0000022` | Not elevated → re-approve UAC |
| Low reclamation | Other apps holding memory → run `Run-DryRun.bat` to see exactly which processes are targeted |
| Korean characters garbled | Switch console font to a Unicode font (Consolas / D2Coding) |
| Script blocked | File marked as downloaded — right-click → Properties → check "Unblock" |

### License

MIT — see [LICENSE](LICENSE).

### Acknowledgments

- API references verified against [MS Docs](https://learn.microsoft.com/en-us/windows/win32/api/), [Process Hacker / System Informer phnt headers](https://github.com/winsiderss/systeminformer/blob/master/phnt/include/ntexapi.h), and [Geoff Chappell's research](https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi/system_information_class.htm).
- Inspired by Sysinternals RAMMap's standby-list purge technique.

### Disclaimer

This script forcibly terminates processes and manipulates kernel memory lists. While extensively validated (zero false positives on Claude Desktop preservation across 9 PIDs in production environment), use at your own risk. **Always run `Run-DryRun.bat` first** to verify targets in your environment.
