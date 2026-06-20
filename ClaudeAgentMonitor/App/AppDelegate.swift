import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── Apple Silicon 전용 ──────────────────────────────────────────
        guard Self.isAppleSilicon() else {
            showIntelNotSupportedAlert()
            return
        }

        NSApp.setActivationPolicy(.accessory)

        Task { await NotificationCoordinator.shared.requestAuthorization() }

        // 모니터링 컴포넌트 순서대로 시작 (Self-healing 먼저 — 나머지 컴포넌트에 영향)
        SelfHealingManager.shared.start()
        ProcessMonitor.shared.startMonitoring()
        SystemMetricsCollector.shared.start()
        ResourceTracker.shared.start()

        // ProcessMonitor 스냅샷 → HistoryTracker + PredictionEngine 동시 연결
        Task {
            for await snapshot in ProcessMonitor.shared.$snapshot.values {
                ProcessHistoryTracker.shared.record(snapshot)
                // 칼만 예측 업데이트 (snapshot 루프마다 최신 시스템 지표 사용)
                let metrics = SystemMetricsCollector.shared.current
                PredictionEngine.shared.update(
                    processCount: snapshot.processes.count,
                    memoryGB:     snapshot.totalMemGB,
                    cpuPercent:   metrics.cpuUsagePercent,
                    thermalLevel: SelfHealingManager.thermalStateLevel()
                )
            }
        }

        // MenuBarController 제거됨 — MenuBarExtra가 대신 클릭 처리
    }

    func applicationWillTerminate(_ notification: Notification) {
        SelfHealingManager.shared.stop()
        ResourceTracker.shared.stop()
        ProcessMonitor.shared.stopMonitoring()
        SystemMetricsCollector.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        false
    }

    // MARK: - Apple Silicon check

    private static func isAppleSilicon() -> Bool {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { ptr -> Bool in
            let chars = ptr.bindMemory(to: CChar.self)
            guard let base = chars.baseAddress else { return false }
            return String(cString: base).hasPrefix("arm")
        }
    }

    private func showIntelNotSupportedAlert() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Apple Silicon 전용 앱"
        alert.informativeText = """
            Claude Agent Monitor는 Apple Silicon(M1/M2/M3/M4) Mac 전용입니다.

            이 Mac은 Intel 프로세서를 사용하고 있어 실행할 수 없습니다.
            Apple Silicon Mac에서 다시 시도해 주세요.
            """
        alert.addButton(withTitle: "종료")
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: nil)
        alert.runModal()
        NSApp.terminate(nil)
    }
}
