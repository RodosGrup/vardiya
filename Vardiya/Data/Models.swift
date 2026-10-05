import Foundation

/// Bir çalışanın (oturum ya da alt ajan) o anki hâli.
/// Ofiste balonun rengi, ikonu ve karakterin animasyonu buradan türetilir.
enum Activity: Equatable {
    case idle
    case thinking
    case reading(String)
    case searching(String)
    case writing(String)
    case running(String)
    case browsing(String)
    case delegating(String)
    case tool(name: String, detail: String)
    case asking
    case awaitingApproval(String)
    case done

    /// Karakter klavyeye mi vuruyor, yoksa yerinde mi duruyor.
    var isBusy: Bool {
        switch self {
        case .idle, .done, .asking, .awaitingApproval: false
        default: true
        }
    }

    /// Kullanıcının bir şey yapması gereken durumlar; menü çubuğunda ayrıca sayılır.
    var needsYou: Bool {
        switch self {
        case .asking, .awaitingApproval: true
        default: false
        }
    }

    var detail: String? {
        switch self {
        case .reading(let d), .searching(let d), .writing(let d), .running(let d),
             .browsing(let d), .delegating(let d), .awaitingApproval(let d):
            d.isEmpty ? nil : d
        case .tool(_, let d):
            d.isEmpty ? nil : d
        default:
            nil
        }
    }
}

/// Dökümden okunan tek bir araç çağrısı. Detay panelindeki "son işlemler" listesini besler.
struct ToolEvent: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let at: Date
    var finishedAt: Date?
    var failed = false

    /// "mcp__claude-in-chrome__tabs_close_mcp" → "tabs close"
    var displayName: String {
        guard name.hasPrefix("mcp__") else { return name }
        let last = name.split(separator: "__").last.map(String.init) ?? name
        return last.replacingOccurrences(of: "_mcp", with: "").replacingOccurrences(of: "_", with: " ")
    }
}

enum WorkerKind: Equatable {
    case main
    case subagent(type: String)
}

/// Ofisteki tek bir karakter.
struct Worker: Identifiable, Equatable {
    let id: String
    var kind: WorkerKind
    var name: String
    var subtitle: String
    var activity: Activity
    var activitySince: Date?
    var recent: [ToolEvent]
    var toolCount: Int
    var outputTokens: Int
    var contextTokens: Int
    var model: String?
    var startedAt: Date?
    var lastEventAt: Date?
    var lastUserText: String?
    var lastUserAt: Date?
    var lastReplyText: String?
    var lastReplyAt: Date?
    var failureStreak = 0
}

/// Açık bir Claude Code oturumu: bir ana çalışan ve onun alt ajanları.
/// Ofiste kendi masa grubuna sahip olur.
struct Shift: Identifiable, Equatable {
    let id: String
    var pid: Int32
    var project: String
    var cwd: String
    var title: String?
    var lastPrompt: String?
    var promptCount: Int
    var startedAt: Date
    var main: Worker
    var subagents: [Worker]

    var workers: [Worker] { [main] + subagents }
    var totalOutputTokens: Int { workers.reduce(0) { $0 + $1.outputTokens } }
}
