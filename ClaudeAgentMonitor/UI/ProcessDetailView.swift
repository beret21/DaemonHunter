import SwiftUI

struct ProcessDetailView: View {
    @EnvironmentObject var monitor: ProcessMonitor
    @Environment(\.dismiss) var dismiss

    @State private var sortBy: SortKey = .age
    @State private var leakedOnly = false
    @State private var searchText = ""

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
            toolbar
            Divider()
            summaryBar
            Divider()
            processList
        }
        .frame(width: 640, height: 480)
        .navigationTitle("프로세스 상세")
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
