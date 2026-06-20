import AppKit
import SwiftUI
import Combine

// MARK: - Closure-based NSMenuItem bridge
// target/action 전체를 우회 — closure를 representedObject에 저장해 호출
final class BlockMenuItem: NSObject, @unchecked Sendable {
    static let shared = BlockMenuItem()
    @objc func invoke(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }
}

extension NSMenuItem {
    static func closure(title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(BlockMenuItem.invoke(_:)), keyEquivalent: key)
        item.target      = BlockMenuItem.shared
        item.representedObject = action as AnyObject
        return item
    }
}

// MARK: - MenuBarController

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover    = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var analysisTask: Task<Void, Never>?

    private let monitor       = ProcessMonitor.shared
    private let analyzer      = ProcessAnalyzer.shared
    private let notifications = NotificationCoordinator.shared

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupPopover()
        setupStatusItem()
        observeMonitor()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard let btn = statusItem.button else { return }
        btn.image = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: "Claude Monitor")
        btn.image?.isTemplate = true
        btn.toolTip = "Claude Agent Monitor"
        // 항상 menu를 붙여야 클릭이 확실히 잡힘
        // menuWillOpen에서 좌/우 클릭 분기
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // 타이틀 (비활성)
        let titleItem = NSMenuItem(title: "Claude Agent Monitor", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        // 우클릭 전용 항목들 (좌클릭은 menuWillOpen에서 팝오버로 전환)
        menu.addItem(.closure(title: "지금 새로고침", key: "r") {
            Task { @MainActor in ProcessMonitor.shared.refresh() }
        })
        menu.addItem(.closure(title: "누수 프로세스 정리") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let r = await self.monitor.killLeaked()
                self.notifications.notifyCleanupDone(killed: r.killed, reclaimedGB: r.reclaimedMB / 1024)
            }
        })
        menu.addItem(.separator())
        menu.addItem(.closure(title: "설정...", key: ",") {
            Task { @MainActor in
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        })
        menu.addItem(.closure(title: "업데이트 확인") {
            Task { @MainActor in UpdateManager.shared.checkForUpdates() }
        })
        menu.addItem(.separator())
        menu.addItem(.closure(title: "종료", key: "q") {
            Task { @MainActor in NSApp.terminate(nil) }
        })

        return menu
    }

    private func setupPopover() {
        let view = StatusPopoverView()
            .environmentObject(monitor)
            .environmentObject(analyzer)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.contentSize = NSSize(width: 380, height: 580)
        popover.behavior    = .applicationDefined
        popover.animates    = true
    }

    private func observeMonitor() {
        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                self?.updateIcon(snap)
                self?.triggerAnalysis(snap)
            }
            .store(in: &cancellables)
    }

    // MARK: - Popover

    func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        Task { _ = await analyzer.analyze(snapshot: monitor.snapshot, force: false) }
    }

    // MARK: - Icon

    private func updateIcon(_ snap: ProcessSnapshot) {
        guard let btn = statusItem.button else { return }
        switch snap.status {
        case .normal:
            btn.image = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: nil)
            btn.image?.isTemplate = true
            btn.contentTintColor = nil
        case .warning:
            btn.image = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: nil)
            btn.image?.isTemplate = false
            btn.contentTintColor = .systemOrange
        case .critical:
            btn.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            btn.image?.isTemplate = false
            btn.contentTintColor = .systemRed
        }
        btn.toolTip = "\(snap.processes.count)개 프로세스 · \(String(format: "%.1f", snap.totalMemGB))GB"
    }

    // MARK: - Analysis

    private func triggerAnalysis(_ snap: ProcessSnapshot) {
        guard snap.status != .normal else { return }
        analysisTask?.cancel()
        analysisTask = Task {
            let result = await analyzer.analyze(
                snapshot: snap,
                delta:   snap.delta(from: monitor.previousSnapshot),
                trend:   ProcessHistoryTracker.shared.analysis,
                metrics: SystemMetricsCollector.shared.current
            )
            notifications.evaluate(snapshot: snap, analysis: result)
        }
    }
}

// MARK: - NSMenuDelegate: 좌클릭 → 팝오버, 우클릭 → 메뉴

extension MenuBarController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        // AppKit은 항상 main thread에서 delegate를 호출하므로 assumeIsolated 안전
        let isRightClick = MainActor.assumeIsolated {
            NSApp.currentEvent.map { $0.type == .rightMouseDown || $0.type == .rightMouseUp } ?? false
        }

        if !isRightClick {
            // 좌클릭: 메뉴를 취소하고 팝오버를 연다
            // NSMenu는 nonisolated context에서 @unchecked Sendable 취급
            // NSMenu는 항상 main thread에서 사용되므로 nonisolated(unsafe)로 전달
            nonisolated(unsafe) let menuRef = menu
            DispatchQueue.main.async {
                menuRef.cancelTracking()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                Task { @MainActor [weak self] in self?.togglePopover() }
            }
        }
    }
}
