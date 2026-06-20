import Foundation
import SQLite3
import os

// MARK: - Shared value types (Codable → JSON 직렬화)

/// 프로세스 단위 직렬화 레코드 — cleanup_log.processes_json 및 process_events에 공통 사용
struct ProcessEventRecord: Codable, Sendable {
    let pid:        Int
    let ppid:       Int
    let ageMinutes: Double
    let memMB:      Double
    let cmdArgs:    String
    let leakReason: String
    var killSuccess: Bool?   // cleanup 이벤트에만 세팅; spawn/leak_detected 시 nil
}

// MARK: - Log / Snapshot models

struct CleanupLogEntry: Identifiable, Sendable {
    let id:                 Int64
    let timestamp:          Date
    let killedCount:        Int
    let failedCount:        Int
    let reclaimedMB:        Double
    let processCountBefore: Int
    let processCountAfter:  Int
    let status:             String
    let notes:              String
    let trigger:            String          // "manual" | "auto"
    let processes:          [ProcessEventRecord]   // 정리된 프로세스 목록

    var reclaimedGB: Double { reclaimedMB / 1024.0 }
}

struct ProcessEventEntry: Identifiable, Sendable {
    let id:        Int64
    let timestamp: Date
    let eventType: String   // "spawn" | "leak_detected" | "cleanup_success" | "cleanup_failed"
    let pid:       Int
    let ppid:      Int
    let ageMinutes:Double
    let memMB:     Double
    let cmdArgs:   String
    let leakReason:String
    let status:    String
    let refId:     Int64?   // cleanup_log.id 참조
}

struct SnapshotRecord: Sendable {
    let timestamp:    Date
    let totalCount:   Int
    let leakedCount:  Int
    let totalMemGB:   Double
    let status:       String
    let growthPattern:String
    let newProcesses: [ProcessEventRecord]   // 이 스냅샷에서 신규 등장한 프로세스
}

// MARK: - DatabaseManager

/// SQLite 기반 영구 저장소.
///
/// ## 마이그레이션 방식
/// - `user_version` PRAGMA를 스키마 버전 번호로 사용
/// - `migrations` 배열에 버전 순서대로 SQL 블록을 추가 (끝에만 추가)
/// - 앱 시작 시 현재 DB 버전보다 높은 마이그레이션을 순서대로 실행
/// - ALTER TABLE로 컬럼 추가 시 반드시 DEFAULT 값 포함
///
/// ## 향후 컬럼 추가 예시
/// ```swift
/// Migration(version: 5, sql: """
///     ALTER TABLE process_events ADD COLUMN session_id TEXT DEFAULT '';
/// """)
/// ```
final class DatabaseManager: Sendable {
    static let shared = DatabaseManager()
    private let logger = Logger(subsystem: "com.beret21.DaemonHunter", category: "Database")
    private let dbPath: String

    // MARK: - Migration registry

    private struct Migration {
        let version: Int
        let sql: String
    }

    private let migrations: [Migration] = [

        // v1: 기본 테이블
        Migration(version: 1, sql: """
            CREATE TABLE IF NOT EXISTS cleanup_log (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp            INTEGER NOT NULL,
                killed_count         INTEGER DEFAULT 0,
                failed_count         INTEGER DEFAULT 0,
                reclaimed_mb         REAL    DEFAULT 0,
                process_count_before INTEGER DEFAULT 0,
                process_count_after  INTEGER DEFAULT 0,
                status               TEXT    DEFAULT '',
                trigger              TEXT    DEFAULT 'manual',
                notes                TEXT    DEFAULT '',
                embedding            BLOB
            );
            CREATE TABLE IF NOT EXISTS process_snapshots (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       INTEGER NOT NULL,
                total_count     INTEGER DEFAULT 0,
                leaked_count    INTEGER DEFAULT 0,
                total_mem_gb    REAL    DEFAULT 0,
                status          TEXT    DEFAULT '',
                growth_pattern  TEXT    DEFAULT '',
                slope_per_min   REAL    DEFAULT 0,
                embedding       BLOB
            );
            CREATE INDEX IF NOT EXISTS idx_cleanup_ts  ON cleanup_log(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_snapshot_ts ON process_snapshots(timestamp DESC);
        """),

        // v2: AI 분석 결과 히스토리
        Migration(version: 2, sql: """
            CREATE TABLE IF NOT EXISTS analysis_results (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       INTEGER NOT NULL,
                summary         TEXT    DEFAULT '',
                recommendation  TEXT    DEFAULT '',
                is_ai_generated INTEGER DEFAULT 0,
                confidence      REAL    DEFAULT 0,
                process_count   INTEGER DEFAULT 0,
                status          TEXT    DEFAULT '',
                embedding       BLOB
            );
            CREATE INDEX IF NOT EXISTS idx_analysis_ts ON analysis_results(timestamp DESC);
        """),

        // v3: 스키마 마이그레이션 감사 로그
        Migration(version: 3, sql: """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version    INTEGER PRIMARY KEY,
                applied_at INTEGER NOT NULL,
                notes      TEXT    DEFAULT ''
            );
        """),

        // v4: 프로세스 이벤트 로그 + 기존 테이블 컬럼 확장
        //
        // process_events: 프로세스 단위 이벤트 기록
        //   event_type: 'spawn'           — 새 Claude 프로세스 감지
        //               'leak_detected'   — 누수 판정
        //               'cleanup_success' — SIGTERM 성공
        //               'cleanup_failed'  — SIGTERM 실패
        //
        // cleanup_log.processes_json: 정리 시점의 대상 프로세스 목록 (디스플레이용)
        // process_snapshots.new_pids_json: 신규 등장 프로세스 목록 (증가 추적용)
        Migration(version: 4, sql: """
            CREATE TABLE IF NOT EXISTS process_events (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp   INTEGER NOT NULL,
                event_type  TEXT    NOT NULL,
                pid         INTEGER DEFAULT 0,
                ppid        INTEGER DEFAULT 0,
                age_minutes REAL    DEFAULT 0,
                mem_mb      REAL    DEFAULT 0,
                cmd_args    TEXT    DEFAULT '',
                leak_reason TEXT    DEFAULT '',
                status      TEXT    DEFAULT '',
                ref_id      INTEGER,
                embedding   BLOB
            );
            CREATE INDEX IF NOT EXISTS idx_events_ts       ON process_events(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_events_pid      ON process_events(pid);
            CREATE INDEX IF NOT EXISTS idx_events_type     ON process_events(event_type);
            CREATE INDEX IF NOT EXISTS idx_events_ref      ON process_events(ref_id);

            ALTER TABLE cleanup_log      ADD COLUMN processes_json TEXT DEFAULT '';
            ALTER TABLE process_snapshots ADD COLUMN new_pids_json TEXT DEFAULT '';
        """),

        // v5: 리소스 추적 + 예측 테이블
        //
        // resource_snapshots: 시스템 전체 프로세스(앱 단위) 메모리/CPU 샘플
        // system_pressure_events: 메모리 압박/온도 이벤트
        // app_health_log: 앱별 건강 점수 및 이슈 기록
        // kalman_predictions: 칼만 필터 예측값/잔차 (예측 정확도 추적)
        Migration(version: 5, sql: """
            CREATE TABLE IF NOT EXISTS resource_snapshots (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       INTEGER NOT NULL,
                app_name        TEXT    NOT NULL,
                exec_path       TEXT    DEFAULT '',
                category        TEXT    DEFAULT 'other',
                pid_count       INTEGER DEFAULT 0,
                total_mem_mb    REAL    DEFAULT 0,
                cpu_percent     REAL    DEFAULT 0,
                mem_delta_mb    REAL    DEFAULT 0,
                is_leak_suspect INTEGER DEFAULT 0,
                embedding       BLOB
            );
            CREATE TABLE IF NOT EXISTS system_pressure_events (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp        INTEGER NOT NULL,
                mem_pressure     TEXT    DEFAULT 'normal',
                mem_used_gb      REAL    DEFAULT 0,
                mem_total_gb     REAL    DEFAULT 0,
                swap_used_gb     REAL    DEFAULT 0,
                thermal_level    INTEGER DEFAULT 0,
                cpu_percent      REAL    DEFAULT 0,
                top_consumer     TEXT    DEFAULT '',
                top_consumer_mb  REAL    DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS app_health_log (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp        INTEGER NOT NULL,
                app_name         TEXT    NOT NULL,
                exec_path        TEXT    DEFAULT '',
                version          TEXT    DEFAULT '',
                health_score     REAL    DEFAULT 1.0,
                issue_type       TEXT    DEFAULT '',
                issue_severity   REAL    DEFAULT 0.0,
                mem_mb_at_issue  REAL    DEFAULT 0,
                notes            TEXT    DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS kalman_predictions (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp        INTEGER NOT NULL,
                metric           TEXT    NOT NULL,
                predicted_value  REAL    DEFAULT 0,
                actual_value     REAL,
                residual         REAL,
                prediction_var   REAL    DEFAULT 0,
                horizon_minutes  REAL    DEFAULT 5
            );
            CREATE INDEX IF NOT EXISTS idx_resource_ts     ON resource_snapshots(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_resource_app    ON resource_snapshots(app_name, timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_pressure_ts     ON system_pressure_events(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_health_app      ON app_health_log(app_name, timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_kalman_ts       ON kalman_predictions(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_kalman_metric   ON kalman_predictions(metric, timestamp DESC);
        """),

        // --- 향후 마이그레이션은 여기에 추가 ---
        // Migration(version: 6, sql: "ALTER TABLE process_events ADD COLUMN session_id TEXT DEFAULT '';"),
    ]

    // MARK: - Init

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.beret21.DaemonHunter", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        dbPath = support.appendingPathComponent("agent_monitor.db").path
        runMigrations()
    }

    // MARK: - Migration runner

    private func runMigrations() {
        withDB { db in
            exec(db: db, sql: "PRAGMA journal_mode=WAL;")
            exec(db: db, sql: "PRAGMA foreign_keys=ON;")

            var currentVersion = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { currentVersion = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }

            let pending = migrations.filter { $0.version > currentVersion }
                .sorted { $0.version < $1.version }
            guard !pending.isEmpty else { return }

            logger.info("DB migration: v\(currentVersion) → v\(pending.last!.version)")

            for m in pending {
                exec(db: db, sql: "BEGIN;")
                exec(db: db, sql: m.sql)
                exec(db: db, sql: "PRAGMA user_version = \(m.version);")
                exec(db: db, sql: "COMMIT;")
                logger.info("Migration v\(m.version) applied")
            }
        }
    }

    // MARK: - Write: Cleanup Log (확장 버전)

    /// 정리 완료 후 호출. 대상 프로세스 목록 포함.
    func insertCleanupLog(
        killedCount: Int, failedCount: Int, reclaimedMB: Double,
        processCountBefore: Int, processCountAfter: Int,
        status: String, trigger: String = "manual", notes: String = "",
        processes: [ProcessEventRecord] = []
    ) -> Int64 {
        var insertedId: Int64 = -1
        withDB { db in
            let json = encodeJSON(processes)
            let sql = """
            INSERT INTO cleanup_log
                (timestamp, killed_count, failed_count, reclaimed_mb,
                 process_count_before, process_count_after, status, trigger, notes, processes_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let T = SQLITE_TRANSIENT
            sqlite3_bind_int64(stmt, 1,  Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt,   2,  Int32(killedCount))
            sqlite3_bind_int(stmt,   3,  Int32(failedCount))
            sqlite3_bind_double(stmt,4,  reclaimedMB)
            sqlite3_bind_int(stmt,   5,  Int32(processCountBefore))
            sqlite3_bind_int(stmt,   6,  Int32(processCountAfter))
            sqlite3_bind_text(stmt,  7,  status, -1, T)
            sqlite3_bind_text(stmt,  8,  trigger, -1, T)
            sqlite3_bind_text(stmt,  9,  notes, -1, T)
            sqlite3_bind_text(stmt,  10, json, -1, T)
            sqlite3_step(stmt)
            insertedId = sqlite3_last_insert_rowid(db)
        }
        return insertedId
    }

    // MARK: - Write: Process Events

    func insertProcessEvents(_ events: [(record: ProcessEventRecord, type: String, status: String, refId: Int64?)]) {
        guard !events.isEmpty else { return }
        withDB { db in
            let sql = """
            INSERT INTO process_events
                (timestamp, event_type, pid, ppid, age_minutes, mem_mb,
                 cmd_args, leak_reason, status, ref_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let ts = Int64(Date().timeIntervalSince1970)
            let T  = SQLITE_TRANSIENT

            for ev in events {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_int64(stmt,  1, ts)
                sqlite3_bind_text(stmt,   2, ev.type, -1, T)
                sqlite3_bind_int(stmt,    3, Int32(ev.record.pid))
                sqlite3_bind_int(stmt,    4, Int32(ev.record.ppid))
                sqlite3_bind_double(stmt, 5, ev.record.ageMinutes)
                sqlite3_bind_double(stmt, 6, ev.record.memMB)
                sqlite3_bind_text(stmt,   7, ev.record.cmdArgs, -1, T)
                sqlite3_bind_text(stmt,   8, ev.record.leakReason, -1, T)
                sqlite3_bind_text(stmt,   9, ev.status, -1, T)
                if let rid = ev.refId { sqlite3_bind_int64(stmt, 10, rid) }
                else                  { sqlite3_bind_null(stmt, 10) }
                sqlite3_step(stmt)
            }
        }
    }

    // MARK: - Write: Snapshot

    func insertSnapshot(snapshot: ProcessSnapshot, pattern: String, slope: Double,
                        newProcesses: [ProcessEventRecord] = []) {
        withDB { db in
            let json = encodeJSON(newProcesses)
            let sql  = """
            INSERT INTO process_snapshots
                (timestamp, total_count, leaked_count, total_mem_gb,
                 status, growth_pattern, slope_per_min, new_pids_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let T = SQLITE_TRANSIENT
            sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int(stmt,   2, Int32(snapshot.processes.count))
            sqlite3_bind_int(stmt,   3, Int32(snapshot.leakedCount))
            sqlite3_bind_double(stmt,4, snapshot.totalMemGB)
            sqlite3_bind_text(stmt,  5, snapshot.status.rawValue, -1, T)
            sqlite3_bind_text(stmt,  6, pattern, -1, T)
            sqlite3_bind_double(stmt,7, slope)
            sqlite3_bind_text(stmt,  8, json, -1, T)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Read: Cleanup Logs

    func fetchCleanupLogs(limit: Int = 50) -> [CleanupLogEntry] {
        var entries: [CleanupLogEntry] = []
        withDB { db in
            let sql = """
            SELECT id, timestamp, killed_count, failed_count, reclaimed_mb,
                   process_count_before, process_count_after, status, trigger, notes,
                   COALESCE(processes_json, '') as processes_json
            FROM cleanup_log ORDER BY timestamp DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let procs: [ProcessEventRecord] = decodeJSON(colText(stmt, col: 10))
                entries.append(CleanupLogEntry(
                    id:                   sqlite3_column_int64(stmt, 0),
                    timestamp:            Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
                    killedCount:          Int(sqlite3_column_int(stmt, 2)),
                    failedCount:          Int(sqlite3_column_int(stmt, 3)),
                    reclaimedMB:          sqlite3_column_double(stmt, 4),
                    processCountBefore:   Int(sqlite3_column_int(stmt, 5)),
                    processCountAfter:    Int(sqlite3_column_int(stmt, 6)),
                    status:               colText(stmt, col: 7),
                    notes:                colText(stmt, col: 9),
                    trigger:              colText(stmt, col: 8),
                    processes:            procs
                ))
            }
        }
        return entries
    }

    // MARK: - Read: Process Events

    func fetchProcessEvents(limit: Int = 200, eventType: String? = nil) -> [ProcessEventEntry] {
        var entries: [ProcessEventEntry] = []
        withDB { db in
            let filter = eventType.map { "WHERE event_type = '\($0)'" } ?? ""
            let sql = """
            SELECT id, timestamp, event_type, pid, ppid, age_minutes, mem_mb,
                   cmd_args, leak_reason, status, ref_id
            FROM process_events \(filter) ORDER BY timestamp DESC LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let refCol = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil
                           : Optional(sqlite3_column_int64(stmt, 10))
                entries.append(ProcessEventEntry(
                    id:         sqlite3_column_int64(stmt, 0),
                    timestamp:  Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
                    eventType:  colText(stmt, col: 2),
                    pid:        Int(sqlite3_column_int(stmt, 3)),
                    ppid:       Int(sqlite3_column_int(stmt, 4)),
                    ageMinutes: sqlite3_column_double(stmt, 5),
                    memMB:      sqlite3_column_double(stmt, 6),
                    cmdArgs:    colText(stmt, col: 7),
                    leakReason: colText(stmt, col: 8),
                    status:     colText(stmt, col: 9),
                    refId:      refCol
                ))
            }
        }
        return entries
    }

    // MARK: - Read: Snapshots (for chart)

    func fetchRecentSnapshots(hours: Int = 24) -> [SnapshotRecord] {
        var records: [SnapshotRecord] = []
        withDB { db in
            let cutoff = Int64(Date().timeIntervalSince1970) - Int64(hours * 3600)
            let sql = """
            SELECT timestamp, total_count, leaked_count, total_mem_gb, status,
                   growth_pattern, COALESCE(new_pids_json, '') as new_pids_json
            FROM process_snapshots WHERE timestamp > ? ORDER BY timestamp ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let newProcs: [ProcessEventRecord] = decodeJSON(colText(stmt, col: 6))
                records.append(SnapshotRecord(
                    timestamp:     Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))),
                    totalCount:    Int(sqlite3_column_int(stmt, 1)),
                    leakedCount:   Int(sqlite3_column_int(stmt, 2)),
                    totalMemGB:    sqlite3_column_double(stmt, 3),
                    status:        colText(stmt, col: 4),
                    growthPattern: colText(stmt, col: 5),
                    newProcesses:  newProcs
                ))
            }
        }
        return records
    }

    // MARK: - Write: Kalman Predictions

    func insertKalmanPrediction(metric: String, predictedValue: Double, actualValue: Double?,
                                residual: Double?, predictionVar: Double, horizonMinutes: Double) {
        withDB { db in
            let sql = """
            INSERT INTO kalman_predictions
                (timestamp, metric, predicted_value, actual_value, residual,
                 prediction_var, horizon_minutes)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let T = SQLITE_TRANSIENT
            sqlite3_bind_int64(stmt,  1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt,   2, metric, -1, T)
            sqlite3_bind_double(stmt, 3, predictedValue)
            if let a = actualValue { sqlite3_bind_double(stmt, 4, a) } else { sqlite3_bind_null(stmt, 4) }
            if let r = residual    { sqlite3_bind_double(stmt, 5, r) } else { sqlite3_bind_null(stmt, 5) }
            sqlite3_bind_double(stmt, 6, predictionVar)
            sqlite3_bind_double(stmt, 7, horizonMinutes)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Write: Resource Snapshot

    func insertResourceSnapshot(appName: String, execPath: String, category: String,
                                pidCount: Int, totalMemMB: Double, cpuPercent: Double,
                                memDeltaMB: Double, isLeakSuspect: Bool) {
        withDB { db in
            let sql = """
            INSERT INTO resource_snapshots
                (timestamp, app_name, exec_path, category, pid_count,
                 total_mem_mb, cpu_percent, mem_delta_mb, is_leak_suspect)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let T = SQLITE_TRANSIENT
            sqlite3_bind_int64(stmt,  1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt,   2, appName, -1, T)
            sqlite3_bind_text(stmt,   3, execPath, -1, T)
            sqlite3_bind_text(stmt,   4, category, -1, T)
            sqlite3_bind_int(stmt,    5, Int32(pidCount))
            sqlite3_bind_double(stmt, 6, totalMemMB)
            sqlite3_bind_double(stmt, 7, cpuPercent)
            sqlite3_bind_double(stmt, 8, memDeltaMB)
            sqlite3_bind_int(stmt,    9, isLeakSuspect ? 1 : 0)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Write: System Pressure Event

    func insertSystemPressureEvent(memPressure: String, memUsedGB: Double, memTotalGB: Double,
                                   swapUsedGB: Double, thermalLevel: Int, cpuPercent: Double,
                                   topConsumer: String, topConsumerMB: Double) {
        withDB { db in
            let sql = """
            INSERT INTO system_pressure_events
                (timestamp, mem_pressure, mem_used_gb, mem_total_gb, swap_used_gb,
                 thermal_level, cpu_percent, top_consumer, top_consumer_mb)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let T = SQLITE_TRANSIENT
            sqlite3_bind_int64(stmt,  1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt,   2, memPressure, -1, T)
            sqlite3_bind_double(stmt, 3, memUsedGB)
            sqlite3_bind_double(stmt, 4, memTotalGB)
            sqlite3_bind_double(stmt, 5, swapUsedGB)
            sqlite3_bind_int(stmt,    6, Int32(thermalLevel))
            sqlite3_bind_double(stmt, 7, cpuPercent)
            sqlite3_bind_text(stmt,   8, topConsumer, -1, T)
            sqlite3_bind_double(stmt, 9, topConsumerMB)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Write: App Health Log

    func insertAppHealthLog(appName: String, execPath: String, version: String,
                            healthScore: Double, issueType: String, issueSeverity: Double,
                            memMBAtIssue: Double, notes: String) {
        withDB { db in
            let sql = """
            INSERT INTO app_health_log
                (timestamp, app_name, exec_path, version, health_score,
                 issue_type, issue_severity, mem_mb_at_issue, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let T = SQLITE_TRANSIENT
            sqlite3_bind_int64(stmt,  1, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt,   2, appName, -1, T)
            sqlite3_bind_text(stmt,   3, execPath, -1, T)
            sqlite3_bind_text(stmt,   4, version, -1, T)
            sqlite3_bind_double(stmt, 5, healthScore)
            sqlite3_bind_text(stmt,   6, issueType, -1, T)
            sqlite3_bind_double(stmt, 7, issueSeverity)
            sqlite3_bind_double(stmt, 8, memMBAtIssue)
            sqlite3_bind_text(stmt,   9, notes, -1, T)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Read: Resource Snapshots (for report)

    func fetchTopResourceApps(hours: Int, limit: Int)
        -> [(appName: String, avgMemMB: Double, peakMemMB: Double, isLeakSuspect: Bool, sampleCount: Int)] {
        var rows: [(appName: String, avgMemMB: Double, peakMemMB: Double, isLeakSuspect: Bool, sampleCount: Int)] = []
        withDB { db in
            let cutoff = Int64(Date().timeIntervalSince1970) - Int64(hours * 3600)
            let sql = """
            SELECT app_name,
                   AVG(total_mem_mb)      AS avg_mem,
                   MAX(total_mem_mb)      AS peak_mem,
                   MAX(is_leak_suspect)   AS leak,
                   COUNT(*)               AS samples
            FROM resource_snapshots
            WHERE timestamp > ?
            GROUP BY app_name
            ORDER BY avg_mem DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoff)
            sqlite3_bind_int(stmt,   2, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((
                    appName:       colText(stmt, col: 0),
                    avgMemMB:      sqlite3_column_double(stmt, 1),
                    peakMemMB:     sqlite3_column_double(stmt, 2),
                    isLeakSuspect: sqlite3_column_int(stmt, 3) != 0,
                    sampleCount:   Int(sqlite3_column_int(stmt, 4))
                ))
            }
        }
        return rows
    }

    // MARK: - Read: App Health (for safety report)

    func fetchAppHealthSummary()
        -> [(appName: String, avgScore: Double, issueCount: Int, lastIssueType: String, lastSeen: Date)] {
        var rows: [(appName: String, avgScore: Double, issueCount: Int, lastIssueType: String, lastSeen: Date)] = []
        withDB { db in
            let sql = """
            SELECT h.app_name,
                   AVG(h.health_score)                                   AS avg_score,
                   SUM(CASE WHEN h.issue_type != '' AND h.issue_type != 'none' THEN 1 ELSE 0 END) AS issues,
                   (SELECT issue_type FROM app_health_log
                     WHERE app_name = h.app_name ORDER BY timestamp DESC LIMIT 1) AS last_issue,
                   MAX(h.timestamp)                                      AS last_seen
            FROM app_health_log h
            GROUP BY h.app_name
            ORDER BY avg_score ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((
                    appName:       colText(stmt, col: 0),
                    avgScore:      sqlite3_column_double(stmt, 1),
                    issueCount:    Int(sqlite3_column_int(stmt, 2)),
                    lastIssueType: colText(stmt, col: 3),
                    lastSeen:      Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)))
                ))
            }
        }
        return rows
    }

    // MARK: - Read: Kalman predictions for residual chart

    func fetchKalmanHistory(metric: String, hours: Int)
        -> [(timestamp: Date, predicted: Double, actual: Double?, residual: Double?)] {
        var rows: [(timestamp: Date, predicted: Double, actual: Double?, residual: Double?)] = []
        withDB { db in
            let cutoff = Int64(Date().timeIntervalSince1970) - Int64(hours * 3600)
            let sql = """
            SELECT timestamp, predicted_value, actual_value, residual
            FROM kalman_predictions
            WHERE metric = ? AND timestamp > ?
            ORDER BY timestamp ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            let T = SQLITE_TRANSIENT
            sqlite3_bind_text(stmt,  1, metric, -1, T)
            sqlite3_bind_int64(stmt, 2, cutoff)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let actual:   Double? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
                let residual: Double? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)
                rows.append((
                    timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0))),
                    predicted: sqlite3_column_double(stmt, 1),
                    actual:    actual,
                    residual:  residual
                ))
            }
        }
        return rows
    }

    // MARK: - Maintenance

    func cleanupOldRecords(keepDays: Int = 30) {
        withDB { db in
            let snapCutoff   = Int64(Date().timeIntervalSince1970) - Int64(keepDays * 86400)
            let logCutoff    = Int64(Date().timeIntervalSince1970) - Int64(keepDays * 3 * 86400)
            let eventsCutoff = Int64(Date().timeIntervalSince1970) - Int64(keepDays * 86400)
            exec(db: db, sql: "DELETE FROM process_snapshots      WHERE timestamp < \(snapCutoff);")
            exec(db: db, sql: "DELETE FROM cleanup_log            WHERE timestamp < \(logCutoff);")
            exec(db: db, sql: "DELETE FROM process_events         WHERE timestamp < \(eventsCutoff);")
            exec(db: db, sql: "DELETE FROM resource_snapshots     WHERE timestamp < \(snapCutoff);")
            exec(db: db, sql: "DELETE FROM system_pressure_events WHERE timestamp < \(snapCutoff);")
            exec(db: db, sql: "DELETE FROM app_health_log         WHERE timestamp < \(logCutoff);")
            exec(db: db, sql: "DELETE FROM kalman_predictions     WHERE timestamp < \(snapCutoff);")
            exec(db: db, sql: "VACUUM;")
        }
    }

    var schemaVersion: Int {
        var v = 0
        withDB { db in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { v = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
        }
        return v
    }

    // MARK: - SQLite helpers

    private func withDB(_ block: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            logger.error("SQLite open failed: \(self.dbPath)")
            return
        }
        defer { sqlite3_close(db) }
        block(db)
    }

    private func exec(db: OpaquePointer, sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            logger.error("SQLite: \(msg) — \(sql.prefix(80))")
            sqlite3_free(err)
        }
    }

    private func colText(_ stmt: OpaquePointer?, col: Int32) -> String {
        guard let stmt, let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }

    // SQLite TRANSIENT 상수 (Swift에서 접근 가능한 형태)
    private var SQLITE_TRANSIENT: sqlite3_destructor_type? {
        unsafeBitCast(-1, to: sqlite3_destructor_type?.self)
    }

    // MARK: - JSON helpers

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let str  = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func decodeJSON<T: Decodable>(_ json: String) -> [T] {
        guard !json.isEmpty, json != "[]",
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }
}
