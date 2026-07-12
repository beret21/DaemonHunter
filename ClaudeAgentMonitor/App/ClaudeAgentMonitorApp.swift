import SwiftUI

@main
struct DaemonHunterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor   = ProcessMonitor.shared
    @StateObject private var analyzer  = ProcessAnalyzer.shared
    @StateObject private var resources = ResourceTracker.shared

    var body: some Scene {
        // MARK: - Menu Bar
        MenuBarExtra {
            StatusPopoverView()
                .environmentObject(monitor)
                .environmentObject(analyzer)
        } label: {
            MenuBarIconView(
                status: monitor.snapshot.status,
                count:  resources.leakSuspects.count
            )
        }
        .menuBarExtraStyle(.window)

        // MARK: - Settings Window
        Settings {
            SettingsView()
        }

        // MARK: - Process Detail Window
        Window("프로세스 상세", id: WindowID.processDetail) {
            ProcessDetailView()
                .environmentObject(monitor)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 520)

        // MARK: - Activity Log Window
        Window("활동 로그", id: WindowID.activityLog) {
            CleanupLogView()
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 580, height: 500)
    }
}

// MARK: - Window IDs

enum WindowID {
    static let processDetail = "process-detail"
    static let activityLog   = "activity-log"
}

// MARK: - Menu Bar Icon

private struct MenuBarIconView: View {
    let status: ProcessSnapshot.SystemStatus
    let count:  Int

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 2) {
            icon
            // Normal 상태에서는 숫자 숨김 — 문제가 있을 때만 표시
            if status != .normal && count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(labelColor)
            }
        }
        .onAppear   { updatePulse(status) }
        .onChange(of: status) { _, new in updatePulse(new) }
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .normal:
            // 🟢 정상: 녹색 cpu 아이콘
            Image(systemName: "cpu.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.green, .green.opacity(0.4))

        case .warning:
            // 🟡 경고: 노란색-주황색 cpu + 느린 깜빡임
            Image(systemName: "cpu.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.yellow, .orange.opacity(0.6))
                .scaleEffect(pulse ? 1.06 : 1.0)
                .animation(
                    pulse
                        ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )

        case .critical:
            // 🔴 위험: 빨간 삼각형 + 빠른 깜빡임
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .scaleEffect(pulse ? 1.15 : 1.0)
                .animation(
                    pulse
                        ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
        }
    }

    private var labelColor: Color {
        status == .critical ? .red : .yellow
    }

    private func updatePulse(_ s: ProcessSnapshot.SystemStatus) {
        let want = (s != .normal)   // warning + critical 모두 애니메이션
        guard pulse != want else { return }
        pulse = want
    }
}
