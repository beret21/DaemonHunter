import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("monitorInterval")    private var interval:    Double = 30
    @AppStorage("leakAgeMinutes")     private var leakAge:     Double = 30
    @AppStorage("leakCPUThreshold")   private var leakCPU:     Double = 0.2
    @AppStorage("warnCount")          private var warnCount:   Double = 20
    @AppStorage("critCount")          private var critCount:   Double = 50
    @AppStorage("critMemGB")          private var critMem:     Double = 10
    @AppStorage("glassOpacity")       private var glassOpacity:Double = 0.3

    @State private var launchAtLogin  = false
    @State private var showResetAlert = false

    var body: some View {
        TabView {
            generalTab.tabItem    { Label("일반", systemImage: "gear") }
            thresholdsTab.tabItem { Label("임계값", systemImage: "slider.horizontal.3") }
            selfHealingTab.tabItem{ Label("자가치유", systemImage: "heart.text.square") }
            appearanceTab.tabItem { Label("외관", systemImage: "paintbrush") }
            languageTab.tabItem   { Label("언어", systemImage: "globe") }
            aboutTab.tabItem      { Label("정보", systemImage: "info.circle") }
        }
        .padding()
        .frame(width: 480, height: 420)
        .onAppear { launchAtLogin = isLaunchAtLoginEnabled() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("모니터링") {
                LabeledContent("갱신 주기: \(Int(interval))초") {
                    Slider(value: $interval, in: 10...120, step: 10)
                        .frame(width: 200)
                        .onChange(of: interval) { _ in
                            ProcessMonitor.shared.startMonitoring()
                        }
                }
            }
            Section("시스템") {
                Toggle("로그인 시 자동 시작", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in setLaunchAtLogin(v) }
            }
            Section {
                Button("기본값 복원", role: .destructive) { showResetAlert = true }
                    .alert("설정 초기화", isPresented: $showResetAlert) {
                        Button("초기화", role: .destructive) { resetDefaults() }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text("모든 임계값이 기본값으로 초기화됩니다.")
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Thresholds

    private var thresholdsTab: some View {
        Form {
            Section("누수 판정 기준") {
                LabeledContent("유휴 판정 시간: \(Int(leakAge))분") {
                    Slider(value: $leakAge, in: 10...120, step: 5).frame(width: 180)
                }
                LabeledContent("유휴 CPU 기준: \(String(format: "%.1f", leakCPU))%") {
                    Slider(value: $leakCPU, in: 0.1...1.0, step: 0.1).frame(width: 180)
                }
            }
            Section("경고 임계값") {
                LabeledContent("경고 프로세스 수: \(Int(warnCount))개") {
                    Slider(value: $warnCount, in: 5...50, step: 5).frame(width: 180)
                }
                LabeledContent("위험 프로세스 수: \(Int(critCount))개") {
                    Slider(value: $critCount, in: 20...100, step: 10).frame(width: 180)
                }
                LabeledContent("위험 메모리: \(Int(critMem))GB") {
                    Slider(value: $critMem, in: 5...50, step: 5).frame(width: 180)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Self-Healing

    private var selfHealingTab: some View {
        SelfHealingSettingsView()
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Section("Liquid Glass") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("투명도: \(Int(glassOpacity * 100))%") {
                        Slider(value: $glassOpacity, in: 0.0...0.9, step: 0.05)
                            .frame(width: 200)
                    }
                    // 미리보기
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.regularMaterial)
                            .opacity(1.0 - glassOpacity)
                            .frame(height: 50)
                        Text("미리보기 — 팝업 배경과 유사")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Language

    private var languageTab: some View {
        LanguageSettingsView()
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Daemon Hunter")
                .font(.title2.weight(.semibold))
            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("DB 버전")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text("v\(DatabaseManager.shared.schemaVersion)")
                        .font(.caption).monospacedDigit()
                }
                Divider().frame(height: 24)
                VStack(spacing: 2) {
                    Text("언어")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(LocalizationManager.shared.currentLanguage.displayName)
                        .font(.caption)
                }
            }
            .padding(8)
            .background(.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Code sub-agent 프로세스를 모니터링하고")
                Text("Apple Intelligence로 상태를 분석합니다.")
            }
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)

            Link("GitHub — beret21/DaemonHunter",
                 destination: URL(string: "https://github.com/beret21/DaemonHunter")!)
                .font(.caption)

            Button("업데이트 확인") { UpdateManager.shared.checkForUpdates() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var appVersion: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "001"
        return "\(short).\(String(format: "%03d", Int(build) ?? 0))"
    }

    private func resetDefaults() {
        interval     = 30;  leakAge   = 30;  leakCPU  = 0.2
        warnCount    = 20;  critCount = 50;  critMem  = 10
        glassOpacity = 0.3
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            // 사용자가 시스템 환경설정에서 승인해야 할 수 있음
        }
    }
}

// MARK: - Language Settings View

private struct LanguageSettingsView: View {
    @StateObject private var lm = LocalizationManager.shared
    @State private var searchText = ""

    private var filteredLanguages: [SupportedLanguage] {
        if searchText.isEmpty { return SupportedLanguage.allCases }
        return SupportedLanguage.allCases.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
            || $0.rawValue.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 설명
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("표시 언어 선택")
                        .font(.subheadline.weight(.semibold))
                    Text("새 언어는 앱 업데이트로 추가됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            // 검색
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("언어 검색", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal).padding(.vertical, 8)

            Divider()

            // 언어 목록
            List(filteredLanguages) { lang in
                LanguageRow(
                    lang: lang,
                    isSelected: lm.currentLanguage == lang,
                    onSelect: { lm.setLanguage(lang) }
                )
                .listRowSeparator(.automatic)
            }
            .listStyle(.plain)

            Divider()

            // 현재 선택 표시
            HStack {
                Text("현재: \(lm.currentLanguage.flag) \(lm.currentLanguage.displayName)")
                    .font(.caption2).foregroundStyle(.secondary)
                if lm.currentLanguage == .systemDefault {
                    Text("→ \(SupportedLanguage.detectSystem().displayName)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if lm.currentLanguage != .systemDefault {
                    Button("기본값으로") { lm.setLanguage(.systemDefault) }
                        .font(.caption2).buttonStyle(.link)
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
    }
}

// MARK: - Language Row

private struct LanguageRow: View {
    let lang: SupportedLanguage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Text(lang.flag)
                    .font(.title3)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(lang.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if lang == .systemDefault {
                        Text("시스템 언어 자동 감지")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(lang.rawValue)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .font(.body.weight(.semibold))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Self-Healing Settings

private struct SelfHealingSettingsView: View {
    @ObservedObject private var healer = SelfHealingManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── 현재 상태 ─────────────────────────────────────
                GroupBox {
                    HStack(spacing: 12) {
                        Text(healer.level.emoji)
                            .font(.largeTitle)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("현재 모드: \(healer.level.description)")
                                .font(.headline)
                            if healer.healingActive {
                                Text(healer.statusMessage)
                                    .font(.caption).foregroundStyle(.orange)
                            } else {
                                Text("정상 동작 중 — 모든 기능 활성화")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(4)
                } label: {
                    Label("자가치유 상태", systemImage: "heart.text.square.fill")
                }

                // ── 자체 리소스 ───────────────────────────────────
                if let m = healer.selfMetrics {
                    GroupBox {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                metricLabel("메모리")
                                metricValue(String(format: "%.1f MB", m.memoryMB),
                                            warn: m.memoryMB > 150, critical: m.memoryMB > 300)
                                Spacer()
                            }
                            GridRow {
                                metricLabel("CPU 평균")
                                metricValue(String(format: "%.1f %%", m.cpuFraction * 100),
                                            warn: m.cpuFraction > 0.20, critical: m.cpuFraction > 0.40)
                                Spacer()
                            }
                            GridRow {
                                metricLabel("DB 크기")
                                metricValue(String(format: "%.1f MB", m.dbFileSizeMB),
                                            warn: m.dbFileSizeMB > 50, critical: m.dbFileSizeMB > 150)
                                Spacer()
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("앱 자체 리소스", systemImage: "cpu")
                    }
                }

                // ── 기능 게이팅 ───────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        gateRow("AI 분석",         healer.level.allowsAIAnalysis)
                        gateRow("리소스 추적",     healer.level.allowsResourceTracking)
                        gateRow("칼만 예측",       healer.level.allowsPredictionEngine)
                        gateRow("DB 전체 쓰기",    healer.level.allowsFullDBWrites)
                        gateRow("DB 최소 쓰기",    healer.level.allowsDBWrites)
                        HStack(spacing: 6) {
                            Image(systemName: healer.dbWriteBlocked ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(healer.dbWriteBlocked ? .red : .green)
                                .font(.caption)
                            Text("DB 회로차단기")
                                .font(.caption)
                            Spacer()
                            Text(healer.dbWriteBlocked ? "열림 (쓰기 차단)" : "닫힘")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                } label: {
                    Label("기능 상태", systemImage: "switch.2")
                }

                // ── 폴링 주기 ─────────────────────────────────────
                GroupBox {
                    HStack {
                        Text("현재 폴링 주기")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(healer.effectivePollingInterval))초")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(healer.healingActive ? .orange : .secondary)
                    }
                    .padding(4)
                } label: {
                    Label("모니터링", systemImage: "timer")
                }

                Text("자가치유는 자동으로 동작하며 수동 설정이 필요 없습니다.\n시스템이 회복되면 모든 기능이 자동으로 재활성화됩니다.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding()
        }
    }

    private func metricLabel(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
    }

    private func metricValue(_ text: String, warn: Bool, critical: Bool) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(critical ? .red : warn ? .orange : .primary)
    }

    private func gateRow(_ name: String, _ active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: active ? "checkmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(active ? .green : .gray)
                .font(.caption)
            Text(name).font(.caption)
            Spacer()
            Text(active ? "활성" : "일시중단")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
