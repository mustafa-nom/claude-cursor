//
//  PatternDatabase.swift
//  claude-cursor
//
//  SQLite database for persisting structured data that doesn't fit into
//  plain markdown files: confidence scores with decay timestamps, lesson
//  progress tracking, session metadata, and tutor nudge rate limiting.
//
//  Uses the built-in SQLite3 C API (libsqlite3, included in macOS) so no
//  external dependency is required. The database file lives alongside the
//  wiki at ~/Library/Application Support/ClaudeCursor/pattern.db.
//

import Foundation
import SQLite3

/// Thread-safe SQLite wrapper for ClaudeCursor's structured data needs.
/// All operations are synchronous and run on the caller's thread — the
/// @MainActor CompanionManager coordinates access.
final class PatternDatabase {

    private var databaseConnection: OpaquePointer?
    private let databasePath: String

    /// Opens (or creates) the database at the standard App Support location.
    init() {
        let appSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let claudeCursorDirectoryURL = appSupportURL.appendingPathComponent("ClaudeCursor")

        // Ensure the directory exists
        try? FileManager.default.createDirectory(
            at: claudeCursorDirectoryURL,
            withIntermediateDirectories: true
        )

        databasePath = claudeCursorDirectoryURL
            .appendingPathComponent("pattern.db")
            .path
    }

    deinit {
        close()
    }

    // MARK: - Connection Lifecycle

    /// Opens the database connection and creates tables if they don't exist.
    /// Must be called before any other operations.
    func open() -> Bool {
        guard sqlite3_open(databasePath, &databaseConnection) == SQLITE_OK else {
            print("⚠️ PatternDatabase: failed to open database at \(databasePath)")
            return false
        }

        // Enable WAL mode for better concurrent read performance
        executeStatement("PRAGMA journal_mode=WAL")

        let tablesCreatedSuccessfully = createTablesIfNeeded()
        if tablesCreatedSuccessfully {
            print("📊 PatternDatabase: opened at \(databasePath)")
        }
        return tablesCreatedSuccessfully
    }

    /// Closes the database connection. Safe to call multiple times.
    func close() {
        if let connection = databaseConnection {
            sqlite3_close(connection)
            databaseConnection = nil
        }
    }

    // MARK: - Lesson Progress

    /// Records or updates progress for a YouTube tutorial lesson.
    func saveLessonProgress(
        youtubeVideoID: String,
        videoTitle: String,
        currentStepIndex: Int,
        totalStepCount: Int,
        lastTimestampSeconds: Double
    ) {
        let sql = """
            INSERT INTO lesson_progress (youtube_video_id, video_title, current_step_index,
                total_step_count, last_timestamp_seconds, last_accessed_at)
            VALUES (?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(youtube_video_id) DO UPDATE SET
                current_step_index = excluded.current_step_index,
                total_step_count = excluded.total_step_count,
                last_timestamp_seconds = excluded.last_timestamp_seconds,
                last_accessed_at = datetime('now')
            """

        executeParameterizedStatement(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (youtubeVideoID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (videoTitle as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(currentStepIndex))
            sqlite3_bind_int(statement, 4, Int32(totalStepCount))
            sqlite3_bind_double(statement, 5, lastTimestampSeconds)
        })
    }

    /// Retrieves lesson progress for a given YouTube video. Returns nil if no
    /// progress has been saved for this video.
    func getLessonProgress(youtubeVideoID: String) -> LessonProgressRecord? {
        let sql = "SELECT * FROM lesson_progress WHERE youtube_video_id = ?"
        var result: LessonProgressRecord?

        queryWithParameters(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (youtubeVideoID as NSString).utf8String, -1, nil)
        }) { statement in
            result = LessonProgressRecord(
                youtubeVideoID: columnText(statement, index: 0),
                videoTitle: columnText(statement, index: 1),
                currentStepIndex: Int(sqlite3_column_int(statement, 2)),
                totalStepCount: Int(sqlite3_column_int(statement, 3)),
                lastTimestampSeconds: sqlite3_column_double(statement, 4),
                lastAccessedAt: columnText(statement, index: 5)
            )
        }

        return result
    }

    // MARK: - Session Metadata

    /// Records the start of a new user session.
    func startSession() -> String {
        let sessionID = UUID().uuidString
        let sql = """
            INSERT INTO sessions (session_id, started_at, interaction_count)
            VALUES (?, datetime('now'), 0)
            """

        executeParameterizedStatement(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, nil)
        })

        return sessionID
    }

    /// Increments the interaction count for the current session and updates
    /// the last interaction timestamp.
    func recordInteraction(sessionID: String) {
        let sql = """
            UPDATE sessions SET
                interaction_count = interaction_count + 1,
                last_interaction_at = datetime('now')
            WHERE session_id = ?
            """

        executeParameterizedStatement(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, nil)
        })
    }

    /// Marks a session as ended.
    func endSession(sessionID: String) {
        let sql = "UPDATE sessions SET ended_at = datetime('now') WHERE session_id = ?"

        executeParameterizedStatement(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, nil)
        })
    }

    /// Returns the most recent session, or nil if no sessions exist.
    func getMostRecentSession() -> SessionRecord? {
        let sql = "SELECT * FROM sessions ORDER BY started_at DESC LIMIT 1"
        var result: SessionRecord?

        query(sql) { statement in
            result = SessionRecord(
                sessionID: columnText(statement, index: 0),
                startedAt: columnText(statement, index: 1),
                endedAt: columnText(statement, index: 2),
                lastInteractionAt: columnText(statement, index: 3),
                interactionCount: Int(sqlite3_column_int(statement, 4))
            )
        }

        return result
    }

    // MARK: - Tutor Nudge Rate Limiting

    /// Records a tutor nudge event (proactive suggestion shown to the user).
    func recordTutorNudge(wasAccepted: Bool) {
        let sql = """
            INSERT INTO tutor_nudges (nudged_at, was_accepted)
            VALUES (datetime('now'), ?)
            """

        executeParameterizedStatement(sql, bindings: { statement in
            sqlite3_bind_int(statement, 1, wasAccepted ? 1 : 0)
        })
    }

    /// Returns the number of tutor nudges in the last hour.
    func tutorNudgeCountInLastHour() -> Int {
        let sql = """
            SELECT COUNT(*) FROM tutor_nudges
            WHERE nudged_at > datetime('now', '-1 hour')
            """
        var count = 0

        query(sql) { statement in
            count = Int(sqlite3_column_int(statement, 0))
        }

        return count
    }

    /// Returns the number of consecutive rejected nudges (most recent first).
    /// Stops counting at the first accepted nudge.
    func consecutiveRejectedNudgeCount() -> Int {
        let sql = "SELECT was_accepted FROM tutor_nudges ORDER BY nudged_at DESC LIMIT 10"
        // Collect all rows first, then iterate with early break. The
        // `query` row handler closure's `return` only exits that single
        // invocation — it does NOT break the sqlite3_step loop — so
        // counting inside the handler would include rejections that are
        // older than the most recent acceptance.
        var acceptedFlagsByRecency: [Bool] = []
        query(sql) { statement in
            acceptedFlagsByRecency.append(sqlite3_column_int(statement, 0) != 0)
        }

        var consecutiveRejections = 0
        for wasAccepted in acceptedFlagsByRecency {
            if wasAccepted { break }
            consecutiveRejections += 1
        }
        return consecutiveRejections
    }

    // MARK: - Confidence Scores

    /// Records or updates a confidence score for a wiki page. Confidence
    /// decays over time — the decay_anchor timestamp marks when the score
    /// was last validated.
    func saveConfidenceScore(
        wikiPageFilename: String,
        confidenceScore: Double,
        sourceCount: Int
    ) {
        let sql = """
            INSERT INTO confidence_scores (wiki_page_filename, confidence_score, source_count, decay_anchor)
            VALUES (?, ?, ?, datetime('now'))
            ON CONFLICT(wiki_page_filename) DO UPDATE SET
                confidence_score = excluded.confidence_score,
                source_count = excluded.source_count,
                decay_anchor = datetime('now')
            """

        executeParameterizedStatement(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (wikiPageFilename as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, confidenceScore)
            sqlite3_bind_int(statement, 3, Int32(sourceCount))
        })
    }

    /// Returns the confidence score for a wiki page, with time-based decay applied.
    /// Returns nil if no score exists for this page.
    func getConfidenceScore(wikiPageFilename: String) -> Double? {
        let sql = """
            SELECT confidence_score, decay_anchor FROM confidence_scores
            WHERE wiki_page_filename = ?
            """
        var result: Double?

        queryWithParameters(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (wikiPageFilename as NSString).utf8String, -1, nil)
        }) { statement in
            let rawScore = sqlite3_column_double(statement, 0)
            let decayAnchorString = columnText(statement, index: 1)

            // Apply time-based decay: confidence drops ~10% per week since the
            // decay anchor (last validation). Clamped to [0.0, 1.0].
            let decayedScore = applyConfidenceDecay(rawScore: rawScore, decayAnchorString: decayAnchorString)
            result = decayedScore
        }

        return result
    }

    // MARK: - Interaction Outcomes

    /// Records the detected outcome of a user interaction for long-term
    /// learning. `wikiPagesConsulted` is a comma-separated list of page
    /// filenames that were included in the context bundle for that turn.
    func recordInteractionOutcome(
        sessionID: String,
        topicKeywords: String,
        frontmostApp: String,
        outcome: String,
        wikiPagesConsulted: String
    ) {
        let sql = """
            INSERT INTO interaction_outcomes
                (session_id, topic_keywords, frontmost_app, outcome, wiki_pages_consulted)
            VALUES (?, ?, ?, ?, ?)
            """
        executeParameterizedStatement(sql) { statement in
            sqlite3_bind_text(statement, 1, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (topicKeywords as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (frontmostApp as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (outcome as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (wikiPagesConsulted as NSString).utf8String, -1, nil)
        }
    }

    /// Persists a completed Computer Use automation run for analytics and future retrieval.
    func recordComputerUseRun(
        runID: String,
        sessionID: String?,
        finalStatus: String,
        iterationCount: Int,
        frontmostBundleID: String,
        summaryLine: String
    ) {
        let sql = """
            INSERT INTO computer_use_runs
                (run_id, session_id, final_status, iteration_count, frontmost_bundle_id, summary_line)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        executeParameterizedStatement(sql) { statement in
            sqlite3_bind_text(statement, 1, (runID as NSString).utf8String, -1, nil)
            if let sessionID {
                sqlite3_bind_text(statement, 2, (sessionID as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, (finalStatus as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 4, Int32(iterationCount))
            sqlite3_bind_text(statement, 5, (frontmostBundleID as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 6, (summaryLine as NSString).utf8String, -1, nil)
        }
    }

    /// Returns the success/failure counts for interactions involving a
    /// specific app. Useful for gauging whether the wiki is helping with
    /// that app's workflow.
    func getOutcomeSummaryForApp(appName: String) -> (successes: Int, failures: Int) {
        let sql = "SELECT outcome FROM interaction_outcomes WHERE frontmost_app = ?"
        var successes = 0
        var failures = 0
        queryWithParameters(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, (appName as NSString).utf8String, -1, nil)
        }) { statement in
            let outcome = columnText(statement, index: 0)
            if outcome == "likelySuccess" { successes += 1 }
            else if outcome == "likelyFailure" { failures += 1 }
        }
        return (successes: successes, failures: failures)
    }

    // MARK: - Private: Table Creation

    private func createTablesIfNeeded() -> Bool {
        let createStatements = [
            """
            CREATE TABLE IF NOT EXISTS lesson_progress (
                youtube_video_id TEXT PRIMARY KEY,
                video_title TEXT NOT NULL,
                current_step_index INTEGER NOT NULL DEFAULT 0,
                total_step_count INTEGER NOT NULL DEFAULT 0,
                last_timestamp_seconds REAL NOT NULL DEFAULT 0,
                last_accessed_at TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT PRIMARY KEY,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                last_interaction_at TEXT,
                interaction_count INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS tutor_nudges (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nudged_at TEXT NOT NULL,
                was_accepted INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS confidence_scores (
                wiki_page_filename TEXT PRIMARY KEY,
                confidence_score REAL NOT NULL DEFAULT 0.5,
                source_count INTEGER NOT NULL DEFAULT 0,
                decay_anchor TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS interaction_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT,
                topic_keywords TEXT,
                frontmost_app TEXT,
                outcome TEXT NOT NULL,
                wiki_pages_consulted TEXT,
                recorded_at TEXT DEFAULT (datetime('now'))
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS computer_use_runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                run_id TEXT NOT NULL,
                session_id TEXT,
                final_status TEXT NOT NULL,
                iteration_count INTEGER NOT NULL DEFAULT 0,
                frontmost_bundle_id TEXT,
                summary_line TEXT,
                recorded_at TEXT DEFAULT (datetime('now'))
            )
            """
        ]

        for sql in createStatements {
            if !executeStatement(sql) {
                return false
            }
        }

        return true
    }

    // MARK: - Private: SQL Execution Helpers

    @discardableResult
    private func executeStatement(_ sql: String) -> Bool {
        guard let connection = databaseConnection else { return false }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let error = errorMessage.map { String(cString: $0) } ?? "unknown error"
            print("⚠️ PatternDatabase: SQL error: \(error)")
            sqlite3_free(errorMessage)
            return false
        }
        return true
    }

    private func executeParameterizedStatement(
        _ sql: String,
        bindings: (OpaquePointer) -> Void
    ) {
        guard let connection = databaseConnection else { return }
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let preparedStatement = statement else {
            print("⚠️ PatternDatabase: failed to prepare statement")
            return
        }

        bindings(preparedStatement)

        if sqlite3_step(preparedStatement) != SQLITE_DONE {
            print("⚠️ PatternDatabase: failed to execute statement")
        }

        sqlite3_finalize(preparedStatement)
    }

    private func query(_ sql: String, rowHandler: (OpaquePointer) -> Void) {
        guard let connection = databaseConnection else { return }
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let preparedStatement = statement else {
            return
        }

        while sqlite3_step(preparedStatement) == SQLITE_ROW {
            rowHandler(preparedStatement)
        }

        sqlite3_finalize(preparedStatement)
    }

    private func queryWithParameters(
        _ sql: String,
        bindings: (OpaquePointer) -> Void,
        rowHandler: (OpaquePointer) -> Void
    ) {
        guard let connection = databaseConnection else { return }
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let preparedStatement = statement else {
            return
        }

        bindings(preparedStatement)

        while sqlite3_step(preparedStatement) == SQLITE_ROW {
            rowHandler(preparedStatement)
        }

        sqlite3_finalize(preparedStatement)
    }

    /// Safely extracts a text column value, returning an empty string if NULL.
    private func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }
}

// MARK: - Record Types

struct LessonProgressRecord {
    let youtubeVideoID: String
    let videoTitle: String
    let currentStepIndex: Int
    let totalStepCount: Int
    let lastTimestampSeconds: Double
    let lastAccessedAt: String

    /// Whether the lesson has been completed (reached the last step).
    var isCompleted: Bool {
        currentStepIndex >= totalStepCount - 1 && totalStepCount > 0
    }

    /// Progress as a fraction from 0.0 to 1.0.
    var progressFraction: Double {
        guard totalStepCount > 0 else { return 0 }
        return Double(currentStepIndex + 1) / Double(totalStepCount)
    }
}

struct SessionRecord {
    let sessionID: String
    let startedAt: String
    let endedAt: String
    let lastInteractionAt: String
    let interactionCount: Int

    /// Whether this session has been explicitly ended.
    var hasEnded: Bool { !endedAt.isEmpty }
}

// MARK: - Confidence Decay

/// Applies time-based decay to a confidence score. Confidence drops
/// approximately 10% per week since the decay anchor (last validation).
/// This encourages re-verification of stale knowledge.
private func applyConfidenceDecay(rawScore: Double, decayAnchorString: String) -> Double {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    // Also try the SQLite datetime format (no T separator, no timezone)
    let sqliteDateFormatter = DateFormatter()
    sqliteDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    sqliteDateFormatter.timeZone = TimeZone(identifier: "UTC")

    guard let decayAnchorDate = dateFormatter.date(from: decayAnchorString)
            ?? sqliteDateFormatter.date(from: decayAnchorString) else {
        return rawScore
    }

    let secondsSinceAnchor = Date().timeIntervalSince(decayAnchorDate)
    let weeksSinceAnchor = secondsSinceAnchor / (7 * 24 * 60 * 60)

    // Exponential decay: score * 0.9^weeks
    let decayFactor = pow(0.9, weeksSinceAnchor)
    return max(0.0, min(1.0, rawScore * decayFactor))
}
