// StakeNativeWatcher.swift
// Native Swift screen capture + Seat-Anchor Card Detection + Apple Vision OCR + Local Qwen 2.5
// Target: Floorp browser (Firefox-based) running Stake.com poker tables
//
// Architecture:
//   Stage 1 — ScreenCapture:          /usr/sbin/screencapture grabs Floorp window PNG
//   Stage 2 — Full-Image OCR:         VNRecognizeTextRequest scans table for text, locating:
//                                     - Hero username ("J4clubs") bounding box
//                                     - Pot size, blinds, action buttons, stacks
//   Stage 3 — Hero Cards Crop:        Takes a tight crop DIRECTLY ABOVE the hero's username
//                                     bounding box (regardless of what seat hero is in)
//                                     and extracts the 2 hole cards via OCR + 4-color suit check.
//   Stage 4 — Board Cards Crop:       Takes a crop of the middle felt (community cards)
//                                     and extracts flop/turn/river cards.
//   Stage 5 — Strategy Advice:        Structured table JSON -> Qwen 2.5 7B @ localhost:1234
//
// Zero cloud. Zero API key. Zero token cost.
// Works with any seat position, window size, or deck colors (standard & 4-color).
// Requires: macOS 12+, Screen Recording permission, LM Studio running on port 1234

import AppKit
import CryptoKit
import Foundation
import Vision

// MARK: - AdviceStore Extension

extension AdviceStore {
    @MainActor
    func setAdvice(_ advice: PokerAdvice) {
        lastId      = advice.id
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

        // 4. Read table: locate hero username -> crop cards directly above it + crop board
        await MainActor.run { self.store.setWatcherStatus("Reading table (seat-anchor)... hero='\(settings.heroUsername)'") }
        let ocrResult = await AppleVisionTableReader.read(imageData: imageData, heroUsername: settings.heroUsername)

        guard !ocrResult.rawText.isEmpty || !ocrResult.heroCards.isEmpty else {
            await MainActor.run {
                self.store.setWatcherStatus("WARNING: Vision OCR returned no text -- check Floorp window / permissions")
            }
            return
        }

        let heroStatus = ocrResult.heroFound
            ? "Hero '\(settings.heroUsername)' [\(ocrResult.heroSeat)]"
            : "Hero '\(settings.heroUsername)' [searching]"
        let summary = "\(heroStatus): cards=\(ocrResult.heroCards) board=\(ocrResult.boardCards) pot=\(ocrResult.potSize.isEmpty ? "-" : ocrResult.potSize) btns=\(ocrResult.detectedButtons) src=\(ocrResult.cardSource)"
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

// MARK: - Table OCR Result

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
    var heroBox:         CGRect?
    var isHeroFolded:    Bool
    var cardSource:      String
}

// MARK: - Apple Vision Table Reader

enum AppleVisionTableReader {

    struct TextItem {
        let text: String
        let box:  CGRect // Vision normalized boundingBox (origin bottom-left)
    }

    static func read(imageData: Data, heroUsername: String) async -> TableOCRResult {
        guard let cgImage = makeCGImage(from: imageData) else {
            return emptyResult()
        }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Stage 1: Run full-image OCR to read table text, locate hero seat, buttons, blinds, pot
        let items = await ocrFullImage(cgImage: cgImage)
        let rawText = items.sorted { $0.box.minY > $1.box.minY }
                           .map { $0.text }.joined(separator: "\n")

        // Parse general table metadata from text
        var result = parseMetadata(items: items, rawText: rawText, heroUsername: heroUsername)

        // Stage 2: Hero Cards Crop & Read
        // If hero username was located on the table, hero's cards sit DIRECTLY ABOVE the username!
        var heroCards: [String] = []
        if result.heroFound, let heroBox = result.heroBox {
            // Convert Vision coordinates (origin at bottom-left) to top-down CGImage coordinates
            let topDownX = heroBox.origin.x
            let topDownY = 1.0 - (heroBox.origin.y + heroBox.size.height)
            let boxW = heroBox.size.width

            // Cards are centered horizontally with username, positioned directly above it
            let cardCropW: CGFloat = max(0.13, boxW * 1.6)
            let cardCropH: CGFloat = 0.14
            let cardCenterX: CGFloat = topDownX + (boxW / 2.0)
            let cardCenterY: CGFloat = topDownY - (cardCropH * 0.45)

            let cropRect = CGRect(
                x: max(0, (cardCenterX - cardCropW / 2.0) * imgW),
                y: max(0, (cardCenterY - cardCropH / 2.0) * imgH),
                width: min(cardCropW * imgW, imgW),
                height: min(cardCropH * imgH, imgH)
            )

            if let heroCardsCrop = cgImage.cropping(to: cropRect) {
                let maxHole = result.gameType.contains("PLO") ? 4 : 2
                heroCards = await extractCards(from: heroCardsCrop, maxCards: maxHole, isHero: true)
            }
        }

        // Stage 3: Community Board Cards Crop & Read
        // Board cards are in the middle of the table felt (x: 0.18..0.60, y: 0.28..0.58)
        var boardCards: [String] = []
        let boardCropRect = CGRect(
            x: max(0, 0.18 * imgW),
            y: max(0, 0.28 * imgH),
            width: min(0.44 * imgW, imgW),
            height: min(0.30 * imgH, imgH)
        )
        if let boardCrop = cgImage.cropping(to: boardCropRect) {
            boardCards = await extractCards(from: boardCrop, maxCards: 5, isHero: false)
        }

        result.heroCards  = heroCards
        result.boardCards = boardCards
        result.cardSource = heroCards.isEmpty
            ? "seat-crop(searching)"
            : "seat-crop(\(heroCards.joined(separator: " ")))"

        if !heroCards.isEmpty {
            result.isHeroFolded = false
        } else if result.heroFound && result.detectedButtons.isEmpty {
            // Hero found at seat but has no cards and no action buttons -> folded/waiting
            result.isHeroFolded = true
        }

        return result
    }

    // MARK: - Card Extraction from Region Crop

    private static func extractCards(from cgImage: CGImage, maxCards: Int, isHero: Bool) async -> [String] {
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { r, err in
                guard err == nil,
                      let obs = r.results as? [VNRecognizedTextObservation]
                else { cont.resume(returning: []); return }

                // Sort text observations horizontally left-to-right
                let sortedObs = obs.sorted { $0.boundingBox.minX < $1.boundingBox.minX }

                var cards: [String] = []
                let suitMap: [Character: Character] = [
                    "♠": "s", "♤": "s",
                    "♥": "h", "♡": "h",
                    "♦": "d", "♢": "d",
                    "♣": "c", "♧": "c"
                ]

                let rankSuitPattern = "\\b(10|[2-9TJQKA])[shdc]\\b"
                let rankOnlyPattern = "\\b(10|[2-9TJQKA])\\b"
                let reRankSuit = try? NSRegularExpression(pattern: rankSuitPattern, options: [.caseInsensitive])
                let reRankOnly = try? NSRegularExpression(pattern: rankOnlyPattern, options: [.caseInsensitive])

                let cropW = CGFloat(cgImage.width)
                let cropH = CGFloat(cgImage.height)

                for ob in sortedObs {
                    guard let top = ob.topCandidates(1).first else { continue }
                    let rawText = top.string.trimmingCharacters(in: .whitespaces)
                    guard !rawText.isEmpty else { continue }

                    // Skip money, pot, blinds, or UI chrome labels
                    if rawText.contains("$") || rawText.lowercased().contains("pot") || rawText.lowercased().contains("total") {
                        continue
                    }

                    // Normalize unicode suit glyphs
                    var normalized = ""
                    for ch in rawText {
                        if let s = suitMap[ch] { normalized.append(s) }
                        else { normalized.append(ch) }
                    }

                    // 1. Try matching Rank + Suit (e.g. "Ad", "3d", "Kh", "8s", "2s")
                    if let re = reRankSuit {
                        let ns = normalized as NSString
                        let matches = re.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
                        for m in matches {
                            var token = ns.substring(with: m.range)
                            if token.count >= 2 {
                                let rank = String(token.prefix(token.count - 1)).uppercased()
                                let suit = String(token.suffix(1)).lowercased()
                                token = rank + suit
                            }
                            if !cards.contains(token) || isHero {
                                cards.append(token)
                            }
                        }
                    }

                    // 2. If no rank+suit match, try Rank only and detect suit from pixel color
                    if cards.count < maxCards, let re = reRankOnly {
                        let ns = normalized as NSString
                        let matches = re.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
                        for m in matches {
                            let rank = ns.substring(with: m.range).uppercased()
                            if cards.contains(where: { $0.hasPrefix(rank) }) { continue }

                            // Sample pixels around this text observation to detect card suit color
                            let obBox = ob.boundingBox
                            let pixelRect = CGRect(
                                x: obBox.origin.x * cropW,
                                y: (1.0 - obBox.origin.y - obBox.height) * cropH,
                                width: obBox.width * cropW,
                                height: obBox.height * cropH
                            ).insetBy(dx: -20, dy: -20)

                            var suit = detectSuitFromColor(cgImage: cgImage, in: pixelRect)
                            if suit.isEmpty && isHero {
                                // Fallback: sample left half vs right half of hero cards crop
                                let halfRect = obBox.origin.x < 0.5
                                    ? CGRect(x: 0, y: 0, width: cropW / 2, height: cropH)
                                    : CGRect(x: cropW / 2, y: 0, width: cropW / 2, height: cropH)
                                suit = detectSuitFromColor(cgImage: cgImage, in: halfRect)
                            }

                            let cardToken = rank + (suit.isEmpty ? "" : suit)
                            cards.append(cardToken)
                        }
                    }

                    if cards.count >= maxCards { break }
                }

                cont.resume(returning: Array(cards.prefix(maxCards)))
            }

            req.recognitionLevel       = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages   = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
        }
    }

    /// Detects card suit from pixel colors in Stake 4-color and 2-color decks:
    /// - Blue  -> "d" (Diamonds in 4-color deck)
    /// - Red   -> "h" (Hearts)
    /// - Green -> "c" (Clubs in 4-color deck)
    /// - Dark  -> "s" (Spades)
    private static func detectSuitFromColor(cgImage: CGImage, in rect: CGRect) -> String {
        guard
            let dataRef = cgImage.dataProvider?.data,
            let ptr     = CFDataGetBytePtr(dataRef)
        else { return "" }

        let imgW = cgImage.width
        let imgH = cgImage.height
        let bpp  = cgImage.bitsPerPixel / 8
        let bpr  = cgImage.bytesPerRow

        let minX = max(0, Int(rect.minX))
        let maxX = min(imgW, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(imgH, Int(rect.maxY))

        guard maxX > minX, maxY > minY else { return "" }

        var blue = 0
        var red = 0
        var green = 0
        var dark = 0

        let step = 2
        for y in stride(from: minY, to: maxY, by: step) {
            for x in stride(from: minX, to: maxX, by: step) {
                let off = y * bpr + x * bpp
                let r = Int(ptr[off])
                let g = Int(ptr[off + 1])
                let b = Int(ptr[off + 2])

                if b > 120 && b > r + 30 && b > g + 20 {
                    blue += 1
                } else if r > 140 && r > g + 40 && r > b + 40 {
                    red += 1
                } else if g > 120 && g > r + 30 && g > b + 30 {
                    green += 1
                } else if r < 50 && g < 50 && b < 50 {
                    dark += 1
                }
            }
        }

        if blue > red && blue > green && blue > 80 { return "d" }
        if red > blue && red > green && red > 80 { return "h" }
        if green > blue && green > red && green > 80 { return "c" }
        if dark > 80 { return "s" }
        return ""
    }

    // MARK: - Full-image OCR

    private static func ocrFullImage(cgImage: CGImage) async -> [TextItem] {
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { r, err in
                guard err == nil,
                      let obs = r.results as? [VNRecognizedTextObservation]
                else { cont.resume(returning: []); return }
                let items = obs.compactMap { ob -> TextItem? in
                    guard let t = ob.topCandidates(1).first else { return nil }
                    return TextItem(text: t.string, box: ob.boundingBox)
                }
                cont.resume(returning: items)
            }
            req.recognitionLevel       = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages   = ["en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
        }
    }

    // MARK: - Metadata parsing

    private static func parseMetadata(items: [TextItem], rawText: String,
                                      heroUsername: String) -> TableOCRResult {
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

        // Locate hero seat by username
        let target = heroUsername.lowercased().filter { $0.isLetter || $0.isNumber }
        var heroBox: CGRect? = nil
        var heroMatchedText = ""

        if !target.isEmpty {
            for item in items {
                let clean = item.text.lowercased().filter { $0.isLetter || $0.isNumber }
                guard !clean.isEmpty else { continue }
                if clean.contains(target) ||
                   (target.count >= 4 && target.contains(clean) && clean.count >= 4) {
                    heroBox = item.box
                    heroMatchedText = item.text
                    break
                }
            }
        }

        let heroFound   = heroBox != nil
        let heroX       = heroBox?.midX ?? 0.5
        let heroY       = heroBox?.midY ?? 0.2
        let heroSeatStr = heroFound
            ? "\(Int(heroX * 100))%,\(Int((1.0 - heroY) * 100))%"
            : "not detected"

        // Action buttons
        let lowerRaw = rawText.lowercased()
        var detectedButtons: [String] = []
        for btn in ["fold", "check", "call", "raise", "bet", "all in", "all-in"] {
            if lowerRaw.contains(btn) { detectedButtons.append(btn.uppercased()) }
        }
        let hasPlayButtons = detectedButtons.contains("CALL") || detectedButtons.contains("CHECK")
            || detectedButtons.contains("RAISE") || detectedButtons.contains("BET")

        // Per-item scan for game info, pot, stacks
        for item in items {
            let trimmed   = item.text.trimmingCharacters(in: .whitespaces)
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
            } else if potSize.isEmpty && item.box.midY >= 0.40 && item.box.midY <= 0.75 {
                let moneys = matches(moneyPattern, in: trimmed)
                if moneys.count == 1 && !trimmed.lowercased().contains("buy") {
                    potSize = moneys[0]
                }
            }

            // Skip hero username token
            if heroFound && (item.text == heroMatchedText || trimmed.lowercased().contains(target)) {
                continue
            }

            // Stacks / villain lines
            let moneys = matches(moneyPattern, in: trimmed)
            let distToHero = heroFound
                ? hypot(item.box.midX - heroX, item.box.midY - heroY)
                : hypot(item.box.midX - 0.5,   item.box.midY - 0.2)

            if !moneys.isEmpty && trimmed != potSize {
                if distToHero <= 0.20 && heroStack.isEmpty {
                    heroStack = moneys.first ?? ""
                } else {
                    villainLines.append(trimmed)
                }
            }
        }

        // Fold detection: button-based only (seat-crop presence overrides this later)
        let isHeroFolded = lowerRaw.contains("folded") ||
                           (lowerRaw.contains("fold") && !hasPlayButtons)

        return TableOCRResult(
            rawText:         rawText,
            heroCards:       [],       // filled in by caller after seat crop
            boardCards:      [],       // filled in by caller after board crop
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
            heroBox:         heroBox,
            isHeroFolded:    isHeroFolded,
            cardSource:      "pending"
        )
    }

    // MARK: - Utilities

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
                       heroBox: nil,
                       isHeroFolded: false, cardSource: "error")
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
You receive a table state JSON extracted from a Stake.com screenshot.
Hero cards are cropped directly above hero's seat username label.
Board cards are cropped from the middle of the table.
Coaching style: \(style).
Hero username on Stake.com: "\(heroUsername)".

Return ONLY a valid JSON object -- no markdown, no explanation, no prose:
{"hand":"","position":"BTN|CO|HJ|MP|UTG|SB|BB","board":"","action":"FOLD|CALL|CHECK|RAISE|BET|WAITING","recommendation":"","confidence":0,"hint":"","small_blind":"","big_blind":"","ante":"","villain_names":"","game_type":"NLH|PLO","table_mode":"CASH|TOURNEY","hero_has_cards":true,"action_on_hero":true}

CRITICAL RULES:
1. "\(heroUsername)" is hero's USERNAME, NOT hero's hand! Never report "J4" or "J4 clubs" as the hand.
2. If "is_hero_folded" is true or "hero_cards" is empty, set "hand" to "", "hero_has_cards" to false, "action_on_hero" to false, "action" to "WAITING", recommendation to "Folded — observing table".
3. If "hero_cards" has entries (e.g. ["Ad","3d"]), output them space-separated in "hand" (e.g. "Ad 3d").
4. If "has_action_buttons" is true, action_on_hero is TRUE. Give an actionable recommendation. Do NOT return WAITING when buttons are visible.
5. Keep recommendation under 20 words. hint under 12 words.
6. "action" must be a SINGLE value: FOLD, CALL, CHECK, RAISE, BET, or WAITING — never pipe-separated.
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

    private static func buildTableJSON(ocrResult: TableOCRResult, mode: String,
                                        heroUsername: String) -> String {
        var raw = ocrResult.rawText
        if raw.count > 1200 { raw = String(raw.prefix(1200)) + "..." }
        let obj: [String: Any] = [
            "hero_username":           heroUsername,
            "hero_seat_detected":      ocrResult.heroFound,
            "hero_seat_coordinates":   ocrResult.heroSeat,
            "is_hero_folded":          ocrResult.isHeroFolded,
            "card_detection_source":   ocrResult.cardSource,
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
        else {
            throw APIError.parse("Unexpected response: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }

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

        let s  = { (k: String) -> String in d[k] as? String ?? "" }
        let ts = ISO8601DateFormatter().string(from: Date())
        let id = Int(Date().timeIntervalSince1970 * 1000) & Int.max

        // Sanitize action — guard against "FOLD|CALL" pipe artifacts from LLM
        var act = s("action")
        if act.contains("|") { act = String(act.split(separator: "|").first ?? "WAITING") }
        if act.isEmpty { act = "WAITING" }

        let sb = s("small_blind").isEmpty ? ocrResult.smallBlind : s("small_blind")
        let bb = s("big_blind").isEmpty   ? ocrResult.bigBlind   : s("big_blind")

        var hand = s("hand")
        let cleanH = hand.lowercased().filter { $0.isLetter || $0.isNumber }
        if ocrResult.isHeroFolded || cleanH == "j4clubs" ||
           (cleanH == "j4" && ocrResult.heroCards.isEmpty) {
            hand = ""
        }
        // Ground truth from OCR always takes precedence over LLM guessing
        if !ocrResult.heroCards.isEmpty && !ocrResult.isHeroFolded {
            hand = ocrResult.heroCards.joined(separator: " ")
        }

        var board = s("board")
        if !ocrResult.boardCards.isEmpty {
            board = ocrResult.boardCards.joined(separator: " ")
        }

        let heroHasCards = !ocrResult.isHeroFolded &&
                           (!hand.isEmpty || !ocrResult.heroCards.isEmpty)
        let actionOnHero = !ocrResult.isHeroFolded &&
                           (!ocrResult.detectedButtons.isEmpty ||
                            (act != "WAITING" && !act.isEmpty))

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
