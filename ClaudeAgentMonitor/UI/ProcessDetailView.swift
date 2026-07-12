import SwiftUI

struct ProcessDetailView: View {
    @EnvironmentObject var monitor: ProcessMonitor
    @ObservedObject var resources: ResourceTracker = .shared
    @Environment(\.dismiss) var dismiss

    @State private var sortBy: SortKey = .age
    @State private var leakedOnly = false
    @State private var searchText = ""
    @State private var selectedTab = 1

    enum SortKey: String, CaseIterable {
        case age    = "경과시간"
        case memory = "메모리"
        case cpu    = "CPU"
        case pid    = "PID"
    }

    var displayed: [AgentProcess] {
        var list = monitor.snapshot.processes
        if leakedOnly { list = list.filter(\.isLeaked) }
        if !searchText.isEmpty {
            list = list.filter { "\($0.pid)".contains(searchText) || $0.leakReason.contains(searchText) }
        }
        return list.sorted {
            switch sortBy {
            case .age:    return $0.ageMinutes > $1.ageMinutes
            case .memory: return $0.memMB > $1.memMB
            case .cpu:    return $0.cpu > $1.cpu
            case .pid:    return $0.pid < $1.pid
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            if selectedTab == 0 {
                toolbar
                Divider()
                summaryBar
                Divider()
                processList
            } else {
                appsSection
            }
        }
        .frame(width: 640, height: 480)
        .navigationTitle("프로세스 상세")
    }

    private var tabPicker: some View {
        Picker("탭", selection: $selectedTab) {
            Text("Claude 프로세스").tag(0)
            Text("추적 앱").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 추적 앱 (ResourceTracker 기반, 범용)

    private var appsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text("추적 앱: \(resources.topApps.count)개")
                    .font(.caption)
                Text("누수의심: \(resources.leakSuspects.count)개")
                    .font(.caption)
                    .foregroundStyle(resources.leakSuspects.isEmpty ? Color.secondary : Color.orange)
                Spacer()
                Text(String(format: "총 %.1fGB", resources.latestReport?.totalMemGB ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(.background.secondary)

            Divider()

            List {
                ForEach(resources.topApps) { app in
                    AppDetailRow(app: app, resources: resources)
                }
            }
            .listStyle(.plain)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("PID 또는 누수원인 검색", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Toggle("누수만", isOn: $leakedOnly)
                .toggleStyle(.checkbox)

            Spacer()

            Picker("정렬", selection: $sortBy) {
                ForEach(SortKey.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 110)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var summaryBar: some View {
        HStack(spacing: 20) {
            Text("표시: \(displayed.count)개")
                .font(.caption)
            Text("전체: \(monitor.snapshot.processes.count)개")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("누수: \(monitor.snapshot.leakedCount)개")
                .font(.caption)
                .foregroundStyle(monitor.snapshot.leakedCount > 0 ? .orange : .secondary)
            Spacer()
            Text(String(format: "총 %.1fGB", monitor.snapshot.totalMemGB))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.background.secondary)
    }

    private var processList: some View {
        Table(displayed) {
            TableColumn("상태") { p in
                HStack(spacing: 3) {
                    Circle()
                        .fill(p.isLeaked ? (p.isIdle ? Color.orange : Color.red) : Color.green)
                        .frame(width: 7, height: 7)
                    if p.isIdle {
                        Text("⏸")
                            .font(.system(size: 9))
                            .help("유휴 \(p.idleSnapshots)회 연속 (CPU 활동 없음)")
                    }
                    if p.isClaudeMemObserver {
                        Text("𝌆")
                            .font(.system(size: 9))
                            .foregroundStyle(.purple)
                            .help("claude-mem 메모리 관찰자 프로세스")
                    }
                }
            }
            .width(50)

            TableColumn("PID") { p in
                Text("\(p.pid)")
                    .font(.system(.body, design: .monospaced))
            }
            .width(65)

            TableColumn("경과") { p in
                Text(p.ageFormatted)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(p.ageMinutes > 60 ? .orange : .primary)
            }
            .width(70)

            TableColumn("메모리") { p in
                Text(String(format: "%.0fMB", p.memMB))
                    .font(.system(.body, design: .monospaced))
            }
            .width(75)

            TableColumn("CPU%") { p in
                Text(String(format: "%.1f%%", p.cpu))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(p.cpu < 0.2 ? .secondary : .primary)
            }
            .width(60)

            TableColumn("누수/유휴 원인") { p in
                if p.isLeaked || p.isIdle {
                    Text(p.leakReason.isEmpty ? "유휴" : p.leakReason)
                        .font(.caption)
                        .foregroundStyle(
                            p.isClaudeMemObserver ? Color.purple
                            : p.isIdle && !p.leakReason.contains("부모사망") && !p.leakReason.contains("장기실행")
                                ? Color.orange : Color.red
                        )
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("이름") { p in
                Text(p.cmdArgs)
                    .font(.caption)
                    .foregroundStyle(p.isClaudeMemObserver ? Color.purple : .secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
    }
}

// MARK: - 추적 앱 행 (ResourceTracker 기반)

/// 앱 단위 행: 이름/카테고리/PID수/메모리/CPU%/누수의심 배지 + 종료 버튼.
/// 확장 시 `resources.detailedProcesses(for:)`로 PID별 고아/유휴 배지를 표시한다.
private struct AppDetailRow: View {
    let app: AppResourceSample
    @ObservedObject var resources: ResourceTracker

    @State private var showKillAlert = false

    private var isLeakSuspect: Bool {
        resources.leakSuspects.contains { $0.appName == app.appName }
    }
    private var isDrilldownEligible: Bool {
        resources.drilldownApps.contains(app.appName)
    }

    var body: some View {
        DisclosureGroup {
            drilldownContent
        } label: {
            headerRow
        }
        .padding(.vertical, 2)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.appName)
                        .font(.body)
                        .lineLimit(1)
                    if isLeakSuspect {
                        Text("누수의심")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.18))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(app.category)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("PID \(app.pids.count)개")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(String(format: "%.0fMB", app.totalMemMB))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 70, alignment: .trailing)
            Text(String(format: "%.1f%%", app.cpuPercent))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 55, alignment: .trailing)
            Button {
                showKillAlert = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("\(app.appName) 종료")
            .alert("앱 종료", isPresented: $showKillAlert) {
                Button("종료", role: .destructive) {
                    resources.killApp(appName: app.appName)
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("\(app.appName)을(를) 종료하시겠습니까? 저장하지 않은 작업이 유실될 수 있습니다.")
            }
        }
    }

    @ViewBuilder
    private var drilldownContent: some View {
        if isDrilldownEligible {
            let details = resources.detailedProcesses(for: app.appName)
            if details.isEmpty {
                Text("상세 데이터 없음")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, 12)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(details) { d in
                        HStack(spacing: 6) {
                            Text("PID \(d.pid)")
                                .font(.system(size: 10, design: .monospaced))
                            if d.isOrphan {
                                Text("고아")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.red)
                            }
                            if d.isIdle {
                                Text("유휴")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Text(String(format: "%.0fMB", d.memMB))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", d.cpuPercent))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 2)
            }
        } else {
            Text("부하가 낮아 상세 평가 대상 아님")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.leading, 12)
        }
    }
}
