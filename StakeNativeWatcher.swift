// StakeNativeWatcher.swift
// Native Swift screen capture + Gemini vision analysis for Stake.com
// Target: Floorp browser (Firefox-based) running Stake.com poker tables
// Zero Python. Zero external processes (except /usr/sbin/screencapture).
//
// Requires: macOS 12+, Screen Recording permission

import AppKit
import CryptoKit
import Foundation

// MARK: - AdviceStore Extension

extension AdviceStore {
    @MainActor
    func setAdvice(_ advice: PokerAdvice) {
        current     = advice
        isIdle      = false
        latencyText = "live"
    }

    @MainActor
    func clearAdvice() {
        current     = nil
        isIdle      = true
        latencyText = "—"
    }

    @MainActor
    func setWatcherStatus(_ msg: String) {
        captureToast = msg
        // Also write to log file so LogsTabView can display it
        let logDir  = NSHomeDirectory() + "/Library/Logs/StakeLab"
        let logPath = logDir + "/watcher.log"
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                    fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }
}

// MARK: - Native Watcher Engine

final class NativeWatcherEngine {
    private let store:    AdviceStore
    private let settings: HUDSettings
    private var task:     Task<Void, Never>?
    private(set) var isRunning = false

    init(store: AdviceStore, settings: HUDSettings) {
        self.store    = store
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task(priority: .utility) { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task      = nil
        isRunning = false
    }

    private func loop() async {
        var lastHash = Data()
        var cycleCount = 0
        while !Task.isCancelled {
            await runCycle(lastHash: &lastHash)
            cycleCount += 1
            // Every 8 cycles (~6s), dump visible process names to help debug window detection
            if cycleCount % 8 == 0 {
                let procs = StakeTableDetector.visibleProcessNames()
                await MainActor.run {
                    self.store.setWatcherStatus("Scanning... Visible apps: \(procs)")
                }
            }
            try? await Task.sleep(nanoseconds: 750_000_000) // 0.75s
        }
    }

    private func runCycle(lastHash: inout Data) async {
        // 1. Find Stake table window in Floorp
        guard let windowID = StakeTableDetector.findStakeWindowID() else {
            let dbg = StakeTableDetector.debugInfo()
            await MainActor.run {
                self.store.setWatcherStatus("No Floorp window found.\n\(dbg)")
            }
            return
        }

        // 2. Capture in-memory PNG
        guard let imageData = ScreenCapture.capture(windowID: windowID) else {
            await MainActor.run { self.store.setWatcherStatus("⚠️ Screen capture failed") }
            return
        }

        // 3. Hash — skip API if unchanged
        let hash = Data(SHA256.hash(data: imageData))
        guard hash != lastHash else { return }
        lastHash = hash

        // 4. Load Gemini key
        let apiKey = EnvLoader.geminiKey()
        guard !apiKey.isEmpty else {
            await MainActor.run {
                self.store.setWatcherStatus("⚠️ GEMINI_API_KEY missing — check .env")
            }
            return
        }

        await MainActor.run { self.store.setWatcherStatus("🔍 Analyzing Stake table…") }

        // 5. Gemini vision
        do {
            let advice = try await StakeGeminiClient.analyze(
                imageData: imageData,
                mode:      settings.gameMode.rawValue,
                style:     settings.coachingStyle.rawValue,
                apiKey:    apiKey
            )
            guard advice.action != "WAITING" else {
                await MainActor.run { self.store.setWatcherStatus("Waiting for hand…") }
                return
            }
            await MainActor.run {
                self.store.setAdvice(advice)
                self.store.setWatcherStatus("✅ \(advice.action) — \(advice.recommendation.prefix(60))")
                if self.settings.voiceAlerts && !advice.action.isEmpty {
                    let sayProc = Process()
                    sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    sayProc.arguments = [advice.action.lowercased()]
                    try? sayProc.run()
                }
            }
        } catch {
            await MainActor.run {
                self.store.setWatcherStatus("⚠️ \(error.localizedDescription.prefix(120))")
            }
        }
    }
}

// MARK: - Stake Table Detector

enum StakeTableDetector {
    /// Finds the Floorp browser window showing Stake.com.
    /// Firefox-based browsers (Floorp) may not expose tab titles to CGWindowList,
    /// so we use the largest Floorp window as the primary target.
    /// Logs what it finds so the Logs tab shows debug info.
    static func findStakeWindow() -> (id: CGWindowID, title: String)? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        var best: (id: CGWindowID, area: CGFloat, title: String)?

        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String
            else { continue }

            // Match Floorp — may show as "Floorp", "floorp", "Floorp Browser"
            // Also catch Firefox-based names in case Floorp uses a different identifier
            let ownerLC = owner.lowercased()
            guard ownerLC.contains("floorp") || ownerLC == "firefox" else { continue }

            guard
                let rawID  = info[kCGWindowNumber as String] as? Int,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let w = bounds["Width"], let h = bounds["Height"],
                w >= 600, h >= 400   // relaxed minimum — handles smaller windows
            else { continue }

            let windowID = CGWindowID(rawID)
            let area     = w * h
            let title    = info[kCGWindowName as String] as? String ?? ""

            if best == nil || area > best!.area {
                best = (id: windowID, area: area, title: title)
            }
        }
        return best.map { (id: $0.id, title: $0.title) }
    }

    /// Public API — returns just the window ID
    static func findStakeWindowID() -> CGWindowID? {
        findStakeWindow()?.id
    }

    /// Returns comma-separated list of unique visible process names for debugging
    static func visibleProcessNames() -> String {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return "unavailable" }
        var seen = Set<String>()
        for info in list {
            if let owner = info[kCGWindowOwnerName as String] as? String {
                seen.insert(owner)
            }
        }
        return seen.sorted().joined(separator: ", ")
    }

    /// Full debug dump with window sizes and titles
    static func debugInfo() -> String {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return "CGWindowList unavailable" }
        var lines: [String] = ["=== Visible Windows ==="]
        for info in list.prefix(40) {
            let owner  = info[kCGWindowOwnerName as String] as? String ?? "?"
            let title  = info[kCGWindowName as String] as? String ?? ""
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let w = Int(bounds["Width"] ?? 0); let h = Int(bounds["Height"] ?? 0)
            lines.append("\(owner) | \(w)×\(h) | \(title.prefix(50))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Screen Capture

enum ScreenCapture {
    /// Captures a specific window as PNG data using /usr/sbin/screencapture.
    /// Works on all macOS versions, handles full-screen and theater mode.
    static func capture(windowID: CGWindowID) -> Data? {
        let tmpPath = NSTemporaryDirectory() +
            "stakelab_cap_\(windowID)_\(Int.random(in: 1000...9999)).png"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-l", "\(windowID)", "-x", "-o", "-t", "png", tmpPath]
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }

        guard proc.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: tmpPath))
    }
}

// MARK: - .env Loader

enum EnvLoader {
    static func geminiKey() -> String {
        let home = NSHomeDirectory()
        let paths = [
            "\(home)/stakelab-hud/.env",
            "\(home)/freakslab-poker-hud/.env",
            "\(home)/.env"
        ]
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), line.hasPrefix("GEMINI_API_KEY=") else { continue }
                return line
                    .dropFirst("GEMINI_API_KEY=".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    }
}

// MARK: - Stake Gemini Vision Client

enum StakeGeminiClient {

    enum APIError: Swift.Error, LocalizedError {
        case http(Int, String), parse(String)
        var errorDescription: String? {
            switch self {
            case .http(let c, let b): return "HTTP \(c): \(b.prefix(160))"
            case .parse(let m):       return "Parse: \(m)"
            }
        }
    }

    static func analyze(
        imageData: Data,
        mode:      String,
        style:     String,
        apiKey:    String
    ) async throws -> PokerAdvice {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw APIError.parse("Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody   = try buildBody(imageData: imageData, mode: mode, style: style)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try parseResponse(data: data)
    }

    private static func buildBody(imageData: Data, mode: String, style: String) throws -> Data {
        // Stake.com UI layout description:
        // - Dark green felt table, octagonal, 8 seats
        // - Hero (bottom center): hole cards shown bottom-left of table area
        // - Community cards: center of table (empty pre-flop)
        // - Pot: center-top of table in white text
        // - Action buttons: bottom bar — Fold (red/grey), Check (blue), Raise (green/orange)
        // - Villain avatars: circular, around table perimeter, stack size below each in white $
        // - Active player: timer ring highlighted around their seat
        // - Game info top: "London #3 · NLHE · $0.01/$0.02"
        // - Cards: standard suit symbols, dark background, colored suits

        let prompt = """
        You are an expert poker coach analyzing a Stake.com online poker screenshot from the Floorp browser.

        STAKE.COM UI LAYOUT (use this to locate elements):
        - Dark green felt table, octagonal shape, up to 8 player seats around perimeter
        - Hero seat: BOTTOM CENTER — hole cards shown near hero's seat area
        - Community cards: CENTER of table (pre-flop = empty, flop/turn/river visible)
        - Pot size: CENTER-TOP of table in white text (e.g. "$0.05")
        - Action buttons: BOTTOM BAR — Fold (left), Check/Call (center), Raise/Bet (right)
        - Villain avatars: circular icons around table perimeter, $ stack below each
        - Active player: highlighted timer ring around their seat
        - Game info: top of screen — format "TableName · NLH/PLO · $SB/$BB"
        - Cards: standard suits (♠♥♦♣), white/colored text on dark card backgrounds

        Game mode: \(mode) | Coaching style: \(style)

        Analyze the screenshot and return ONLY a JSON object — no markdown, no explanation:
        {
          "hand":           "hero hole cards e.g. '4s Th' using s/h/d/c for suits, or empty string",
          "position":       "BTN | CO | HJ | MP | UTG | SB | BB | EP, or empty",
          "board":          "community cards e.g. 'Ah Kd 2c' or empty if pre-flop",
          "action":         "FOLD | CALL | CHECK | RAISE | BET | WAITING",
          "recommendation": "one concise coaching sentence",
          "confidence":     integer 0-100,
          "hint":           "key read: pot odds, opponent tendency, or board texture note",
          "small_blind":    "SB amount e.g. '0.01' or empty",
          "big_blind":      "BB amount e.g. '0.02' or empty",
          "ante":           "ante amount or empty",
          "villain_names":  "comma-separated visible villain usernames or empty",
          "game_type":      "NLH | PLO | SHORT",
          "table_mode":     "CASH | TOURNEY",
          "hero_has_cards": true or false,
          "action_on_hero": true or false
        }

        Use action WAITING if: no active hand, hero folded, or it is not hero's turn.
        """

        let body: [String: Any] = [
            "contents": [["parts": [
                ["text": prompt],
                ["inline_data": [
                    "mime_type": "image/png",
                    "data": imageData.base64EncodedString()
                ]]
            ]]],
            "generationConfig": ["temperature": 0.15, "maxOutputTokens": 400]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func parseResponse(data: Data) throws -> PokerAdvice {
        guard
            let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cands = root["candidates"] as? [[String: Any]],
            let cont  = cands.first?["content"] as? [String: Any],
            let parts = cont["parts"] as? [[String: Any]],
            var text  = parts.first?["text"] as? String
        else { throw APIError.parse("Unexpected Gemini response structure") }

        // Strip markdown fences
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for fence in ["```json", "```"] {
            if text.hasPrefix(fence) { text = String(text.dropFirst(fence.count)) }
        }
        if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let jd = text.data(using: .utf8),
            let d  = try? JSONSerialization.jsonObject(with: jd) as? [String: Any]
        else { throw APIError.parse("JSON decode failed: \(text.prefix(200))") }

        let s   = { (k: String) -> String in d[k] as? String ?? "" }
        let ts  = ISO8601DateFormatter().string(from: Date())
        let id  = Int(Date().timeIntervalSince1970 * 1000) & Int.max
        let act = s("action")

        return PokerAdvice(
            id:             id,
            hand:           s("hand"),
            position:       s("position"),
            board:          s("board"),
            action:         act,
            recommendation: s("recommendation"),
            confidence:     d["confidence"] as? Int ?? 0,
            hint:           s("hint"),
            timestamp:      ts,
            smallBlind:     s("small_blind"),
            bigBlind:       s("big_blind"),
            ante:           s("ante"),
            villainNames:   s("villain_names"),
            gameType:       s("game_type"),
            tableMode:      s("table_mode").isEmpty ? "CASH" : s("table_mode"),
            heroHasCards:   (d["hero_has_cards"] as? Bool) ?? (act != "WAITING"),
            actionOnHero:   (d["action_on_hero"] as? Bool) ?? (act != "WAITING" && !act.isEmpty)
        )
    }
}
