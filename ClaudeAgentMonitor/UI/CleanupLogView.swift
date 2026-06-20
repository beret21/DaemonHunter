import SwiftUI

struct CleanupLogView: View {
    @State private var entries:   [CleanupLogEntry]  = []
    @State private var spawnEvents: [ProcessEventEntry] = []
    @State private var isLoading  = true
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("활동 로그", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button { load() } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Tab picker
            Picker("탭", selection: $selectedTab) {
                Text("정리 기록").tag(0)
                Text("증가 이벤트").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 6)

            Divider()

            if isLoading {
                ProgressView("로딩 중...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedTab == 0 {
                cleanupTab
            } else {
                spawnTab
            }
        }
        .frame(width: 560, height: 480)
        .onAppear { load() }
    }

    // MARK: - Tab: Cleanup Records

    private var cleanupTab: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyState(
                    icon: "tray",
                    title: "정리 기록 없음",
                    hint: "누수 정리 버튼을 누르면 기록이 남습니다."
                )
            } else {
                List(entries) { entry in
                    CleanupLogRow(entry: entry)
                }
                .listStyle(.plain)

                Divider()
                summaryFooter(entries: entries)
            }
        }
    }

    // MARK: - Tab: Spawn / Increase Events

    private var spawnTab: some View {
        VStack(spacing: 0) {
            if spawnEvents.isEmpty {
                emptyState(
                    icon: "waveform",
                    title: "증가 이벤트 없음",
                    hint: "모니터링 중 새 Claude 프로세스가 감지되면 여기에 기록됩니다."
                )
            } else {
                List(spawnEvents) { ev in
                    SpawnEventRow(event: ev)
                }
                .listStyle(.plain)

                Divider()
                HStack {
                    Text("총 \(spawnEvents.count)건의 프로세스 이벤트")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 6)
            }
        }
    }

    // MARK: - Helpers

    private func emptyState(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(hint).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryFooter(entries: [CleanupLogEntry]) -> some View {
        HStack {
            let totalKilled = entries.reduce(0) { $0 + $1.killedCount }
            let totalGB     = entries.reduce(0.0) { $0 + $1.reclaimedMB } / 1024.0
            Text("총 \(entries.count)건 · \(totalKilled)개 종료 · \(String(format: "%.1f", totalGB))GB 회수")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private func load() {
        isLoading = true
        Task.detached {
            let logs   = DatabaseManager.shared.fetchCleanupLogs(limit: 100)
            let events = DatabaseManager.shared.fetchProcessEvents(limit: 300, eventType: "spawn")
            await MainActor.run {
                entries      = logs
                spawnEvents  = events
                isLoading    = false
            }
        }
    }
}

// MARK: - Cleanup Log Row

private struct CleanupLogRow: View {
    let entry: CleanupLogEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Summary line
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.timestamp, style: .date)
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(entry.timestamp, style: .time)
                                .font(.caption2).foregroundStyle(.secondary)
                            if entry.trigger == "auto" {
                                Text("자동").font(.caption2)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.blue.opacity(0.15)).foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                        }
                        HStack(spacing: 10) {
                            Label("\(entry.killedCount)개 종료", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            if entry.failedCount > 0 {
                                Label("\(entry.failedCount)개 실패", systemImage: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                            }
                            Label(String(format: "%.1fGB 회수", entry.reclaimedGB),
                                  systemImage: "memorychip").foregroundStyle(.green)
                        }
                        .font(.caption)
                        .labelStyle(CompactLabelStyle())

                        HStack {
                            Text("\(entry.processCountBefore) → \(entry.processCountAfter) 프로세스")
                                .font(.caption2).foregroundStyle(.tertiary)
                            if !entry.processes.isEmpty {
                                Text("· \(entry.processes.count)개 상세 ▾")
                                    .font(.caption2).foregroundStyle(.blue)
                            }
                        }
                    }

                    Spacer()

                    Text(entry.status)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(statusColor.opacity(0.12)).foregroundStyle(statusColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .buttonStyle(.plain)

            // Expanded: 프로세스 목록
            if expanded && !entry.processes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.processes, id: \.pid) { proc in
                        ProcessMiniRow(proc: proc)
                    }
                }
                .padding(.leading, 18)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch entry.status {
        case "CRITICAL": return .red
        case "WARNING":  return .orange
        default:         return .green
        }
    }
}

// MARK: - Process Mini Row (cleanup 상세)

private struct ProcessMiniRow: View {
    let proc: ProcessEventRecord

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: proc.killSuccess == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(proc.killSuccess == true ? .green : .red)
                .font(.caption2)

            Text("PID \(proc.pid)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(ageText)
                .font(.caption2).foregroundStyle(.tertiary)

            Text(String(format: "%.0fMB", proc.memMB))
                .font(.caption2).foregroundStyle(.tertiary)

            if !proc.leakReason.isEmpty {
                Text("· \(proc.leakReason)")
                    .font(.caption2).foregroundStyle(.orange)
            }

            Text(proc.cmdArgs)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 1)
    }

    private var ageText: String {
        let m = Int(proc.ageMinutes)
        let h = m / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m % 60))m" : "\(m)m"
    }
}

// MARK: - Spawn Event Row

private struct SpawnEventRow: View {
    let event: ProcessEventEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: eventIcon)
                .foregroundStyle(eventColor)
                .font(.caption)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(event.timestamp, style: .time)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text(event.timestamp, style: .date)
                        .font(.caption2).foregroundStyle(.tertiary)

                    Text(eventLabel)
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(eventColor.opacity(0.12)).foregroundStyle(eventColor)
                        .clipShape(Capsule())
                }

                HStack(spacing: 8) {
                    Text("PID \(event.pid)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)

                    let m = Int(event.ageMinutes)
                    let h = m / 60
                    Text(h > 0 ? "\(h)h\(String(format: "%02d", m % 60))m" : "\(m)m")
                        .font(.caption2).foregroundStyle(.tertiary)

                    Text(String(format: "%.0fMB", event.memMB))
                        .font(.caption2).foregroundStyle(.tertiary)

                    if !event.leakReason.isEmpty {
                        Text(event.leakReason)
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }

                if !event.cmdArgs.isEmpty {
                    Text(event.cmdArgs)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }

            Spacer()

            Text(event.status)
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(statusBg).foregroundStyle(statusFg)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.vertical, 2)
    }

    private var eventIcon: String {
        switch event.eventType {
        case "spawn":           return "plus.circle"
        case "leak_detected":   return "exclamationmark.triangle"
        case "cleanup_success": return "checkmark.circle"
        case "cleanup_failed":  return "xmark.circle"
        default:                return "circle"
        }
    }

    private var eventColor: Color {
        switch event.eventType {
        case "spawn":           return .blue
        case "leak_detected":   return .orange
        case "cleanup_success": return .green
        case "cleanup_failed":  return .red
        default:                return .secondary
        }
    }

    private var eventLabel: String {
        switch event.eventType {
        case "spawn":           return "신규"
        case "leak_detected":   return "누수감지"
        case "cleanup_success": return "정리완료"
        case "cleanup_failed":  return "정리실패"
        default:                return event.eventType
        }
    }

    private var statusBg: Color {
        switch event.status {
        case "CRITICAL": return .red.opacity(0.12)
        case "WARNING":  return .orange.opacity(0.12)
        default:         return .green.opacity(0.12)
        }
    }

    private var statusFg: Color {
        switch event.status {
        case "CRITICAL": return .red
        case "WARNING":  return .orange
        default:         return .green
        }
    }
}

// MARK: - Compact label style

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}
