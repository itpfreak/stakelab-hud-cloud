// StakeCommon.swift
// Shared data models, settings, and advice store for StakeLab HUD and StakeStream Air-Gap
// Requires: macOS 12+

import Foundation
import CoreGraphics
import Combine
import SQLite3

// MARK: - Game Mode & Coaching Playstyle

enum GameMode: String, CaseIterable {
    case cash    = "CASH"
    case tourney = "TOURNEY"
    var label: String { rawValue }
    var icon:  String { self == .cash ? "💵" : "🏆" }
}

enum CoachingStyle: String, CaseIterable {
    case gto         = "GTO"
    case lag         = "LAG"
    case tag         = "TAG"
    case icm         = "ICM"
    case antiStation = "EXPLOIT"
    case streamer    = "STREAMER"

    var label: String {
        switch self {
        case .gto:         return "GTO Baseline"
        case .lag:         return "LAG Aggressive"
        case .tag:         return "TAG Solid"
        case .icm:         return "ICM Survival"
        case .antiStation: return "Max Value Exploit"
        case .streamer:    return "Streamer / Degen"
        }
    }

    var shortLabel: String {
        switch self {
        case .gto:         return "GTO"
        case .lag:         return "LAG"
        case .tag:         return "TAG"
        case .icm:         return "ICM"
        case .antiStation: return "VALUE"
        case .streamer:    return "STREAM"
        }
    }

    var icon: String {
        switch self {
        case .gto:         return "⚖️"
        case .lag:         return "🔥"
        case .tag:         return "🛡️"
        case .icm:         return "⏳"
        case .antiStation: return "💰"
        case .streamer:    return "🎮"
        }
    }
}

// MARK: - Settings (persisted to ~/.stakelab_hud_settings)

enum HUDSizePreset: String, CaseIterable {
    case slim     = "XS"
    case compact  = "S"
    case standard = "M"
    case large    = "L"

    var dimensions: (width: CGFloat, height: CGFloat, fontScale: CGFloat) {
        switch self {
        case .slim:     return (280, 680, 0.75)
        case .compact:  return (340, 620, 0.85)
        case .standard: return (390, 720, 1.0)
        case .large:    return (440, 850, 1.25)
        }
    }
}

final class HUDSettings: ObservableObject {
    static let shared = HUDSettings()
    private let path = NSHomeDirectory() + "/.stakelab_hud_settings"

    @Published var gameMode:      GameMode      = .cash
    @Published var coachingStyle: CoachingStyle = .gto
    @Published var streamerMode:  Bool          = false
    @Published var fontScale:     CGFloat       = 1.0   // 0.75 / 1.0 / 1.25 / 1.5
    @Published var voiceAlerts:   Bool          = true
    @Published var voiceName:     String        = "Samantha"
    @Published var voiceRate:     Int           = 175
    @Published var sizePreset:    HUDSizePreset = .standard
    @Published var hudOpacity:    Double        = 0.95   // 0.40 to 1.00 for transparent fullscreen overlay
    @Published var heroUsername:  String        = "J4clubs"
    @Published var savedFrameX:   Double?       = nil
    @Published var savedFrameY:   Double?       = nil
    @Published var savedFrameW:   Double?       = nil
    @Published var savedFrameH:   Double?       = nil

    private init() { load() }

    func save() {
        var d: [String: Any] = [
            "gameMode": gameMode.rawValue,
            "coachingStyle": coachingStyle.rawValue,
            "streamerMode": streamerMode,
            "fontScale": fontScale,
            "voiceAlerts": voiceAlerts,
            "voiceName": voiceName,
            "voiceRate": voiceRate,
            "sizePreset": sizePreset.rawValue,
            "hudOpacity": hudOpacity,
            "heroUsername": heroUsername
        ]
        if let x = savedFrameX, let y = savedFrameY, let w = savedFrameW, let h = savedFrameH {
            d["savedFrameX"] = x
            d["savedFrameY"] = y
            d["savedFrameW"] = w
            d["savedFrameH"] = h
        }
        try? JSONSerialization.data(withJSONObject: d).write(to: URL(fileURLWithPath: path))
        // Write mode and style file for watcher to read
        let modeFile = NSHomeDirectory() + "/.stakelab_hud_mode"
        try? gameMode.rawValue.write(toFile: modeFile, atomically: true, encoding: .utf8)
        let styleFile = NSHomeDirectory() + "/.stakelab_hud_style"
        try? coachingStyle.rawValue.write(toFile: styleFile, atomically: true, encoding: .utf8)
        let streamerFile = NSHomeDirectory() + "/.stakelab_hud_streamer"
        try? (streamerMode ? "1" : "0").write(toFile: streamerFile, atomically: true, encoding: .utf8)
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let m = d["gameMode"] as? String, let mode = GameMode(rawValue: m) { gameMode = mode }
        if let s = d["coachingStyle"] as? String, let style = CoachingStyle(rawValue: s) { coachingStyle = style }
        if let st = d["streamerMode"] as? Bool { streamerMode = st }
        if let s = d["fontScale"] as? CGFloat { fontScale = s }
        if let v = d["voiceAlerts"] as? Bool { voiceAlerts = v }
        if let vn = d["voiceName"] as? String { voiceName = vn }
        if let vr = d["voiceRate"] as? Int { voiceRate = vr }
        if let p = d["sizePreset"] as? String, let preset = HUDSizePreset(rawValue: p) { sizePreset = preset }
        if let op = d["hudOpacity"] as? Double { hudOpacity = op }
        if let u = d["heroUsername"] as? String, !u.isEmpty { heroUsername = u }
        if let x = d["savedFrameX"] as? Double, let y = d["savedFrameY"] as? Double,
           let w = d["savedFrameW"] as? Double, let h = d["savedFrameH"] as? Double {
            savedFrameX = x
            savedFrameY = y
            savedFrameW = w
            savedFrameH = h
        }
    }
}

// MARK: - Data Model

struct PokerAdvice: Equatable {
    let id: Int
    let hand: String
    let position: String
    let board: String
    let action: String
    let recommendation: String
    let confidence: Int
    let hint: String
    let timestamp: String
    let smallBlind: String
    let bigBlind: String
    let ante: String
    let villainNames: String
    let gameType: String
    let tableMode: String
    let heroHasCards: Bool
    let actionOnHero: Bool
}

// MARK: - Position Stat Model

struct PositionStat: Identifiable {
    let id = UUID()
    let position: String
    let hands: Int
    let followPct: Int
    let avgDelta: Double

    var isProfit: Bool { avgDelta > 0 }
    var isLeak:   Bool { followPct < 40 || avgDelta < -1 }
}

// MARK: - Opponent Profile Model

struct OpponentProfile: Identifiable {
    let id = UUID()
    let username: String
    let vpip: Int?; let pfr: Int?; let threeBet: Int?
    let cbet: Int?; let foldToCbet: Int?; let hands: Int?
    let handsVsMe: Int?; let handsWonVsMe: Int?
    let playerType: String
    let notes: String?
}

// MARK: - Database Poller

func resolveDatabasePath() -> String {
    let home = NSHomeDirectory()
    return home + "/stakelab_poker.db"
}

final class AdviceStore: ObservableObject {
    @Published var current: PokerAdvice?      = nil
    @Published var isIdle:  Bool              = false
    @Published var latencyText: String        = "—"
    @Published var sessionCalls: Int          = 0
    @Published var sessionCost:  Double       = 0.0
    @Published var captureToast: String       = ""
    @Published var knownPlayers: [OpponentProfile] = []
    @Published var totalProfiled: Int         = 0
    @Published var positionStats: [PositionStat] = []

    private var db: OpaquePointer? = nil
    var lastId: Int = -1  // internal so NativeWatcher extension can update it
    private var lastSpokenText: String = ""
    private var lastSpokenAdviceId: Int = -1
    private var lastSpokenHand: String = ""
    private var timer: DispatchSourceTimer?
    private var nativeMode: Bool = false
    let dbPath: String

    init() {
        dbPath = resolveDatabasePath()
        openDB()
        startPolling()
    }

    deinit {
        timer?.cancel()
        if db != nil { sqlite3_close(db) }
    }

    private func openDB() {
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            if let err = sqlite3_errmsg(db) {
                print("❌ SQLite open error for \(dbPath): \(String(cString: err))")
            }
            db = nil
        } else {
            print("📖 Swift HUD successfully connected to DB at: \(dbPath)")
        }
    }

    private func startPolling() {
        let q = DispatchQueue(label: "poker.hud.poller", qos: .utility)
        let src = DispatchSource.makeTimerSource(queue: q)
        src.schedule(deadline: .now(), repeating: .milliseconds(250))
        src.setEventHandler { [weak self] in
            guard !(self?.nativeMode ?? false) else { return }
            self?.poll()
        }
        src.resume()
        timer = src
    }

    /// Call this when native watcher takes over — stops SQLite polling
    /// so it doesn't overwrite advice coming from the vision engine.
    func enableNativeMode() {
        nativeMode = true
    }

    func disableNativeMode() {
        nativeMode = false
    }

    private func poll() {
        if db == nil { openDB() }
        guard let db = db else { return }
        let sql = "SELECT id,hand,position,board,action,recommendation,confidence,hint,timestamp,COALESCE(small_blind,''),COALESCE(big_blind,''),COALESCE(ante,''),COALESCE(villain_names,''),COALESCE(game_type,'NLH'),COALESCE(action_on_hero, 0),COALESCE(table_mode, 'TOURNEY'),COALESCE(hero_has_cards, 1) FROM live_advice ORDER BY id DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if let err = sqlite3_errmsg(db) {
                print("❌ SQLite prepare error for query on \(dbPath): \(String(cString: err))")
            }
            return
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }

        let id         = Int(sqlite3_column_int(stmt, 0))
        let hand       = col(stmt, 1); let position = col(stmt, 2)
        let board      = col(stmt, 3); let action   = col(stmt, 4)
        let rec        = col(stmt, 5)
        let confidence = Int(sqlite3_column_int(stmt, 6))
        let hint       = col(stmt, 7); let timestamp = col(stmt, 8)
        let smallBlind = col(stmt, 9); let bigBlind  = col(stmt, 10)
        let ante       = col(stmt, 11); let villains  = col(stmt, 12)
        let gameType   = col(stmt, 13)
        let actionOnHero = sqlite3_column_int(stmt, 14) != 0
        let detectedTableMode = col(stmt, 15).uppercased()
        let heroHasCards = sqlite3_column_int(stmt, 16) != 0

        guard id != lastId else {
            let idle = isStale(timestamp, minutes: 3)
            if idle != isIdle { DispatchQueue.main.async { self.isIdle = idle } }
            self.pollCost()
            return
        }
        lastId = id
        let advice  = PokerAdvice(id: id, hand: hand, position: position, board: board,
                                  action: action, recommendation: rec, confidence: confidence,
                                  hint: hint, timestamp: timestamp,
                                  smallBlind: smallBlind, bigBlind: bigBlind,
                                  ante: ante, villainNames: villains,
                                  gameType: gameType,
                                  tableMode: detectedTableMode,
                                  heroHasCards: heroHasCards,
                                  actionOnHero: actionOnHero)
        let latency = latencyStr(timestamp)
        DispatchQueue.main.async {
            self.current = advice
            self.isIdle = false
            self.latencyText = latency

            // Auto-switch CASH vs TOURNEY tab if table mode was detected
            if detectedTableMode == "CASH" && HUDSettings.shared.gameMode != .cash {
                HUDSettings.shared.gameMode = .cash
            } else if detectedTableMode == "TOURNEY" && HUDSettings.shared.gameMode != .tourney {
                HUDSettings.shared.gameMode = .tourney
            }

            // Voice Alert (Native macOS speech synthesizer)
            let cleanHand = hand.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasCards = !cleanHand.isEmpty && !cleanHand.lowercased().contains("no card")
            let ageSec = self.ageInSeconds(timestamp)
            let isFresh = ageSec <= 5.0
            let isActionable = !action.isEmpty && action != "WAIT" && action != "IDLE" && !action.uppercased().contains("N/A")

            if HUDSettings.shared.voiceAlerts && hasCards && actionOnHero && isFresh && isActionable {
                let speech = action.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
                let isNewAdvice = (id != self.lastSpokenAdviceId)
                let isNewHandOrAction = (cleanHand != self.lastSpokenHand || speech != self.lastSpokenText)

                if isNewAdvice && isNewHandOrAction {
                    self.lastSpokenText = speech
                    self.lastSpokenAdviceId = id
                    self.lastSpokenHand = cleanHand
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    let vName = HUDSettings.shared.voiceName
                    let vRate = String(HUDSettings.shared.voiceRate)
                    proc.arguments = ["-v", vName, "-r", vRate, speech]
                    try? proc.run()
                }
            } else if !actionOnHero || !hasCards {
                if cleanHand != self.lastSpokenHand {
                    self.lastSpokenText = ""
                    self.lastSpokenHand = cleanHand
                }
            }
        }
        self.pollCost()
    }

    private func pollCost() {
        guard let db = db else { return }
        let today = { () -> String in
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            return df.string(from: Date())
        }()
        let sql = "SELECT api_calls, est_cost_usd FROM session_stats WHERE session_date = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (today as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        let calls = Int(sqlite3_column_int(stmt, 0))
        let cost  = sqlite3_column_double(stmt, 1)
        DispatchQueue.main.async { self.sessionCalls = calls; self.sessionCost = cost }

        // Poll capture toast
        let toastSQL = "SELECT stat_value, updated_at FROM coaching_stats WHERE stat_key = 'last_captured_player' LIMIT 1"
        var toastStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, toastSQL, -1, &toastStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(toastStmt) }
        if sqlite3_step(toastStmt) == SQLITE_ROW {
            let msg = String(cString: sqlite3_column_text(toastStmt, 0))
            let ts  = String(cString: sqlite3_column_text(toastStmt, 1))
            if let date = parseDate(ts), Date().timeIntervalSince(date) < 8 {
                DispatchQueue.main.async { if self.captureToast != msg { self.captureToast = msg } }
            } else {
                DispatchQueue.main.async { if !self.captureToast.isEmpty { self.captureToast = "" } }
            }
        }

        // Poll opponent profiles for current table villains
        let oppSQL = "SELECT username, vpip, pfr, three_bet, cbet, fold_to_cbet, hands_sample, notes, COALESCE(hands_vs_me,0), COALESCE(hands_won_vs_me,0) FROM opponent_profiles ORDER BY last_seen DESC LIMIT 20"
        var oppStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, oppSQL, -1, &oppStmt, nil) == SQLITE_OK {
            var profiles: [OpponentProfile] = []
            while sqlite3_step(oppStmt) == SQLITE_ROW {
                let uname = String(cString: sqlite3_column_text(oppStmt, 0))
                let vpip  = sqlite3_column_type(oppStmt, 1) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 1)) : nil
                let pfr   = sqlite3_column_type(oppStmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 2)) : nil
                let tbet  = sqlite3_column_type(oppStmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 3)) : nil
                let cbet  = sqlite3_column_type(oppStmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 4)) : nil
                let ftc   = sqlite3_column_type(oppStmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 5)) : nil
                let hands = sqlite3_column_type(oppStmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 6)) : nil
                let rawNotes = sqlite3_column_type(oppStmt, 7) != SQLITE_NULL ? String(cString: sqlite3_column_text(oppStmt, 7)) : nil
                let ptype = rawNotes ?? "unknown"
                let hvsme = sqlite3_column_type(oppStmt, 8) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 8)) : nil
                let hwon  = sqlite3_column_type(oppStmt, 9) != SQLITE_NULL ? Int(sqlite3_column_int(oppStmt, 9)) : nil
                profiles.append(OpponentProfile(username: uname, vpip: vpip, pfr: pfr, threeBet: tbet,
                                                cbet: cbet, foldToCbet: ftc, hands: hands,
                                                handsVsMe: hvsme, handsWonVsMe: hwon, playerType: ptype, notes: rawNotes))
            }
            sqlite3_finalize(oppStmt)
            let total = (try? { () -> Int in
                var s: OpaquePointer?
                sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM opponent_profiles", -1, &s, nil)
                defer { sqlite3_finalize(s) }
                return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
            }()) ?? 0
            DispatchQueue.main.async { self.knownPlayers = profiles; self.totalProfiled = total }
        }

        // Poll position stats
        let posSQL = "SELECT stat_value FROM coaching_stats WHERE stat_key = 'position_stats' LIMIT 1"
        var posStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, posSQL, -1, &posStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(posStmt) }
        if sqlite3_step(posStmt) == SQLITE_ROW,
           let ptr = sqlite3_column_text(posStmt, 0) {
            let raw = String(cString: ptr)
            var stats: [PositionStat] = []
            for entry in raw.split(separator: "|") {
                let parts = entry.split(separator: ":")
                guard parts.count == 4,
                      let hands = Int(parts[1]),
                      let follow = Int(parts[2]),
                      let delta = Double(parts[3]) else { continue }
                stats.append(PositionStat(position: String(parts[0]),
                                          hands: hands, followPct: follow, avgDelta: delta))
            }
            let order = ["BTN","CO","HJ","MP","UTG","SB","BB"]
            stats.sort { order.firstIndex(of: $0.position) ?? 99 < order.firstIndex(of: $1.position) ?? 99 }
            DispatchQueue.main.async { self.positionStats = stats }
        }
    }

    private func col(_ s: OpaquePointer?, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(s, i) else { return "" }
        return String(cString: p)
    }
    private func isStale(_ ts: String, minutes: Int) -> Bool {
        guard let d = parseDate(ts) else { return false }
        return Date().timeIntervalSince(d) > Double(minutes * 60)
    }
    private func ageInSeconds(_ ts: String) -> Double {
        guard let d = parseDate(ts) else { return 9999 }
        return Date().timeIntervalSince(d)
    }
    private func latencyStr(_ ts: String) -> String {
        guard let d = parseDate(ts) else { return "—" }
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "\(s)s ago" : "\(s/60)m ago"
    }
    private func parseDate(_ ts: String) -> Date? {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss","yyyy-MM-dd'T'HH:mm:ss","yyyy-MM-dd HH:mm:ss.SSS"] {
            df.dateFormat = fmt; if let d = df.date(from: ts) { return d }
        }
        return nil
    }
}
