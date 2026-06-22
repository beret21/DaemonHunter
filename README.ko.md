# Daemon Hunter

[English](README.md)

> 좀비가 된 Claude Code 서브에이전트 프로세스를 찾아내고 정리하는 macOS 메뉴바 앱

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black?logo=apple)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![License](https://img.shields.io/badge/license-MIT-green)

---

## 무엇을 하는 앱인가요?

Claude Code는 복잡한 작업 수행 시 수많은 서브에이전트 프로세스를 생성합니다. 이 에이전트들은 작업 완료 후 종료되어야 하지만, 실제로는 그렇지 않은 경우가 많습니다. 수백 MB의 메모리를 점유한 채 Mac을 조용히 달구고 있습니다.

**Daemon Hunter**는 시스템을 실시간으로 감시하여 좀비·유휴 에이전트를 찾아내고, 클릭 한 번으로 메모리를 회수할 수 있게 합니다.

```
메뉴바 아이콘 (신호등 상태)
┌─────────────────────────────────────────┐
│  🟢 cpu  ← 정상 (초록, 카운트 없음)    │
│  🟡 cpu  ← 경고 (노랑, 맥동)           │
│  🔴 ⚠    ← 위험 (빨강, 빠른 맥동)     │
└─────────────────────────────────────────┘
```

---

## 스크린샷

<!-- 스크린샷 추가: 앱 실행 → 메뉴바 아이콘 클릭 → Cmd+Shift+4 → 팝오버 선택 → img/ 저장 -->

### 상태 팝오버

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

### 프로세스 상세 창

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

## 주요 기능

### 실시간 프로세스 모니터링
- `proc_listpids` + `proc_pidpath`로 Claude Code 메인/서브에이전트 전체 추적
- `--output-format stream-json` 플래그로 서브에이전트 식별
- `--disallowedTools` 플래그로 **claude-mem 관찰자** 별도 감지
- 기본 30초 폴링 (시스템 부하 시 자동 조정)

### 유휴/좀비 감지
- 스냅샷마다 프로세스별 CPU 델타 측정 (`pti_total_user + pti_total_system`)
- 3회 연속 CPU 증가량 < 10ms → **유휴** 판정 (약 90초)
- 유휴는 주황색, 누수는 빨간색으로 표시

### 칼만 필터 예측
- 프로세스 수·메모리·CPU·발열 4개 지표에 칼만 필터 적용
- 잔차 z-score 이상 탐지 (3σ 초과 시 경보)
- **절대값 이상**: 예측이 정확해도 값 자체가 위험 수준이면 경보
- 5분·10분 후 예측 + 1σ/2σ 신뢰 구간
- 모든 예측값 SQLite에 저장

### Apple Intelligence 분석
- `FoundationModels`(`@Generable`)로 디바이스 내 LLM 분석
- AI 미사용 시 규칙 기반 분석으로 즉시 폴백 (< 100ms)
- 구조화 출력: 심각도, 요약, 권고사항, 알림 여부
- 팝오버 열림 시 60초마다 자동 갱신

### 자가치유 (Self-Healing)
- 앱 자신의 PID 리소스 모니터링 (`proc_pidinfo`)
- 5단계 백프레셔: 정상 → 주의 → 감소 → 최소 → 일시정지
- DB 쓰기 서킷 브레이커 (500ms 초과 시 차단)
- 앱 자체가 시스템 부하의 원인이 되지 않도록 설계

### 스마트 알림
- 시스템 알림 + 즉각 실행 버튼 (확인 / 누수 정리 / 열기)
- 중복 알림 방지 (10분 쿨다운)
- 경고·위험 단계별 알림 카테고리 구분

### 추세 차트
- 칼만 예측선이 오버레이된 히스토리 스파크라인
- 급성장/완만성장/안정/감소 패턴 감지
- 만성 누수 프로세스 추적 (PID 레벨 대기열 체류 시간)

### SQLite 데이터베이스 (v5 스키마)
- 프로세스 이벤트: leak_detected, idle_detected, cleanup_done
- 칼만 예측 히스토리: metric, predicted, actual, residual
- `PRAGMA user_version`으로 자동 마이그레이션

### 다국어 UI
- 10개 언어: 한국어, 영어, 일본어, 중국어(간체/번체), 스페인어, 프랑스어, 독일어, 포르투갈어, 아랍어

---

## 시스템 요구사항

| 항목 | 요구사항 |
|------|---------|
| **macOS** | 26.0 (Tahoe) 이상 |
| **아키텍처** | Apple Silicon 전용 (M1/M2/M3/M4) |
| **개발 언어** | Swift 6.0 |

> Intel Mac은 지원하지 않습니다 — Intel에서 실행 시 경고 후 종료됩니다.

---

## 설치 방법

### 다운로드 (권장)

1. [Releases](https://github.com/beret21/DaemonHunter/releases)에서 `DaemonHunter-x.y.z.zip` 다운로드
2. 압축 해제 후 `DaemonHunter.app`을 Applications로 이동
3. 최초 설치 이후 업데이트는 Sparkle을 통해 자동 배포

### 소스에서 빌드

```bash
git clone https://github.com/beret21/DaemonHunter.git
cd DaemonHunter
open ClaudeAgentMonitor.xcodeproj
# Product → Archive → Distribute App
```

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

**메모리 관찰자 에이전트**는 기억 저장 후 종료되어야 하지만, 종료되지 않아 누적됩니다.  
Daemon Hunter는 다음으로 감지합니다:

1. **식별**: 경로가 `/claude`로 끝나고 인수에 `--disallowedTools` 포함
2. **누수 조건**: 나이 > `leakAgeMinutes` (기본 30분, 일반 서브에이전트는 90분)
3. **유휴 조건**: 3회 연속 30초 폴링에서 CPU 델타 < 10ms

실제 사례: 두 작업 세션에 걸쳐 **107개 관찰자** 축적 (약 12GB RAM 점유) → Daemon Hunter로 일괄 정리.

---

## 변경 이력

### v0.1.3 — 2026-06-22

- **추가**: 앱 이름 "AI Agent Monitor" → **Daemon Hunter** 변경
- **추가**: `--disallowedTools` 플래그로 `claude-mem` 관찰자 프로세스 감지
- **추가**: 프로세스 상세 창에 "이름" 컬럼 추가 (`cmdArgs`)
- **추가**: claude-mem 관찰자 프로세스용 보라색 상태 표시
- **추가**: 신호등 메뉴바 아이콘 (초록/노랑/빨강) + 맥동 애니메이션
- **추가**: `buildnumber.txt` 기반 빌드 번호 자동 증가 (Xcode 빌드 페이즈)
- **추가**: 가독성 향상을 위한 흰색 배경 팝오버
- **추가**: 상태 팝오버에 `mem관찰` 통계 셀 추가
- **수정**: 관찰자 누수 임계값 30분으로 설정 (일반 서브에이전트 90분 대비)

### v0.1.0 — 2026-06-19

- 최초 출시
- Claude Code 서브에이전트 프로세스 실시간 모니터링
- 유휴 감지 (CPU 델타 < 10ms × 3회 연속 스냅샷)
- 칼만 필터 예측 + 잔차 z-score 이상 탐지
- 절대값 이상 경보 (프로세스 수, 메모리, CPU, 발열)
- Apple Intelligence 디바이스 내 분석 + 규칙 기반 폴백
- 자가치유 5단계 백프레셔
- 스마트 알림 (10분 쿨다운)
- SQLite v5 스키마 + 자동 마이그레이션
- 10개 언어 UI

---

## 기여

이슈와 PR 환영합니다. 대규모 변경 전에 이슈를 먼저 열어 주세요.

---

## 라이선스

MIT License — [LICENSE](LICENSE) 참조
