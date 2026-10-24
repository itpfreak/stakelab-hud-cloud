// StakeNativeWatcher.swift
// Native Swift screen capture + Seat-Anchor Card Detection + Apple Vision OCR + Gemini Cloud
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
//   Stage 5 — Strategy Advice:        Full-table screenshot -> Gemini vision cloud API
//
// Zero cloud. Zero API key. Zero token cost.
// Works with any seat position, window size, or deck colors (standard & 4-color).
// Requires: macOS 12+, Screen Recording permission, GEMINI_API_KEY in the local .env

import AppKit
import CryptoKit
import Foundation
import Vision

// MARK: - AdviceStore Extension

extension AdviceStore {
    @MainActor
    func setAdvice(_ advice: PokerAdvice) {
        // Local vision can miss hero cards for one frame while action moves around.
        // Do not wipe a live hand with a transient WAITING/no-card result.
        if let existing = current,
           existing.heroHasCards,
           !existing.hand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !advice.heroHasCards,
           advice.action == "WAITING" {
            setWatcherStatus("Holding live hand — ignored transient no-card frame")
            latencyText = "live"
            return
        }
        lastId      = advice.id
        current     = advice
        isIdle      = false
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
    private var inferenceTask: Task<Void, Never>?
    private var latestMeaningfulState = ""
    private var cachedHeroBox: CGRect?
    private(set) var isRunning = false
    private(set) var isPaused  = false

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
        inferenceTask?.cancel()
        task      = nil
        inferenceTask = nil
        isRunning = false
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        Task { @MainActor in
            self.store.setWatcherStatus("❚❚ PAUSED (Stream scene: away/BRB)")
        }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        Task { @MainActor in
            self.store.setWatcherStatus("▶ RESUMED (Stream scene: live)")
        }
    }

    private func loop() async {
        var lastHash = Data()
        var cycleCount = 0
        while !Task.isCancelled {
            if isPaused {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s check while paused
                continue
            }
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
        let cycleStarted = Date()
        // 1. Find Stake table window in Floorp
        guard let windowID = StakeTableDetector.findStakeWindowID() else {
            let dbg = StakeTableDetector.debugInfo()
            await MainActor.run {
                self.store.setWatcherStatus("No Floorp window found.\n\(dbg)")
            }
            return
        }

        // 2. Capture in-memory PNG
        let captureStarted = Date()
        guard let imageData = ScreenCapture.capture(windowID: windowID) else {
            await MainActor.run {
                self.store.setWatcherStatus("WARNING: Capture failed -- ensure Screen Recording is granted in System Settings -> Privacy -> Screen Recording")
            }
            return
        }

        let captureMS = Int(Date().timeIntervalSince(captureStarted) * 1000)

        // 3. Hash -- skip OCR+LLM if screen unchanged
        let hash = Data(SHA256.hash(data: imageData))
        guard hash != lastHash else { return }
        lastHash = hash

        // 4. Read table: locate hero username -> crop cards directly above it + crop board
        let ocrStarted = Date()
        await MainActor.run { self.store.setWatcherStatus("Reading table (capture=\(captureMS)ms)... hero='\(settings.heroUsername)'") }
        let ocrResult = await AppleVisionTableReader.read(
            imageData: imageData,
            heroUsername: settings.heroUsername,
            cachedHeroBox: cachedHeroBox
        )
        cachedHeroBox = ocrResult.heroBox ?? cachedHeroBox
        let ocrMS = Int(Date().timeIntervalSince(ocrStarted) * 1000)

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

        // Ignore animation/timer changes that do not alter poker state. This is
        // the main latency win: OCR can continue, but Qwen only runs when cards,
        // board, action buttons, pot/stack, or HUD settings actually change.
        let meaningfulState = [
            ocrResult.heroCards.joined(separator: ","),
            ocrResult.boardCards.joined(separator: ","),
            ocrResult.detectedButtons.joined(separator: ","),
            ocrResult.potSize, ocrResult.heroStack,
            ocrResult.smallBlind, ocrResult.bigBlind, ocrResult.ante,
            ocrResult.heroFound ? "hero-found" : "hero-missing",
            ocrResult.isHeroFolded ? "folded" : "live",
            settings.gameMode.rawValue, settings.coachingStyle.rawValue,
            settings.tournamentStructure.rawValue, settings.tournamentStage.rawValue
        ].joined(separator: "|")
        guard meaningfulState != latestMeaningfulState else { return }

        // Never invoke the model while folded/observing. Clear stale advice once
        // when the hand ends, then wait for a new positively detected hand.
        guard !ocrResult.isHeroFolded && !ocrResult.heroCards.isEmpty else {
            latestMeaningfulState = meaningfulState
            inferenceTask?.cancel()
            inferenceTask = nil
            await MainActor.run {
                self.store.clearAdvice()
                self.store.setWatcherStatus("No active hero hand — model skipped")
            }
            return
        }

        // Publish the OCR-grounded hand immediately. Do not make the HUD wait
        // for the local model before showing a newly dealt hand; Qwen can still
        // refine the recommendation asynchronously below.
        let provisional = PokerAdvice(
            id:             Int(Date().timeIntervalSince1970 * 1000) & Int.max,
            hand:           ocrResult.heroCards.joined(separator: " "),
            position:       "",
            board:          ocrResult.boardCards.joined(separator: " "),
            action:         "WAITING",
            recommendation: ocrResult.detectedButtons.isEmpty ? "Waiting for action." : "Action detected — analyzing.",
            confidence:     0,
            hint:           "",
            timestamp:      ISO8601DateFormatter().string(from: Date()),
            smallBlind:     ocrResult.smallBlind,
            bigBlind:       ocrResult.bigBlind,
            ante:           ocrResult.ante,
            villainNames:   "",
            gameType:       ocrResult.gameType,
            tableMode:      ocrResult.tableMode,
            heroHasCards:   true,
            actionOnHero:   !ocrResult.detectedButtons.isEmpty
        )
        latestMeaningfulState = meaningfulState
        inferenceTask?.cancel()
        await MainActor.run {
            self.store.setAdvice(provisional)
            self.store.latencyText = "OCR \(ocrMS)ms / capture \(captureMS)ms"
            self.store.setWatcherStatus("\(summary) -> Asking Gemini Cloud (OCR=\(ocrMS)ms, capture=\(captureMS)ms)...")
        }

        // Do not block capture/OCR on the model. A slow request must not leave
        // the previous hand displayed while the next hand is being dealt.
        let requestState = meaningfulState
        let requestOCR = ocrResult
        let requestImageData = imageData
        let requestMode = settings.gameMode.rawValue
        let requestStyle = settings.coachingStyle.rawValue
        let requestStructure = settings.tournamentStructure.rawValue
        let requestStage = settings.tournamentStage.rawValue
        let requestUsername = settings.heroUsername
        let requestStarted = Date()
        inferenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let apiKey = EnvLoader.geminiKey()
                let nousProxyBase = EnvLoader.value("NOUS_PROXY_BASE_URL")
                guard !apiKey.isEmpty || !nousProxyBase.isEmpty else {
                    throw StakeGeminiClient.APIError.parse("GEMINI_API_KEY missing — set it in ~/stakelab-hud-cloud/.env")
                }
                let advice = try await StakeGeminiClient.analyze(
                    imageData: requestImageData,
                    mode: requestMode,
                    style: requestStyle,
                    apiKey: apiKey
                )
                guard !Task.isCancelled, requestState == self.latestMeaningfulState else { return }
                let modelMS = Int(Date().timeIntervalSince(requestStarted) * 1000)
                await MainActor.run {
                    guard requestState == self.latestMeaningfulState else { return }
                    self.store.setAdvice(advice)
                    self.store.latencyText = "model \(modelMS)ms / OCR \(ocrMS)ms"
                    if advice.action == "WAITING" {
                        let msg = advice.recommendation.isEmpty ? "Waiting for action / hand" : advice.recommendation
                        self.store.setWatcherStatus("Waiting (model=\(modelMS)ms, OCR=\(ocrMS)ms): \(msg.prefix(60))")
                    } else {
                        self.store.setWatcherStatus("OK (model=\(modelMS)ms, OCR=\(ocrMS)ms): \(advice.action) -- \(advice.recommendation.prefix(60))")
                        if self.settings.voiceAlerts && !advice.action.isEmpty && advice.actionOnHero {
                            let sayProc = Process()
                            sayProc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                            sayProc.arguments = [advice.action.lowercased()]
                            try? sayProc.run()
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.store.setWatcherStatus("LLM error: \(error.localizedDescription.prefix(120))")
                }
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
    var ante:            String
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

    static func read(imageData: Data, heroUsername: String, cachedHeroBox: CGRect? = nil) async -> TableOCRResult {
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
        // The hero username is stable while the table is open. Reuse its last
        // anchor when full-frame OCR misses it during a card animation, so a
        // new hand does not wait for another successful username recognition.
        let seatBox = result.heroBox ?? cachedHeroBox
        if let heroBox = seatBox {
            if result.heroBox == nil { result.heroBox = heroBox }
            result.heroFound = true
            // Convert Vision coordinates (origin at bottom-left) to top-down CGImage coordinates
            let topDownX = heroBox.origin.x
            let topDownY = 1.0 - (heroBox.origin.y + heroBox.size.height)
            let boxW = heroBox.size.width

            // Cards are centered horizontally with username, positioned directly above it
            let cardCropW: CGFloat = max(0.16, boxW * 2.0)
            let cardCropH: CGFloat = 0.16
            let cardCenterX: CGFloat = topDownX + (boxW / 2.0)
            let cardCenterY: CGFloat = topDownY - (cardCropH * 0.50)

            let cropRect = CGRect(
                x: max(0, (cardCenterX - cardCropW / 2.0) * imgW),
                y: max(0, (cardCenterY - cardCropH / 2.0) * imgH),
                width: min(cardCropW * imgW, imgW - max(0, (cardCenterX - cardCropW / 2.0) * imgW)),
                height: min(cardCropH * imgH, imgH - max(0, (cardCenterY - cardCropH / 2.0) * imgH))
            )

            if let heroCardsCrop = cgImage.cropping(to: cropRect) {
                let maxHole = result.gameType.contains("PLO") ? 4 : 2
                heroCards = await extractCards(from: heroCardsCrop, maxCards: maxHole, isHero: true)
            }
        }

        // Stage 3: Community Board Cards Crop & Read
        // Covers center table felt across all table zoom levels and scrolls (x: 0.16..0.62, y: 0.22..0.72)
        var boardCards: [String] = []
        let boardCropRect = CGRect(
            x: max(0, 0.16 * imgW),
            y: max(0, 0.22 * imgH),
            width: min(0.46 * imgW, imgW - max(0, 0.16 * imgW)),
            height: min(0.50 * imgH, imgH - max(0, 0.22 * imgH))
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

                var rawTokens: [(rank: String, suit: String, box: CGRect)] = []
                let suitMap: [Character: String] = [
                    "♠": "s", "♤": "s",
                    "♥": "h", "♡": "h",
                    "♦": "d", "♢": "d",
                    "♣": "c", "♧": "c",
                    "s": "s", "h": "h", "d": "d", "c": "c"
                ]

                // Robust regex: matches rank + optional suit even when tokens are contiguous (A3, Ad3d, 6♥4♠7♥Q♥, K8)
                let cardPattern = "(10|[2-9TJQKA])\\s*([shdc♠♥♦♣♤♡♢♧]?)"
                guard let re = try? NSRegularExpression(pattern: cardPattern, options: [.caseInsensitive]) else {
                    cont.resume(returning: [])
                    return
                }

                for ob in sortedObs {
                    guard let top = ob.topCandidates(1).first else { continue }
                    let rawText = top.string.trimmingCharacters(in: .whitespaces)
                    guard !rawText.isEmpty else { continue }

                    // Skip money, pot, blinds, or UI chrome labels
                    if rawText.contains("$") || rawText.lowercased().contains("pot") || rawText.lowercased().contains("total") {
                        continue
                    }

                    let ns = rawText as NSString
                    let matches = re.matches(in: rawText, range: NSRange(location: 0, length: ns.length))
                    for m in matches {
                        guard m.numberOfRanges >= 2 else { continue }
                        let rankRange = m.range(at: 1)
                        guard rankRange.location != NSNotFound else { continue }
                        let rank = ns.substring(with: rankRange).uppercased()

                        var suit = ""
                        if m.numberOfRanges >= 3 && m.range(at: 2).location != NSNotFound {
                            let suitChar = ns.substring(with: m.range(at: 2)).lowercased()
                            if let s = suitMap[suitChar.first ?? " "] {
                                suit = s
                            }
                        }
                        rawTokens.append((rank: rank, suit: suit, box: ob.boundingBox))
                    }
                }

                let cropW = CGFloat(cgImage.width)
                let cropH = CGFloat(cgImage.height)
                var finalCards: [String] = []

                if isHero {
                    // Hero cards: maxCards (2 in NLH, 4 in PLO)
                    // If suit was not recognized by text OCR, sample pixel colors:
                    // Token 0 -> left half of crop, Token 1 -> right half of crop
                    for (idx, token) in rawTokens.prefix(maxCards).enumerated() {
                        var suit = token.suit
                        if suit.isEmpty {
                            let halfW = cropW / CGFloat(max(1, min(maxCards, 2)))
                            let sampleRect = CGRect(x: CGFloat(idx) * halfW, y: 0, width: halfW, height: cropH)
                            suit = detectSuitFromColor(cgImage: cgImage, in: sampleRect)
                        }
                        finalCards.append(token.rank + (suit.isEmpty ? "s" : suit))
                    }
                } else {
                    // Board cards: up to 5 cards (Flop 3, Turn 4, River 5)
                    for token in rawTokens.prefix(maxCards) {
                        var suit = token.suit
                        if suit.isEmpty {
                            let obBox = token.box
                            let pixelRect = CGRect(
                                x: max(0, obBox.origin.x * cropW - 20),
                                y: max(0, (1.0 - obBox.origin.y - obBox.height) * cropH - 20),
                                width: min(obBox.width * cropW + 40, cropW),
                                height: min(obBox.height * cropH + 40, cropH)
                            )
                            suit = detectSuitFromColor(cgImage: cgImage, in: pixelRect)
                        }
                        finalCards.append(token.rank + (suit.isEmpty ? "s" : suit))
                    }
                }

                cont.resume(returning: finalCards)
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
            // Full-frame OCR only locates metadata/username; use the faster
            // pass here and reserve accurate OCR for the small card crops.
            req.recognitionLevel       = .fast
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
            ante:            "",
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
                       heroStack: "", smallBlind: "", bigBlind: "", ante: "",
                       gameType: "", tableMode: "", villainInfo: "",
                       detectedButtons: [], heroFound: false, heroSeat: "",
                       heroBox: nil,
                       isHeroFolded: false, cardSource: "error")
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
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return nil
        }

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



// MARK: - Local provider configuration

enum EnvLoader {
    private static let paths = [
        NSHomeDirectory() + "/stakelab-hud-cloud/.env",
        NSHomeDirectory() + "/.env"
    ]

    static func value(_ name: String) -> String {
        for path in paths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), line.hasPrefix(name + "=") else { continue }
                return String(line.dropFirst((name + "=").count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return ProcessInfo.processInfo.environment[name] ?? ""
    }

    static func geminiKey() -> String { value("GEMINI_API_KEY") }
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
        let proxyBase = EnvLoader.value("NOUS_PROXY_BASE_URL")
        if !proxyBase.isEmpty {
            return try await NousProxyClient.analyze(
                imageData: imageData, mode: mode, style: style,
                model: EnvLoader.value("NOUS_MODEL").isEmpty ? "google/gemini-3.7-flash" : EnvLoader.value("NOUS_MODEL"),
                baseURL: proxyBase, apiKey: EnvLoader.value("NOUS_PROXY_KEY").isEmpty ? "sk-unused" : EnvLoader.value("NOUS_PROXY_KEY")
            )
        }
        let model = EnvLoader.value("GEMINI_MODEL").isEmpty ? "gemini-3.7-flash" : EnvLoader.value("GEMINI_MODEL")
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: endpoint) else {
            throw APIError.parse("Invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody   = try buildBody(imageData: imageData, mode: mode, style: style)
        // Resize large images (browser windows can be 2560px+ Retina) to avoid timeouts
        if let resized = resizeImageData(imageData, maxWidth: 1280) {
            req.httpBody = try buildBody(imageData: resized, mode: mode, style: style)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try parseResponse(data: data)
    }

    private static func resizeImageData(_ data: Data, maxWidth: CGFloat) -> Data? {
        guard let src = NSImage(data: data), src.size.width > maxWidth else { return nil }
        let scale   = maxWidth / src.size.width
        let newSize = NSSize(width: maxWidth, height: src.size.height * scale)
        let dst = NSImage(size: newSize)
        dst.lockFocus()
        src.draw(in: NSRect(origin: .zero, size: newSize),
                 from: NSRect(origin: .zero, size: src.size),
                 operation: .copy, fraction: 1.0)
        dst.unlockFocus()
        guard let tiff = dst.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
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


// MARK: - Nous Portal subscription proxy client

enum NousProxyClient {
    enum APIError: Swift.Error, LocalizedError {
        case http(Int, String), parse(String)
        var errorDescription: String? {
            switch self {
            case .http(let c, let b): return "Nous proxy HTTP \(c): \(b.prefix(160))"
            case .parse(let m): return "Nous proxy parse: \(m)"
            }
        }
    }

    static func analyze(imageData: Data, mode: String, style: String,
                        model: String, baseURL: String, apiKey: String) async throws -> PokerAdvice {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw APIError.parse("Invalid proxy URL")
        }
        let prompt = """
You are a fast live poker HUD. Analyze this Stake.com screenshot and return ONLY valid JSON.
Game mode: \(mode). Coaching style: \(style).
Return keys: hand, position, board, action, recommendation, confidence, hint, small_blind, big_blind, ante, villain_names, game_type, table_mode, hero_has_cards, action_on_hero.
Use action FOLD, CALL, CHECK, RAISE, BET, or WAITING. Use WAITING when hero has no cards, folded, or it is not hero's turn. Keep recommendation under 20 words. Do not invent cards.
"""
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": [
                    ["type": "text", "text": "Read the poker table screenshot."],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(imageData.base64EncodedString())"]]
                ]]
            ],
            "temperature": 0.1,
            "max_tokens": 160
        ]
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.http(0, "No HTTP response") }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try parse(data: data)
    }

    private static func parse(data: Data) throws -> PokerAdvice {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              var text = message["content"] as? String else {
            throw APIError.parse("Missing choices.message.content")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json") { text = String(text.dropFirst(7)) }
        if text.hasPrefix("```") { text = String(text.dropFirst(3)) }
        if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = String(text[start...end]).data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw APIError.parse("Invalid JSON response: \(text.prefix(200))")
        }
        let str = { (key: String) in d[key] as? String ?? "" }
        let action = str("action").isEmpty ? "WAITING" : str("action")
        return PokerAdvice(
            id: Int(Date().timeIntervalSince1970 * 1000) & Int.max,
            hand: str("hand"), position: str("position"), board: str("board"), action: action,
            recommendation: str("recommendation"), confidence: d["confidence"] as? Int ?? 0,
            hint: str("hint"), timestamp: ISO8601DateFormatter().string(from: Date()),
            smallBlind: str("small_blind"), bigBlind: str("big_blind"), ante: str("ante"),
            villainNames: str("villain_names"), gameType: str("game_type"),
            tableMode: str("table_mode").isEmpty ? "CASH" : str("table_mode"),
            heroHasCards: (d["hero_has_cards"] as? Bool) ?? !str("hand").isEmpty,
            actionOnHero: (d["action_on_hero"] as? Bool) ?? (action != "WAITING")
        )
    }
}
