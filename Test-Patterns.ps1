# 패턴 검증용 테스트 스크립트 (실제 종료 안 함)
# MemoryReset.ps1 의 Get-TargetProcesses 함수만 추출해서 실행 — 안전성 검증 도구.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 같은 폴더의 MemoryReset.ps1 을 읽어서 함수 정의 추출
$mainScript = Join-Path $PSScriptRoot 'MemoryReset.ps1'
if (-not (Test-Path $mainScript)) {
    Write-Host "[ERR] MemoryReset.ps1 을 같은 폴더에서 찾을 수 없음: $mainScript" -ForegroundColor Red
    exit 1
}
$src = Get-Content $mainScript -Raw -Encoding UTF8
# Get-TargetProcesses 함수 추출 (정규식)
if ($src -match '(?ms)function Get-TargetProcesses \{.*?^\}') {
    $funcDef = $Matches[0]
    Invoke-Expression $funcDef
} else {
    Write-Host "함수 추출 실패" -ForegroundColor Red
    exit 1
}

$targets = Get-TargetProcesses

Write-Host "== 종료 대상 분류 =="
$targets | Group-Object {
    if ($_.ExecutablePath -match '(?i)\\Programs\\Antigravity\\') { 'Antigravity 본체' }
    elseif ($_.ExecutablePath -match '(?i)\\\.antigravity\\extensions') { 'Claude CLI (Antigravity 확장)' }
    elseif ($_.ExecutablePath -match '(?i)\\Claude\\claude-code\\') { 'Claude CLI (standalone)' }
    elseif ($_.Name -eq 'node.exe') { 'Claude CLI (node)' }
    else { '기타' }
} | ForEach-Object {
    $ws = [math]::Round((($_.Group | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
    '{0,-40} {1,4} 개  {2,10:N1} MB' -f $_.Name, $_.Count, $ws
}

Write-Host ""
Write-Host "== Claude Desktop 보존 검증 =="
$desktop = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
    Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
$inTargets = $targets | Where-Object { $_.ExecutablePath -match '(?i)\\WindowsApps\\Claude_' }
'Desktop 앱 PID 수: {0}' -f @($desktop).Count
'그 중 종료 대상에 잘못 포함된 수: {0}' -f @($inTargets).Count
if (@($inTargets).Count -eq 0) {
    Write-Host "[PASS] Claude Desktop 안전하게 보존됨" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Claude Desktop 이 종료 대상에 포함됨!" -ForegroundColor Red
    $inTargets | Select-Object Name, ProcessId, ExecutablePath | Format-List
}

Write-Host ""
Write-Host "== 합계 =="
$totalMB = [math]::Round((($targets | Measure-Object WorkingSetSize -Sum).Sum / 1MB), 1)
'종료 시 회수 가능 (working set 기준): {0:N1} MB ({1} 프로세스)' -f $totalMB, @($targets).Count

Write-Host ""
Write-Host "== '기타' 카테고리 상세 (예상치 못한 매칭 확인) =="
$unknown = $targets | Where-Object {
    $_.ExecutablePath -notmatch '(?i)\\Programs\\Antigravity\\' -and
    $_.ExecutablePath -notmatch '(?i)\\\.antigravity\\extensions' -and
    $_.ExecutablePath -notmatch '(?i)\\Claude\\claude-code\\' -and
    $_.Name -ne 'node.exe'
}
if ($unknown) {
    $unknown | Select-Object Name, ProcessId, ExecutablePath, @{N='WS_MB';E={[math]::Round($_.WorkingSetSize/1MB,1)}} | Format-List
} else {
    Write-Host "(없음)"
}

Write-Host ""
Write-Host "== 자기 자신(현재 PowerShell PID=$PID) 제외 검증 =="
$selfIncluded = $targets | Where-Object { $_.ProcessId -eq $PID }
if ($null -eq $selfIncluded) {
    Write-Host "[PASS] 자기 자신 제외됨" -ForegroundColor Green
} else {
    Write-Host "[FAIL] 자기 자신이 대상에 포함됨!" -ForegroundColor Red
}

# v1.1 신규 기능 smoke test
Write-Host ""
Write-Host "== v1.1 신규 함수/플래그 smoke test =="

# 1. 신규 함수가 스크립트에 정의되어 있는지 확인
$expectedFunctions = @('Show-MemoryDiagnostics', 'Invoke-DeepRecovery', 'Invoke-ShellRestart')
foreach ($fn in $expectedFunctions) {
    if ($src -match "(?ms)^function\s+$fn\b") {
        Write-Host "[PASS] 함수 정의 존재: $fn" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 함수 정의 누락: $fn" -ForegroundColor Red
    }
}

# 2. 신규 파라미터 선언 확인
$expectedParams = @('Deep', 'IncludeShell', 'Diagnose')
foreach ($p in $expectedParams) {
    $pattern = '\[switch\]\$' + $p + '\b'
    if ($src -match $pattern) {
        Write-Host "[PASS] 파라미터 정의: -$p" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 파라미터 누락: -$p" -ForegroundColor Red
    }
}

# 3. v1.1.1 안전 가드 검증 (Round 1 패치 추적)
if ($src -match 'finally\s*\{[\s\S]*?Enable-MMAgent') {
    Write-Host "[PASS] MMAgent Disable→Enable try/finally 가드 존재" -ForegroundColor Green
} else {
    Write-Host "[WARN] MMAgent try/finally 가드 미확인 — Disable 후 Enable 실패 시 시스템 압축 영구 비활성화 위험" -ForegroundColor Yellow
}

if ($src -match 'availMB\s*-lt\s*1024') {
    Write-Host "[PASS] 압축 해제 spike OOM 가드 존재 (가용 RAM < 1GB 시 skip)" -ForegroundColor Green
} else {
    Write-Host "[WARN] OOM 가드 미확인" -ForegroundColor Yellow
}

if ($src -match 'restartedByWindows\s*=\s*\$true') {
    Write-Host "[PASS] Explorer 재시작 폴링 루프 존재" -ForegroundColor Green
} else {
    Write-Host "[WARN] Explorer 폴링 루프 미확인 — 셸 확장 많은 시스템에서 1.5초 부족 가능" -ForegroundColor Yellow
}

# 6. v1.1.2 elevation safety: Explorer 자동 재시작에만 의존 (Round 2 패치)
if ($src -match '의도적으로\s*elevated\s*explorer\.exe\s*직접\s*실행하지\s*않음') {
    Write-Host "[PASS] Explorer elevation 위험 회피 (자동 재시작 전용)" -ForegroundColor Green
} else {
    Write-Host "[WARN] elevated explorer 자동 시작 가드 미확인 — 일반 앱이 권한 부족 겪을 위험" -ForegroundColor Yellow
}

# 7. v1.1.2 MMAgent sleep 1500ms (Round 2 패치)
if ($src -match 'Start-Sleep\s+-Milliseconds\s+1500') {
    Write-Host "[PASS] MMAgent decompress 대기 1500ms (이전 800ms 에서 증가)" -ForegroundColor Green
} else {
    Write-Host "[WARN] MMAgent sleep 1500ms 미확인" -ForegroundColor Yellow
}

# v1.2 신규 기능 smoke test
Write-Host ""
Write-Host "== v1.2 트레이/CSV smoke test =="

# 8. CSV 로깅 함수 존재
if ($src -match '(?ms)^function\s+Write-RecoveryLog\b') {
    Write-Host "[PASS] CSV 로깅 함수 정의: Write-RecoveryLog" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Write-RecoveryLog 함수 누락" -ForegroundColor Red
}

# 9. CSV 락/재시도 가드
if ($src -match 'maxRetry\s*=\s*3' -and $src -match 'fallback') {
    Write-Host "[PASS] CSV 파일 락 재시도 + fallback 가드 존재" -ForegroundColor Green
} else {
    Write-Host "[WARN] CSV 락 가드 미확인" -ForegroundColor Yellow
}

# 10. 트레이 데몬 파일 존재 + smoke check
$trayPath = Join-Path $PSScriptRoot 'MemoryReset-Tray.ps1'
if (Test-Path $trayPath) {
    Write-Host "[PASS] MemoryReset-Tray.ps1 파일 존재" -ForegroundColor Green
    $trayContent = Get-Content $trayPath -Raw -Encoding UTF8

    # 10-1. P0 수정 검증: Add-Type 이 mutex 검사보다 먼저
    $addTypeIdx = $trayContent.IndexOf("Add-Type -AssemblyName System.Windows.Forms")
    $mutexIdx   = $trayContent.IndexOf("New-Object System.Threading.Mutex")
    if ($addTypeIdx -gt 0 -and $mutexIdx -gt 0 -and $addTypeIdx -lt $mutexIdx) {
        Write-Host "[PASS] Tray Add-Type 이 mutex 검사 이전에 실행" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] Tray Add-Type 순서 오류 — 두번째 인스턴스 시 MessageBox 실패 가능" -ForegroundColor Red
    }

    # 10-2. mutex Local\ scope (Global\ 권한 이슈 회피)
    if ($trayContent.Contains("'Local\MemoryReset-Tray-Singleton'")) {
        Write-Host "[PASS] Tray mutex Local\ scope (사용자 세션)" -ForegroundColor Green
    } elseif ($trayContent.Contains("'Global\MemoryReset-Tray-Singleton'")) {
        Write-Host "[WARN] Tray mutex Global\ — 권한 이슈 가능, Local\ 권장" -ForegroundColor Yellow
    } else {
        Write-Host "[WARN] Tray mutex naming 미확인" -ForegroundColor Yellow
    }

    # 10-3. Tick 함수 분리 (reflection 의존성 제거)
    if ($trayContent -match '(?ms)^function\s+Invoke-MemoryTick\b') {
        Write-Host "[PASS] Tray Invoke-MemoryTick 함수 분리 (reflection 미의존)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Tick 함수 분리 미확인" -ForegroundColor Yellow
    }

    # 10-4. 디버그 로그 헬퍼
    if ($trayContent -match '(?ms)^function\s+Write-TrayLog\b') {
        Write-Host "[PASS] Tray 디버그 로그 헬퍼 존재 (silent failure 추적 가능)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Write-TrayLog 미확인 — silent failure 추적 어려움" -ForegroundColor Yellow
    }
} else {
    Write-Host "[FAIL] MemoryReset-Tray.ps1 파일 없음" -ForegroundColor Red
}

# 11. .gitignore 개인 데이터 보호
$gitignorePath = Join-Path $PSScriptRoot '.gitignore'
if (Test-Path $gitignorePath) {
    $gi = Get-Content $gitignorePath -Raw
    if ($gi -match '\*\.csv' -and $gi -match 'tray-settings') {
        Write-Host "[PASS] .gitignore 가 *.csv + tray-settings.json 보호" -ForegroundColor Green
    } else {
        Write-Host "[WARN] .gitignore 개인 데이터 패턴 미확인" -ForegroundColor Yellow
    }
}

# v1.2.1 Round 2 패치 검증
Write-Host ""
Write-Host "== v1.2.1 Round 2 패치 검증 =="

# 12. STA 명시 (Tray.bat)
$trayBat = Join-Path $PSScriptRoot 'Tray.bat'
if (Test-Path $trayBat) {
    $batContent = Get-Content $trayBat -Raw
    if ($batContent -match '-Sta\b') {
        Write-Host "[PASS] Tray.bat 가 -Sta 플래그 명시 (WinForms 호환성)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Tray.bat -Sta 미확인 — MTA 환경에서 InputBox 등 hang 가능" -ForegroundColor Yellow
    }
}

# 13. CSV 컬럼명 명확화: FreedMB / UsedBeforeMB / UsedAfterMB
if ($src -match 'UsedBeforeMB' -and $src -match 'FreedMB') {
    Write-Host "[PASS] CSV 스키마 명확 (UsedBefore/UsedAfter/FreedMB)" -ForegroundColor Green
} else {
    Write-Host "[WARN] CSV 컬럼명 명확화 미확인" -ForegroundColor Yellow
}

# 14. fallback 파일 동시초 충돌 방지 (일자 단위 통합 + GUID emergency)
if ($src -match 'recovery-history-fallback-' -and $src -match 'recovery-history-emergency-') {
    Write-Host "[PASS] CSV fallback 동시초 충돌 방지 (일자 통합 + GUID 비상)" -ForegroundColor Green
} else {
    Write-Host "[WARN] CSV fallback 충돌 방지 미확인" -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════════════
# v1.4 활동추적 / idle 판정 / 텔레그램 알림 smoke test
# ════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "== v1.4 활동추적 / idle 판정 / 텔레그램 smoke test =="

# 15. 신규 함수 정의 존재
$v14fn = @('Update-ActivityState','Test-ProcessIdle','Get-ReclaimCandidates','Send-TelegramMessage','Invoke-ActivityTracking','Get-TrackerSettings','ConvertTo-HashtableDeep')
foreach ($fn in $v14fn) {
    if ($src -match "(?ms)^function\s+$fn\b") {
        Write-Host "[PASS] 함수 정의: $fn" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 함수 누락: $fn" -ForegroundColor Red
    }
}

# 16. 신규 파라미터 선언
foreach ($p in @('TrackActivity','IdleOnly')) {
    if ($src -match ('\[switch\]\$' + $p + '\b')) {
        Write-Host "[PASS] 파라미터: -$p" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 파라미터 누락: -$p" -ForegroundColor Red
    }
}

# 17. -TrackActivity 는 UAC 승격 제외 (무인 5분 실행 시 UAC 팝업 방지)
if ($src -match '-not\s+\(Test-IsAdmin\)\s+-and\s+-not\s+\$TrackActivity') {
    Write-Host "[PASS] -TrackActivity UAC 승격 제외 (무인 실행 안전)" -ForegroundColor Green
} else {
    Write-Host "[FAIL] -TrackActivity 가 UAC 승격 트리거 — 스케줄러 5분마다 팝업 위험" -ForegroundColor Red
}

# 18. [보안] 텔레그램 봇 토큰 하드코딩 금지 — 설정 파일에서만 로드되어야 함
if ($src -match '\d{8,}:[A-Za-z0-9_-]{30,}') {
    Write-Host "[FAIL] 소스에 봇 토큰 형태 문자열 발견 — 시크릿 하드코딩 위험!" -ForegroundColor Red
} else {
    Write-Host "[PASS] 소스에 하드코딩된 봇 토큰 없음 (tracker-settings.json 에서만 로드)" -ForegroundColor Green
}

# 19. [안전] idle 판정 3중 가드 필드 (관측충분 firstTrackedAt + 무활동 lastActiveAt + CPU율 lastCpuRatePct)
if ($src -match 'firstTrackedAt' -and $src -match 'lastActiveAt' -and $src -match 'lastCpuRatePct') {
    Write-Host "[PASS] idle 판정 3중 가드 필드 존재 (관측충분/무활동/CPU율)" -ForegroundColor Green
} else {
    Write-Host "[WARN] idle 판정 가드 필드 미확인" -ForegroundColor Yellow
}

# 20. PID 재사용 방어 — creationDate 비교로 신규/동일 프로세스 구분
if ($src -match 'creationDate' -and $src -match 'CreationDate') {
    Write-Host "[PASS] PID 재사용 방어 (creationDate 일치 검사)" -ForegroundColor Green
} else {
    Write-Host "[WARN] PID 재사용 방어 미확인" -ForegroundColor Yellow
}

# 21. .gitignore 가 tracker-settings.json(토큰) 을 인라인 주석 없이 정확히 보호
$giPath = Join-Path $PSScriptRoot '.gitignore'
if (Test-Path $giPath) {
    $giFix = Get-Content $giPath -Raw
    if ($giFix -match '(?m)^tracker-settings\.json\s*$') {
        Write-Host "[PASS] .gitignore tracker-settings.json 정확 보호 (인라인 주석 없음)" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] tracker-settings.json 토큰 파일 미보호 — 커밋 위험!" -ForegroundColor Red
    }
}

# 22. example 템플릿 존재 (토큰 없는 커밋용)
if (Test-Path (Join-Path $PSScriptRoot 'tracker-settings.example.json')) {
    Write-Host "[PASS] tracker-settings.example.json 템플릿 존재" -ForegroundColor Green
} else {
    Write-Host "[WARN] example 템플릿 누락" -ForegroundColor Yellow
}

# 23. 스케줄러/런처 스크립트 존재
foreach ($script in @('Track-Schedule.ps1','Track-Register.bat','Track-Unregister.bat','Run-IdleDryRun.bat','Run-IdleCleanup.bat')) {
    if (Test-Path (Join-Path $PSScriptRoot $script)) {
        Write-Host "[PASS] 스크립트 존재: $script" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 스크립트 누락: $script" -ForegroundColor Red
    }
}

# ════════════════════════════════════════════════════════════════════
# v1.4.1 부산물(자손 트리) 정리 smoke test
# ════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "== v1.4.1 부산물(자손 트리) 정리 smoke test =="

if ($src -match '(?ms)^function\s+Get-DescendantPids\b') {
    Write-Host "[PASS] 함수 정의: Get-DescendantPids" -ForegroundColor Green
} else { Write-Host "[FAIL] Get-DescendantPids 누락" -ForegroundColor Red }

if ($src -match '\[switch\]\$IncludeDescendants\b') {
    Write-Host "[PASS] 파라미터: -IncludeDescendants" -ForegroundColor Green
} else { Write-Host "[FAIL] -IncludeDescendants 누락" -ForegroundColor Red }

# Get-DescendantPids 는 flat array 반환이어야 함 (,@() 이중 wrap 금지 — desc 가 단일 int[] 원소가 되는 버그)
if ($src -match 'return \$result\.ToArray\(\)' -and $src -notmatch 'return ,\$result\.ToArray\(\)') {
    Write-Host "[PASS] Get-DescendantPids flat array 반환 (이중 wrap 없음)" -ForegroundColor Green
} else { Write-Host "[WARN] Get-DescendantPids 반환 형태 미확인" -ForegroundColor Yellow }

# IncludeDescendants 시 self / ExcludePids 제외 가드
if ($src -match 'ProcessId\) -ne \$self' -and $src -match 'ExcludePids -notcontains') {
    Write-Host "[PASS] 자손 수집 시 self / KeepPids 제외 가드 존재" -ForegroundColor Green
} else { Write-Host "[WARN] 자손 제외 가드 미확인" -ForegroundColor Yellow }

if (Test-Path (Join-Path $PSScriptRoot 'Run-PurgeAll.bat')) {
    Write-Host "[PASS] Run-PurgeAll.bat (원클릭 전체 청소) 존재" -ForegroundColor Green
} else { Write-Host "[FAIL] Run-PurgeAll.bat 누락" -ForegroundColor Red }
