import AppKit
import SwiftUI

/// Renkler tek yerde. Açık tema referans videodaki temiz mavi-beyaz ofisten,
/// koyu tema ise aynı sahnenin gece vardiyası hâli.
enum Theme {
    static let accent = dynamic(light: 0x1A6FE0, dark: 0x4C93FF)
    static let accentSoft = dynamic(light: 0xE6F0FD, dark: 0x16263F)
    static let success = dynamic(light: 0x1F9D55, dark: 0x3CCB7F)
    static let successSoft = dynamic(light: 0xE5F6EC, dark: 0x13301F)
    static let warning = dynamic(light: 0xE07B12, dark: 0xFFA640)
    static let warningSoft = dynamic(light: 0xFDF0E1, dark: 0x3A2A14)
    static let muted = dynamic(light: 0x7A8494, dark: 0x8B95A6)
    static let mutedSoft = dynamic(light: 0xF0F2F5, dark: 0x252A33)

    static let window = dynamic(light: 0xF4F6F9, dark: 0x101318)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x181C23)
    static let border = dynamic(light: 0xE3E7ED, dark: 0x2A303A)
    static let text = dynamic(light: 0x111827, dark: 0xECEFF4)
    static let textSecondary = dynamic(light: 0x5B6472, dark: 0x9AA3B2)

    // Sahne
    static let floorTop = dynamic(light: 0xF7F9FC, dark: 0x1A1F27)
    static let floorGrid = dynamic(light: 0xE4E9F0, dark: 0x252C37)
    static let floorSideLeft = dynamic(light: 0xE6EBF2, dark: 0x13171D)
    static let floorSideRight = dynamic(light: 0xD8DFE9, dark: 0x0E1116)
    static let deskTop = dynamic(light: 0xFFFFFF, dark: 0x2A313C)
    static let deskSide = dynamic(light: 0xE9EDF3, dark: 0x1F252E)
    static let deskEdge = dynamic(light: 0xC9D1DC, dark: 0x3A4250)
    static let device = dynamic(light: 0x3B4250, dark: 0x0B0D11)
    static let chair = dynamic(light: 0xFFFFFF, dark: 0x343C48)
    static let person = dynamic(light: 0x1A6FE0, dark: 0x4C93FF)
    static let personIdle = dynamic(light: 0x9DB5D6, dark: 0x7487A3)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Durumun görünümü

extension Activity {
    var symbol: String {
        switch self {
        case .idle: "cup.and.saucer"
        case .thinking: "sparkles"
        case .reading: "doc.text"
        case .searching: "magnifyingglass"
        case .writing: "pencil.line"
        case .running: "terminal"
        case .browsing: "safari"
        case .delegating: "person.2"
        case .tool: "wrench.and.screwdriver"
        case .asking: "questionmark.bubble"
        case .awaitingApproval: "hand.raised"
        case .done: "checkmark.circle"
        }
    }

    var label: String {
        switch self {
        case .idle: String(localized: "Awaiting orders")
        case .thinking: String(localized: "Thinking")
        case .reading: String(localized: "Reading")
        case .searching: String(localized: "Searching")
        case .writing: String(localized: "Writing")
        case .running: String(localized: "Running")
        case .browsing: String(localized: "Browsing")
        case .delegating: String(localized: "Delegating")
        case .tool(let name, _): name
        case .asking: String(localized: "Asking you")
        case .awaitingApproval: String(localized: "Needs approval")
        case .done: String(localized: "Done")
        }
    }

    var tint: Color {
        switch self {
        case .idle: Theme.muted
        case .done: Theme.success
        case .asking, .awaitingApproval: Theme.warning
        default: Theme.accent
        }
    }

    var softTint: Color {
        switch self {
        case .idle: Theme.mutedSoft
        case .done: Theme.successSoft
        case .asking, .awaitingApproval: Theme.warningSoft
        default: Theme.accentSoft
        }
    }
}

enum Format {
    /// 12.400 → "12,4K"
    static func tokens(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func elapsed(since date: Date, now: Date = .now) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return String(localized: "\(s) sec") }
        if s < 3600 { return String(localized: "\(s / 60) min") }
        return String(localized: "\(s / 3600) h \(s % 3600 / 60) min")
    }

    static func model(_ id: String?) -> String? {
        guard let id else { return nil }
        // "claude-opus-5-5" → "Opus 5.5"
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.count <= 2 }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}
