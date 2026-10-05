import Foundation
import Observation

/// Açık oturumları ve alt ajanları her saniye tarayan, arayüzün tek veri kaynağı.
///
/// Claude Code'un ayarlarına dokunmuyoruz: canlı oturumlar `~/.claude/sessions/<pid>.json`
/// kaydından, ayrıntılar `~/.claude/projects/` altındaki dökümlerden okunuyor.
@MainActor
@Observable
final class ShiftStore {
    private(set) var shifts: [Shift] = []
    private(set) var lastRefresh: Date?
    var selectedWorkerID: String?

    @ObservationIgnored private let scanner = ShiftScanner()
    @ObservationIgnored private var timer: Timer?

    var selectedWorker: Worker? {
        guard let id = selectedWorkerID else { return nil }
        return shifts.lazy.flatMap(\.workers).first { $0.id == id }
    }

    var selectedShift: Shift? {
        guard let id = selectedWorkerID else { return nil }
        return shifts.first { $0.workers.contains { $0.id == id } }
    }

    var busyCount: Int { shifts.flatMap(\.workers).filter(\.activity.isBusy).count }
    var needsYouCount: Int { shifts.flatMap(\.workers).filter(\.activity.needsYou).count }
    var totalOutputTokens: Int { shifts.reduce(0) { $0 + $1.totalOutputTokens } }
    var shiftStartedAt: Date? { shifts.map(\.startedAt).min() }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private var isRefreshing = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let scanner = scanner
        Task.detached(priority: .utility) {
            let result = await scanner.scan()
            await MainActor.run {
                self.apply(result)
                self.isRefreshing = false
            }
        }
    }

    private func apply(_ result: [Shift]) {
        if result != shifts { shifts = result }
        lastRefresh = .now
        // Seçim yoksa ya da seçili kişi gittiyse ilk oturumu seç.
        if selectedWorker == nil { selectedWorkerID = shifts.first?.main.id }
    }
}

// MARK: - Tarayıcı

/// Dosya okumaları ana iş parçacığını kilitlemesin diye ayrı bir aktörde.
actor ShiftScanner {
    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    private var transcripts: [URL: Transcript] = [:]
    private var transcriptPaths: [String: URL] = [:]

    /// Alt ajanlar bu kadar süre sessiz kaldıysa masaları kaldırılır.
    private let subagentLinger: TimeInterval = 10 * 60
    private let maxSubagentsPerShift = 4

    func scan() -> [Shift] {
        let entries = readRegistry()
        var shifts: [Shift] = []
        for entry in entries {
            guard let url = transcriptURL(for: entry.sessionId, cwd: entry.cwd) else { continue }
            let transcript = transcript(at: url)
            transcript.refresh()

            let main = makeWorker(
                id: entry.sessionId,
                kind: .main,
                name: entry.project,
                subtitle: transcript.title ?? entry.name,
                transcript: transcript,
                registryBusy: entry.isBusy,
                startedAt: entry.startedAt
            )
            let subagents = scanSubagents(sessionDir: url.deletingPathExtension(), completed: transcript.completedTaskToolIDs)

            shifts.append(Shift(
                id: entry.sessionId,
                pid: entry.pid,
                project: entry.project,
                cwd: entry.cwd,
                title: transcript.title,
                lastPrompt: transcript.lastPrompt,
                promptCount: transcript.promptCount,
                startedAt: entry.startedAt,
                main: main,
                subagents: subagents,
                transcriptURL: url
            ))
        }
        // Masa sırası sabit kalsın: oturum açılış zamanına göre.
        shifts.sort { $0.startedAt < $1.startedAt }

        // Aynı projede birden fazla oturum varsa aynı odada otururlar;
        // balonlarda karışmasınlar diye ikinciden itibaren numara veriyoruz.
        var seen: [String: Int] = [:]
        for i in shifts.indices {
            let n = (seen[shifts[i].cwd] ?? 0) + 1
            seen[shifts[i].cwd] = n
            if n > 1 { shifts[i].main.name = "\(shifts[i].project) · \(n)" }
        }
        return shifts
    }

    // MARK: Oturum kaydı

    private struct RegistryEntry {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let name: String
        let status: String
        let startedAt: Date

        var project: String { (cwd as NSString).lastPathComponent }
        var isBusy: Bool { status == "busy" }
    }

    private func readRegistry() -> [RegistryEntry] {
        let dir = claudeDir.appending(path: "sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file -> RegistryEntry? in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String,
                  Self.isAlive(pid: Int32(pid)) else { return nil }
            let started = (json["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
            return RegistryEntry(
                pid: Int32(pid),
                sessionId: sessionId,
                cwd: cwd,
                name: json["name"] as? String ?? "",
                status: json["status"] as? String ?? "idle",
                startedAt: started
            )
        }
    }

    /// Kapanan oturumların kayıt dosyası bazen geride kalıyor; süreç gerçekten yaşıyor mu bakıyoruz.
    private static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Dökümler

    private func transcript(at url: URL) -> Transcript {
        if let t = transcripts[url] { return t }
        let t = Transcript(url: url)
        transcripts[url] = t
        return t
    }

    /// Proje klasör adı cwd'den türetiliyor ama kuralı belgelenmiş değil;
    /// önce tahmin ediyor, bulamazsak tüm proje klasörlerinde arıyoruz.
    private func transcriptURL(for sessionId: String, cwd: String) -> URL? {
        if let cached = transcriptPaths[sessionId] { return cached }
        let projects = claudeDir.appending(path: "projects")
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let guess = projects.appending(path: slug).appending(path: "\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: guess.path) {
            transcriptPaths[sessionId] = guess
            return guess
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appending(path: "\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                transcriptPaths[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    private func scanSubagents(sessionDir: URL, completed: Set<String>) -> [Worker] {
        let dir = sessionDir.appending(path: "subagents")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }

        let recent = files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                return Date.now.timeIntervalSince(modified) < subagentLinger ? (url, modified) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maxSubagentsPerShift)

        return recent.map { url, _ in
            let meta = readMeta(url.deletingPathExtension().appendingPathExtension("meta.json"))
            let transcript = transcript(at: url)
            transcript.refresh()
            let type = meta["agentType"] as? String ?? "Agent"
            var worker = makeWorker(
                id: url.deletingPathExtension().lastPathComponent,
                kind: .subagent(type: type),
                name: type,
                subtitle: meta["description"] as? String ?? "",
                transcript: transcript,
                registryBusy: nil,
                startedAt: transcript.firstEventAt
            )
            // Ana oturum bu ajanın bittiğini bildirdiyse dökümün son hâline bakmadan "bitti" say.
            if let toolID = meta["toolUseId"] as? String, completed.contains(toolID) {
                worker.activity = .done
            }
            return worker
        }
        // Masa yerleri zıplamasın diye başlangıç sırasına göre.
        .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    private func readMeta(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    // MARK: Durum çıkarımı

    private func makeWorker(
        id: String,
        kind: WorkerKind,
        name: String,
        subtitle: String,
        transcript: Transcript,
        registryBusy: Bool?,
        startedAt: Date?
    ) -> Worker {
        let (activity, since) = Self.activity(for: transcript, registryBusy: registryBusy)
        return Worker(
            id: id,
            kind: kind,
            name: name,
            subtitle: subtitle,
            activity: activity,
            activitySince: since,
            recent: transcript.recent.reversed(),
            toolCount: transcript.toolCount,
            outputTokens: transcript.outputTokens,
            contextTokens: transcript.contextTokens,
            model: transcript.model,
            startedAt: startedAt,
            lastEventAt: transcript.lastEventAt,
            lastUserText: transcript.lastUserText,
            lastUserAt: transcript.lastUserAt,
            lastReplyText: transcript.lastReplyText,
            lastReplyAt: transcript.lastReplyAt,
            failureStreak: transcript.failureStreak
        )
    }

    /// registryBusy: ana oturumlarda kayıt dosyasındaki busy/idle bilgisi; alt ajanlarda nil.
    static func activity(for t: Transcript, registryBusy: Bool?) -> (Activity, Date?) {
        if let tool = t.pending.last {
            let a = activity(forTool: tool)
            // Oturum "boşta" görünüyor ama bir araç sonuç bekliyorsa,
            // Claude Code büyük ihtimalle sizden onay istiyor.
            if registryBusy == false {
                return (tool.name == "AskUserQuestion" ? .asking : .awaitingApproval(tool.summary), tool.at)
            }
            return (a, tool.at)
        }
        let finished = ["end_turn", "stop_sequence", "interrupted", "max_tokens", "refusal"].contains(t.lastStopReason ?? "")
        switch registryBusy {
        case .some(true):
            return (.thinking, t.lastEventAt)
        case .some(false):
            return (.idle, t.lastEventAt)
        case .none:
            return (finished ? .done : .thinking, t.lastEventAt)
        }
    }

    static func activity(forTool tool: ToolEvent) -> Activity {
        let d = tool.summary
        let hint = tool.hint
        if hint == .web { return .webSearching(d) }
        if hint == .screenshot { return .capturing(d) }
        switch tool.name {
        case "Read", "NotebookRead":
            switch hint {
            case .image: return .viewing(d)
            case .document: return .readingDocs(d)
            default: return .reading(d)
            }
        case "Grep", "Glob", "LS", "ToolSearch", "LSP":
            return .searching(d)
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return hint == .document ? .writingDocs(d) : .writing(d)
        case "Bash", "BashOutput", "Monitor", "KillShell":
            switch hint {
            case .build: return .building(d)
            case .test: return .testing(d)
            case .git: return .usingGit(d)
            default: return .running(d)
            }
        case "Agent", "Task", "Workflow", "SendMessage":
            return .delegating(d)
        case "AskUserQuestion":
            return .asking
        default:
            if tool.name.hasPrefix("mcp__claude-in-chrome") { return .browsing(d) }
            let short = tool.name.split(separator: "__").last.map(String.init) ?? tool.name
            return .tool(name: short, detail: d)
        }
    }
}
