import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 레인 B(SystemHealthEvaluator) + 예측(PredictionEngine) 독립 폴링 타이머.
    // ProcessMonitor.$snapshot 스트림과 결합 해제 — 그 스트림이 멈춰도 레인 B는 계속 갱신된다.
    private var laneBTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ── Apple Silicon 전용 ──────────────────────────────────────────
        guard Self.isAppleSilicon() else {
            showIntelNotSupportedAlert()
            return
        }

        NSApp.setActivationPolicy(.accessory)

        Task { await NotificationCoordinator.shared.requestAuthorization() }

        // Sparkle 업데이터 초기화 — SPUStandardUpdaterController를 launch 시 생성해야
        // SUEnableAutomaticChecks + SUScheduledCheckInterval(1일) 자동 체크가 실제로 동작한다.
        _ = UpdateManager.shared

        // 모니터링 컴포넌트 순서대로 시작 (Self-healing 먼저 — 나머지 컴포넌트에 영향)
        SelfHealingManager.shared.start()
        ProcessMonitor.shared.startMonitoring()
        SystemMetricsCollector.shared.start()
        ResourceTracker.shared.start()

        // 레인 B(SystemHealthEvaluator) + 예측(PredictionEngine) 독립 폴링 시작 —
        // 아래 ProcessMonitor.$snapshot 루프와 결합 해제(레인 B 관련 호출은 여기서 뺐다).
        startLaneBPolling()

        // ProcessMonitor 스냅샷 루프 (구 파이프라인 — 2·3단계 은퇴 예정)
        // 레인 B/예측 호출은 위 독립 타이머로 이전됨. 현재 이 스트림의 다른 소비자는 없으나
        // (NotificationCoordinator.evaluate 호출부는 죽은 코드인 MenuBarController뿐),
        // 구 파이프라인 은퇴 시 함께 정리 예정이라 스트림 자체는 유지.
        Task {
            for await _ in ProcessMonitor.shared.$snapshot.values {}
        }

        // ResourceTracker collect 사이클 → ProcessHistoryTracker 신규 record 경로 (주 파이프라인).
        // 구 record(snapshot) 호출은 위 루프에서 제거 — process_snapshots DB 이중 기록을 피하고,
        // UI가 구독하는 tracker.analysis 가 앱 단위 시계열(새 의미)로 채워진다.
        Task {
            for await report in ResourceTracker.shared.$latestReport.values {
                guard let report else { continue }
                ProcessHistoryTracker.shared.recordResource(
                    apps: report.apps,
                    suspects: report.suspects,
                    memory: report.memory
                )
            }
        }

        // MenuBarController 제거됨 — MenuBarExtra가 대신 클릭 처리
    }

    func applicationWillTerminate(_ notification: Notification) {
        laneBTimer?.invalidate()
        SelfHealingManager.shared.stop()
        ResourceTracker.shared.stop()
        ProcessMonitor.shared.stopMonitoring()
        SystemMetricsCollector.shared.stop()
    }

    // MARK: - 레인 B(SystemHealthEvaluator) + 예측(PredictionEngine) 독립 폴링

    private func startLaneBPolling() {
        refreshLaneB()
        laneBTimer?.invalidate()
        let interval = SelfHealingManager.shared.effectivePollingInterval
        laneBTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshLaneB()
        }
    }

    private func refreshLaneB() {
        Task { @MainActor in
            // 칼만 예측 업데이트 — process_count 입력은 ResourceTracker의 "누수의심 앱 수"로 교체.
            // 추적 앱 수(상위 최대 20개, 수집 상한 그 자체) 그대로 쓰면 상시 경고에 가까운
            // 오탐이 나므로(레인A는 심각도=압박이지 원시 카운트가 아니라는 설계 원칙과도 불일치),
            // 문제 크기를 실제로 반영하는 leak-suspect 수를 쓴다. 임계도 별도 키
            // (leakSuspectWarnCount/CritCount, AgentProcess.swift AppSettings)로 분리.
            // memoryGB — 구 pipeline의 snapshot.totalMemGB(Claude 프로세스 메모리 합)에서
            // ResourceTracker의 "추적 앱 총 메모리"(레인A, latestReport.totalMemGB)로 교체.
            // 주의: 시스템 전역 사용 메모리(SystemMetricsCollector.memUsedGB)는 쓰지 않는다 —
            // 64GB 기기에서 상시 20~40GB대라 옛 절대임계(위험=10GB, criticalMemoryGB)에 걸리면
            // memory_gb 이상신호가 항상 "위험"으로 고정되는 오탐이 남(레인B가 이미 상대적
            // 메모리 압박을 별도로 판정하므로 이 metric까지 시스템 전역을 볼 필요도 없다).
            let metrics = SystemMetricsCollector.shared.current
            PredictionEngine.shared.update(
                processCount: ResourceTracker.shared.latestReport?.suspects.count ?? 0,
                memoryGB:     ResourceTracker.shared.latestReport?.totalMemGB ?? 0,
                cpuPercent:   metrics.cpuUsagePercent,
                thermalLevel: SelfHealingManager.thermalStateLevel()
            )

            // 시스템 전역 관측 + 오버헤드 파인더
            await GlobalProcessScanner.shared.refresh()
            SystemHealthEvaluator.shared.evaluate()
        }
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
