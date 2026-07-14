// ════════════════════════════════════════════════════════════════════
// MemoryReset 메뉴바 앱 (macOS) — Windows 판 MemoryReset-Tray.ps1 대응.
//
//   · 메뉴 막대에 메모리 사용률 상주 표시
//   · 임계치(기본 90%) 도달 시 알림 — 자동 회수는 하지 않음
//     (사용자 결정 보장 / 작업 손실 방지 — Windows 판과 동일한 설계)
//   · 클릭 메뉴: 기본/깊은/최대 회수 · 진단 · 드라이런 · 이력 · 임계치 설정 · 종료
//   · 단일 인스턴스 (flock)
//   · 설정: menubar-settings.json (AlertThresholdPct / CheckIntervalSec / AlertCooldownMin)
//
// 빌드: ./build-menubar.sh   (swiftc — Xcode Command Line Tools 필요)
// ════════════════════════════════════════════════════════════════════

import AppKit
import Darwin
import Foundation

// ── 설정 ────────────────────────────────────────────────────────────
struct Settings: Codable {
    var AlertThresholdPct: Double = 90
    var CheckIntervalSec: Double = 30
    var AlertCooldownMin: Double = 10
}

// 실행 파일 위치 기준으로 스크립트/설정을 찾는다.
// .app 번들 안에서 실행되면 Contents/MacOS/ 이므로 3단계 위로 올라간다.
let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()

let scriptDir: URL = {
    // 번들: <root>/MemoryResetMenuBar.app/Contents/MacOS/MemoryResetMenuBar
    if executableDir.path.hasSuffix(".app/Contents/MacOS") {
        return executableDir
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // .app
            .deletingLastPathComponent()   // root
    }
    return executableDir
}()

func settingsURL() -> URL { scriptDir.appendingPathComponent("menubar-settings.json") }
func mainScriptPath() -> String { scriptDir.appendingPathComponent("memoryreset.sh").path }
func historyPath() -> String { scriptDir.appendingPathComponent("recovery-history.csv").path }

func loadSettings() -> Settings {
    guard let data = try? Data(contentsOf: settingsURL()),
          let s = try? JSONDecoder().decode(Settings.self, from: data) else {
        return Settings()
    }
    return s
}

func saveSettings(_ s: Settings) {
    let enc = JSONEncoder()
    enc.outputFormatting = .prettyPrinted
    if let data = try? enc.encode(s) {
        try? data.write(to: settingsURL())
    }
}

// ── 메모리 통계 (host_statistics64 — vm_stat 과 동일한 회계) ─────────
// 사용 중 = App(Anonymous − Purgeable) + Wired + Compressed
// 가용    = 전체 − 사용 중   (파일 캐시는 회수 가능하므로 가용에 포함)
struct MemInfo {
    var totalMB: Double
    var usedMB: Double
    var freeMB: Double
    var usedPct: Double
}

func readMemory() -> MemInfo? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

    let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }

    var pageSize: vm_size_t = 0
    guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

    var totalBytes: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname("hw.memsize", &totalBytes, &size, nil, 0) == 0 else { return nil }

    let ps = Double(pageSize)
    let mb = 1024.0 * 1024.0

    let anonymous = Double(stats.internal_page_count)
    let purgeable = Double(stats.purgeable_count)
    let wired = Double(stats.wire_count)
    let compressed = Double(stats.compressor_page_count)

    let appPages = max(anonymous - purgeable, 0)
    let usedPages = appPages + wired + compressed

    let totalMB = Double(totalBytes) / mb
    let usedMB = usedPages * ps / mb
    let freeMB = max(totalMB - usedMB, 0)
    let usedPct = totalMB > 0 ? (usedMB / totalMB) * 100.0 : 0

    return MemInfo(totalMB: totalMB, usedMB: usedMB, freeMB: freeMB, usedPct: usedPct)
}

// ── 알림 (osascript — 번들 서명 없이도 확실히 동작) ──────────────────
func notify(title: String, message: String) {
    let esc = { (s: String) -> String in
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
    let script = "display notification \"\(esc(message))\" with title \"\(esc(title))\""
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}

// ── 회수 실행 — Terminal.app 에서 열어 사용자가 진행 상황을 보게 한다 ──
// (Windows 판이 PowerShell 콘솔 창을 띄우는 것과 같은 의도)
func runRecovery(_ extraArgs: [String]) {
    let shellCmd = ([mainScriptPath()] + extraArgs)
        .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        .joined(separator: " ")
    let forAppleScript = shellCmd
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "Terminal"
        activate
        do script "\(forAppleScript)"
    end tell
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    do {
        try p.run()
    } catch {
        notify(title: "MemoryReset — 실행 실패", message: error.localizedDescription)
    }
}

// ── 단일 인스턴스 (flock) ───────────────────────────────────────────
func acquireSingleInstanceLock() -> Bool {
    let lockPath = scriptDir.appendingPathComponent(".menubar.lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // 락 파일을 못 만들면 그냥 진행
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    return true  // fd 는 프로세스 종료까지 유지 (의도적으로 닫지 않음)
}

// ── 앱 본체 ─────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var settings = loadSettings()
    private var lastAlert: Date?
    private let statusMenuItem = NSMenuItem(title: "측정 중...", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "RAM …"

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        menu.addItem(item("기본 회수", #selector(basicRecovery)))
        menu.addItem(item("깊은 회수 (purge + DNS)", #selector(deepRecovery)))
        menu.addItem(item("최대 회수 (+ Finder/Dock 재시작)", #selector(maxRecovery)))
        menu.addItem(.separator())
        menu.addItem(item("고아만 정리 (안전)", #selector(orphansOnly)))
        menu.addItem(item("무활동 세션만 정리", #selector(idleOnly)))
        menu.addItem(.separator())
        menu.addItem(item("진단", #selector(diagnose)))
        menu.addItem(item("드라이런 (미리보기)", #selector(dryRun)))
        menu.addItem(item("회수 이력 보기", #selector(openHistory)))
        menu.addItem(.separator())
        menu.addItem(item("임계치 설정...", #selector(editThreshold)))
        menu.addItem(item("종료", #selector(quit)))

        statusItem.menu = menu

        startTimer()
        refresh()
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = max(settings.CheckIntervalSec, 5)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let m = readMemory() else { return }

        let icon: String
        switch m.usedPct {
        case ..<70: icon = "🟢"
        case ..<85: icon = "🟡"
        default:    icon = "🔴"
        }
        statusItem.button?.title = String(format: "%@ %.0f%%", icon, m.usedPct)
        statusMenuItem.title = String(
            format: " 사용 %.0f%% / 가용 %.0f MB / 전체 %.0f MB",
            m.usedPct, m.freeMB, m.totalMB)

        // 임계치 알림 — 자동 회수는 하지 않는다 (사용자 결정 보장)
        if m.usedPct >= settings.AlertThresholdPct {
            let cooled = lastAlert.map {
                Date().timeIntervalSince($0) >= settings.AlertCooldownMin * 60
            } ?? true
            if cooled {
                lastAlert = Date()
                notify(
                    title: "메모리 임계치 도달",
                    message: String(
                        format: "사용률 %.0f%% (가용 %.0f MB) — 메뉴 막대에서 회수를 실행하세요.",
                        m.usedPct, m.freeMB))
            }
        }
    }

    // ── 메뉴 액션 ───────────────────────────────────────────────────
    @objc private func basicRecovery() { runRecovery([]) }
    @objc private func deepRecovery()  { runRecovery(["--deep"]) }
    @objc private func maxRecovery()   { runRecovery(["--deep", "--include-shell"]) }
    @objc private func orphansOnly()   { runRecovery(["--orphans-only"]) }
    @objc private func idleOnly()      { runRecovery(["--idle-only"]) }
    @objc private func diagnose()      { runRecovery(["--diagnose"]) }
    @objc private func dryRun()        { runRecovery(["--dry-run"]) }

    @objc private func openHistory() {
        let path = historyPath()
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            notify(title: "이력 없음", message: "아직 회수를 실행한 적이 없습니다.")
        }
    }

    @objc private func editThreshold() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "임계치 설정"
        alert.informativeText = "메모리 사용률이 이 값을 넘으면 알림을 보냅니다.\n(자동 회수는 하지 않습니다)"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = String(format: "%.0f", settings.AlertThresholdPct)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            if let v = Double(field.stringValue.trimmingCharacters(in: .whitespaces)),
               v >= 1, v <= 99 {
                settings.AlertThresholdPct = v
                saveSettings(settings)
                startTimer()
                refresh()
                notify(title: "설정 저장됨", message: String(format: "임계치: %.0f%%", v))
            } else {
                notify(title: "값이 올바르지 않음", message: "1 ~ 99 사이 숫자를 입력하세요.")
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// ── 진입점 ──────────────────────────────────────────────────────────
guard acquireSingleInstanceLock() else {
    FileHandle.standardError.write("MemoryReset 메뉴바가 이미 실행 중입니다.\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Dock 아이콘 없이 메뉴 막대에만 상주
let delegate = AppDelegate()
app.delegate = delegate
app.run()
