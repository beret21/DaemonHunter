# Daemon Hunter

[한국어](README.ko.md)

> A macOS menu bar app that hunts zombie and idle Claude Code sub-agent processes — before they eat your RAM.

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black?logo=apple)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![License](https://img.shields.io/badge/license-MIT-green)

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

<!-- Add screenshots: run the app → Cmd+Shift+4 → select popover → save to img/ -->

### Status Popover

```
╔═══════════════════════════════════════════╗
║  🔴 CRITICAL          [AI 분석] [상세] [·]║
╠═══════════════════════════════════════════╣
║  AI Analysis  ✦ Apple Intelligence        ║
║  ──────────────────────────────────────  ║
║  42 sub-agents running, 8 idle.           ║
║  Total 9.2 GB memory occupied.            ║
║  💡 Clean up 8 idle processes.            ║
╠═══════════════════════════════════════════╣
║  42       9.2GB    8      📈    2   12    ║
║  agents  memory  leak   trend  alarm  mem ║
╠═══════════════════════════════════════════╣
║  CPU 34%  MEM 71%  🌡 Normal  Fan 2400rpm ║
╠═══════════════════════════════════════════╣
║  [🧹 Clean 8 leaked processes]            ║
╠═══════════════════════════════════════════╣
║  Daemon Hunter v0.1.3    [Self-Heal 🟢]  ║
╚═══════════════════════════════════════════╝
```

### Process Detail Window

```
╔══╦═══════╦═════╦════════╦══════╦════════════╦══════════════════╗
║  ║  PID  ║ Age ║ Memory ║ CPU% ║ Leak/Idle  ║      Name        ║
╠══╬═══════╬═════╬════════╬══════╬════════════╬══════════════════╣
║🟢║ 82841 ║  3m ║  231MB ║ 1.2% ║            ║ sonnet-4-5       ║
║🟡⏸║75632║ 45m ║  228MB ║ 0.0% ║ idle       ║ claude-mem obs.  ║
║🔴║ 23151 ║120m ║  229MB ║ 0.0% ║ parent-died║ claude-mem obs.  ║
╚══╩═══════╩═════╩════════╩══════╩════════════╩══════════════════╝
```

---

## Features

### Real-Time Process Monitoring
- Tracks all Claude Code main sessions and sub-agents via `proc_listpids` + `proc_pidpath`
- Detects sub-agents by `--output-format stream-json` flag
- Detects **claude-mem observers** by `--disallowedTools` flag (spawned by `bun worker-service`)
- 30-second polling interval (adaptive under system pressure)

### Idle / Zombie Detection
- Measures per-process CPU delta (`pti_total_user + pti_total_system`) every snapshot
- Sub-agent with < 10 ms CPU increase for 3+ consecutive polls → **idle** (≈ 90 seconds)
- Idle agents shown in orange; leaked agents shown in red

### Kalman Filter Prediction
- 2-state Kalman filter per metric: process count, memory, CPU%, thermal level
- Residual z-score anomaly detection (> 3σ triggers alarm)
- **Absolute value anomaly**: even well-predicted values alert if they exceed thresholds
- Forecast 5-min and 10-min ahead with 1σ/2σ confidence bounds
- All predictions stored in SQLite for historical analysis

### Apple Intelligence Analysis
- Uses `FoundationModels` (`@Generable`) for on-device LLM analysis
- Falls back to rule-based analysis in < 100 ms when AI is unavailable
- Structured output: severity, summary, recommendation, notification decision
- Auto-refreshes every 60 seconds when popover is open

### Self-Healing
- Monitors its own PID resource usage (`proc_pidinfo`)
- 5-level backpressure: Normal → Cautious → Reduced → Minimal → Suspended
- Circuit breaker for slow DB writes (> 500 ms)
- Adaptive polling: doubles interval under pressure, recovers with hysteresis

### Smart Notifications
- System notifications with actionable buttons (Confirm / Clean Up / Open)
- Time-sensitive interruption level for critical alerts
- 10-minute cooldown prevents duplicate notifications

### Trend Chart
- Historical sparkline overlaid with Kalman prediction line
- Fast-growing / slow-growing / stable / declining pattern detection
- Chronic leaker tracking (PID-level queue dwell time)

### SQLite Database (v5 schema)
- Process events: leak_detected, idle_detected, cleanup_done
- Kalman prediction history: metric, predicted, actual, residual
- Automatic migration with `PRAGMA user_version`

### Multilingual UI
- 10 languages: Korean, English, Japanese, Simplified Chinese, Traditional Chinese,
  Spanish, French, German, Portuguese, Arabic

---

## Requirements

| Item | Requirement |
|------|------------|
| **macOS** | 26.0 (Tahoe) or later |
| **Architecture** | Apple Silicon (M1/M2/M3/M4) only |
| **Swift** | 6.0 |

> Intel Mac is not supported — the app exits with an alert if running on Intel.

---

## Installation

### Download (Recommended)

1. Download `DaemonHunter-x.y.z.zip` from [Releases](https://github.com/beret21/DaemonHunter/releases)
2. Unzip and move `DaemonHunter.app` to Applications
3. After initial install, updates are delivered automatically via Sparkle

### Build from Source

```bash
git clone https://github.com/beret21/DaemonHunter.git
cd DaemonHunter
open ClaudeAgentMonitor.xcodeproj
# Product → Archive → Distribute App
```

---

## Architecture

```
DaemonHunter/
├── App/
│   ├── ClaudeAgentMonitorApp.swift   # @main, MenuBarExtra, Window scenes
│   └── AppDelegate.swift             # Lifecycle, ProcessMonitor → PredictionEngine
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
    ├── StatusPopoverView.swift        # Main popover (360 px wide)
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
3. **Idle condition**: CPU delta < 10 ms for 3 consecutive 30-second polls

One real-world incident: **107 observer agents** accumulated (≈ 12 GB RAM) across two work sessions before cleanup.

---

## Changelog

### v0.1.3 — 2026-06-22

- **New**: Renamed app from "AI Agent Monitor" to **Daemon Hunter**
- **New**: `claude-mem` observer detection via `--disallowedTools` flag
- **New**: "Name" column in Process Detail view (`cmdArgs`)
- **New**: Purple status indicator for claude-mem observer processes
- **New**: Traffic-light menu bar icon (green / yellow / red) with pulsing animation
- **New**: Build number auto-increment via `buildnumber.txt` (Xcode build phase)
- **New**: White background popover for better readability
- **New**: `mem관찰` stats cell in status popover
- **Fix**: Observer leak threshold set to 30 min (vs 90 min for regular sub-agents)

### v0.1.0 — 2026-06-19

- Initial release
- Real-time Claude Code sub-agent process monitoring
- Idle detection (CPU delta < 10 ms × 3 consecutive snapshots)
- Kalman filter prediction with residual z-score anomaly detection
- Absolute value anomaly alerting (process count, memory, CPU, thermal)
- Apple Intelligence on-device analysis with rule-based fallback
- Self-healing 5-level backpressure
- Smart notifications with 10-minute cooldown
- SQLite v5 schema with automatic migration
- 10-language UI

---

## Contributing

Issues and PRs welcome. Please open an issue before starting large changes.

---

## License

MIT License — see [LICENSE](LICENSE) for details.
