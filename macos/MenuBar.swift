// ════════════════════════════════════════════════════════════════════
// MemoryReset menu bar app (macOS) — Windows version MemoryReset-Tray.ps1 counterpart.
//
//   · Display memory usage persistently in menu bar
//   · Alert when threshold(default 90%) is reached — no automatic recovery
//     (guarantees user choice / prevents work loss — same design as Windows version)
//   · Click menu: basic/deep/max recovery · diagnostics · dry run · history · threshold settings · exit
//   · Single instance (flock)
//   · Settings: menubar-settings.json (AlertThresholdPct / CheckIntervalSec / AlertCooldownMin)
//
// Build: ./build-menubar.sh   (swiftc — requires Xcode Command Line Tools)
// ════════════════════════════════════════════════════════════════════

import AppKit
import Darwin
import Foundation

// ── Settings ────────────────────────────────────────────────────────────
struct Settings: Codable {
    var AlertThresholdPct: Double = 90
    var CheckIntervalSec: Double = 30
    var AlertCooldownMin: Double = 10
}

// Finds script/settings relative to executable location.
// When run inside .app bundle, go 3 levels up because it is Contents/MacOS/.
let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()

let scriptDir: URL = {
    // Bundle: <root>/MemoryResetMenuBar.app/Contents/MacOS/MemoryResetMenuBar
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

// ── Memory statistics (host_statistics64 — same accounting as vm_stat) ─────────
// Used = App(Anonymous − Purgeable) + Wired + Compressed
// Available    = Total − Used   (file cache is recoverable, so included in available)
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

// ── Alerts (osascript — works reliably without bundle signing) ──────────────────
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

// ── Run recovery — opens in Terminal.app so user can see progress ──
// (same intent as Windows version opening a PowerShell console window)
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
        notify(title: "MemoryReset — execution failed", message: error.localizedDescription)
    }
}

// ── Single instance (flock) ───────────────────────────────────────────
func acquireSingleInstanceLock() -> Bool {
    let lockPath = scriptDir.appendingPathComponent(".menubar.lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // Proceed anyway if lock file cannot be created
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { return false }
    return true  // Keep fd until process termination (intentionally not closed)
}

// ── App body ─────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var settings = loadSettings()
    private var lastAlert: Date?
    private let statusMenuItem = NSMenuItem(title: "Measuring...", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "RAM …"

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        menu.addItem(item("Basic recovery", #selector(basicRecovery)))
        menu.addItem(item("Deep recovery (purge + DNS)", #selector(deepRecovery)))
        menu.addItem(item("Maximum recovery (+ Finder/Dock restart)", #selector(maxRecovery)))
        menu.addItem(.separator())
        menu.addItem(item("Cleanup orphans only (safe)", #selector(orphansOnly)))
        menu.addItem(item("Cleanup idle sessions only", #selector(idleOnly)))
        menu.addItem(.separator())
        menu.addItem(item("Diagnostics", #selector(diagnose)))
        menu.addItem(item("Dry run (preview)", #selector(dryRun)))
        menu.addItem(item("View recovery history", #selector(openHistory)))
        menu.addItem(.separator())
        menu.addItem(item("Threshold settings...", #selector(editThreshold)))
        menu.addItem(item("Exit", #selector(quit)))

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
            format: " Used %.0f%% / Available %.0f MB / Total %.0f MB",
            m.usedPct, m.freeMB, m.totalMB)

        // Threshold alert — do not recover automatically (guarantees user choice)
        if m.usedPct >= settings.AlertThresholdPct {
            let cooled = lastAlert.map {
                Date().timeIntervalSince($0) >= settings.AlertCooldownMin * 60
            } ?? true
            if cooled {
                lastAlert = Date()
                notify(
                    title: "Memory Threshold Reached",
                    message: String(
                        format: "Usage %.0f%% (available %.0f MB) — Run recovery from the menu bar.",
                        m.usedPct, m.freeMB))
            }
        }
    }

    // ── Menu Actions ───────────────────────────────────────────────────
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
            notify(title: "No History", message: "No recovery has been run yet.")
        }
    }

    @objc private func editThreshold() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Threshold Settings"
        alert.informativeText = "An alert is sent when memory usage exceeds this value.\n(Auto recovery is not performed)"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

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
                notify(title: "Settings Saved", message: String(format: "Threshold: %.0f%%", v))
            } else {
                notify(title: "Invalid Value", message: "Enter a number between 1 ~ 99.")
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// ── Entry Point ──────────────────────────────────────────────────────────
guard acquireSingleInstanceLock() else {
    FileHandle.standardError.write("MemoryReset menu bar is already running.\n".data(using: .utf8)!)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Resides only in the menu bar without a Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
