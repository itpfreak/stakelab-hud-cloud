// StakeLab.swift — Native macOS poker HUD overlay
// Compile: swiftc StakeLab.swift -o StakeLab -lsqlite3
// Requires: macOS 12+

import AppKit
import SwiftUI
import SQLite3
import Combine

// Note: Shared models (GameMode, CoachingStyle, HUDSettings, PokerAdvice, AdviceStore)
// are defined in StakeCommon.swift

// MARK: - Design Tokens

private enum C {
    static let bg       = Color(red:0.10,green:0.12,blue:0.18)
    static let divider  = Color(red:0.30,green:0.33,blue:0.42)
    static let label    = Color(red:0.55,green:0.60,blue:0.72)
    static let primary  = Color.white
    static let secondary = Color(red:0.82,green:0.85,blue:0.92)
    static let gold     = Color(red:1.0,green:0.85,blue:0.35)
    static let fold     = Color(red:1.00,green:0.35,blue:0.35)
    static let raise    = Color(red:0.25,green:0.95,blue:0.55)
    static let call     = Color(red:0.35,green:0.75,blue:1.00)
    static let cyan     = Color(red:0.20,green:0.85,blue:0.95)
    static let confHigh = Color(red:0.25,green:0.95,blue:0.55)
    static let confMid  = Color(red:1.00,green:0.82,blue:0.20)
    static let confLow  = Color(red:1.00,green:0.45,blue:0.25)
    static let tourneyBadge = Color(red:1.0,green:0.70,blue:0.10)
}

extension String {
    var actionColor: Color {
        let u = uppercased()
        if u.contains("FOLD")                                         { return C.fold  }
        if u.contains("RAISE")||u.contains("BET")||u.contains("SHOVE") { return C.raise }
        if u.contains("CALL")||u.contains("CHECK")                    { return C.call  }
        return C.primary
    }
}

// Scaled font helper — reads fontScale from settings
func fz(_ base: CGFloat) -> Font {
    .system(size: base * HUDSettings.shared.fontScale)
}
func fzW(_ base: CGFloat, _ weight: Font.Weight, _ design: Font.Design = .default) -> Font {
    .system(size: base * HUDSettings.shared.fontScale, weight: weight, design: design)
}

// MARK: - Toolbar (minimalist top bar)

struct HUDToolbar: View {
    @ObservedObject var settings = HUDSettings.shared
    @ObservedObject var store: AdviceStore

    var body: some View {
        HStack(spacing: 8) {
            // Cash / Tourney toggle
            HStack(spacing: 0) {
                ForEach(GameMode.allCases, id: \.self) { mode in
                    Button(action: {
                        settings.gameMode = mode
                        settings.save()
                    }) {
                        Text("\(mode.icon) \(mode.label)")
                            .font(fzW(10, .bold, .monospaced))
                            .foregroundColor(settings.gameMode == mode ? .black : C.label)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(settings.gameMode == mode
                                ? (mode == .cash ? C.call : C.tourneyBadge)
                                : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(C.divider.opacity(0.4))
            .clipShape(Capsule())

            // Active Style Badge
            Text("\(settings.coachingStyle.icon) \(settings.coachingStyle.shortLabel)")
                .font(fzW(10, .bold, .monospaced))
                .foregroundColor(settings.streamerMode ? .purple : C.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(settings.streamerMode ? Color.purple.opacity(0.2) : C.secondary.opacity(0.18))
                .clipShape(Capsule())

            if settings.gameMode == .tourney {
                Text("\(settings.tournamentStructure.icon) \(settings.tournamentStructure.shortLabel) • \(settings.tournamentStage.icon) \(settings.tournamentStage.shortLabel)")
                    .font(fzW(9, .bold, .monospaced))
                    .foregroundColor(C.tourneyBadge)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(C.tourneyBadge.opacity(0.16))
                    .clipShape(Capsule())
            }

            Spacer()

            // Settings Menu
            Menu {
                Text("Coaching Style:")
                ForEach(CoachingStyle.allCases, id: \.self) { style in
                    Button(action: {
                        settings.coachingStyle = style
                        settings.save()
                    }) {
                        Text(settings.coachingStyle == style ? "✓ \(style.icon) \(style.label)" : "\(style.icon) \(style.label)")
                    }
                }
                Divider()
                Text("Tournament Structure:")
                ForEach(TournamentStructure.allCases, id: \.self) { structure in
                    Button(action: {
                        settings.tournamentStructure = structure
                        settings.save()
                    }) {
                        Text(settings.tournamentStructure == structure ? "✓ \(structure.icon) \(structure.label)" : "\(structure.icon) \(structure.label)")
                    }
                }
                Divider()
                Text("Tournament Stage:")
                ForEach(TournamentStage.allCases, id: \.self) { stage in
                    Button(action: {
                        settings.tournamentStage = stage
                        settings.save()
                    }) {
                        Text(settings.tournamentStage == stage ? "✓ \(stage.icon) \(stage.label)" : "\(stage.icon) \(stage.label)")
                    }
                }
                Divider()
                Button(action: {
                    settings.streamerMode.toggle()
                    if settings.streamerMode {
                        settings.coachingStyle = .streamer
                    } else if settings.coachingStyle == .streamer {
                        settings.coachingStyle = .gto
                    }
                    settings.save()
                }) {
                    Text(settings.streamerMode ? "✓ 🎮 Streamer Mode (ON)" : "🎮 Streamer Mode (OFF)")
                }
                Divider()
                Text("Voice Alerts:")
                Button(settings.voiceAlerts ? "✓ Voice Alerts Enabled" : "Enable Voice Alerts") {
                    settings.voiceAlerts.toggle()
                    settings.save()
                }
                if settings.voiceAlerts {
                    Button(settings.voiceName == "Samantha" ? "✓ Samantha (US Natural)" : "Samantha (US Natural)") {
                        settings.voiceName = "Samantha"; settings.save()
                    }
                    Button(settings.voiceName == "Daniel" ? "✓ Daniel (UK Formal)" : "Daniel (UK Formal)") {
                        settings.voiceName = "Daniel"; settings.save()
                    }
                }
                Divider()
                Text("Window Preset:")
                ForEach(HUDSizePreset.allCases, id: \.self) { preset in
                    Button(action: {
                        settings.sizePreset = preset
                        settings.fontScale = preset.dimensions.fontScale
                        settings.save()
                        if let appDelegate = NSApp.delegate as? AppDelegate {
                            appDelegate.positionOnSecondaryMonitor()
                        }
                    }) {
                        Text(settings.sizePreset == preset ? "✓ \(preset.rawValue) (\(Int(preset.dimensions.width))px)" : "\(preset.rawValue) (\(Int(preset.dimensions.width))px)")
                    }
                }
                Divider()
                Text("Glass Opacity:")
                Button(settings.hudOpacity >= 0.95 ? "✓ 100% Solid" : "100% Solid") {
                    settings.hudOpacity = 0.98; settings.save()
                }
                Button(abs(settings.hudOpacity - 0.85) < 0.05 ? "✓ 85% Frosted" : "85% Frosted") {
                    settings.hudOpacity = 0.85; settings.save()
                }
                Button(abs(settings.hudOpacity - 0.70) < 0.05 ? "✓ 70% Semi-Transparent" : "70% Semi-Transparent") {
                    settings.hudOpacity = 0.70; settings.save()
                }
                Divider()
                Text("Hero: \(settings.heroUsername)")
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                    Text("Settings")
                        .font(fzW(10, .bold, .monospaced))
                }
                .foregroundColor(C.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(C.divider.opacity(0.4))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
        }
    }
}

// MARK: - Sub-views

struct ConfidencePill: View {
    let value: Int
    var color: Color {
        switch value {
        case 80...100: return C.confHigh
        case 55...79:  return C.confMid
        default:       return C.confLow
        }
    }
    var body: some View {
        Text("\(value)%")
            .font(fzW(14, .bold, .monospaced))
            .foregroundColor(.black)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(color).clipShape(Capsule())
    }
}

// MARK: - 4-Color Deck Card Renderer & Badges
struct PlayingCardPill: View {
    let raw: String
    
    private var suit: String {
        let l = raw.lowercased()
        if raw.contains("♦") || l.hasSuffix("d") { return "♦" }
        if raw.contains("♥") || l.hasSuffix("h") { return "♥" }
        if raw.contains("♣") || l.hasSuffix("c") { return "♣" }
        if raw.contains("♠") || l.hasSuffix("s") { return "♠" }
        return ""
    }
    
    private var rank: String {
        var r = raw
        for s in ["♦", "♥", "♣", "♠", "d", "h", "c", "s", "D", "H", "C", "S"] {
            r = r.replacingOccurrences(of: s, with: "")
        }
        return r.trimmingCharacters(in: .whitespaces)
    }
    
    private var badgeBgColor: Color {
        switch suit {
        case "♦": return Color(red: 0.12, green: 0.45, blue: 0.95) // Stake Blue
        case "♥": return Color(red: 0.92, green: 0.22, blue: 0.22) // Vibrant Red
        case "♣": return Color(red: 0.18, green: 0.72, blue: 0.32) // Stake Green
        case "♠": return Color(red: 0.14, green: 0.15, blue: 0.18) // Dark / Black
        default:  return Color(red: 0.22, green: 0.24, blue: 0.30) // Neutral
        }
    }
    
    private var borderColor: Color {
        switch suit {
        case "♠": return Color(white: 0.45)
        default:  return Color.white.opacity(0.35)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(rank)
                .font(fzW(18, .black, .rounded))
                .foregroundColor(.white)
            if !suit.isEmpty {
                Text(suit)
                    .font(fzW(16, .black, .rounded))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeBgColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
    }
}

struct CardRowView: View {
    let cardsString: String
    
    private var cardList: [String] {
        let pattern = "(?:10|[2-9TJQKA])[shdc♠♥♦♣♤♡♢♧]?"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return cardsString.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        }
        let range = NSRange(cardsString.startIndex..., in: cardsString)
        let matches = re.matches(in: cardsString, range: range).compactMap {
            Range($0.range, in: cardsString).map { String(cardsString[$0]) }
        }
        return matches.isEmpty
            ? cardsString.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            : matches
    }
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(cardList, id: \.self) { card in
                PlayingCardPill(raw: card)
            }
        }
    }
}

struct StatusHeader: View {
    let position: String; let latency: String
    let isIdle: Bool;     let hand: String
    let smallBlind: String; let bigBlind: String; let ante: String
    let gameType: String
    let heroHasCards: Bool
    @ObservedObject var settings = HUDSettings.shared

    var blindsDisplay: String {
        guard !smallBlind.isEmpty, !bigBlind.isEmpty else { return "" }
        let base = "\(smallBlind)/\(bigBlind)"
        return ante.isEmpty ? base : "\(base) (\(ante))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(isIdle ? Color.orange : Color.green).frame(width: 8, height: 8)
                Text(isIdle ? "IDLE" : "LIVE")
                    .font(fzW(12, .bold, .monospaced))
                    .foregroundColor(isIdle ? .orange : .green)
                if !position.isEmpty {
                    Text("·").foregroundColor(C.label)
                    Text(position.uppercased())
                        .font(fzW(13, .bold, .monospaced)).foregroundColor(C.secondary)
                }
                if !blindsDisplay.isEmpty {
                    Text("·").foregroundColor(C.label)
                    Text(blindsDisplay)
                        .font(fzW(12, .semibold, .monospaced)).foregroundColor(C.secondary)
                }
                if !gameType.isEmpty {
                    Text("·").foregroundColor(C.label)
                    Text(gameType)
                        .font(fzW(11, .bold, .monospaced))
                        .foregroundColor(gameType.contains("PLO") ? C.gold : C.label)
                }
                Spacer()
            }
            // Hole cards rendered with 4-Color Deck Badges (only shown when hero is in hand)
            if heroHasCards && !hand.isEmpty {
                HStack(spacing: 8) {
                    Text("HOLE CARDS").font(fzW(11, .bold, .monospaced)).foregroundColor(C.label)
                    CardRowView(cardsString: hand)
                }
            }
        }
    }
}

struct RecommendationBadge: View {
    let action: String; let recommendation: String; let confidence: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("ADVICE")
                    .font(fzW(13, .black, .monospaced))
                    .foregroundColor(C.gold)
                if action != "WAITING" && !action.isEmpty {
                    Text(action)
                        .font(fzW(13, .black, .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(action.actionColor)
                        .clipShape(Capsule())
                }
                Spacer()
                if confidence > 0 { ConfidencePill(value: confidence) }
            }

            Text(recommendation.isEmpty ? action : recommendation)
                .font(fzW(24, .black, .rounded))
                .foregroundColor(action == "WAITING" ? C.primary : action.actionColor)
                .lineLimit(4)
                .minimumScaleFactor(0.72)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(C.divider.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct HandInfoRow: View {
    let board: String
    var body: some View {
        if !board.isEmpty {
            HStack(spacing: 8) {
                Text("BOARD").font(fzW(11, .bold, .monospaced)).foregroundColor(C.label)
                CardRowView(cardsString: board)
            }
        }
    }
}

struct PushFoldIndicator: View {
    let advice: PokerAdvice
    let bbVal: Double

    // Check if recommendation or hint indicates shove range
    private var isShoveZone: Bool {
        advice.action.uppercased().contains("SHOVE") ||
        advice.recommendation.uppercased().contains("ALL-IN") ||
        advice.recommendation.uppercased().contains("SHOVE") ||
        advice.hint.uppercased().contains("PUSH/FOLD") ||
        advice.hint.uppercased().contains("SHOVE")
    }

    var body: some View {
        if isShoveZone {
            HStack(spacing: 8) {
                Text("⚡ PUSH/FOLD")
                    .font(fzW(11, .bold, .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(C.tourneyBadge)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Short Stack: Push/Fold range active")
                    .font(fzW(11, .semibold, .monospaced))
                    .foregroundColor(C.tourneyBadge)

                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(C.tourneyBadge.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct HintSection: View {
    let hint: String
    private var bullets: [String] {
        hint.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var body: some View {
        if !hint.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("WHY / TIPS")
                        .font(fzW(12, .bold, .monospaced))
                        .foregroundColor(C.gold)
                    Spacer()
                }
                ForEach(bullets, id: \.self) { line in
                    let isCoachingHeader = line.contains("LIVE COACHING FEEDBACK") || line.contains("EXPLOIT") || line.contains("OPPONENT")
                    let isLeakWarning = line.contains("⚠️")
                    let isConceptTip = line.contains("💡")
                    let isDeltaStat = line.contains("📈") || line.contains("📉") || line.contains("📊")
                    let isOpponentBullet = line.starts(with: "•") || line.contains("VPIP") || line.contains("PFR")

                    HStack(alignment: .top, spacing: 10) {
                        Text(isLeakWarning ? "⚠️" : (isConceptTip ? "💡" : (isDeltaStat ? "📊" : (isOpponentBullet ? "🎯" : "›"))))
                            .font(fzW(isLeakWarning || isConceptTip || isDeltaStat || isOpponentBullet ? 16 : 20, .black))
                            .foregroundColor(isLeakWarning ? C.fold : (isOpponentBullet ? C.cyan : (isConceptTip ? C.secondary : (isDeltaStat ? C.call : C.gold))))
                        Text(line.replacingOccurrences(of: "⚠️ ", with: "").replacingOccurrences(of: "💡 ", with: "").replacingOccurrences(of: "📈 ", with: "").replacingOccurrences(of: "📉 ", with: "").replacingOccurrences(of: "📊 ", with: "").replacingOccurrences(of: "• ", with: ""))
                            .font(fzW(isCoachingHeader ? 13 : 14, isCoachingHeader || isLeakWarning ? .bold : .medium))
                            .foregroundColor(isLeakWarning ? Color.yellow : (isOpponentBullet ? C.cyan : (isConceptTip ? C.call : (isCoachingHeader ? C.gold : C.primary))))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, isCoachingHeader ? 2 : 0)
                }
            }
            .padding(10)
            .background(C.divider.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("🃏").font(.system(size: 44))
            Text("Waiting for hand...").font(fzW(16, .semibold)).foregroundColor(C.secondary)
            Text("Open Stake.com in Floorp to begin.").font(fz(14)).foregroundColor(C.label)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Position Performance View

struct PositionPerformanceView: View {
    let stats: [PositionStat]

    var body: some View {
        if !stats.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("📍 POSITION PERFORMANCE")
                    .font(fzW(11, .bold, .monospaced)).foregroundColor(C.label)

                ForEach(stats) { stat in
                    HStack(spacing: 10) {
                        // Position label
                        Text(stat.position)
                            .font(fzW(13, .bold, .monospaced))
                            .foregroundColor(C.primary)
                            .frame(width: 36, alignment: .leading)

                        // Follow rate bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(C.divider.opacity(0.3))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(stat.isLeak ? C.fold : C.raise)
                                    .frame(width: geo.size.width * CGFloat(stat.followPct) / 100, height: 6)
                            }
                        }
                        .frame(height: 6)

                        // Follow %
                        Text("\(stat.followPct)%")
                            .font(fzW(11, .bold, .monospaced))
                            .foregroundColor(stat.isLeak ? C.fold : C.raise)
                            .frame(width: 34, alignment: .trailing)

                        // Avg delta
                        Text(stat.avgDelta >= 0 ? "+\(String(format: "%.1f", stat.avgDelta))" : "\(String(format: "%.1f", stat.avgDelta))")
                            .font(fzW(11, .bold, .monospaced))
                            .foregroundColor(stat.isProfit ? C.raise : C.fold)
                            .frame(width: 42, alignment: .trailing)

                        // Hands count
                        Text("\(stat.hands)h")
                            .font(fzW(10, .regular, .monospaced))
                            .foregroundColor(C.label)
                            .frame(width: 30, alignment: .trailing)
                    }
                }

                // Legend
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Rectangle().fill(C.raise).frame(width: 8, height: 8).cornerRadius(1)
                        Text("follow%").font(fzW(9, .regular, .monospaced)).foregroundColor(C.label)
                    }
                    HStack(spacing: 4) {
                        Text("+/-").font(fzW(9, .bold, .monospaced)).foregroundColor(C.label)
                        Text("avg stack Δ").font(fzW(9, .regular, .monospaced)).foregroundColor(C.label)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - Players Tab

struct PlayerRow: View {
    let username: String
    let vpip: Int?; let pfr: Int?; let threeBet: Int?
    let cbet: Int?; let foldToCbet: Int?; let hands: Int?
    let handsVsMe: Int?; let handsWonVsMe: Int?
    let playerType: String
    let notes: String?
    @State private var isExpanded: Bool = false

    var typeColor: Color {
        let t = playerType.lowercased()
        if t.contains("shark")                            { return C.gold }
        if t.contains("donkey")                           { return C.fold }
        if t.contains("fish")                             { return C.fold }
        if t.contains("maniac")                           { return C.tourneyBadge }
        if t.contains("nit")                              { return C.label }
        if t.contains("calling") || t.contains("station") { return C.call }
        if t.contains("tag")                              { return C.raise }
        if t.contains("lag")                              { return C.tourneyBadge }
        if t.contains("loose") && t.contains("passive")   { return C.fold }
        if t.contains("loose") && t.contains("aggress")   { return C.tourneyBadge }
        if t.contains("tight") && t.contains("aggress")   { return C.raise }
        if t.contains("tight") && t.contains("passive")   { return C.call }
        return C.secondary
    }

    var typeShort: String {
        let t = playerType.lowercased()
        if t.contains("shark")                            { return "SHARK 🦈" }
        if t.contains("donkey")                           { return "DONKEY 🐴" }
        if t.contains("fish")                             { return "FISH 🐟" }
        if t.contains("maniac")                           { return "MANIAC 💣" }
        if t.contains("nit")                              { return "NIT 🪨" }
        if t.contains("calling") || t.contains("station") { return "STATION 🚉" }
        if t.contains("tag")                              { return "TAG ⚡" }
        if t.contains("lag")                              { return "LAG 🔥" }
        if t.contains("loose") && t.contains("passive")   { return "FISH 🐟" }
        if t.contains("loose") && t.contains("aggress")   { return "LAG 🔥" }
        if t.contains("tight") && t.contains("aggress")   { return "TAG ⚡" }
        if t.contains("tight") && t.contains("passive")   { return "NIT 🪨" }
        if !playerType.isEmpty && playerType != "unknown" && playerType != "Active Player" {
            let firstWord = playerType.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? playerType
            return "\(firstWord) 🎯"
        }
        return "UNKNOWN ❓"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text(username)
                        .font(fzW(14, .bold, .monospaced))
                        .foregroundColor(C.primary)
                    Spacer()
                    Text(typeShort)
                        .font(fzW(12, .bold, .monospaced))
                        .foregroundColor(typeColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(typeColor.opacity(0.15))
                        .clipShape(Capsule())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(C.label)
                        .padding(.leading, 4)
                }
            }
            .buttonStyle(PlainButtonStyle())

            HStack(spacing: 10) {
                statPill("VPIP", vpip, warn: vpip.map { $0 > 35 } ?? false)
                statPill("PFR",  pfr,  warn: false)
                statPill("3B",   threeBet, warn: false)
                statPill("CB",   cbet, warn: false)
                if let h = hands {
                    Text("\(h) hands")
                        .font(fzW(10, .regular, .monospaced))
                        .foregroundColor(C.label)
                }
            }
            if let ftc = foldToCbet, ftc > 0 {
                Text("Folds to Cbet: \(ftc)%  \(ftc > 60 ? "→ bluff flop!" : ftc < 35 ? "→ value only" : "")")
                    .font(fzW(11, .regular, .monospaced))
                    .foregroundColor(ftc > 60 ? C.raise : C.label)
            }
            if let hvm = handsVsMe, hvm > 0 {
                let won = handsWonVsMe ?? 0
                let winPct = Int(Double(won) / Double(hvm) * 100)
                Text("VS me: \(hvm) hands, won \(won) (\(winPct)%)")
                    .font(fzW(11, .regular, .monospaced))
                    .foregroundColor(winPct > 55 ? C.fold : C.label)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().background(C.divider)
                    HStack {
                        Text("🎯 SPECIFIC HABITS & TELLS")
                            .font(fzW(11, .bold, .monospaced))
                            .foregroundColor(C.cyan)
                        Spacer()
                    }
                    if let n = notes, !n.isEmpty, n != "UNKNOWN" && n != "unknown" {
                        Text(n)
                            .font(fzW(13, .medium))
                            .foregroundColor(C.primary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Accumulating hand samples. Watcher is tracking preflop/postflop sizing and tendencies.")
                            .font(fzW(12, .regular))
                            .foregroundColor(C.label)
                    }
                    
                    // Specific tactical hints based on known stats
                    if let v = vpip, let p = pfr {
                        if v > 40 && p < 15 {
                            Text("💡 Exploit: Loose-Passive Calling Station. Do not bluff. Value bet big on 3 streets when ahead.")
                                .font(fzW(12, .bold))
                                .foregroundColor(C.raise)
                        } else if v < 18 && p < 15 {
                            Text("💡 Exploit: Nit / Rock. Steal their blinds relentlessly. Fold if they show aggression.")
                                .font(fzW(12, .bold))
                                .foregroundColor(C.gold)
                        } else if p > 25 {
                            Text("💡 Exploit: Hyper-Aggressive. 4-bet for value and trap on dry boards.")
                                .font(fzW(12, .bold))
                                .foregroundColor(C.tourneyBadge)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(C.divider.opacity(isExpanded ? 0.28 : 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    func statPill(_ label: String, _ val: Int?, warn: Bool) -> some View {
        if let v = val {
            VStack(spacing: 2) {
                Text("\(v)%")
                    .font(fzW(13, .bold, .monospaced))
                    .foregroundColor(warn ? C.fold : C.primary)
                Text(label)
                    .font(fzW(9, .regular, .monospaced))
                    .foregroundColor(C.label)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(C.divider.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct PlayersTabView: View {
    @ObservedObject var store: AdviceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Active players (currently in hand)
            let activeNames = Set((store.current?.villainNames ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            let active  = store.knownPlayers.filter { activeNames.contains($0.username) }
            let benched = store.knownPlayers.filter { !activeNames.contains($0.username) }

            if active.isEmpty && benched.isEmpty {
                VStack(spacing: 12) {
                    Text("👥").font(.system(size: 36))
                    Text("No opponents profiled yet")
                        .font(fzW(15, .semibold)).foregroundColor(C.secondary)
                    Text("Hover over players in ClubGG\nto capture their stats")
                        .font(fz(13)).foregroundColor(C.label)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                if !active.isEmpty {
                    Text("🟢 IN THIS HAND")
                        .font(fzW(11, .bold, .monospaced)).foregroundColor(C.raise)
                    ForEach(active, id: \.username) { p in
                        PlayerRow(username: p.username, vpip: p.vpip, pfr: p.pfr,
                                  threeBet: p.threeBet, cbet: p.cbet,
                                  foldToCbet: p.foldToCbet, hands: p.hands,
                                  handsVsMe: p.handsVsMe, handsWonVsMe: p.handsWonVsMe,
                                  playerType: p.playerType, notes: p.notes)
                    }
                }
                if !benched.isEmpty {
                    if !active.isEmpty {
                        Rectangle().fill(C.divider).frame(height: 1).padding(.vertical, 4)
                    }
                    Text("📋 KNOWN AT TABLE")
                        .font(fzW(11, .bold, .monospaced)).foregroundColor(C.label)
                    ForEach(benched, id: \.username) { p in
                        PlayerRow(username: p.username, vpip: p.vpip, pfr: p.pfr,
                                  threeBet: p.threeBet, cbet: p.cbet,
                                  foldToCbet: p.foldToCbet, hands: p.hands,
                                  handsVsMe: p.handsVsMe, handsWonVsMe: p.handsWonVsMe,
                                  playerType: p.playerType, notes: p.notes)
                            .opacity(0.7)
                    }
                }
                Text("Total in DB: \(store.totalProfiled)")
                    .font(fzW(11, .regular, .monospaced)).foregroundColor(C.label)
                    .padding(.top, 4)
            }

            // Position performance always shown at bottom
            if !store.positionStats.isEmpty {
                Rectangle().fill(C.divider).frame(height: 1).padding(.vertical, 4)
                PositionPerformanceView(stats: store.positionStats)
            }
        }
    }
}

// MARK: - Main Content


// MARK: - Logs / Diagnostics Tab

struct LogsTabView: View {
    @ObservedObject var store: AdviceStore
    @State private var logText: String = "Reading watcher log..."
    @State private var syncStatus: String = "Idle"
    @State private var isSyncing: Bool = false
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("📟 WATCHER LOGS & STATUS")
                    .font(fzW(12, .bold, .monospaced))
                    .foregroundColor(C.label)
                Spacer()
                Button(action: {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.positionOnSecondaryMonitor()
                    }
                    fetchLog()
                }) {
                    Text("🔄 Re-Snap & Refresh")
                        .font(fzW(11, .bold, .monospaced))
                        .foregroundColor(C.primary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(C.divider.opacity(0.4))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // LAN Peer Sync Control Bar
            HStack(spacing: 8) {
                Text("⚡ LAN DB Sync:")
                    .font(fzW(11, .semibold, .monospaced))
                    .foregroundColor(C.label)
                Text(syncStatus)
                    .font(fzW(11, .bold, .monospaced))
                    .foregroundColor(syncStatus.contains("Done") ? C.call : (syncStatus.contains("Syncing") ? .orange : C.secondary))
                Spacer()
                Button(action: {
                    performManualSync()
                }) {
                    HStack(spacing: 4) {
                        Text(isSyncing ? "⏳" : "📡")
                        Text(isSyncing ? "Syncing..." : "Sync Peer DB Now")
                            .font(fzW(10, .bold, .monospaced))
                    }
                    .foregroundColor(isSyncing ? .black : C.call)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(isSyncing ? Color.orange : C.call.opacity(0.18))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSyncing)
            }
            .padding(10)
            .background(C.divider.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Session Calls:")
                        .font(fzW(12, .semibold, .monospaced)).foregroundColor(C.label)
                    Text("\(store.sessionCalls)")
                        .font(fzW(12, .bold, .monospaced)).foregroundColor(C.primary)
                    Spacer()
                    Text("Est AI Cost:")
                        .font(fzW(12, .semibold, .monospaced)).foregroundColor(C.label)
                    Text(String(format: "$%.3f", store.sessionCost))
                        .font(fzW(12, .bold, .monospaced)).foregroundColor(C.gold)
                }
                HStack {
                    Text("Latency:")
                        .font(fzW(12, .semibold, .monospaced)).foregroundColor(C.label)
                    Text(store.latencyText)
                        .font(fzW(12, .bold, .monospaced)).foregroundColor(C.secondary)
                    Spacer()
                    Text("Status:")
                        .font(fzW(12, .semibold, .monospaced)).foregroundColor(C.label)
                    Text(store.isIdle ? "Idle (>3m)" : "Active")
                        .font(fzW(12, .bold, .monospaced)).foregroundColor(store.isIdle ? .orange : C.raise)
                }
            }
            .padding(10)
            .background(C.divider.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Live Watcher Output (~/Library/Logs/StakeLab/watcher.log):")
                .font(fzW(11, .semibold, .monospaced))
                .foregroundColor(C.label)

            // Log area — newest at bottom, auto-scrolls via TextEditor native scroll.
            // TextEditor inherently scrolls to show cursor at end when text updates.
            ZStack(alignment: .bottomLeading) {
                TextEditor(text: .constant(logText))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(C.secondary)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 320)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onAppear {
            fetchLog()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                fetchLog()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func fetchLog() {
        let path = NSHomeDirectory() + "/Library/Logs/StakeLab/watcher.log"
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            // Newest lines LAST — chronological order, auto-scroll keeps bottom visible.
            let tail = lines.suffix(60).joined(separator: "\n")
            self.logText = tail.isEmpty ? "(Log is currently empty - waiting for captures)" : tail
        } else {
            self.logText = "Log file not created yet."
        }
    }

    private func performManualSync() {
        // Peer sync removed — native Swift watcher writes directly to AdviceStore
        DispatchQueue.main.async {
            self.syncStatus = "Native mode — no peer sync"
            self.isSyncing  = false
        }
    }
}

struct HUDContentView: View {
    @ObservedObject var store:    AdviceStore
    @ObservedObject var settings = HUDSettings.shared
    @State private var activeTab: Int = 0   // 0=Advice 1=Players

    var body: some View {
        ZStack {
            C.bg.opacity(settings.hudOpacity).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 14).stroke(C.divider.opacity(0.5), lineWidth: 1)

            VStack(spacing: 0) {
                // ── Toolbar + tabs ──
                VStack(spacing: 10) {
                    HUDToolbar(store: store)

                    // Tab switcher (Advice, Players, Logs/Diagnostics)
                    HStack(spacing: 0) {
                        tabButton(label: "🃏 ADVICE", idx: 0)
                        tabButton(label: "👥 PLAYERS", idx: 1)
                        tabButton(label: "📟 LOGS", idx: 2)
                    }
                    .background(C.divider.opacity(0.3))
                    .clipShape(Capsule())
                }
                .padding(16)

                Rectangle().fill(C.divider).frame(height: 1)

                // ── Tab content ──
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if activeTab == 0 {
                            adviceTab
                        } else if activeTab == 1 {
                            PlayersTabView(store: store)
                        } else {
                            LogsTabView(store: store)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    func tabButton(label: String, idx: Int) -> some View {
        Button(action: { activeTab = idx }) {
            Text(label)
                .font(fzW(12, .bold, .monospaced))
                .foregroundColor(activeTab == idx ? .black : C.label)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(activeTab == idx ? C.call : Color.clear)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var adviceTab: some View {
        if let advice = store.current {
            StatusHeader(position: advice.position, latency: store.latencyText,
                         isIdle: store.isIdle, hand: advice.hand,
                         smallBlind: advice.smallBlind, bigBlind: advice.bigBlind,
                         ante: advice.ante, gameType: advice.gameType,
                         heroHasCards: advice.heroHasCards)
                .opacity(store.isIdle ? 0.5 : 1.0)

            Rectangle().fill(C.divider).frame(height: 1)

            if settings.streamerMode {
                HStack(spacing: 8) {
                    Text("🎮")
                        .font(fz(16))
                    Text("STREAMER MODE ACTIVE")
                        .font(fzW(14, .black, .monospaced))
                        .foregroundColor(Color.purple)
                    Spacer()
                    Text("Habits / Stats DB Untracked")
                        .font(fzW(11, .semibold, .monospaced))
                        .foregroundColor(C.label)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.purple.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !advice.heroHasCards {
                // Hero is folded or sitting out / observing
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill")
                        .font(fz(18))
                        .foregroundColor(C.label)
                    Text("FOLDED / OBSERVING")
                        .font(fzW(18, .bold, .monospaced))
                        .foregroundColor(C.label)
                    Spacer()
                    Text("Waiting for next hand")
                        .font(fzW(12, .semibold, .monospaced))
                        .foregroundColor(C.divider)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(C.divider.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if !advice.actionOnHero {
                // Hero has cards but action is on opponents
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                    Text("WAITING FOR ACTION")
                        .font(fzW(16, .bold, .monospaced))
                        .foregroundColor(C.secondary)
                    Spacer()
                    Text("Hand active")
                        .font(fzW(12, .medium, .monospaced))
                        .foregroundColor(C.label)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(C.divider.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                RecommendationBadge(action: "WAITING",
                                    recommendation: advice.recommendation.isEmpty ? "Hand active — monitor action ahead of you." : advice.recommendation,
                                    confidence: advice.confidence)
            } else {
                // Action is actively ON HERO
                RecommendationBadge(action: advice.action,
                                    recommendation: advice.recommendation,
                                    confidence: advice.confidence)
                    .opacity(store.isIdle ? 0.75 : 1.0)
            }

            HandInfoRow(board: advice.board)
                .opacity(store.isIdle ? 0.4 : 1.0)

            // Push / Fold Short-Stack Matrix Indicator (< 12 BB)
            if advice.heroHasCards, let bbVal = Double(advice.bigBlind), bbVal > 0 {
                PushFoldIndicator(advice: advice, bbVal: bbVal)
                    .opacity(store.isIdle ? 0.4 : 1.0)
            }

            if !advice.hint.isEmpty {
                Rectangle().fill(C.divider).frame(height: 1)
                // Strip opponent context from hints — shown in Players tab instead
                let cleanHint = advice.hint.components(separatedBy: "\nKNOWN OPPONENTS").first ?? advice.hint
                HintSection(hint: cleanHint)
                    .opacity(store.isIdle ? 0.3 : 1.0)
            }

            if store.isIdle {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(fz(12)).foregroundColor(.orange)
                    Text("Prior hand — no updates for 3+ min").font(fz(12)).foregroundColor(.orange)
                }.padding(.top, 2)
            }

            // Villain read — always show if there are villains
            if !advice.villainNames.isEmpty {
                Rectangle().fill(C.divider).frame(height: 1)
                VillainReadSection(
                    villainNames: advice.villainNames,
                    knownPlayers: store.knownPlayers
                )
            }
        } else {
            EmptyStateView()
        }
    }
}

// MARK: - Villain Read Card

struct VillainReadSection: View {
    let villainNames: String
    let knownPlayers: [OpponentProfile]

    private var activeVillains: [OpponentProfile] {
        let names = Set(villainNames.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        return knownPlayers.filter { names.contains($0.username) }
    }

    private var unknownNames: [String] {
        let names = villainNames.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let known = Set(knownPlayers.map { $0.username })
        return names.filter { !known.contains($0) }
    }

    var body: some View {
        if !villainNames.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("👤 VILLAIN READ")
                    .font(fzW(12, .bold, .monospaced))
                    .foregroundColor(C.label)

                if activeVillains.isEmpty && unknownNames.isEmpty {
                    Text("Tracking active table players...")
                        .font(fzW(12, .regular))
                        .foregroundColor(C.label)
                } else {
                    ForEach(activeVillains, id: \.username) { p in
                        VillainCard(profile: p)
                    }
                    ForEach(Array(unknownNames.prefix(3)), id: \.self) { name in
                        HStack(spacing: 8) {
                            Text(name)
                                .font(fzW(13, .semibold, .monospaced))
                                .foregroundColor(C.secondary)
                            Text("— no read yet")
                                .font(fzW(11, .regular, .monospaced))
                                .foregroundColor(C.label)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(C.divider.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if unknownNames.count > 3 {
                        Text("+\(unknownNames.count - 3) more players — no read yet")
                            .font(fzW(11, .regular, .monospaced))
                            .foregroundColor(C.label)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

struct VillainCard: View {
    let profile: OpponentProfile
    @State private var isExpanded: Bool = false

    var typeShort: String {
        let t = profile.playerType.lowercased()
        if t.contains("shark")                            { return "SHARK 🦈" }
        if t.contains("donkey")                           { return "DONKEY 🐴" }
        if t.contains("fish")                             { return "FISH 🐟" }
        if t.contains("maniac")                           { return "MANIAC 💣" }
        if t.contains("nit")                              { return "NIT 🪨" }
        if t.contains("calling") || t.contains("station") { return "STATION 🚉" }
        if t.contains("tag")                              { return "TAG ⚡" }
        if t.contains("lag")                              { return "LAG 🔥" }
        if t.contains("loose") && t.contains("passive")   { return "FISH 🐟" }
        if t.contains("loose") && t.contains("aggress")   { return "LAG 🔥" }
        if t.contains("tight") && t.contains("aggress")   { return "TAG ⚡" }
        if t.contains("tight") && t.contains("passive")   { return "NIT 🪨" }
        if !profile.playerType.isEmpty && profile.playerType != "unknown" && profile.playerType != "Active Player" {
            let firstWord = profile.playerType.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces) ?? profile.playerType
            return "\(firstWord) 🎯"
        }
        return "UNKNOWN ❓"
    }

    var typeColor: Color {
        let t = profile.playerType.lowercased()
        if t.contains("shark")                            { return C.gold }
        if t.contains("donkey")                           { return C.fold }
        if t.contains("fish")                             { return C.fold }
        if t.contains("maniac")                           { return C.tourneyBadge }
        if t.contains("nit")                              { return C.label }
        if t.contains("calling") || t.contains("station") { return C.call }
        if t.contains("tag")                              { return C.raise }
        if t.contains("lag")                              { return C.tourneyBadge }
        if t.contains("loose") && t.contains("passive")   { return C.fold }
        if t.contains("loose") && t.contains("aggress")   { return C.tourneyBadge }
        if t.contains("tight") && t.contains("aggress")   { return C.raise }
        if t.contains("tight") && t.contains("passive")   { return C.call }
        return C.secondary
    }

    var actionTip: String {
        // If there's an exploit tendency in the notes (e.g. "TAG: Overfolds to turn bets")
        if profile.playerType.contains(":") {
            let parts = profile.playerType.components(separatedBy: ":")
            if parts.count > 1 {
                let note = parts[1].trimmingCharacters(in: .whitespaces)
                if !note.isEmpty { return "→ \(note)" }
            }
        }
        if let ftc = profile.foldToCbet {
            if ftc > 65 { return "→ Fire flop cbets — folds \(ftc)%" }
            if ftc < 30 { return "→ Value bet only — calls everything" }
        }
        if let vpip = profile.vpip, vpip > 40 { return "→ Loose caller — thin value bets" }
        if let pfr = profile.pfr, pfr > 20    { return "→ Aggressive — re-raise or fold" }
        return ""
    }

    var vsLine: String? {
        guard let hvm = profile.handsVsMe, hvm > 0 else { return nil }
        let won = profile.handsWonVsMe ?? 0
        let pct = Int(Double(won) / Double(hvm) * 100)
        return "VS you: \(hvm) hands, they won \(pct)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Text(profile.username)
                        .font(fzW(13, .bold, .monospaced))
                        .foregroundColor(C.primary).lineLimit(1)
                    Text(typeShort)
                        .font(fzW(11, .bold, .monospaced)).foregroundColor(typeColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(typeColor.opacity(0.15)).clipShape(Capsule())
                    Spacer()
                    if let v = profile.vpip {
                        Text("V:\(v)%").font(fzW(11, .bold, .monospaced))
                            .foregroundColor(v > 35 ? C.fold : C.secondary)
                    }
                    if let p = profile.pfr {
                        Text("P:\(p)%").font(fzW(11, .regular, .monospaced)).foregroundColor(C.label)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(C.label)
                        .padding(.leading, 2)
                }
            }
            .buttonStyle(PlainButtonStyle())

            if !actionTip.isEmpty && !isExpanded {
                Text(actionTip).font(fzW(12, .regular)).foregroundColor(C.raise)
            } else if let h = profile.hands, h > 0, !isExpanded {
                Text("\(h) hand\(h == 1 ? "" : "s") tracked at table").font(fzW(11, .regular, .monospaced)).foregroundColor(C.label)
            }
            if let vs = vsLine, !isExpanded {
                Text(vs).font(fzW(11, .regular, .monospaced)).foregroundColor(C.label)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().background(C.divider)
                    HStack {
                        Text("🎯 SPECIFIC HABITS & TELLS")
                            .font(fzW(11, .bold, .monospaced))
                            .foregroundColor(C.cyan)
                        Spacer()
                    }
                    if let n = profile.notes, !n.isEmpty, n != "UNKNOWN" && n != "unknown" {
                        Text(n)
                            .font(fzW(12, .medium))
                            .foregroundColor(C.primary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Accumulating hand samples. Watcher is tracking preflop/postflop sizing and tendencies.")
                            .font(fzW(11, .regular))
                            .foregroundColor(C.label)
                    }
                    
                    if let ftc = profile.foldToCbet, ftc > 0 {
                        Text("Fold to C-Bet: \(ftc)%  \(ftc > 60 ? "→ Bluff flop frequently!" : ftc < 35 ? "→ Value only" : "")")
                            .font(fzW(11, .regular, .monospaced))
                            .foregroundColor(ftc > 60 ? C.raise : C.label)
                    }
                    if let vs = vsLine {
                        Text(vs).font(fzW(11, .regular, .monospaced)).foregroundColor(C.label)
                    }

                    // Tactical rules based on stats
                    if let v = profile.vpip, let p = profile.pfr {
                        if v > 40 && p < 15 {
                            Text("💡 Exploit: Loose-Passive Calling Station. Do not bluff. Value bet 3 streets.")
                                .font(fzW(11, .bold))
                                .foregroundColor(C.raise)
                        } else if v < 18 && p < 15 {
                            Text("💡 Exploit: Nit / Rock. Steal their blinds relentlessly. Fold to their aggression.")
                                .font(fzW(11, .bold))
                                .foregroundColor(C.gold)
                        } else if p > 25 {
                            Text("💡 Exploit: Hyper-Aggressive. 4-bet for value and trap on dry boards.")
                                .font(fzW(11, .bold))
                                .foregroundColor(C.tourneyBadge)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(C.divider.opacity(isExpanded ? 0.28 : 0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Window

final class HUDWindow: NSWindow {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
            NSApp.terminate(nil)
            return true
        }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            self.close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: HUDWindow?
    let store    = AdviceStore()
    let settings = HUDSettings.shared

    private var snapTimer: Timer?
    private var lastClubGGRect: NSRect = .zero
    private var isSnapping = false
    private var watcherEngine: NativeWatcherEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Set up main menu bar for Cmd+Q / Quit
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit Stake Lab HUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu

        // Write initial mode file for watcher
        settings.save()

        // ── Native Swift watcher (zero Python) ──────────────────────────────────
        store.enableNativeMode()   // stop SQLite poll — watcher owns advice updates
        watcherEngine = NativeWatcherEngine(store: store, settings: settings)
        watcherEngine?.start()

        let dims = settings.sizePreset.dimensions
        let initialWidth = dims.width
        let initialHeight = dims.height

        window = HUDWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        guard let window = window else { return }

        window.title           = "Stake Lab HUD"
        window.isOpaque        = true
        window.backgroundColor = NSColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1.0)
        window.hasShadow       = true
        window.sharingType     = .none // Exclude completely from all screen recording APIs (OBS, Zoom, Discord)
        // Set window level to .mainMenu / .popUpMenu so it remains visible above full screen apps & browsers
        window.level           = .normal
        window.collectionBehavior = [.canJoinAllSpaces]
        window.minSize         = NSSize(width: 260, height: 420)
        window.delegate        = self

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight))
        effect.material = .hudWindow; effect.blendingMode = .withinWindow; effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10; effect.layer?.masksToBounds = true
        effect.layer?.backgroundColor = NSColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1.0).cgColor

        let hosting = NSHostingView(rootView: HUDContentView(store: store))
        hosting.frame = NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight)
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        window.contentView = effect
        
        if let x = settings.savedFrameX, let y = settings.savedFrameY,
           let w = settings.savedFrameW, let h = settings.savedFrameH {
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: false)
        } else {
            window.setContentSize(NSSize(width: initialWidth, height: initialHeight))
            positionOnSecondaryMonitor()
        }
        window.makeKeyAndOrderFront(nil)

        print("✅ Stake Lab HUD launched — \(store.dbPath) | mode: \(settings.gameMode.rawValue)")
    }

    func positionOnSecondaryMonitor() {
        guard let window = self.window else { return }
        
        let targetScreen: NSScreen
        if NSScreen.screens.count > 1 {
            // Pick secondary monitor (screen index 1 or non-main)
            targetScreen = NSScreen.screens.first { $0 != NSScreen.main } ?? NSScreen.screens[1]
        } else {
            targetScreen = NSScreen.main ?? NSScreen.screens[0]
        }
        
        let sr = targetScreen.visibleFrame
        let dims = settings.sizePreset.dimensions
        let targetWidth = min(dims.width, sr.width - 40)
        let targetHeight = min(dims.height, sr.height - 40)
        
        // Position on the right side of the secondary monitor
        let posX = sr.maxX - targetWidth - 20
        let posY = sr.maxY - targetHeight - 20
        
        window.setFrame(NSRect(x: posX, y: posY, width: targetWidth, height: targetHeight), display: true, animate: false)
        saveWindowFrame()
    }

    func saveWindowFrame() {
        guard let frame = window?.frame else { return }
        settings.savedFrameX = Double(frame.origin.x)
        settings.savedFrameY = Double(frame.origin.y)
        settings.savedFrameW = Double(frame.size.width)
        settings.savedFrameH = Double(frame.size.height)
        settings.save()
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    private func fallbackPosition() {
        guard let window = window else { return }
        let sr = (window.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let dims = settings.sizePreset.dimensions
        let w = dims.width
        let h = min(dims.height, sr.height - 20)
        if lastClubGGRect != .zero {
            lastClubGGRect = .zero
            window.setFrame(NSRect(x: sr.maxX - w - 20, y: sr.maxY - h - 20, width: w, height: h), display: true, animate: true)
        }
    }

    private func runAppleScript(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        watcherEngine?.stop()
        snapTimer?.invalidate()
    }
}

@main
struct StakeLabHUDApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = delegate  // retain
        app.run()
    }
}