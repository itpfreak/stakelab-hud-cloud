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
        captureToast = msg
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

        // 4. OCR the table with Apple Vision
        await MainActor.run { self.store.setWatcherStatus("Reading table (Vision OCR)...") }
        let ocrResult = await AppleVisionTableReader.read(imageData: imageData)

        guard !ocrResult.rawText.isEmpty else {
            await MainActor.run {
                self.store.setWatcherStatus("WARNING: Vision OCR returned no text -- check screen capture size/permission")
            }
            return
        }

        // 5. Call local LLM
        await MainActor.run { self.store.setWatcherStatus("Asking Qwen 2.5 (localhost:1234)...") }

        do {
            let advice = try await LMStudioClient.analyze(
                ocrResult: ocrResult,
                mode:      settings.gameMode.rawValue,
                style:     settings.coachingStyle.rawValue
            )
            guard advice.action != "WAITING" else {
                await MainActor.run { self.store.setWatcherStatus("Waiting for hand...") }
                return
            }
            await MainActor.run {
                self.store.setAdvice(advice)
                self.store.setWatcherStatus("OK: \(advice.action) -- \(advice.recommendation.prefix(60))")
                if self.settings.voiceAlerts && !advice.action.isEmpty {
                    let sayProc = Process()
                    sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    sayProc.arguments = [advice.action.lowercased()]
                    try? sayProc.run()
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
    var rawText:     String
    var heroCards:   [String]
    var boardCards:  [String]
    var potSize:     String
    var heroStack:   String
    var smallBlind:  String
    var bigBlind:    String
    var gameType:    String
    var tableMode:   String
    var villainInfo: String
}

enum AppleVisionTableReader {

    static func read(imageData: Data) async -> TableOCRResult {
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

                var lines: [(text: String, y: CGFloat)] = []
                for obs in observations {
                    guard let top = obs.topCandidates(1).first else { continue }
                    lines.append((text: top.string, y: obs.boundingBox.minY))
                }
                lines.sort { $0.y > $1.y }
                let rawText = lines.map { $0.text }.joined(separator: "\n")
                let result  = parseOCRLines(lines.map { $0.text }, rawText: rawText)
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
                       gameType: "", tableMode: "", villainInfo: "")
    }

    private static func parseOCRLines(_ lines: [String], rawText: String) -> TableOCRResult {
        var heroCards:   [String] = []
        var boardCards:  [String] = []
        var potSize      = ""
        var heroStack    = ""
        var smallBlind   = ""
        var bigBlind     = ""
        var gameType     = "NLH"
        var tableMode    = "CASH"
        var villainLines: [String] = []

        let cardPattern  = "[2-9TJQKA][shdc]"
        let moneyPattern = "\\$[\\d]+\\.[\\d]{2}"

        func matches(_ pattern: String, in text: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return re.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }

        for line in lines {
            let trimmed  = line.trimmingCharacters(in: .whitespaces)
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
            } else if potSize.isEmpty {
                let moneys = matches(moneyPattern, in: trimmed)
                if moneys.count == 1 && !trimmed.lowercased().contains("buy") {
                    potSize = moneys[0]
                }
            }

            let cards = matches(cardPattern, in: trimmed)
            if !cards.isEmpty {
                if cards.count == 2 && heroCards.isEmpty { heroCards = cards }
                else if cards.count >= 3 { boardCards = cards }
            }

            let moneys = matches(moneyPattern, in: trimmed)
            if !moneys.isEmpty && trimmed != potSize {
                villainLines.append(trimmed)
                heroStack = moneys.last ?? heroStack
            }
        }

        return TableOCRResult(
            rawText:     rawText,
            heroCards:   heroCards,
            boardCards:  boardCards,
            potSize:     potSize,
            heroStack:   heroStack,
            smallBlind:  smallBlind,
            bigBlind:    bigBlind,
            gameType:    gameType,
            tableMode:   tableMode,
            villainInfo: villainLines.suffix(10).joined(separator: "; ")
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
        ocrResult: TableOCRResult,
        mode:      String,
        style:     String
    ) async throws -> PokerAdvice {

        guard let url = URL(string: endpoint) else {
            throw APIError.unreachable("bad URL")
        }

        let tableJSON = buildTableJSON(ocrResult: ocrResult, mode: mode)

        let systemPrompt = """
You are a live poker HUD engine for Stake.com online poker.
You receive an OCR-extracted table state JSON from a Stake.com screenshot.
Coaching style: \(style).

Return ONLY a valid JSON object -- no markdown, no explanation, no prose:
{"hand":"","position":"BTN|CO|HJ|MP|UTG|SB|BB","board":"","action":"FOLD|CALL|CHECK|RAISE|BET|WAITING","recommendation":"","confidence":0,"hint":"","small_blind":"","big_blind":"","ante":"","villain_names":"","game_type":"NLH|PLO","table_mode":"CASH|TOURNEY","hero_has_cards":true,"action_on_hero":true}

Use action WAITING if: no active hand, hero has folded, or it is not hero's turn.
Keep recommendation under 20 words. hint under 12 words.
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

    private static func buildTableJSON(ocrResult: TableOCRResult, mode: String) -> String {
        var raw = ocrResult.rawText
        if raw.count > 1200 { raw = String(raw.prefix(1200)) + "..." }
        let obj: [String: Any] = [
            "game_mode":    mode,
            "game_type":    ocrResult.gameType.isEmpty  ? "NLH"  : ocrResult.gameType,
            "table_mode":   ocrResult.tableMode.isEmpty ? "CASH" : ocrResult.tableMode,
            "hero_cards":   ocrResult.heroCards,
            "board_cards":  ocrResult.boardCards,
            "pot":          ocrResult.potSize,
            "hero_stack":   ocrResult.heroStack,
            "small_blind":  ocrResult.smallBlind,
            "big_blind":    ocrResult.bigBlind,
            "villain_info": ocrResult.villainInfo,
            "raw_ocr_text": raw
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
            smallBlind:     sb,
            bigBlind:       bb,
            ante:           s("ante"),
            villainNames:   s("villain_names"),
            gameType:       s("game_type").isEmpty  ? ocrResult.gameType  : s("game_type"),
            tableMode:      s("table_mode").isEmpty ? ocrResult.tableMode : s("table_mode"),
            heroHasCards:   (d["hero_has_cards"] as? Bool) ?? (act != "WAITING"),
            actionOnHero:   (d["action_on_hero"] as? Bool) ?? (act != "WAITING" && !act.isEmpty)
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
