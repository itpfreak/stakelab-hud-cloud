// StakeNativeWatcher.swift
// Native Swift screen capture + Purple-blob card detection + Apple Vision OCR + Local Qwen 2.5
// Target: Floorp browser (Firefox-based) running Stake.com poker tables
//
// Architecture:
//   Stage 1 — ScreenCapture:        /usr/sbin/screencapture grabs Floorp window PNG
//   Stage 2 — PurpleCardDetector:   Scans for colored card-back blobs (purple by default),
//                                    classifies them as hero or board, crops each card face,
//                                    then runs VNRecognizeTextRequest on each small crop.
//   Stage 3 — AppleVisionTableReader: Reads all remaining table text (pot, blinds, buttons,
//                                    stacks, player names) from the full image.
//   Stage 4 — LMStudioClient:        Structured table JSON -> Qwen 2.5 7B @ localhost:1234
//
// Card back color requirement: Set your Stake.com card back to any solid color
// (purple recommended). Configure PurpleCardDetector constants to match if you change it.
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

        // 4. Read table: purple blob card detection + full-image text OCR
        await MainActor.run { self.store.setWatcherStatus("Reading table (blob+OCR)... hero='\(settings.heroUsername)'") }
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

// MARK: - Purple Card Blob Detector

/// Detects colored card backs by scanning for a configurable target color,
/// clusters matching pixels into card-sized blobs, classifies them as hero
/// (bottom zone) or board (center zone), then crops each card face for OCR.
///
/// To change the card-back color: update cardBackR/G/B to match your Stake setting.
/// Purple (132, 24, 245) is the recommended color — distinct from all table elements.
enum PurpleCardDetector {

    // ── Tunable constants ───────────────────────────────────────────────────

    /// Target card-back color (sRGB 0–255). Default = Stake purple (132, 24, 245).
    static let cardBackR: Int = 132
    static let cardBackG: Int =  24
    static let cardBackB: Int = 245

    /// Per-channel tolerance for color matching.
    static let colorTolerance: Int = 40

    /// Minimum clustered pixel count for a blob to count as a card.
    static let minBlobPixels: Int = 8

    // ── Public types ────────────────────────────────────────────────────────

    struct CardBlob {
        let centerX:     CGFloat   // normalized 0–1 relative to table width
        let centerY:     CGFloat   // normalized 0–1
        let isHero:      Bool      // true = hero hand (y > 58%), false = board (y 28–58%)
        let tableScaleX: CGFloat   // tableRightX / imgW — used by cropCard
    }

    // ── Public entry point ──────────────────────────────────────────────────

    /// Returns detected card blobs from a CGImage.
    /// Automatically detects the poker table right boundary so that Floorp
    /// browser chrome (sidebar, UI panels) on the right is excluded from
    /// coordinate normalization.
    static func detect(cgImage: CGImage) -> [CardBlob] {
        guard
            let dataRef = cgImage.dataProvider?.data,
            let ptr     = CFDataGetBytePtr(dataRef)
        else { return [] }

        let imgW = cgImage.width
        let imgH = cgImage.height
        let bpp  = cgImage.bitsPerPixel / 8   // bytes per pixel (3 or 4)
        let bpr  = cgImage.bytesPerRow

        // ── Auto-detect table right edge ────────────────────────────────────
        // Floorp browser chrome on the right side is a uniform dark color
        // identical to the table felt (32-58, 36-60, 50-74). Scan several
        // horizontal strips from right→left to find where "table" content ends
        // and the browser chrome begins. We look for the first x column (from
        // the right) that contains any non-dark pixel, which marks table content.
        // If the whole image is table, tableRightX == imgW.
        func isDarkChrome(_ r: Int, _ g: Int, _ b: Int) -> Bool {
            // Table felt + Floorp chrome are both dark blue-gray in this range
            return r < 80 && g < 80 && b < 90
        }

        var tableRightX = imgW
        let stripeYs = [imgH / 4, imgH / 2, imgH * 3 / 4]
        // Scan right→left at three y levels; stop at first non-dark column
        outer: for x in stride(from: imgW - 1, through: imgW * 4 / 10, by: -1) {
            var allDark = true
            for sy in stripeYs {
                let off = sy * bpr + x * bpp
                let r = Int(ptr[off]); let g = Int(ptr[off+1]); let b = Int(ptr[off+2])
                if !isDarkChrome(r, g, b) { allDark = false; break }
            }
            if !allDark { tableRightX = x + 1; break outer }
        }

        // Clamp: table must be at least 40% of image width (sanity check)
        if tableRightX < imgW * 4 / 10 { tableRightX = imgW }

        // Step 1: Collect matching pixel coords within table bounds (sample every 2px)
        var hits: [(x: Int, y: Int)] = []
        let step = 2
        for y in stride(from: 0, to: imgH, by: step) {
            for x in stride(from: 0, to: tableRightX, by: step) {
                let offset = y * bpr + x * bpp
                let r = Int(ptr[offset])
                let g = Int(ptr[offset + 1])
                let b = Int(ptr[offset + 2])
                if abs(r - cardBackR) <= colorTolerance &&
                   abs(g - cardBackG) <= colorTolerance &&
                   abs(b - cardBackB) <= colorTolerance {
                    hits.append((x, y))
                }
            }
        }
        guard !hits.isEmpty else { return [] }

        // Step 2: Cluster by proximity using a coarse bucket grid (~3% of image width)
        let bucketSize = max(1, imgW / 33)
        var buckets: [Int: [Int: [(Int, Int)]]] = [:]
        for h in hits {
            let bx = h.x / bucketSize
            let by = h.y / bucketSize
            buckets[bx, default: [:]][by, default: []].append((h.x, h.y))
        }

        // BFS merge of adjacent buckets into blobs
        var visited = Set<String>()
        var blobs:   [[(Int, Int)]] = []

        for (bx, col) in buckets {
            for (by, _) in col {
                let key = "\(bx)_\(by)"
                guard !visited.contains(key) else { continue }
                var blob:  [(Int, Int)] = []
                var queue: [(Int, Int)] = [(bx, by)]
                while !queue.isEmpty {
                    let (cx, cy) = queue.removeFirst()
                    let k = "\(cx)_\(cy)"
                    guard !visited.contains(k) else { continue }
                    visited.insert(k)
                    if let pixels = buckets[cx]?[cy] { blob.append(contentsOf: pixels) }
                    for dx in -1...1 {
                        for dy in -1...1 {
                            let nx = cx + dx; let ny = cy + dy
                            let nk = "\(nx)_\(ny)"
                            if !visited.contains(nk), buckets[nx]?[ny] != nil {
                                queue.append((nx, ny))
                            }
                        }
                    }
                }
                if blob.count >= minBlobPixels { blobs.append(blob) }
            }
        }

        // Step 3: Compute blob centers and zone-classify
        // Normalize against tableRightX (not imgW) so coords are table-relative
        let fW = CGFloat(tableRightX)
        let fH = CGFloat(imgH)

        return blobs.compactMap { blob -> CardBlob? in
            let sumX = blob.reduce(0) { $0 + $1.0 }
            let sumY = blob.reduce(0) { $0 + $1.1 }
            let cx   = CGFloat(sumX) / CGFloat(blob.count) / fW
            let cy   = CGFloat(sumY) / CGFloat(blob.count) / fH
            // Board zone: y 28–58% | Hero zone: y 58–82% | Ignore UI chrome outside these
            guard cy >= 0.28 && cy <= 0.82 else { return nil }
            let scaleX = CGFloat(tableRightX) / CGFloat(imgW)
            return CardBlob(centerX: cx, centerY: cy, isHero: cy > 0.58, tableScaleX: scaleX)
        }
    }

    // ── Card crop ───────────────────────────────────────────────────────────

    /// Crops a region around a blob center for per-card OCR.
    /// blob.centerX is table-relative (0–1 of table width), so we multiply by
    /// tableScaleX to convert back to full-image pixel coordinates.
    static func cropCard(cgImage: CGImage, blob: CardBlob,
                         cardW: CGFloat = 0.10, cardH: CGFloat = 0.12) -> CGImage? {
        let imgW   = CGFloat(cgImage.width)
        let imgH   = CGFloat(cgImage.height)
        // Convert table-relative centerX back to full-image coords
        let absX   = blob.centerX * blob.tableScaleX * imgW
        let absY   = blob.centerY * imgH
        let halfW  = cardW * blob.tableScaleX * imgW / 2
        let halfH  = cardH * imgH / 2
        let x = max(0, absX - halfW)
        let y = max(0, absY - halfH)
        let w = min(halfW * 2, imgW - x)
        let h = min(halfH * 2, imgH - y)
        guard w > 10, h > 10 else { return nil }
        return cgImage.cropping(to: CGRect(x: x, y: y, width: w, height: h))
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
    var isHeroFolded:    Bool
    var cardSource:      String   // "blob+ocr" | "ocr-only" | "error"
}

// MARK: - Apple Vision Table Reader

enum AppleVisionTableReader {

    struct TextItem {
        let text: String
        let box:  CGRect
    }

    static func read(imageData: Data, heroUsername: String) async -> TableOCRResult {
        guard let cgImage = makeCGImage(from: imageData) else {
            return emptyResult()
        }

        // Stage 1: Detect colored card-back blobs
        let blobs = PurpleCardDetector.detect(cgImage: cgImage)

        let heroBlobs  = blobs.filter {  $0.isHero }.sorted { $0.centerX < $1.centerX }
        let boardBlobs = blobs.filter { !$0.isHero }.sorted { $0.centerX < $1.centerX }

        // Stage 2: OCR each detected card crop
        var heroCards:  [String] = []
        var boardCards: [String] = []

        for blob in heroBlobs.prefix(4) {   // max 4 hole cards (PLO)
            if let crop = PurpleCardDetector.cropCard(cgImage: cgImage, blob: blob) {
                let card = await ocrSingleCard(cgImage: crop)
                if !card.isEmpty { heroCards.append(card) }
            }
        }

        for blob in boardBlobs.prefix(5) {   // max 5 community cards
            if let crop = PurpleCardDetector.cropCard(cgImage: cgImage, blob: blob) {
                let card = await ocrSingleCard(cgImage: crop)
                if !card.isEmpty { boardCards.append(card) }
            }
        }

        let tableScale = blobs.first.map { String(format: "%.0f%%", $0.tableScaleX * 100) } ?? "100%"
        let cardSource = blobs.isEmpty ? "ocr-only" : "blob+ocr(\(blobs.count)blobs,tbl=\(tableScale))"

        // Stage 3: Full-image OCR for table metadata (pot, blinds, buttons, stacks)
        let items   = await ocrFullImage(cgImage: cgImage)
        let rawText = items.sorted { $0.box.minY > $1.box.minY }
                          .map { $0.text }.joined(separator: "\n")

        // Stage 4: Parse metadata
        var result = parseMetadata(items: items, rawText: rawText, heroUsername: heroUsername)
        result.heroCards  = heroCards
        result.boardCards = boardCards
        result.cardSource = cardSource

        // Blob detection of hero cards is ground truth — override fold detection
        if !heroCards.isEmpty { result.isHeroFolded = false }

        return result
    }

    // MARK: - Per-card OCR

    /// OCR a small card crop. Returns "Ah", "Kd", "10s", rank-only, or "" if unreadable.
    private static func ocrSingleCard(cgImage: CGImage) async -> String {
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { r, err in
                guard err == nil,
                      let obs = r.results as? [VNRecognizedTextObservation]
                else { cont.resume(returning: ""); return }

                var texts: [String] = []
                for ob in obs {
                    if let t = ob.topCandidates(1).first { texts.append(t.string) }
                }
                let combined = texts.joined(separator: " ")
                cont.resume(returning: parseCardToken(from: combined))
            }
            req.recognitionLevel       = .accurate
            req.usesLanguageCorrection = false
            req.recognitionLanguages   = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])
        }
    }

    /// Parse a single card notation from OCR text of a card crop.
    /// Handles: "A♠", "Ah", "10d", "K", "9s", rank-only fallback.
    private static func parseCardToken(from text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "" }

        // Normalize unicode suit glyphs to letter suits
        let suitMap: [Character: Character] = [
            "♠": "s", "♤": "s",
            "♥": "h", "♡": "h",
            "♦": "d", "♢": "d",
            "♣": "c", "♧": "c"
        ]
        var normalized = ""
        for ch in t {
            if let s = suitMap[ch] { normalized.append(s) }
            else { normalized.append(ch) }
        }

        // Primary: rank + suit
        let rankSuitPattern = "\\b(10|[2-9TJQKA])[shdc]\\b"
        if let re = try? NSRegularExpression(pattern: rankSuitPattern, options: [.caseInsensitive]) {
            let ns = normalized as NSString
            if let m = re.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)) {
                var token = ns.substring(with: m.range)
                // Capitalize rank, lowercase suit
                if token.count >= 2 {
                    let rank = String(token.prefix(token.count - 1)).uppercased()
                    let suit = String(token.suffix(1)).lowercased()
                    token = rank + suit
                }
                return token
            }
        }

        // Fallback: rank only (suit not visible / covered by card back color)
        let rankOnlyPattern = "\\b(10|[2-9TJQKA])\\b"
        if let re = try? NSRegularExpression(pattern: rankOnlyPattern, options: [.caseInsensitive]) {
            let ns = normalized as NSString
            if let m = re.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range).uppercased()
            }
        }
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
            ? "\(Int(heroX * 100))%,\(Int(heroY * 100))%"
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
            } else if potSize.isEmpty && item.box.midY >= 0.45 && item.box.midY <= 0.80 {
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
                if distToHero <= 0.22 && heroStack.isEmpty {
                    heroStack = moneys.first ?? ""
                } else {
                    villainLines.append(trimmed)
                }
            }
        }

        // Fold detection: button-based only (blob presence overrides this later)
        let isHeroFolded = lowerRaw.contains("folded") ||
                           (lowerRaw.contains("fold") && !hasPlayButtons)

        return TableOCRResult(
            rawText:         rawText,
            heroCards:       [],       // filled in by caller after blob+OCR pass
            boardCards:      [],       // filled in by caller after blob+OCR pass
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
Cards were detected via pixel color blob detection + per-card OCR crops.
Coaching style: \(style).
Hero username on Stake.com: "\(heroUsername)".

Return ONLY a valid JSON object -- no markdown, no explanation, no prose:
{"hand":"","position":"BTN|CO|HJ|MP|UTG|SB|BB","board":"","action":"FOLD|CALL|CHECK|RAISE|BET|WAITING","recommendation":"","confidence":0,"hint":"","small_blind":"","big_blind":"","ante":"","villain_names":"","game_type":"NLH|PLO","table_mode":"CASH|TOURNEY","hero_has_cards":true,"action_on_hero":true}

CRITICAL RULES:
1. "\(heroUsername)" is hero's USERNAME, NOT hero's hand! Never report "J4" or "J4 clubs" as the hand.
2. If "is_hero_folded" is true or "hero_cards" is empty, set "hand" to "", "hero_has_cards" to false, "action_on_hero" to false, "action" to "WAITING", recommendation to "Folded — observing table".
3. If "hero_cards" has entries (e.g. ["Ah","Kd"]), output them space-separated in "hand" (e.g. "Ah Kd").
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
        // Blob-detected cards are ground truth — use them if LLM left hand blank
        if hand.isEmpty && !ocrResult.heroCards.isEmpty && !ocrResult.isHeroFolded {
            hand = ocrResult.heroCards.joined(separator: " ")
        }

        var board = s("board")
        if board.isEmpty && !ocrResult.boardCards.isEmpty {
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
