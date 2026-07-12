import Foundation
import Combine

// MARK: - Supported Languages
//
// 새 언어 추가 방법:
// 1. `SupportedLanguage` 케이스 추가
// 2. `strings` 딕셔너리에 번역 추가
// 3. 앱 재배포 (마이그레이션 불필요)

enum SupportedLanguage: String, CaseIterable, Identifiable {
    // 케이스 순서 = 설정 화면에 표시되는 순서
    case systemDefault = "system"
    case korean        = "ko"
    case english       = "en"
    case japanese      = "ja"
    case chineseSimp   = "zh-Hans"
    case chineseTrad   = "zh-Hant"
    case spanish       = "es"
    case french        = "fr"
    case german        = "de"
    case portuguese    = "pt"
    case arabic        = "ar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault: return "시스템 기본값"
        case .korean:        return "한국어"
        case .english:       return "English"
        case .japanese:      return "日本語"
        case .chineseSimp:   return "中文（简体）"
        case .chineseTrad:   return "中文（繁體）"
        case .spanish:       return "Español"
        case .french:        return "Français"
        case .german:        return "Deutsch"
        case .portuguese:    return "Português"
        case .arabic:        return "العربية"
        }
    }

    var flag: String {
        switch self {
        case .systemDefault: return "🌐"
        case .korean:        return "🇰🇷"
        case .english:       return "🇺🇸"
        case .japanese:      return "🇯🇵"
        case .chineseSimp:   return "🇨🇳"
        case .chineseTrad:   return "🇹🇼"
        case .spanish:       return "🇪🇸"
        case .french:        return "🇫🇷"
        case .german:        return "🇩🇪"
        case .portuguese:    return "🇧🇷"
        case .arabic:        return "🇸🇦"
        }
    }

    var isRTL: Bool { self == .arabic }

    /// 현재 공식 지원 언어: 한국어·영어. (다국어 확장이 목표이나 정식 지원 전까지는 두 언어만)
    /// 시스템 기본 언어가 한국어면 한국어, 그 외(영어 포함 미지원 언어)는 영어로.
    static func detectSystem() -> SupportedLanguage {
        let base = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
        return base == "ko" ? .korean : .english
    }

    /// 설정 화면에 노출할, 현재 정식 지원하는 선택지(시스템 기본값 + 한국어 + 영어).
    /// 나머지 언어의 번역 데이터는 향후 정식 지원을 위해 보존만 한다.
    static var officiallySupported: [SupportedLanguage] { [.systemDefault, .korean, .english] }
}

// MARK: - String Keys
//
// UI 문자열을 타입 안전하게 참조하기 위한 열거형.
// 새 문자열 추가: 1) 케이스 추가, 2) 각 언어 딕셔너리에 번역 추가.

enum L10nKey: String {
    // App
    case appName = "app.name"

    // Header / Status
    case statusNormal   = "status.normal"
    case statusWarning  = "status.warning"
    case statusCritical = "status.critical"

    // AI Section
    case aiAnalysis        = "ai.analysis"
    case aiAnalyzing       = "ai.analyzing"
    case aiReanalyze       = "ai.reanalyze"
    case aiAppleIntel      = "ai.apple_intelligence"
    case aiRuleBased       = "ai.rule_based"

    // Stats
    case statAgents    = "stat.agents"
    case statMemory    = "stat.memory"
    case statLeaks     = "stat.leaks"
    case statTrend     = "stat.trend"
    case statSession   = "stat.session"

    // Trend
    case trendStable      = "trend.stable"
    case trendSlowGrowing = "trend.slow_growing"
    case trendFastGrowing = "trend.fast_growing"
    case trendSpike       = "trend.spike"
    case trendShrinking   = "trend.shrinking"

    // Actions
    case actionCleanup     = "action.cleanup"
    case actionCleaning    = "action.cleaning"
    case actionCleanupDone = "action.cleanup_done"
    case actionLog         = "action.log"
    case actionSettings    = "action.settings"
    case actionQuit        = "action.quit"
    case actionUpdate      = "action.update"

    // Settings
    case settingsTitle     = "settings.title"
    case settingsGeneral   = "settings.general"
    case settingsThreshold = "settings.threshold"
    case settingsLanguage  = "settings.language"
    case settingsAbout     = "settings.about"

    // Log
    case logTitle         = "log.title"
    case logEmpty         = "log.empty"
    case logEmptyHint     = "log.empty_hint"
    case logTotal         = "log.total"

    // Notification
    case notifWarningTitle  = "notif.warning_title"
    case notifCriticalTitle = "notif.critical_title"
    case notifCleanupTitle  = "notif.cleanup_title"
    case notifActionConfirm = "notif.action.confirm"
    case notifActionCleanup = "notif.action.cleanup"
    case notifActionOpen    = "notif.action.open"
}

// MARK: - Translation Tables
//
// 구조: [L10nKey: [SupportedLanguage: String]]
// 미번역 키는 영어로 폴백.

private let translations: [L10nKey: [SupportedLanguage: String]] = [

    .appName: [
        .korean: "데몬 헌터",
        .english: "Daemon Hunter",
        .japanese: "デーモンハンター",
        .chineseSimp: "守护进程猎手",
        .chineseTrad: "守護行程獵人",
        .spanish: "Cazador de Daemons",
        .french: "Chasseur de Daemons",
        .german: "Daemon-Jäger",
        .portuguese: "Caçador de Daemons",
        .arabic: "صائد العمليات",
    ],

    .statusNormal: [
        .korean: "NORMAL", .english: "NORMAL", .japanese: "正常",
        .chineseSimp: "正常", .chineseTrad: "正常", .spanish: "NORMAL",
        .french: "NORMAL", .german: "NORMAL", .portuguese: "NORMAL", .arabic: "طبيعي",
    ],
    .statusWarning: [
        .korean: "WARNING", .english: "WARNING", .japanese: "警告",
        .chineseSimp: "警告", .chineseTrad: "警告", .spanish: "AVISO",
        .french: "ALERTE", .german: "WARNUNG", .portuguese: "AVISO", .arabic: "تحذير",
    ],
    .statusCritical: [
        .korean: "CRITICAL", .english: "CRITICAL", .japanese: "危険",
        .chineseSimp: "危险", .chineseTrad: "危險", .spanish: "CRÍTICO",
        .french: "CRITIQUE", .german: "KRITISCH", .portuguese: "CRÍTICO", .arabic: "حرج",
    ],

    .aiAnalysis: [
        .korean: "AI 분석", .english: "AI Analysis", .japanese: "AI分析",
        .chineseSimp: "AI分析", .chineseTrad: "AI分析", .spanish: "Análisis IA",
        .french: "Analyse IA", .german: "KI-Analyse", .portuguese: "Análise IA", .arabic: "تحليل الذكاء الاصطناعي",
    ],
    .aiAnalyzing: [
        .korean: "분석 중...", .english: "Analyzing...", .japanese: "分析中...",
        .chineseSimp: "分析中...", .chineseTrad: "分析中...", .spanish: "Analizando...",
        .french: "Analyse...", .german: "Analysiere...", .portuguese: "Analisando...", .arabic: "جارٍ التحليل...",
    ],
    .aiReanalyze: [
        .korean: "재분석", .english: "Reanalyze", .japanese: "再分析",
        .chineseSimp: "重新分析", .chineseTrad: "重新分析", .spanish: "Reanalizar",
        .french: "Réanalyser", .german: "Erneut analysieren", .portuguese: "Reanalisar", .arabic: "إعادة التحليل",
    ],
    .aiAppleIntel: [
        .korean: "Apple Intelligence", .english: "Apple Intelligence",
        .japanese: "Apple Intelligence", .chineseSimp: "Apple Intelligence",
        .chineseTrad: "Apple Intelligence", .spanish: "Apple Intelligence",
        .french: "Apple Intelligence", .german: "Apple Intelligence",
        .portuguese: "Apple Intelligence", .arabic: "Apple Intelligence",
    ],
    .aiRuleBased: [
        .korean: "규칙 기반", .english: "Rule-based", .japanese: "ルールベース",
        .chineseSimp: "基于规则", .chineseTrad: "基於規則", .spanish: "Basado en reglas",
        .french: "Basé sur règles", .german: "Regelbasiert", .portuguese: "Baseado em regras", .arabic: "قائم على القواعد",
    ],

    .statAgents: [
        .korean: "앱", .english: "Apps", .japanese: "アプリ",
        .chineseSimp: "应用", .chineseTrad: "應用程式", .spanish: "Aplicaciones",
        .french: "Applications", .german: "Anwendungen", .portuguese: "Aplicativos", .arabic: "التطبيقات",
    ],
    .statMemory: [
        .korean: "메모리", .english: "Memory", .japanese: "メモリ",
        .chineseSimp: "内存", .chineseTrad: "記憶體", .spanish: "Memoria",
        .french: "Mémoire", .german: "Speicher", .portuguese: "Memória", .arabic: "ذاكرة",
    ],
    .statLeaks: [
        .korean: "누수", .english: "Leaks", .japanese: "リーク",
        .chineseSimp: "泄漏", .chineseTrad: "洩漏", .spanish: "Fugas",
        .french: "Fuites", .german: "Lecks", .portuguese: "Vazamentos", .arabic: "تسريبات",
    ],
    .statTrend: [
        .korean: "추세", .english: "Trend", .japanese: "傾向",
        .chineseSimp: "趋势", .chineseTrad: "趨勢", .spanish: "Tendencia",
        .french: "Tendance", .german: "Trend", .portuguese: "Tendência", .arabic: "اتجاه",
    ],
    .statSession: [
        .korean: "세션", .english: "Session", .japanese: "セッション",
        .chineseSimp: "会话", .chineseTrad: "工作階段", .spanish: "Sesión",
        .french: "Session", .german: "Sitzung", .portuguese: "Sessão", .arabic: "جلسة",
    ],

    .trendStable: [
        .korean: "안정", .english: "Stable", .japanese: "安定",
        .chineseSimp: "稳定", .chineseTrad: "穩定", .spanish: "Estable",
        .french: "Stable", .german: "Stabil", .portuguese: "Estável", .arabic: "مستقر",
    ],
    .trendSlowGrowing: [
        .korean: "완만 증가", .english: "Slow Growth", .japanese: "緩やか増加",
        .chineseSimp: "缓慢增长", .chineseTrad: "緩慢增長", .spanish: "Crecimiento lento",
        .french: "Croissance lente", .german: "Langsames Wachstum", .portuguese: "Crescimento lento", .arabic: "نمو بطيء",
    ],
    .trendFastGrowing: [
        .korean: "급속 증가", .english: "Fast Growth", .japanese: "急速増加",
        .chineseSimp: "快速增长", .chineseTrad: "快速增長", .spanish: "Crecimiento rápido",
        .french: "Croissance rapide", .german: "Schnelles Wachstum", .portuguese: "Crescimento rápido", .arabic: "نمو سريع",
    ],
    .trendSpike: [
        .korean: "일시 급증", .english: "Spike", .japanese: "急増",
        .chineseSimp: "突增", .chineseTrad: "突增", .spanish: "Pico",
        .french: "Pic", .german: "Spitze", .portuguese: "Pico", .arabic: "ارتفاع مفاجئ",
    ],
    .trendShrinking: [
        .korean: "감소 중", .english: "Shrinking", .japanese: "減少中",
        .chineseSimp: "减少中", .chineseTrad: "減少中", .spanish: "Disminuyendo",
        .french: "Diminution", .german: "Schrumpfend", .portuguese: "Diminuindo", .arabic: "تناقص",
    ],

    .actionCleanup: [
        .korean: "누수 정리", .english: "Clean Leaks", .japanese: "リーク整理",
        .chineseSimp: "清理泄漏", .chineseTrad: "清理洩漏", .spanish: "Limpiar fugas",
        .french: "Nettoyer fuites", .german: "Lecks bereinigen", .portuguese: "Limpar vazamentos", .arabic: "تنظيف التسريبات",
    ],
    .actionCleaning: [
        .korean: "정리 중...", .english: "Cleaning...", .japanese: "整理中...",
        .chineseSimp: "清理中...", .chineseTrad: "清理中...", .spanish: "Limpiando...",
        .french: "Nettoyage...", .german: "Bereinige...", .portuguese: "Limpando...", .arabic: "جارٍ التنظيف...",
    ],
    .actionLog: [
        .korean: "로그", .english: "Log", .japanese: "ログ",
        .chineseSimp: "日志", .chineseTrad: "日誌", .spanish: "Registro",
        .french: "Journal", .german: "Protokoll", .portuguese: "Registro", .arabic: "سجل",
    ],
    .actionSettings: [
        .korean: "설정", .english: "Settings", .japanese: "設定",
        .chineseSimp: "设置", .chineseTrad: "設定", .spanish: "Ajustes",
        .french: "Réglages", .german: "Einstellungen", .portuguese: "Configurações", .arabic: "إعدادات",
    ],
    .actionQuit: [
        .korean: "종료", .english: "Quit", .japanese: "終了",
        .chineseSimp: "退出", .chineseTrad: "退出", .spanish: "Salir",
        .french: "Quitter", .german: "Beenden", .portuguese: "Sair", .arabic: "إنهاء",
    ],
    .actionUpdate: [
        .korean: "업데이트", .english: "Update", .japanese: "アップデート",
        .chineseSimp: "更新", .chineseTrad: "更新", .spanish: "Actualizar",
        .french: "Mettre à jour", .german: "Aktualisieren", .portuguese: "Atualizar", .arabic: "تحديث",
    ],

    .settingsTitle: [
        .korean: "설정", .english: "Settings", .japanese: "設定",
        .chineseSimp: "设置", .chineseTrad: "設定", .spanish: "Ajustes",
        .french: "Réglages", .german: "Einstellungen", .portuguese: "Configurações", .arabic: "إعدادات",
    ],
    .settingsGeneral: [
        .korean: "일반", .english: "General", .japanese: "一般",
        .chineseSimp: "通用", .chineseTrad: "一般", .spanish: "General",
        .french: "Général", .german: "Allgemein", .portuguese: "Geral", .arabic: "عام",
    ],
    .settingsThreshold: [
        .korean: "임계값", .english: "Thresholds", .japanese: "しきい値",
        .chineseSimp: "阈值", .chineseTrad: "閾值", .spanish: "Umbrales",
        .french: "Seuils", .german: "Schwellenwerte", .portuguese: "Limites", .arabic: "العتبات",
    ],
    .settingsLanguage: [
        .korean: "언어", .english: "Language", .japanese: "言語",
        .chineseSimp: "语言", .chineseTrad: "語言", .spanish: "Idioma",
        .french: "Langue", .german: "Sprache", .portuguese: "Idioma", .arabic: "اللغة",
    ],
    .settingsAbout: [
        .korean: "정보", .english: "About", .japanese: "情報",
        .chineseSimp: "关于", .chineseTrad: "關於", .spanish: "Acerca",
        .french: "À propos", .german: "Info", .portuguese: "Sobre", .arabic: "حول",
    ],

    .logTitle: [
        .korean: "정리 로그", .english: "Cleanup Log", .japanese: "整理ログ",
        .chineseSimp: "清理日志", .chineseTrad: "清理日誌", .spanish: "Registro de limpieza",
        .french: "Journal de nettoyage", .german: "Bereinigungsprotokoll", .portuguese: "Registro de limpeza", .arabic: "سجل التنظيف",
    ],
    .logEmpty: [
        .korean: "정리 기록 없음", .english: "No cleanup records", .japanese: "整理記録なし",
        .chineseSimp: "无清理记录", .chineseTrad: "無清理記錄", .spanish: "Sin registros",
        .french: "Aucun enregistrement", .german: "Keine Einträge", .portuguese: "Sem registros", .arabic: "لا توجد سجلات تنظيف",
    ],

    .notifWarningTitle: [
        .korean: "⚠️ 경고 — Daemon Hunter",
        .english: "⚠️ Warning — Daemon Hunter",
        .japanese: "⚠️ 警告 — Daemon Hunter",
        .chineseSimp: "⚠️ 警告 — Daemon Hunter",
        .chineseTrad: "⚠️ 警告 — Daemon Hunter",
        .spanish: "⚠️ Advertencia — Daemon Hunter",
        .french: "⚠️ Alerte — Daemon Hunter",
        .german: "⚠️ Warnung — Daemon Hunter",
        .portuguese: "⚠️ Aviso — Daemon Hunter",
        .arabic: "⚠️ تحذير — Daemon Hunter",
    ],
    .notifCriticalTitle: [
        .korean: "🔴 위험 — Daemon Hunter",
        .english: "🔴 Critical — Daemon Hunter",
        .japanese: "🔴 危険 — Daemon Hunter",
        .chineseSimp: "🔴 危险 — Daemon Hunter",
        .chineseTrad: "🔴 危險 — Daemon Hunter",
        .spanish: "🔴 Crítico — Daemon Hunter",
        .french: "🔴 Critique — Daemon Hunter",
        .german: "🔴 Kritisch — Daemon Hunter",
        .portuguese: "🔴 Crítico — Daemon Hunter",
        .arabic: "🔴 حرج — Daemon Hunter",
    ],
    .notifActionConfirm: [
        .korean: "확인", .english: "OK", .japanese: "確認",
        .chineseSimp: "确认", .chineseTrad: "確認", .spanish: "Aceptar",
        .french: "OK", .german: "OK", .portuguese: "OK", .arabic: "موافق",
    ],
    .notifActionCleanup: [
        .korean: "누수 정리", .english: "Clean Leaks", .japanese: "リーク整理",
        .chineseSimp: "清理泄漏", .chineseTrad: "清理洩漏", .spanish: "Limpiar",
        .french: "Nettoyer", .german: "Bereinigen", .portuguese: "Limpar", .arabic: "تنظيف",
    ],
    .notifActionOpen: [
        .korean: "열기", .english: "Open", .japanese: "開く",
        .chineseSimp: "打开", .chineseTrad: "開啟", .spanish: "Abrir",
        .french: "Ouvrir", .german: "Öffnen", .portuguese: "Abrir", .arabic: "فتح",
    ],
]

// MARK: - Manager

@MainActor
final class LocalizationManager: ObservableObject {
    @Published private(set) var currentLanguage: SupportedLanguage

    static let shared = LocalizationManager()

    private let key = "selectedLanguage"

    private init() {
        let saved = UserDefaults.standard.string(forKey: "selectedLanguage") ?? SupportedLanguage.systemDefault.rawValue
        let lang  = SupportedLanguage(rawValue: saved) ?? .systemDefault
        currentLanguage = lang
    }

    func setLanguage(_ lang: SupportedLanguage) {
        currentLanguage = lang
        UserDefaults.standard.set(lang.rawValue, forKey: key)
    }

    /// 실제 사용할 언어 (systemDefault → 시스템 언어 감지)
    var resolved: SupportedLanguage {
        currentLanguage == .systemDefault ? SupportedLanguage.detectSystem() : currentLanguage
    }

    func string(_ key: L10nKey) -> String {
        let lang = resolved
        // 1) 현재 언어 찾기
        if let s = translations[key]?[lang], !s.isEmpty { return s }
        // 2) 영어 폴백
        if let s = translations[key]?[.english], !s.isEmpty { return s }
        // 3) 키 이름 그대로 반환 (미번역 감지용)
        return key.rawValue
    }
}

// MARK: - Convenience

/// 짧은 표기: `L10n(.appName)` — UI 코드(MainActor)에서만 호출
@MainActor
func L10n(_ key: L10nKey) -> String {
    LocalizationManager.shared.string(key)
}
