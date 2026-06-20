# 👻 Daemon Hunter

> A macOS menu bar app that hunts zombie and idle Claude Code sub-agent processes — before they eat your RAM.

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black?logo=apple)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![License](https://img.shields.io/badge/license-MIT-green)
![Build](https://img.shields.io/badge/build-passing-brightgreen)

---

## What It Does

Claude Code spawns many sub-agent processes during complex tasks. These agents should exit when their work is done — but often they don't. They linger in memory, consuming hundreds of MB each and silently heating up your Mac.

**Daemon Hunter** watches your system in real time, identifies zombie and idle agents, and lets you reclaim that memory in one click.

```
Menu Bar Icon (traffic-light status)
┌─────────────────────────────────────────┐
│  🟢 cpu  ← Normal (green, no count)    │
│  🟡 cpu  ← Warning (yellow, pulsing)   │
│  🔴 ⚠    ← Critical (red, fast pulse) │
└─────────────────────────────────────────┘
```

---

## Screenshots

<!-- Replace with actual screenshots: Cmd+Shift+4 → select popover window -->
> **How to add screenshots:**
> 1. Run the app
> 2. Click the menu bar icon to open the popover
> 3. Press `Cmd+Shift+4` and select the popover window
> 4. Save to `docs/screenshots/` and update links below

### Status Popover

```
╔═══════════════════════════════════════════╗
║  🔴 CRITICAL          [AI 분석] [상세] [·]║
╠═══════════════════════════════════════════╣
║  AI 분석  ✦ Apple Intelligence           ║
║  ──────────────────────────────────────  ║
║  서브 에이전트 42개 실행 중이며 8개가    ║
║  유휴 상태입니다. 총 9.2GB 메모리 점유.  ║
║  💡 유휴 프로세스 8개를 정리하세요.      ║
╠═══════════════════════════════════════════╣
║  42       9.2GB    8      📈    2   12   ║
║  에이전트  메모리  누수   추세  경보 mem관찰║
╠═══════════════════════════════════════════╣
║  CPU 34%  MEM 71%  🌡 보통  팬 2400rpm   ║
╠═══════════════════════════════════════════╣
║  [🧹 누수 8개 정리]                      ║
╠═══════════════════════════════════════════╣
║  Daemon Hunter v0.1.3    [자가치유 🟢]   ║
╚═══════════════════════════════════════════╝
```

### Process Detail Window

```
╔══╦═══════╦═════╦════════╦══════╦════════════╦══════════════════╗
║  ║  PID  ║ 경과 ║ 메모리 ║ CPU% ║ 누수/유휴  ║      이름        ║
╠══╬═══════╬═════╬════════╬══════╬════════════╬══════════════════╣
║🟢║ 82841 ║  3m  ║  231MB ║ 1.2% ║           ║ sonnet-4-5       ║
║🟡⏸║75632 ║ 45m  ║  228MB ║ 0.0% ║ 유휴       ║ claude-mem 관찰자║
║🔴║ 23151 ║120m  ║  229MB ║ 0.0% ║ 부모사망   ║ claude-mem 관찰자║
╚══╩═══════╩═════╩════════╩══════╩════════════╩══════════════════╝
```

---

## Features

### 🔍 Real-Time Process Monitoring
- Tracks all Claude Code main sessions and sub-agents via `proc_listpids` + `proc_pidpath`
- Detects sub-agents by `--output-format stream-json` flag
- Detects **claude-mem observers** by `--disallowedTools` flag (spawned by `bun worker-service`)
- 30-second polling interval (adaptive under system pressure)

### 🧠 Idle / Zombie Detection
- Measures per-process CPU delta (`pti_total_user + pti_total_system`) every snapshot
- Sub-agent with < 10ms CPU increase for 3+ consecutive polls → **idle** (≈ 90 seconds)
- Idle agents shown in orange; leaked agents shown in red

### 📈 Kalman Filter Prediction
- 2-state Kalman filter per metric: process count, memory, CPU%, thermal level
- Residual z-score anomaly detection (> 3σ triggers alarm)
- **Absolute value anomaly**: even well-predicted values alert if they exceed thresholds
- Forecast 5-min and 10-min ahead with 1σ/2σ confidence bounds
- All predictions stored in SQLite for historical analysis

### 🤖 Apple Intelligence Analysis
- Uses `FoundationModels` (`@Generable`) for on-device LLM analysis
- Falls back to rule-based analysis in < 100ms when AI is unavailable
- Structured output: severity, summary, recommendation, notification decision
- Auto-refreshes every 60 seconds when popover is open

### 🚑 Self-Healing
- Monitors its own PID resource usage (`proc_pidinfo`)
- 5-level backpressure: Normal → Cautious → Reduced → Minimal → Suspended
- Circuit breaker for slow DB writes (> 500ms)
- Adaptive polling: doubles interval under pressure, recovers with hysteresis

### 🔔 Smart Notifications
- System notifications with actionable buttons (Confirm / Clean Up / Open)
- Time-sensitive interruption level for critical alerts
- 10-minute cooldown prevents duplicate notifications
- Separate category registration per status level

### 📊 Trend Chart
- Historical sparkline overlaid with Kalman prediction line
- Fast-growing / slow-growing / stable / declining pattern detection
- Chronic leaker tracking (PID-level queue dwell time)

### 🛢 SQLite Database (v5 schema)
- Process events: leak_detected, idle_detected, cleanup_done
- Kalman prediction history: metric, predicted, actual, residual
- Snapshot history for trend analysis
- Automatic migration with `PRAGMA user_version`

### 🌐 Multilingual UI
- 10 languages: Korean, English, Japanese, Simplified Chinese, Traditional Chinese,  
  Spanish, French, German, Portuguese, Arabic

---

## Requirements

| Item | Requirement |
|------|------------|
| **macOS** | 26.0 (Tahoe) or later |
| **Architecture** | Apple Silicon (M1/M2/M3/M4) only |
| **Xcode** | 16.0+ |
| **Swift** | 6.0 |

> Intel Mac is explicitly not supported — the app exits with an alert if running on Intel.

---

## Installation

### Build from Source

```bash
git clone https://github.com/beret21/DaemonHunter.git
cd DaemonHunter
open ClaudeAgentMonitor.xcodeproj
```

Then in Xcode: **Product → Run** (`⌘R`)

### Auto-Update (Sparkle)
Once set up, the app checks for updates automatically via the GitHub releases feed.

```bash
# First-time setup: generate Sparkle signing keys
./setup.sh
```

---

## Architecture

```
DaemonHunter/
├── App/
│   ├── ClaudeAgentMonitorApp.swift   # @main, MenuBarExtra, Window scenes
│   └── AppDelegate.swift             # Lifecycle, ProcessMonitor → PredictionEngine pipe
├── Core/
│   ├── AgentProcess.swift            # Data model + ProcessSnapshot + AppSettings
│   ├── ProcessMonitor.swift          # libproc scanning, idle enrichment
│   ├── ProcessHistoryTracker.swift   # Snapshot recording, trend analysis
│   ├── PredictionEngine.swift        # Kalman filter, anomaly detection
│   ├── DatabaseManager.swift         # SQLite3 + migration (v1–v5)
│   ├── SelfHealingManager.swift      # Backpressure, circuit breaker
│   ├── ResourceTracker.swift         # Own-PID memory/CPU monitoring
│   ├── SystemMetrics.swift           # CPU%, load avg, thermal, fan
│   └── LocalizationManager.swift     # 10-language string table
├── Intelligence/
│   ├── ProcessAnalyzer.swift         # Apple Intelligence + rule-based fallback
│   └── NotificationCoordinator.swift # UNUserNotificationCenter, categories
└── UI/
    ├── StatusPopoverView.swift        # Main popover (360px wide)
    ├── ProcessDetailView.swift        # Sortable/filterable process table
    ├── SettingsView.swift             # 6-tab settings panel
    ├── TrendChartView.swift           # Canvas-based sparkline + Kalman overlay
    └── CleanupLogView.swift           # Process event history log
```

---

## How Zombie Detection Works

Claude Code uses [`claude-mem`](https://github.com/thedotmack/claude-mem) as an MCP plugin for persistent memory. It runs:

```
bun worker-service.cjs --daemon          ← persistent daemon (PPID=1/launchd)
  ├── node mcp-server.cjs               ← per-session stdio MCP server
  ├── claude --output-format stream-json \
  │         --disallowedTools Bash,...  ← memory observer agent (one per session)
  └── python chroma-mcp                 ← ChromaDB vector store
```

The **memory observer agents** (`--disallowedTools`) are supposed to save memory and exit. They often don't. Daemon Hunter detects them via:

1. **Identification**: path ends with `/claude` + args contain `--disallowedTools`
2. **Leak condition**: age > `leakAgeMinutes` (default 30 min, vs 90 min for regular sub-agents)
3. **Idle condition**: CPU delta < 10ms for 3 consecutive 30-second polls

One real-world incident: **107 observer agents** accumulated (≈ 12 GB RAM) across two work sessions before cleanup.

---

## Contributing

Issues and PRs welcome. Please open an issue before starting large changes.

```bash
# Run locally
open ClaudeAgentMonitor.xcodeproj
# ⌘R to build and run
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

---

# 👻 Daemon Hunter (한국어)

> 좀비가 된 Claude Code 서브에이전트 프로세스를 찾아내고 정리하는 macOS 메뉴바 앱

---

## 무엇을 하는 앱인가요?

Claude Code는 복잡한 작업 수행 시 수많은 서브에이전트 프로세스를 생성합니다. 이 에이전트들은 작업 완료 후 종료되어야 하지만, 실제로는 그렇지 않은 경우가 많습니다. 수백 MB의 메모리를 점유한 채 Mac을 조용히 달구고 있습니다.

**Daemon Hunter**는 시스템을 실시간으로 감시하여 좀비·유휴 에이전트를 찾아내고, 클릭 한 번으로 메모리를 회수할 수 있게 합니다.

---

## 주요 기능

### 🔍 실시간 프로세스 모니터링
- `proc_listpids` + `proc_pidpath`로 Claude Code 메인/서브에이전트 전체 추적
- `--output-format stream-json` 플래그로 서브에이전트 식별
- `--disallowedTools` 플래그로 **claude-mem 관찰자** 별도 감지
- 기본 30초 폴링 (시스템 부하 시 자동 조정)

### 🧠 유휴/좀비 감지
- 스냅샷마다 프로세스별 CPU 델타 측정 (`pti_total_user + pti_total_system`)
- 3회 연속 CPU 증가량 < 10ms → **유휴** 판정 (약 90초)
- 유휴는 주황색, 누수는 빨간색으로 표시

### 📈 칼만 필터 예측
- 프로세스 수·메모리·CPU·발열 4개 지표에 칼만 필터 적용
- 잔차 z-score 이상 탐지 (3σ 초과 시 경보)
- **절대값 이상**: 예측이 정확해도 값 자체가 위험 수준이면 경보
- 5분·10분 후 예측 + 1σ/2σ 신뢰 구간

### 🤖 Apple Intelligence 분석
- `FoundationModels`(`@Generable`)로 디바이스 내 LLM 분석
- AI 미사용 시 규칙 기반 분석으로 즉시 폴백 (< 100ms)
- 구조화 출력: 심각도, 요약, 권고사항, 알림 여부

### 🚑 자가치유 (Self-Healing)
- 앱 자신의 PID 리소스 모니터링
- 5단계 백프레셔: 정상 → 주의 → 감소 → 최소 → 일시정지
- DB 쓰기 서킷 브레이커 (500ms 초과 시 차단)
- 앱 자체가 시스템 부하의 원인이 되지 않도록 설계

### 🔔 스마트 알림
- 시스템 알림 + 즉각 실행 버튼 (확인 / 누수 정리 / 열기)
- 중복 알림 방지 (10분 쿨다운)
- 경고·위험 단계별 알림 카테고리 구분

### 🌐 다국어 지원
- 10개 언어: 한국어, 영어, 일본어, 중국어(간체/번체), 스페인어, 프랑스어, 독일어, 포르투갈어, 아랍어

---

## 시스템 요구사항

| 항목 | 요구사항 |
|------|---------|
| **macOS** | 26.0 (Tahoe) 이상 |
| **아키텍처** | Apple Silicon 전용 (M1/M2/M3/M4) |
| **Xcode** | 16.0 이상 |
| **Swift** | 6.0 |

---

## 설치 방법

```bash
git clone https://github.com/beret21/DaemonHunter.git
cd DaemonHunter
open ClaudeAgentMonitor.xcodeproj
```

Xcode에서 **Product → Run** (`⌘R`)

---

## claude-mem 좀비 발생 원리

Claude Code는 메모리 플러그인 [`claude-mem`](https://github.com/thedotmack/claude-mem)을 통해 다음 프로세스를 생성합니다:

```
bun worker-service.cjs --daemon          ← 지속형 데몬 (PPID=1)
  ├── node mcp-server.cjs               ← 세션별 stdio MCP 서버
  ├── claude --output-format stream-json \
  │         --disallowedTools Bash,...  ← 메모리 관찰자 에이전트
  └── python chroma-mcp                 ← ChromaDB 벡터 DB
```

메모리 관찰자 에이전트는 기억 저장 후 종료되어야 하지만, 종료되지 않아 누적됩니다.
실제 사례: 두 작업 세션에 걸쳐 **107개 관찰자** 축적 (약 12GB RAM 점유) → Daemon Hunter로 일괄 정리.

---

## 라이선스

MIT License
