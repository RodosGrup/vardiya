import Foundation

/// Bir çalışanın (oturum ya da alt ajan) o anki hâli.
/// Ofiste balonun rengi, ikonu ve karakterin animasyonu buradan türetilir.
enum Activity: Equatable {
    case idle
    case thinking
    /// Kod dosyası okuyor (inceliyor)
    case reading(String)
    case searching(String)
    /// Kod dosyası yazıyor / düzenliyor
    case writing(String)
    case running(String)
    /// Görsele ya da ekran görüntüsüne bakıyor
    case viewing(String)
    case readingDocs(String)
    case writingDocs(String)
    case building(String)
    case testing(String)
    case capturing(String)
    case webSearching(String)
    case usingGit(String)
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
             .browsing(let d), .delegating(let d), .awaitingApproval(let d),
             .viewing(let d), .readingDocs(let d), .writingDocs(let d), .building(let d),
             .testing(let d), .capturing(let d), .webSearching(let d), .usingGit(let d):
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
    /// Araç girdisinden çıkarılan iş türü: görsel mi, belge mi, derleme mi…
    var hint: ToolHint = .none

    /// "mcp__claude-in-chrome__tabs_close_mcp" → "tabs close"
    var displayName: String {
        guard name.hasPrefix("mcp__") else { return name }
        let last = name.split(separator: "__").last.map(String.init) ?? name
        return last.replacingOccurrences(of: "_mcp", with: "").replacingOccurrences(of: "_", with: " ")
    }
}

/// Bir araç çağrısının ne tür bir iş olduğu; dosya uzantısından ya da komuttan çıkarılır.
enum ToolHint: Equatable {
    case none, image, document, code, build, test, git, screenshot, web

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]
    private static let docExts: Set<String> = ["md", "markdown", "txt", "pdf", "rtf", "doc", "docx", "csv", "rst", "adoc"]

    static func classify(name: String, input: [String: Any]) -> ToolHint {
        if name == "WebSearch" || name == "WebFetch" { return .web }
        if name.contains("screenshot") || (input["action"] as? String) == "screenshot" { return .screenshot }
        if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
            let ext = (path as NSString).pathExtension.lowercased()
            if imageExts.contains(ext) { return .image }
            if docExts.contains(ext) { return .document }
            return ext.isEmpty ? .none : .code
        }
        if let command = (input["command"] as? String)?.lowercased() {
            return classify(command: command)
        }
        return .none
    }

    /// Kabuk komutundan iş türü. Yalnızca baştaki ana komuta değil, zincirin tamamına bakıyoruz
    /// (`cd x && xcodebuild …` gibi).
    static func classify(command c: String) -> ToolHint {
        if c.contains("screencapture") || c.contains("screenshot") { return .screenshot }
        let testWords = ["xcodebuild test", "swift test", "npm test", "npm run test", "yarn test", "pnpm test",
                         "pytest", "jest", "vitest", "go test", "cargo test", "flutter test", "phpunit", "rspec"]
        if testWords.contains(where: c.contains) { return .test }
        let buildWords = ["xcodebuild", "swift build", "swiftc", "xcodegen", "npm run build", "yarn build", "pnpm build",
                          "cargo build", "go build", "make ", "gradle", "flutter build", "tsc", "vite build", "next build",
                          "npm install", "npm i ", "yarn install", "pnpm install", "pip install", "brew install", "pod install"]
        if buildWords.contains(where: c.contains) { return .build }
        if c.hasPrefix("git ") || c.contains("&& git ") || c.contains("; git ") || c.hasPrefix("gh ") { return .git }
        return .none
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
    /// Oturumun döküm dosyası; sohbet penceresi buradan okur.
    var transcriptURL: URL?

    var workers: [Worker] { [main] + subagents }
    var totalOutputTokens: Int { workers.reduce(0) { $0 + $1.outputTokens } }
}
