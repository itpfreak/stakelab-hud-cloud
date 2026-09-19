// StakeNativeWatcher.swift
// Native Swift screen capture + Apple Vision OCR + Local Qwen 2.5 via LM Studio
// Target: Floorp browser (Firefox-based) running Stake.com poker tables
//
// Architecture:
//   Stage 1 — ScreenCapture: /usr/sbin/screencapture grabs Floorp window PNG
//   Stage 2 — AppleVisionTableReader: VNRecognizeTextRequest extracts all visible text
//   Stage 3 — LMStudioClient: structured table JSON -> Qwen 2.5 7B @ localhost:1234
//
// Zero cloud. Zero API key. Zero token cost.
// Requires: macOS 12+, Screen Recording permission, LM Studio running on port 1234

import AppKit
import CryptoKit
import Foundation
import Vision

// MARK: - AdviceStore Extension

extension AdviceStore {
    @MainActor
    func setAdvice(_ advice: PokerAdvice) {
        lastId      = advice.id  // prevent SQLite poll from overwriting
        current     = advice
        isIdle      = false
        latencyText = "live"
    }

    @MainActor
    func clearAdvice() {
        current     = nil
        isIdle      = true
        latencyText = "---"
    }

    @MainActor
    func setWatcherStatus(_ msg: String) {
        // Logs go to watcher.log and the Logs/Diagnostics tab — keeping main HUD view clean
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
        var lastHash   = Data()
        var cycleCount = 0
        while !Task.isCancelled {
            await runCycle(lastHash: &lastHash)
            cycleCount += 1
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
            await MainActor.run {
                self.store.setWatcherStatus("WARNING: Capture failed -- ensure Screen Recording is granted in System Settings -> Privacy -> Screen Recording")
            }
            return
        }

        // 3. Hash -- skip OCR+LLM if screen unchanged
        let hash = Data(SHA256.hash(data: imageData))
        guard hash != lastHash else { return }
        lastHash = hash

        // 4. OCR the table with Apple Vision (targeting hero by username)
        await MainActor.run { self.store.setWatcherStatus("Reading table (Vision OCR)... Searching for hero '\(settings.heroUsername)'") }
        let ocrResult = await AppleVisionTableReader.read(imageData: imageData, heroUsername: settings.heroUsername)

        guard !ocrResult.rawText.isEmpty else {
            await MainActor.run {
                self.store.setWatcherStatus("WARNING: Vision OCR returned no text -- check Floorp window / permissions")
            }
            return
        }

        let heroStatus = ocrResult.heroFound ? "Hero '\(settings.heroUsername)' [\(ocrResult.heroSeat)]" : "Hero '\(settings.heroUsername)' [searching]"
        let summary = "\(heroStatus): cards=\(ocrResult.heroCards) pot=\(ocrResult.potSize.isEmpty ? "-" : ocrResult.potSize) btns=\(ocrResult.detectedButtons)"
        await MainActor.run { self.store.setWatcherStatus("\(summary) -> Asking Qwen 2.5...") }

        do {
            let advice = try await LMStudioClient.analyze(
                ocrResult:    ocrResult,
                mode:         settings.gameMode.rawValue,
                style:        settings.coachingStyle.rawValue,
                heroUsername: settings.heroUsername
            )
            await MainActor.run {
                self.store.setAdvice(advice)
                if advice.action == "WAITING" {
                    let msg = advice.recommendation.isEmpty ? "Waiting for action / hand" : advice.recommendation
                    self.store.setWatcherStatus("Waiting: \(msg.prefix(60))")
                } else {
                    self.store.setWatcherStatus("OK: \(advice.action) -- \(advice.recommendation.prefix(60))")
                    if self.settings.voiceAlerts && !advice.action.isEmpty && advice.actionOnHero {
                        let sayProc = Process()
                        sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                        sayProc.arguments = [advice.action.lowercased()]
                        try? sayProc.run()
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.store.setWatcherStatus("LLM error: \(error.localizedDescription.prefix(120))")
            }
        }
    }
}

// MARK: - Apple Vision Table Reader

struct TableOCRResult {
    var rawText:         String
    var heroCards:       [String]
    var boardCards:      [String]
    var potSize:         String
    var heroStack:       String
    var smallBlind:      String
    var bigBlind:        String
    var gameType:        String
    var tableMode:       String
    var villainInfo:     String
    var detectedButtons: [String]
    var heroFound:       Bool
    var heroSeat:        String
    var isHeroFolded:    Bool
}

enum AppleVisionTableReader {

    struct TextItem {
        let text: String
        let box:  CGRect
    }

    static func read(imageData: Data, heroUsername: String) async -> TableOCRResult {
        return await withCheckedContinuation { continuation in
            guard let cgImage = makeCGImage(from: imageData) else {
                continuation.resume(returning: emptyResult())
                return
            }

            let request = VNRecognizeTextRequest { req, error in
                guard error == nil,
                      let observations = req.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: emptyResult())
                    return
                }

                var items: [TextItem] = []
                for obs in observations {
                    guard let top = obs.topCandidates(1).first else { continue }
                    items.append(TextItem(text: top.string, box: obs.boundingBox))
                }
                let sortedItems = items.sorted { $0.box.minY > $1.box.minY }
                let rawText = sortedItems.map { $0.text }.joined(separator: "\n")
                let result  = parseOCRItems(items: sortedItems, rawText: rawText, heroUsername: heroUsername)
                continuation.resume(returning: result)
            }

            request.recognitionLevel        = .accurate
            request.usesLanguageCorrection  = false
            request.recognitionLanguages    = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: emptyResult())
            }
        }
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    private static func emptyResult() -> TableOCRResult {
        TableOCRResult(rawText: "", heroCards: [], boardCards: [], potSize: "",
                       heroStack: "", smallBlind: "", bigBlind: "",
                       gameType: "", tableMode: "", villainInfo: "",
                       detectedButtons: [], heroFound: false, heroSeat: "",
                       isHeroFolded: false)
    }

    private static func parseOCRItems(items: [TextItem], rawText: String, heroUsername: String) -> TableOCRResult {
        var potSize       = ""
        var heroStack     = ""
        var smallBlind    = ""
        var bigBlind      = ""
        var gameType      = "NLH"
        var tableMode     = "CASH"
        var villainLines: [String] = []

        let moneyPattern = "\\$[\\d]+\\.[\\d]{2}"

        func matches(_ pattern: String, in text: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return re.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }

        // 1. Locate Hero Seat by Username
        let target = heroUsername.lowercased().filter { $0.isLetter || $0.isNumber }
        var heroBox: CGRect? = nil
        var heroMatchedText = ""

        if !target.isEmpty {
            for item in items {
                let clean = item.text.lowercased().filter { $0.isLetter || $0.isNumber }
                guard !clean.isEmpty else { continue }
                if clean.contains(target) || (target.count >= 4 && target.contains(clean) && clean.count >= 4) {
                    heroBox = item.box
                    heroMatchedText = item.text
                    break
                }
            }
        }

        let heroFound = (heroBox != nil)
        let heroX = heroBox?.midX ?? 0.5
        let heroY = heroBox?.midY ?? 0.2
        let heroSeatStr = heroFound
            ? "\(Int(heroX * 100))%,\(Int(heroY * 100))%"
            : "not detected"

        // 2. Action buttons
        let lowerRaw = rawText.lowercased()
        var detectedButtons: [String] = []
        for btn in ["fold", "check", "call", "raise", "bet", "all in", "all-in"] {
            if lowerRaw.contains(btn) {
                detectedButtons.append(btn.uppercased())
            }
        }
        let hasPlayButtons = detectedButtons.contains("CALL") || detectedButtons.contains("CHECK") || detectedButtons.contains("RAISE") || detectedButtons.contains("BET")

        // 3. Card extraction helper
        let cardWithSuitRegex = try? NSRegularExpression(pattern: "\\b(?:10|[2-9TJQKA])[shdc♠♥♦♣♤♡♢♧]\\b|\\b(?:10|[2-9TJQKA])[♠♥♦♣♤♡♢♧]", options: [.caseInsensitive])
        let twoRanksRegex     = try? NSRegularExpression(pattern: "\\b(10|[2-9TJQKA])\\s*(10|[2-9TJQKA])\\b", options: [.caseInsensitive])
        let singleRankRegex   = try? NSRegularExpression(pattern: "\\b(10|[2-9TJQKA])\\b", options: [.caseInsensitive])

        func extractCards(from line: String) -> [String] {
            var t = line
            t = t.replacingOccurrences(of: "\\$[\\d.]+", with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\d+/\\d+", with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\b\\d+(?:\\.\\d+)?[xXbB]+\\b", with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\b\\d+s\\b", with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\b\\d+%\\b", with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\b\\d+-max\\b", with: " ", options: .regularExpression)
            for w in ["stack", "check", "call", "fold", "folded", "raise", "bet", "pot", "dealer", "table", "auto", "time", "bank", "lobby", "tourney", "total"] {
                t = t.replacingOccurrences(of: "\\b\(w)\\b", with: " ", options: [.regularExpression, .caseInsensitive])
            }
            if !target.isEmpty {
                t = t.replacingOccurrences(of: "\\bJ4clubs?\\b", with: " ", options: [.regularExpression, .caseInsensitive])
            }

            let range = NSRange(t.startIndex..., in: t)

            if let re = cardWithSuitRegex {
                let m = re.matches(in: t, range: range).compactMap { Range($0.range, in: t).map { String(t[$0]) } }
                if !m.isEmpty { return m }
            }

            if let re = twoRanksRegex {
                let m = re.matches(in: t, range: range)
                if let first = m.first, first.numberOfRanges >= 3 {
                    var pair: [String] = []
                    if let r1 = Range(first.range(at: 1), in: t) { pair.append(String(t[r1])) }
                    if let r2 = Range(first.range(at: 2), in: t) { pair.append(String(t[r2])) }
                    if pair.count == 2 { return pair }
                }
            }

            if let re = singleRankRegex {
                let m = re.matches(in: t, range: range).compactMap { Range($0.range, in: t).map { String(t[$0]) } }
                if !m.isEmpty { return m }
            }

            return []
        }

        // 4. Scan items for game info, pot, cards, and stacks
        var boardCards: [String] = []
        var nonBoardCardsWithDist: [(card: String, dist: CGFloat)] = []

        for item in items {
            let trimmed = item.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let upperLine = trimmed.uppercased()

            if upperLine.contains("NLH") || upperLine.contains("NLHE") { gameType = "NLH" }
            else if upperLine.contains("PLO") { gameType = "PLO" }

            if upperLine.contains("TOURNEY") || upperLine.contains("MTT") || upperLine.contains("SIT") {
                tableMode = "TOURNEY"
            }

            if let slashRange = trimmed.range(of: "\\$[\\d.]+/\\$[\\d.]+", options: .regularExpression) {
                let blindStr = String(trimmed[slashRange])
                let parts = blindStr.components(separatedBy: "/")
                if parts.count == 2 { smallBlind = parts[0]; bigBlind = parts[1] }
            }

            if trimmed.lowercased().hasPrefix("pot") {
                let moneys = matches(moneyPattern, in: trimmed)
                if let p = moneys.first { potSize = p }
            } else if potSize.isEmpty && item.box.midY >= 0.45 && item.box.midY <= 0.80 {
                let moneys = matches(moneyPattern, in: trimmed)
                if moneys.count == 1 && !trimmed.lowercased().contains("buy") {
                    potSize = moneys[0]
                }
            }

            // Exclude username item
            if heroFound && (item.text == heroMatchedText || trimmed.lowercased().contains(target)) {
                continue
            }
            if trimmed.lowercased().contains("j4club") {
                continue
            }

            let cards = extractCards(from: trimmed)
            let ix = item.box.midX
            let iy = item.box.midY
            let isCenterBoard = (ix >= 0.28 && ix <= 0.72) && (iy >= 0.38 && iy <= 0.65)
            let distToHero = heroFound ? hypot(ix - heroX, iy - heroY) : hypot(ix - 0.5, iy - 0.2)

            if !cards.isEmpty {
                if isCenterBoard {
                    boardCards.append(contentsOf: cards)
                } else {
                    for c in cards {
                        nonBoardCardsWithDist.append((card: c, dist: distToHero))
                    }
                }
            }

            // Money / Stacks
            let moneys = matches(moneyPattern, in: trimmed)
            if !moneys.isEmpty && trimmed != potSize {
                if distToHero <= 0.22 && heroStack.isEmpty {
                    heroStack = moneys.first ?? ""
                } else {
                    villainLines.append(trimmed)
                }
            }
        }

        // 5. Detect if hero has folded
        let isHeroFolded = (lowerRaw.contains("folded") || (lowerRaw.contains("fold") && !hasPlayButtons)) || (nonBoardCardsWithDist.isEmpty && !hasPlayButtons)

        var heroCards: [String] = []
        if !isHeroFolded {
            nonBoardCardsWithDist.sort { $0.dist < $1.dist }
            let maxHole = gameType.contains("PLO") ? 4 : 2
            heroCards = Array(nonBoardCardsWithDist.prefix(maxHole).map { $0.card })
        }

        return TableOCRResult(
            rawText:         rawText,
            heroCards:       heroCards,
            boardCards:      boardCards,
            potSize:         potSize,
            heroStack:       heroStack,
            smallBlind:      smallBlind,
            bigBlind:        bigBlind,
            gameType:        gameType,
            tableMode:       tableMode,
            villainInfo:     villainLines.suffix(10).joined(separator: "; "),
            detectedButtons: detectedButtons,
            heroFound:       heroFound,
            heroSeat:        heroSeatStr,
            isHeroFolded:    isHeroFolded
        )
    }
}

// MARK: - LM Studio Client (Qwen 2.5 7B @ localhost:1234)

enum LMStudioClient {

    enum APIError: Swift.Error, LocalizedError {
        case http(Int, String), parse(String), unreachable(String)
        var errorDescription: String? {
            switch self {
            case .http(let c, let b):   return "HTTP \(c): \(b.prefix(160))"
            case .parse(let m):         return "Parse: \(m)"
            case .unreachable(let m):   return "LM Studio unreachable: \(m)"
            }
        }
    }

    static let endpoint  = "http://localhost:1234/v1/chat/completions"
    static let modelName = "qwen2.5-7b-instruct"

    static func analyze(
        ocrResult:    TableOCRResult,
        mode:         String,
        style:        String,
        heroUsername: String
    ) async throws -> PokerAdvice {

        guard let url = URL(string: endpoint) else {
            throw APIError.unreachable("bad URL")
        }

        let tableJSON = buildTableJSON(ocrResult: ocrResult, mode: mode, heroUsername: heroUsername)

        let systemPrompt = """
You are a live poker HUD engine for Stake.com online poker.
You receive an OCR-extracted table state JSON from a Stake.com screenshot.
Coaching style: \(style).
Hero username on Stake.com: "\(heroUsername)".

Return ONLY a valid JSON object -- no markdown, no explanation, no prose:
{"hand":"","position":"BTN|CO|HJ|MP|UTG|SB|BB","board":"","action":"FOLD|CALL|CHECK|RAISE|BET|WAITING","recommendation":"","confidence":0,"hint":"","small_blind":"","big_blind":"","ante":"","villain_names":"","game_type":"NLH|PLO","table_mode":"CASH|TOURNEY","hero_has_cards":true,"action_on_hero":true}

CRITICAL RULES:
1. "\(heroUsername)" is hero's USERNAME, NOT hero's hand! Never report "J4" or "J4 clubs" as the hand.
2. If "is_hero_folded" is true or "hero_cards" is empty, hero is FOLDED. Set "hand" to "", "hero_has_cards" to false, "action_on_hero" to false, "action" to "WAITING", and recommendation to "Folded — observing table".
3. If "hero_cards" has cards (e.g. ["K", "8"] or ["Kh", "8c"]), output them in "hand" separated by spaces (e.g. "K 8").
4. If "has_action_buttons" is true, action_on_hero is TRUE. Give an actionable recommendation (CHECK, CALL, BET, RAISE, FOLD). Do NOT return WAITING when action buttons are visible!
5. Keep recommendation under 20 words. hint under 12 words.
"""

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": tableJSON]
            ],
            "temperature": 0.1,
            "max_tokens":  300
        ]

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody   = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.unreachable("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try parseResponse(data: data, ocrResult: ocrResult)
    }

    private static func buildTableJSON(ocrResult: TableOCRResult, mode: String, heroUsername: String) -> String {
        var raw = ocrResult.rawText
        if raw.count > 1200 { raw = String(raw.prefix(1200)) + "..." }
        let obj: [String: Any] = [
            "hero_username":           heroUsername,
            "hero_seat_detected":      ocrResult.heroFound,
            "hero_seat_coordinates":   ocrResult.heroSeat,
            "is_hero_folded":          ocrResult.isHeroFolded,
            "game_mode":               mode,
            "game_type":               ocrResult.gameType.isEmpty  ? "NLH"  : ocrResult.gameType,
            "table_mode":              ocrResult.tableMode.isEmpty ? "CASH" : ocrResult.tableMode,
            "hero_cards":              ocrResult.heroCards,
            "board_cards":             ocrResult.boardCards,
            "pot":                     ocrResult.potSize,
            "hero_stack":              ocrResult.heroStack,
            "small_blind":             ocrResult.smallBlind,
            "big_blind":               ocrResult.bigBlind,
            "detected_buttons":        ocrResult.detectedButtons,
            "has_action_buttons":      !ocrResult.detectedButtons.isEmpty,
            "villain_info":            ocrResult.villainInfo,
            "raw_ocr_text":            raw
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str  = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private static func parseResponse(data: Data, ocrResult: TableOCRResult) throws -> PokerAdvice {
        guard
            let root    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            var text    = message["content"] as? String
        else { throw APIError.parse("Unexpected response: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")") }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for fence in ["```json", "```"] {
            if text.hasPrefix(fence) { text = String(text.dropFirst(fence.count)) }
        }
        if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let start = text.firstIndex(of: "{") {
            var candidate = String(text[start...])
            if let end = candidate.lastIndex(of: "}") {
                candidate = String(candidate[...end])
            } else {
                if let lastComma = candidate.lastIndex(of: ",") {
                    candidate = String(candidate[...lastComma].dropLast()) + "}"
                } else {
                    candidate += "}"
                }
            }
            text = candidate
        }

        guard
            let jd = text.data(using: .utf8),
            let d  = try? JSONSerialization.jsonObject(with: jd) as? [String: Any]
        else { throw APIError.parse("JSON decode failed: \(text.prefix(200))") }

        let s   = { (k: String) -> String in d[k] as? String ?? "" }
        let ts  = ISO8601DateFormatter().string(from: Date())
        let id  = Int(Date().timeIntervalSince1970 * 1000) & Int.max
        let act = s("action")
        let sb  = s("small_blind").isEmpty ? ocrResult.smallBlind : s("small_blind")
        let bb  = s("big_blind").isEmpty   ? ocrResult.bigBlind   : s("big_blind")

        var hand = s("hand")
        let cleanH = hand.lowercased().filter { $0.isLetter || $0.isNumber }
        if ocrResult.isHeroFolded || cleanH == "j4clubs" || (cleanH == "j4" && ocrResult.heroCards.isEmpty) {
            hand = ""
        }
        if hand.isEmpty && !ocrResult.heroCards.isEmpty && !ocrResult.isHeroFolded {
            hand = ocrResult.heroCards.joined(separator: " ")
        }

        var board = s("board")
        if board.isEmpty && !ocrResult.boardCards.isEmpty {
            board = ocrResult.boardCards.joined(separator: " ")
        }

        let heroHasCards = !ocrResult.isHeroFolded && (!hand.isEmpty || !ocrResult.heroCards.isEmpty)
        let actionOnHero = !ocrResult.isHeroFolded && (!ocrResult.detectedButtons.isEmpty || (act != "WAITING" && !act.isEmpty))

        return PokerAdvice(
            id:             id,
            hand:           hand,
            position:       s("position"),
            board:          board,
            action:         act,
            recommendation: s("recommendation"),
            confidence:     d["confidence"] as? Int ?? 0,
            hint:           s("hint"),
            timestamp:      ts,
            smallBlind:     sb,
            bigBlind:       bb,
            ante:           s("ante"),
            villainNames:   s("villain_names"),
            gameType:       s("game_type").isEmpty  ? ocrResult.gameType  : s("game_type"),
            tableMode:      s("table_mode").isEmpty ? ocrResult.tableMode : s("table_mode"),
            heroHasCards:   heroHasCards,
            actionOnHero:   actionOnHero
        )
    }
}

// MARK: - Stake Table Detector

enum StakeTableDetector {
    static func findStakeWindow() -> (id: CGWindowID, title: String)? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        var best: (id: CGWindowID, area: CGFloat, title: String)?

        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String else { continue }
            let ownerLC = owner.lowercased()
            guard ownerLC.contains("floorp") || ownerLC == "firefox" else { continue }

            guard
                let rawID  = info[kCGWindowNumber as String] as? Int,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let w = bounds["Width"], let h = bounds["Height"],
                w >= 600, h >= 400
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

    static func findStakeWindowID() -> CGWindowID? { findStakeWindow()?.id }

    static func visibleProcessNames() -> String {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return "unavailable" }
        var seen = Set<String>()
        for info in list {
            if let owner = info[kCGWindowOwnerName as String] as? String { seen.insert(owner) }
        }
        return seen.sorted().joined(separator: ", ")
    }

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
            lines.append("\(owner) | \(w)x\(h) | \(title.prefix(50))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Screen Capture

enum ScreenCapture {
    static func capture(windowID: CGWindowID) -> Data? {
        let tmpPath = NSTemporaryDirectory() +
            "stakelab_cap_\(windowID)_\(Int.random(in: 1000...9999)).png"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-l", "\(windowID)", "-x", "-o", "-t", "png", tmpPath]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }

        if proc.terminationStatus != 0 { return nil }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tmpPath)),
              data.count > 500 else { return nil }
        return data
    }
}
