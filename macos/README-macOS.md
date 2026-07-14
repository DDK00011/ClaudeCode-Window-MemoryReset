# MemoryReset — macOS 포팅

> Claude Code / Codex CLI 가 쌓아놓은 잔존 프로세스를 안전하게 정리하고 RAM 을 회수하는 zsh 스크립트.
> Windows 판([MemoryReset.ps1](../MemoryReset.ps1))의 macOS 이식본.

![zsh](https://img.shields.io/badge/zsh-5.9%2B-green)
![macOS 12+](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

---

## 먼저 읽어야 할 것 — macOS 는 Windows 와 문제의 성격이 다릅니다

Windows 판의 핵심 가치는 **"종료된 프로세스의 메모리가 Standby List 에 묶여 안 돌아오는 문제"** 를 커널
API 로 강제 회수하는 것이었습니다. **macOS 에는 그 문제가 없습니다.** 프로세스를 죽이면 그 페이지는
즉시 free list 로 돌아옵니다.

그래서 이 포팅의 가치는 다른 곳에 있습니다:

| | Windows 판 | macOS 판 |
|---|---|---|
| **주된 회수원** | Standby List / File Cache purge (커널 API) | **누적된 claude/codex 프로세스 종료** |
| **보조 회수원** | EmptyWorkingSet, Memory Compression flush | 파일 캐시 `purge(8)` |
| **관리자 권한** | **항상 필요** (모든 모드가 UAC 승격) | **프로세스 종료엔 불필요.** `purge` 에서만 sudo |

macOS 에서 실제로 RAM 을 먹는 건 **버려진 채 살아있는 CLI 프로세스들**입니다. 이 스크립트는 그것들을
정확히 찾아 죽이는 데 집중합니다.

### 실측 결과 (개발 중 이 코드로 잡아낸 실제 누수)

| 항목 | 값 |
|---|---|
| 발견된 고아 트리 | **4개 프로세스 / 1,345 MB** |
| 정체 | 구버전(`2.1.208`) daemon 이 죽으면서 남긴 `bg-pty-host` + `bg-spare` 트리 |
| 활성 세션 영향 | **없음** (현재 `2.1.209` 세션과 스크립트 자신의 조상 체인은 보존) |

> 측정 환경: macOS 26 (Darwin 25.3), Apple Silicon, 16 GB RAM

---

## Windows → macOS 대응표 (정직한 버전)

| Windows 판 단계 | macOS 대응 | 비고 |
|---|---|---|
| `CloseMainWindow()` | `SIGTERM` | |
| `taskkill /F /T` | `SIGKILL` + 자손 트리 BFS | |
| `EmptyWorkingSet` (psapi) | **대응물 없음** | macOS 는 필요 시 자동으로 working set 을 줄인다. 불필요. |
| `SetSystemFileCacheSize` | `purge(8)` | sudo 필요 |
| `NtSetSystemInformation` → `MemoryPurgeStandbyList` | `purge(8)` | macOS 엔 Standby List 자체가 없음 |
| `NtSetSystemInformation` → `MemoryFlushModifiedList` | **대응물 없음** | |
| Memory Compression flush (`Disable/Enable-MMAgent`) | **대응물 없음** | macOS 압축 store 를 flush 하는 공개 API 가 없다 |
| `Clear-DnsClientCache` | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` | |
| `nbtstat -R` / `netsh ... arpcache` | 해당 없음 | NetBIOS 는 macOS 에 없음 |
| Explorer.exe 재시작 | `killall Finder` + `killall Dock` | launchd 가 자동 재시작 |
| 작업 스케줄러 | **launchd** (`~/Library/LaunchAgents`) | |
| 시스템 트레이 (NotifyIcon) | **메뉴 막대** (NSStatusItem, Swift) | |
| UAC 승격 | **불필요** (종료는 sudo 없이 됨) | `purge` 만 sudo |

**"대응물 없음" 을 억지로 흉내내지 않았습니다.** macOS 에 존재하지 않는 커널 조작을 가짜로 구현하는
대신, 없다고 명시하고 실제로 효과가 있는 단계만 남겼습니다.

---

## 설치 — 다른 맥에 옮기기

```bash
git clone -b macos-port git@github.com:DDK00011/ClaudeCode-Window-MemoryReset.git
cd ClaudeCode-Window-MemoryReset/macos
./setup.sh
```

`setup.sh` 는 아무것도 종료하지 않습니다. 환경을 점검하고, 실행 권한과 격리 속성을 정리하고,
안전 규칙 45종을 검증한 뒤, **그 맥의 실제 현황**을 보여주고 다음 단계를 안내합니다.
Finder 에서 `Setup.command` 를 더블클릭해도 됩니다.

| 옵션 | 추가 동작 |
|---|---|
| `./setup.sh` | 점검 + 테스트 + 진단만 |
| `./setup.sh --with-menubar` | + 메뉴 막대 앱 빌드/실행 |
| `./setup.sh --with-launchd` | + 백그라운드 추적 에이전트 등록 |
| `./setup.sh --all` | 전부 |

### 맥마다 다시 해야 하는 것 (중요)

| 항목 | 이유 |
|---|---|
| **메뉴 막대 앱 빌드** | 바이너리는 커밋되지 않습니다 (아키텍처 의존). `./build-menubar.sh` 로 각 맥에서 빌드 |
| **launchd 등록** | plist 에 **절대 경로**가 박힙니다. 폴더를 옮겼다면 `./install-launchd.sh` 를 **다시** 실행 |
| **`--dry-run` 먼저** | claude 설치 형태(네이티브 / npm / IDE 확장)가 맥마다 다를 수 있습니다. 대상이 0개로 나오면 아래 참고 |

> **zip 으로 받았다면**: macOS 가 `com.apple.quarantine` 을 붙여 `.command` 더블클릭이 막힙니다.
> `setup.sh` 가 자동으로 제거합니다. `git clone` 으로 받으면 애초에 붙지 않습니다.

### 대상이 0개로 나올 때

이 포팅의 식별 규칙은 **네이티브 설치**(`~/.local/share/claude/`)와 npm/IDE 확장 설치를 다룹니다.
claude 를 쓰고 있는데도 0개라면 설치 형태가 다른 것이니, 아래 출력을 확인하고 이슈로 알려주세요:

```bash
ps -axo pid,ppid,rss,command | grep -iE 'claude|codex' | grep -v grep
```

---

## 빠른 시작

```bash
cd macos

# 1. 무엇이 잡히는지 먼저 확인 (아무것도 죽이지 않음, sudo 불필요)
./memoryreset.sh --diagnose

# 2. 무엇이 죽을지 미리보기
./memoryreset.sh --dry-run

# 3. 가장 안전한 실제 정리 — 부모가 죽은 고아만
./memoryreset.sh --orphans-only

# 4. 깊은 회수 (프로세스 종료 + 파일 캐시 purge + DNS flush)
./memoryreset.sh --deep
```

Finder 에서 더블클릭하려면 `.command` 파일을 쓰세요 (Windows 의 `.bat` 대응):

| 파일 | 동작 |
|---|---|
| `Run-Diagnose.command` | 진단만 |
| `Run-DryRun.command` | 미리보기 |
| `Run-Orphans.command` | 고아만 안전 정리 |
| `Run.command` | 기본 회수 |
| `Run-Deep.command` | 깊은 회수 |
| `Run-IdleDryRun.command` | idle/고아 정리 미리보기 |
| `Run-IdleCleanup.command` | idle/고아 실제 정리 |
| `Run-PurgeAll.command` | 전체 청소 (자손 포함) |

---

## 옵션

| 옵션 | 의미 | 기본값 |
|---|---|---|
| `--dry-run` | 종료/회수 없이 대상만 표시 | off |
| `--diagnose` | 메모리 분포 + 좀비 분석만 (read-only) | off |
| `--deep` | `purge(8)` + DNS 캐시 flush 추가 | off |
| `--include-shell` | Finder + Dock 재시작 (`--deep` 자동 활성) | off |
| `--orphans-only` | 부모가 죽은 고아만 대상 (**안전 모드**) | off |
| `--idle-only` | idle(무활동 누적) / 고아만 대상 (활성 세션 보존) | off |
| `--interactive` | 종료 전 PID 별 보존 선택 | off |
| `--keep-pids "1,2"` | 지정 PID 보존 | — |
| `--include-descendants` | 대상의 자손 트리(부산물)까지 종료 | off |
| `--track-activity` | 추적 1-tick (CPU 스냅샷 + 알림, **종료 안 함**) | off |
| `--graceful-timeout N` | SIGTERM 후 대기 초 | `8` |
| `--skip-confirmation` | Y/n 프롬프트 생략 | off |
| `--no-purge` | `purge(8)` 생략 — sudo 를 전혀 쓰지 않음 | off |

### 상황별 권장

| 상황 | 명령 |
|---|---|
| 뭐가 메모리를 먹는지 보고 싶다 | `--diagnose` |
| 안전하게 확실한 누수만 정리 | `--orphans-only` |
| 버려진 세션까지 정리 (활성은 보존) | `--idle-only` |
| 재부팅에 가까운 청소 | `--deep --include-descendants` |

---

## 안전장치

### 1. Claude Desktop 앱은 절대 종료하지 않습니다

`/Applications/Claude.app` (및 `~/Applications/Claude.app`) 는 블랙리스트로 차단됩니다.
`--enable-feature=@anthropic-ai/claude-code` 같은 인수로 위장해도 블랙리스트가 먼저 이깁니다.
GUI IDE 본체(VS Code / Cursor / Windsurf / Antigravity / Codex.app)도 마찬가지입니다.

### 2. 자기 자신 + **조상 체인 전체** 를 제외합니다 (macOS 전용 안전장치)

Windows 판은 자기 `$PID` 하나만 제외합니다. macOS 에서 그대로 옮기면 **위험합니다** —
이 스크립트는 보통 claude 세션의 터미널 안에서 실행되므로, 조상 체인에 claude 프로세스가 있습니다:

```
스크립트 → zsh → claude bg-spare → claude bg-pty-host → claude daemon → launchd
                 └──────────── 전부 종료 대상 후보 ────────────┘
```

조상을 제외하지 않으면 **자기를 실행한 세션을 죽입니다.** 그래서 macOS 판은 PPID 를 타고 올라가며
조상 전체를 보존 목록에 넣습니다. `--diagnose` 출력에서 확인할 수 있습니다.

### 3. 고아 판정을 macOS 방식으로 재설계했습니다

macOS 는 부모가 죽으면 자식을 즉시 **launchd(PID 1)로 재부모화**합니다. Windows 판의
"부모 PID 가 사라졌는가 / PID 재사용인가" 판정은 성립하지 않습니다. 대신 훨씬 정확한 신호가 있습니다:

| 상황 | 판정 |
|---|---|
| claude helper(`bg-spare`/`bg-pty-host`) 인데 **PPID=1** | **고아** — daemon 이 죽었다 |
| `claude daemon` 인데 PPID=1 | **정상** — 원래 detach 되는 데몬 |
| 부모가 살아있음 | **고아 아님** (보수적 — 활성 세션 오탐 방지) |

> Windows 판의 "부모가 살아있어도 정상 spawner 가 아니면 고아" 규칙은 **이식하지 않았습니다.**
> macOS 에서 그대로 쓰면 로그인 셸(argv[0] 이 `-zsh`)·터미널 에뮬레이터를 전부 오탐합니다.
> 개발 중 실측으로 확인한 오탐이라 규칙 자체를 뺐습니다.

### 4. 활성 세션 보존 (`--idle-only`)

claude 활성 세션도 입력 대기 중엔 CPU 0% 입니다. "지금 CPU 낮음" 만으로 죽이면 활성 세션을 죽입니다.
그래서 **활동 이력을 시간에 걸쳐 누적**해서 `idleMinutes` **연속** 무활동인 것만 정리합니다.
활성 세션은 그 안에 반드시 CPU 를 쓰므로 보존됩니다. (Windows 판과 동일한 원리)

### 5. 검증

```bash
./test-patterns.sh     # 45개 판별 규칙 테스트 (zsh 함정 회귀 가드 포함) — 실제 프로세스를 건드리지 않음
```

Claude Desktop 보존 / IDE 본체 보존 / 고아 판정 / 분류를 합성 커맨드라인으로 검증합니다.

---

## 종료 대상 식별 규칙

**Claude Code CLI** (다음 중 하나라도 해당):
- `~/.local/share/claude/...` (네이티브 설치 — `versions/*`, `ClaudeCode.app`)
- `~/.local/bin/claude` (네이티브 심볼릭 링크)
- argv[0] 이 `claude bg-*` / `claude pty-*` 이고 커맨드라인에 `/tmp/cc-daemon-<uid>/` 소켓 경로
- `.../node_modules/@anthropic-ai/claude-code/...` (npm 전역/로컬)
- `~/.vscode/extensions/anthropic.claude-code-*` (Cursor / Antigravity / Windsurf 동일)
- `~/.claude/local/...`

**Codex CLI**: `codex` 바이너리, `Codex.app/Contents/Resources/...` 의 `node_repl`, `@openai/codex`

**절대 종료 안 함**: `/Applications/Claude.app`, GUI IDE 본체, `Codex.app/Contents/MacOS/`, 자기 조상 체인

---

## 백그라운드 추적 + 자동 정리 (launchd)

Windows 판의 작업 스케줄러(`Track-Register.bat` / `Cleanup-Schedule.ps1`) 대응입니다.

```bash
./install-launchd.sh                      # 추적 + 자동 정리 등록 (정리 기본 3시간)
./install-launchd.sh --interval-min 90    # 자동 정리를 1시간 30분 간격으로
./install-launchd.sh --status             # 상태 확인
./install-launchd.sh --remove             # 둘 다 해제
```

> 간격을 바꾸려면 **다시 등록하면 됩니다** — `install-launchd.sh` 가 기존 plist 를 덮어쓰고
> 재로드합니다. 따로 해제할 필요 없습니다.

등록되는 것:

| LaunchAgent | 주기 | 동작 |
|---|---|---|
| `com.claudecode.memoryreset.tracker` | `trackIntervalMin` (기본 5분) | CPU 스냅샷 기록 + 임계 초과 시 텔레그램 알림. **절대 종료 안 함** |
| `com.claudecode.memoryreset.cleanup` | 기본 3시간 (`--interval-min` 으로 변경) | `--idle-only` — idle/고아만 종료. 활성 세션 보존 |

**정리 주기와 `idleMinutes` 는 다른 값입니다** — 헷갈리기 쉬우니 구분하세요:

| | 뜻 | 기본값 |
|---|---|---|
| 정리 주기 (`--interval-min`) | 얼마나 **자주 확인**하는가 | 180분 |
| `idleMinutes` (설정 파일) | 얼마나 **오래 놀아야** 죽이는가 | 60분 |

즉 `--interval-min 90` + `idleMinutes 60` = **90분마다 확인해서, 60분 넘게 무활동인 세션만 종료**.
정리 주기를 짧게 해도 60분 안 논 세션은 절대 안 죽습니다.

> **sudo 불필요.** LaunchAgent 는 사용자 권한으로 돕니다. 프로세스 종료에 root 가 필요 없기 때문입니다.
> cleanup 은 무인 실행이라 `--no-purge` 로 등록됩니다 (sudo 프롬프트가 뜨면 영원히 멈추므로).

`idle` 판정에는 추적 이력이 `idleMinutes`(기본 60분) 이상 누적돼야 합니다. 그 전까지는 고아만 정리됩니다.

---

## 메뉴 막대 앱 (Windows 트레이 대응)

```bash
./build-menubar.sh --run          # 빌드 + 실행
./build-menubar.sh --autostart    # 로그인 시 자동 시작 등록
./build-menubar.sh --unregister   # 해제
```

- 메뉴 막대에 🟢/🟡/🔴 + 메모리 사용률 상주 표시
- 임계치(기본 90%) 도달 시 알림 — **자동 회수는 하지 않음** (사용자 결정 보장, 작업 손실 방지)
- 메뉴: 기본/깊은/최대 회수 · 고아만 · 무활동만 · 진단 · 드라이런 · 이력 · 임계치 설정 · 종료
- 회수를 고르면 Terminal.app 이 열려 진행 상황이 보입니다 (Windows 판이 콘솔 창을 띄우는 것과 동일)
- 단일 인스턴스 (flock)
- 설정: `menubar-settings.json`

> `swiftc` (Xcode Command Line Tools) 가 필요합니다: `xcode-select --install`
> 없어도 **모든 기능을 CLI 로 쓸 수 있습니다** — 메뉴 막대는 선택 사항입니다.

---

## 텔레그램 알림

```bash
cp tracker-settings.example.json tracker-settings.json
# telegramBotToken / telegramChatId 를 채우고 alert.enabled 를 true 로
```

| 설정 | 의미 | 기본값 |
|---|---|---|
| `idleMinutes` | 이 시간(분) 연속 무활동이면 idle 판정 | `60` |
| `cpuThresholdPct` | 활동으로 간주할 CPU 율(%) 하한 | `0.5` |
| `trackIntervalMin` | 추적 스냅샷 주기(분) | `5` |
| `alert.idleCountThreshold` | idle/고아 개수 ≥ 이 값이면 알림 | `10` |
| `alert.idleMemMBThreshold` | idle/고아 메모리합(MB) ≥ 이 값이면 알림 | `4096` |
| `alert.ramPctThreshold` | idle/고아가 전체 RAM 의 ≥ 이 % 면 알림 | `10` |
| `alert.cooldownMin` | 재알림 최소 간격(분) | `30` |

> `tracker-settings.json` 은 봇 토큰을 담으므로 `.gitignore` 로 커밋이 차단됩니다.

---

## purge 를 암호 없이 쓰기 (선택)

`purge(8)` 은 root 권한이 필요합니다. 매번 암호를 넣기 싫다면 sudoers 에 등록하세요:

```bash
echo "$(whoami) ALL=(root) NOPASSWD: /usr/sbin/purge" | sudo tee /etc/sudoers.d/memoryreset-purge
sudo chmod 440 /etc/sudoers.d/memoryreset-purge
```

> 이 한 줄은 `/usr/sbin/purge` **하나만** 암호 없이 허용합니다. 되돌리려면
> `sudo rm /etc/sudoers.d/memoryreset-purge`.
>
> 등록하지 않아도 됩니다 — `--no-purge` 를 쓰거나, 그냥 두면 대화형 실행 시에만 암호를 물어봅니다.
> **프로세스 종료(= 회수량의 대부분)는 sudo 없이 동작합니다.**

---

## 생성되는 파일

| 파일 | 내용 | git |
|---|---|---|
| `recovery-history.csv` | 회수 이력 (Windows 판과 동일 스키마) | 무시됨 |
| `activity-state.tsv` | 활동 추적 상태 (Windows 판의 JSON → 셸에서 안전한 TSV 로 변경) | 무시됨 |
| `tracker-state.tsv` | 마지막 알림 시각 (쿨다운) | 무시됨 |
| `memoryreset.log` / `tracker.log` | 실행 로그 | 무시됨 |
| `tracker-settings.json` | 설정 + 봇 토큰 | **무시됨 (토큰 보호)** |
| `menubar-settings.json` | 메뉴바 임계치 설정 | 무시됨 |

---

## 트러블슈팅

| 증상 | 원인 / 해결 |
|---|---|
| `--idle-only` 가 아무것도 안 잡음 | 추적 이력이 `idleMinutes` 만큼 누적돼야 합니다. `./install-launchd.sh --status` 로 tracker 가 도는지 확인 |
| `purge` 에서 암호를 물어봄 | 정상입니다. `--no-purge` 로 건너뛰거나 위 sudoers 등록 |
| 메뉴바 앱이 안 뜸 | `xcode-select --install` 후 `./build-menubar.sh --run`. `menubar.err.log` 확인 |
| 회수량이 적음 | `--diagnose` 로 무엇이 점유 중인지 확인. claude 외 앱(Chrome 등)이 먹고 있을 수 있음 |
| 활성 세션이 죽었다 | `--orphans-only` / `--idle-only` / `--interactive` 를 쓰세요. 옵션 없는 기본 실행은 **모든** CLI 세션을 종료합니다 (Y/n 확인은 표시됨) |

---

## Windows 판과의 차이 요약

1. **sudo 가 거의 필요 없다** — 프로세스 종료는 사용자 권한으로 충분. `purge` 만 예외.
2. **커널 메모리 조작 단계가 없다** — macOS 엔 Standby List 가 없고, 압축 store flush API 도 없다.
3. **고아 판정이 다르다** — PPID=1 재부모화 기반. Windows 의 spawner 화이트리스트는 오탐이라 제거.
4. **자기 조상 체인을 보존한다** — macOS 필수 안전장치 (Windows 판엔 없음).
5. **상태 파일이 TSV** — 셸에서 JSON 을 안전하게 쓰기 어려워 내부 상태만 TSV 로. 설정 파일은 JSON 그대로.
6. **`-IncludeShell` 은 Finder/Dock 재시작** — Explorer 재시작 대응.

## 라이선스

MIT — 원본과 동일. [LICENSE](../LICENSE) 참고.
