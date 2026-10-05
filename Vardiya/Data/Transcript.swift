import Foundation

/// Tek bir JSONL dökümünü artımlı okur ve özetini tutar.
///
/// Dökümler 30 MB'ı geçebiliyor; her saniye baştan okumak yerine en son kalınan
/// bayttan devam ediyoruz. Yarım kalmış son satır bir sonraki okumaya saklanır.
final class Transcript {
    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()

    private(set) var title: String?
    private(set) var lastPrompt: String?
    private(set) var promptCount = 0
    private(set) var model: String?
    private(set) var outputTokens = 0
    private(set) var contextTokens = 0
    private(set) var toolCount = 0
    private(set) var firstEventAt: Date?
    private(set) var lastEventAt: Date?
    /// Son asistan mesajının bitiş nedeni; "end_turn" ise ajan sözünü bitirmiş demektir.
    private(set) var lastStopReason: String?
    /// Sonucu henüz gelmemiş araç çağrıları, başlama sırasıyla.
    private(set) var pending: [ToolEvent] = []
    private(set) var recent: [ToolEvent] = []
    /// Ana oturuma gelen "<task-notification>" bildirimlerinden: işi biten arka plan ajanlarının araç kimlikleri.
    private(set) var completedTaskToolIDs = Set<String>()
    /// Kullanıcının son mesajı ve ajanın son yazılı yanıtı; balonlar ve zarf animasyonu bunları kullanıyor.
    private(set) var lastUserText: String?
    private(set) var lastUserAt: Date?
    private(set) var lastReplyText: String?
    private(set) var lastReplyAt: Date?
    /// Art arda hata veren araç çağrısı sayısı; ofiste "isyan" için.
    private(set) var failureStreak = 0

    private var countedMessageIDs = Set<String>()
    private static let recentLimit = 14

    init(url: URL) {
        self.url = url
    }

    /// Dosyada yeni satır varsa okur. Değişiklik olduysa true döner.
    @discardableResult
    func refresh() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset {
            // Dosya kısalmışsa (yeniden yazılmış) baştan başla.
            reset()
        }
        guard size > offset else { return false }

        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return false }
        offset += UInt64(chunk.count)

        var buffer = partial
        buffer.append(chunk)
        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            let line = buffer[lineStart..<newline]
            if !line.isEmpty { apply(line: Data(line)) }
            lineStart = buffer.index(after: newline)
        }
        partial = Data(buffer[lineStart...])
        return true
    }

    private func reset() {
        offset = 0
        partial = Data()
        title = nil; lastPrompt = nil; promptCount = 0; model = nil
        outputTokens = 0; contextTokens = 0; toolCount = 0
        firstEventAt = nil; lastEventAt = nil; lastStopReason = nil
        pending = []; recent = []; countedMessageIDs = []; completedTaskToolIDs = []
        lastUserText = nil; lastUserAt = nil; lastReplyText = nil; lastReplyAt = nil; failureStreak = 0
    }

    // MARK: - Satır işleme

    private func apply(line: Data) {
        guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = entry["type"] as? String else { return }

        let at = (entry["timestamp"] as? String).flatMap(Self.parseDate)
        if let at {
            if firstEventAt == nil { firstEventAt = at }
            lastEventAt = at
        }

        switch type {
        case "ai-title":
            title = entry["aiTitle"] as? String
        case "custom-title":
            title = entry["customTitle"] as? String ?? title
        case "last-prompt":
            lastPrompt = entry["lastPrompt"] as? String
        case "assistant":
            applyAssistant(entry, at: at ?? .now)
        case "user":
            applyUser(entry, at: at ?? .now)
        case "attachment":
            // Ajan çalışırken yazılan mesajlar "queued_command" eki olarak kaydediliyor;
            // tur kesilmediği için bekleyen araçlara dokunmadan yalnızca mesajı alıyoruz.
            if let a = entry["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
               (a["commandMode"] as? String ?? "prompt") == "prompt",
               let text = a["prompt"] as? String, let snippet = Snippet.make(text) {
                promptCount += 1
                lastUserText = snippet
                lastUserAt = at ?? .now
            }
        default:
            break
        }
    }

    private func applyAssistant(_ entry: [String: Any], at: Date) {
        guard let message = entry["message"] as? [String: Any] else { return }
        // API hata kayıtları "<synthetic>" model adıyla geliyor; gerçek bir yanıt değiller.
        if entry["isApiErrorMessage"] as? Bool == true { return }
        if let m = message["model"] as? String, !m.hasPrefix("<") { model = m }
        // Akış sırasında yazılan satırlarda stop_reason çoğunlukla boş;
        // boş değer gelince son bilineni silmiyoruz.
        if let reason = message["stop_reason"] as? String { lastStopReason = reason }

        // Aynı mesaj her içerik bloğu için ayrı satır olarak yazılıyor;
        // kullanımı mesaj kimliği başına bir kez sayıyoruz.
        if let usage = message["usage"] as? [String: Any] {
            let id = message["id"] as? String ?? UUID().uuidString
            let input = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            if input > 0 { contextTokens = input }
            if countedMessageIDs.insert(id).inserted {
                outputTokens += usage["output_tokens"] as? Int ?? 0
            }
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String, let snippet = Snippet.make(text) {
                lastReplyText = snippet
                lastReplyAt = at
            }
        }
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            let event = ToolEvent(id: id, name: name, summary: ToolSummary.summarize(name: name, input: input), at: at)
            pending.append(event)
            recent.append(event)
            toolCount += 1
        }
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    private func applyUser(_ entry: [String: Any], at: Date) {
        guard let message = entry["message"] as? [String: Any] else { return }

        if let text = message["content"] as? String {
            // Arka plan görev bildirimleri ve slash komut çıktıları da düz metin olarak
            // geliyor (<task-notification>, <command-name> …); bunlar kullanıcı isteği değil.
            let isSystemText = text.hasPrefix("<") || entry["isMeta"] as? Bool == true
            if text.hasPrefix("<task-notification>"), let id = Self.tag("tool-use-id", in: text) {
                completedTaskToolIDs.insert(id)
            }
            if !isSystemText { startNewTurn(text: text, at: at) }
            return
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return }
        // Alt ajanlar işi bir teslim aracıyla bitiriyor; bu sonuç turu kapatıyor.
        if entry["toolEndsTurn"] as? Bool == true { lastStopReason = "end_turn" }
        var sawResult = false
        for block in blocks where block["type"] as? String == "tool_result" {
            sawResult = true
            guard let id = block["tool_use_id"] as? String else { continue }
            pending.removeAll { $0.id == id }
            if let i = recent.lastIndex(where: { $0.id == id }) {
                recent[i].finishedAt = at
                recent[i].failed = block["is_error"] as? Bool ?? false
            }
            // Kullanıcının reddettiği ya da izin verilmeyen çağrılar ajanın hatası değil.
            let rejected = entry["toolUseResult"] as? String == "User rejected tool use"
            if block["is_error"] as? Bool == true, !rejected { failureStreak += 1 } else { failureStreak = 0 }
        }
        guard !sawResult, entry["isMeta"] as? Bool != true else { return }
        let firstText = blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        if entry["interruptedMessageId"] != nil || firstText.hasPrefix("[Request interrupted") {
            // Kullanıcı Esc'e bastı: çalışan araçlar durdu ama bu yeni bir istek değil.
            pending.removeAll()
            lastStopReason = "interrupted"
        } else {
            startNewTurn(text: firstText, at: at)
        }
    }

    /// Kullanıcının yeni isteği. Yarım kalan araç çağrılarını burada temizliyoruz,
    /// yoksa sonuçları hiç gelmediği için sonsuza dek "çalışıyor" görünürler.
    private func startNewTurn(text: String, at: Date) {
        promptCount += 1
        lastUserText = Snippet.make(text)
        lastUserAt = at
        pending.removeAll()
        lastStopReason = nil
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tarih

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        isoFormatter.date(from: s)
    }
}

/// Uzun mesajlardan balona sığacak tek satırlık özet: Markdown işaretleri atılır, ilk cümle alınır.
enum Snippet {
    static func make(_ text: String, limit: Int = 90) -> String? {
        var s = text
        for mark in ["**", "__", "`", "#", "> "] { s = s.replacingOccurrences(of: mark, with: "") }
        let line = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") || $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
            .first { !$0.isEmpty && !$0.hasPrefix("|") && !$0.hasPrefix("<") } ?? ""
        guard !line.isEmpty else { return nil }
        if line.count <= limit { return line }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Araç girdisinden kısa, okunabilir bir özet çıkarır: dosya adı, komut açıklaması vb.
enum ToolSummary {
    static func summarize(name: String, input: [String: Any]) -> String {
        guard let raw = firstValue(in: input) else { return "" }
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > 60 ? String(oneLine.prefix(57)) + "…" : oneLine
    }

    /// Öncelik sırası önemli: Bash'in "description"ı ham komuttan daha anlaşılır.
    private static func firstValue(in input: [String: Any]) -> String? {
        if let s = input["description"] as? String { return s }
        for key in ["file_path", "notebook_path"] {
            if let s = input[key] as? String { return (s as NSString).lastPathComponent }
        }
        for key in ["pattern", "query"] {
            if let s = input[key] as? String { return s }
        }
        if let s = input["url"] as? String, let host = URL(string: s)?.host() { return host }
        for key in ["skill", "command", "prompt"] {
            if let s = input[key] as? String { return s }
        }
        return nil
    }
}
