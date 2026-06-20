import Foundation
import UserNotifications
import AppKit
import os

@MainActor
final class NotificationCoordinator: ObservableObject {
    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "Notifications")

    private var lastNotifiedStatus:  ProcessSnapshot.SystemStatus?
    private var lastNotificationTime: [Category: Date] = [:]

    static let shared = NotificationCoordinator()
    private init() {}

    // MARK: - Category / Action identifiers

    enum Category: String, CaseIterable {
        case statusWarning = "status-warning"
        case statusCritical = "status-critical"
        case cleanupDone   = "cleanup-done"
    }

    private enum ActionID: String {
        case confirm = "CONFIRM"   // "확인" — dismisses
        case cleanup = "CLEANUP"   // "정리 실행" — fires cleanup
        case open    = "OPEN"      // "열기"
    }

    // MARK: - Authorization + Category registration

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()

        do {
            // .timeSensitive: Focus 필터 관통 + 배너가 더 오래 유지됨
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge, .timeSensitive]
            )
            logger.info("Notification authorization: \(granted)")
        } catch {
            logger.error("Notification auth error: \(error)")
        }

        registerCategories()
    }

    private func registerCategories() {
        let confirm = UNNotificationAction(
            identifier: ActionID.confirm.rawValue,
            title: "확인",
            options: [.foreground]
        )
        let cleanup = UNNotificationAction(
            identifier: ActionID.cleanup.rawValue,
            title: "누수 정리",
            options: [.foreground, .destructive]
        )
        let open = UNNotificationAction(
            identifier: ActionID.open.rawValue,
            title: "열기",
            options: [.foreground]
        )

        // 경고 카테고리: 확인 | 열기
        let warnCat = UNNotificationCategory(
            identifier: Category.statusWarning.rawValue,
            actions: [confirm, open],
            intentIdentifiers: [],
            options: [.customDismissAction]   // 사용자가 명시적으로 액션을 눌러야 처리됨
        )

        // 위험 카테고리: 누수 정리 | 확인
        let critCat = UNNotificationCategory(
            identifier: Category.statusCritical.rawValue,
            actions: [cleanup, confirm],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // 정리 완료 카테고리: 확인
        let doneCat = UNNotificationCategory(
            identifier: Category.cleanupDone.rawValue,
            actions: [confirm],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories(
            [warnCat, critCat, doneCat]
        )
    }

    // MARK: - Evaluate & notify (상태 변화 시 호출)

    func evaluate(snapshot: ProcessSnapshot, analysis: ProcessAnalyzer.AnalysisResult) {
        guard snapshot.status != .normal else {
            lastNotifiedStatus = .normal
            return
        }
        guard analysis.shouldNotify else { return }
        guard !isCoolingDown(for: snapshot.status) else { return }

        switch snapshot.status {
        case .warning:
            send(
                title: "⚠️ 경고 — Daemon Hunter",
                body: analysis.notificationMessage.isEmpty ? analysis.summary : analysis.notificationMessage,
                level: .warning,
                category: .statusWarning
            )
        case .critical:
            send(
                title: "🔴 위험 — Daemon Hunter",
                body: analysis.notificationMessage.isEmpty ? analysis.summary : analysis.notificationMessage,
                level: .critical,
                category: .statusCritical
            )
        case .normal: break
        }

        lastNotifiedStatus = snapshot.status
    }

    func notifyCleanupDone(killed: Int, reclaimedGB: Double) {
        send(
            title: "정리 완료 — Daemon Hunter",
            body: "\(killed)개 프로세스 종료, \(String(format: "%.1f", reclaimedGB))GB 회수",
            level: .info,
            category: .cleanupDone
        )
    }

    // MARK: - Build & deliver

    enum NotificationLevel { case info, warning, critical }

    private func send(title: String, body: String, level: NotificationLevel, category: Category) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.categoryIdentifier = category.rawValue

        switch level {
        case .info:
            content.sound = .default
            content.interruptionLevel = .active
        case .warning:
            content.sound = .default
            // timeSensitive: Focus를 뚫고, 배너가 더 오래 유지
            content.interruptionLevel = .timeSensitive
        case .critical:
            content.sound = .defaultCritical
            content.interruptionLevel = .timeSensitive
        }

        // 고정 identifier: 같은 경고가 중복 쌓이지 않도록 카테고리 단위로 교체
        let id = "cam.\(category.rawValue)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        UNUserNotificationCenter.current().add(request) { [weak self] err in
            if let err {
                self?.logger.error("Notification failed: \(err.localizedDescription)")
            }
        }

        lastNotificationTime[category] = Date()
        logger.info("Notification [\(category.rawValue)] sent: \(body.prefix(60))")
    }

    // MARK: - Cooldown

    private func isCoolingDown(for status: ProcessSnapshot.SystemStatus) -> Bool {
        let cat: Category = status == .critical ? .statusCritical : .statusWarning
        // 상태가 바뀌었으면 쿨다운 무시
        if lastNotifiedStatus != status { return false }
        guard let last = lastNotificationTime[cat] else { return false }
        return Date().timeIntervalSince(last) < AppSettings.notificationCooldownSeconds
    }
}
