import Foundation
import SwiftUI
import AppKit

@MainActor
final class ServiceMonitor: ObservableObject {
    @Published var services: [Service] = []
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 3.0
    private var firstSeen: [String: Date] = [:]
    private var refreshStartedAt: Date?
    // If a refresh's background scan was in flight when the Mac slept, its
    // completion block may never run — isRefreshing would stay true forever
    // and every subsequent tick would bail out, leaving the menu empty.
    private let refreshStaleAfter: TimeInterval = 15.0
    private var activity: NSObjectProtocol?

    init() {
        // Keep App Nap from suspending the timer — the app has no windows,
        // so macOS otherwise throttles it within minutes of going background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .background,
            reason: "Continuous port monitoring"
        )

        refresh()
        startTimer()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func startTimer() {
        timer?.invalidate()
        // .common mode: keep firing while the menu is open (event tracking)
        // and while NSAlert runs modal — .default mode stalls in both.
        let t = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func handleWake() {
        Task { @MainActor in
            // Drop any stuck in-flight state and resync timer/scan immediately.
            self.isRefreshing = false
            self.refreshStartedAt = nil
            self.startTimer()
            self.refresh()
        }
    }

    func refresh() {
        if isRefreshing {
            if let started = refreshStartedAt, Date().timeIntervalSince(started) < refreshStaleAfter {
                return
            }
            // Previous refresh is stale (likely killed by system sleep) — recover.
        }
        isRefreshing = true
        refreshStartedAt = Date()
        Task.detached(priority: .background) {
            let procs = PortScanner.scan()
            let docks = DockerScanner.scan()
            let unsorted = procs + docks
            await MainActor.run {
                let now = Date()
                let liveIds = Set(unsorted.map(\.id))
                self.firstSeen = self.firstSeen.filter { liveIds.contains($0.key) }
                for svc in unsorted where self.firstSeen[svc.id] == nil {
                    self.firstSeen[svc.id] = now
                }
                let seenMap = self.firstSeen
                let sorted = unsorted.sorted { a, b in
                    let ta = seenMap[a.id] ?? .distantPast
                    let tb = seenMap[b.id] ?? .distantPast
                    if ta != tb { return ta > tb }
                    if a.port != b.port { return a.port < b.port }
                    return a.name < b.name
                }
                self.services = sorted
                self.lastRefresh = now
                self.isRefreshing = false
                self.refreshStartedAt = nil
            }
        }
    }

    func killService(_ svc: Service) {
        Task.detached(priority: .userInitiated) {
            switch svc.kind {
            case .process:
                guard let pid = svc.pid else { return }
                _ = runShell("/bin/kill", args: ["-TERM", "\(pid)"])
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if runShellEx("/bin/kill", args: ["-0", "\(pid)"]).exitCode == 0 {
                    _ = runShell("/bin/kill", args: ["-KILL", "\(pid)"])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }

                let aliveCheck = runShellEx("/bin/kill", args: ["-0", "\(pid)"])
                if aliveCheck.exitCode == 0 {
                    // Resisted unprivileged kill. Verify PID-name binding before
                    // considering privileged escalation — a recycled PID killed
                    // with root could nuke a system service.
                    if Self.pidMatches(pid: pid, expected: svc.name) {
                        let authorize = await self.confirmEscalation(name: svc.name, pid: pid)
                        if authorize, Self.pidMatches(pid: pid, expected: svc.name) {
                            Self.elevatedKill(pid: pid)
                        }
                    }
                }

                // Whether or not we needed escalation, check for launchd-respawn:
                // ollama, postgres-via-brew, etc. respawn within milliseconds of being killed.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let respawned = Self.findProcess(byName: svc.name), respawned != pid {
                    await self.handleRespawn(name: svc.name, oldPid: pid, newPid: respawned)
                }

            case .docker:
                guard let id = svc.containerId, let dpath = DockerScanner.dockerPath() else { return }
                _ = runShell(dpath, args: ["stop", id], timeout: 15.0)
            }
            await MainActor.run { self.refresh() }
        }
    }

    // MARK: - Helpers (nonisolated: pure subprocess work, no actor state)

    private nonisolated static func pidMatches(pid: Int32, expected: String) -> Bool {
        let r = runShellEx("/bin/ps", args: ["-p", "\(pid)", "-o", "comm="])
        guard r.exitCode == 0 else { return false }
        let comm = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if comm.isEmpty { return false }
        let base = (comm as NSString).lastPathComponent
        let exp = expected.lowercased()
        return base.lowercased() == exp
            || base.lowercased().hasPrefix(exp)
            || exp.hasPrefix(base.lowercased())
            || comm.lowercased().contains(exp)
    }

    private nonisolated static func elevatedKill(pid: Int32) {
        // pid is Int32 (validated upstream) — interpolation into AppleScript is safe.
        let script = "do shell script \"/bin/kill -9 \(pid)\" with administrator privileges"
        _ = runShellEx("/usr/bin/osascript", args: ["-e", script], timeout: 60.0)
    }

    private nonisolated static func findProcess(byName name: String) -> Int32? {
        let r = runShellEx("/bin/ps", args: ["-axo", "pid=,comm="])
        guard r.exitCode == 0 else { return nil }
        let target = name.lowercased()
        for line in r.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidPart = String(trimmed[..<spaceIdx])
            let comm = trimmed[trimmed.index(after: spaceIdx)...].trimmingCharacters(in: .whitespaces)
            let base = (comm as NSString).lastPathComponent.lowercased()
            if base.contains(target) || target.contains(base), let pid = Int32(pidPart) {
                return pid
            }
        }
        return nil
    }

    // MARK: - UI prompts (must run on main actor)

    private func confirmEscalation(name: String, pid: Int32) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Couldn't terminate \(name)"
        alert.informativeText = """
        PID \(pid) is still running after SIGKILL. \
        macOS can try again with administrator privileges — \
        you'll be asked for your password (or Touch ID).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Authorize")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func handleRespawn(name: String, oldPid: Int32, newPid: Int32) async {
        // Identify the launchd entry that resurrected the process.
        let entry = LaunchctlScanner.find(byPid: newPid)
            ?? LaunchctlScanner.find(byNameContaining: name)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(name) respawned"

        if let entry = entry {
            alert.informativeText = """
            \(name) was killed (PID \(oldPid)) but immediately restarted on PID \(newPid).

            Detected: \(entry.humanDescription)

            Porto can stop it permanently by running:
              \(entry.stopCommandPreview)
            """
            alert.addButton(withTitle: "Stop Permanently")
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.informativeText = """
            A new instance of \(name) appeared on PID \(newPid) right after killing PID \(oldPid). \
            It's likely launchd-managed but Porto couldn't identify the exact service.

            Try in Terminal:  launchctl list | grep \(name.lowercased())
            """
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard let entry = entry else { return }

        switch response {
        case .alertFirstButtonReturn:
            await runStopPermanently(entry: entry)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.stopCommandPreview, forType: .string)
        default:
            break
        }
    }

    private func runStopPermanently(entry: LaunchdEntry) async {
        let result = await Task.detached(priority: .userInitiated) {
            LaunchctlScanner.executeStop(entry)
        }.value
        let alert = NSAlert()
        alert.messageText = result.success ? "Stopped" : "Couldn't stop"
        alert.informativeText = result.message
        alert.alertStyle = result.success ? .informational : .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        refresh()
    }
}
