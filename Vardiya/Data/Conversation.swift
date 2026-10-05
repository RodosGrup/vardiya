import Foundation
import Observation

/// Sohbet penceresindeki tek bir satır: sizin mesajınız, ajanın yanıtı ya da bir araç adımı.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case tool(name: String, summary: String, failed: Bool)
    }

    let id: String
    let kind: Kind
    let text: String
    let at: Date?
    /// Kuyrukta, ajana henüz teslim edilmemiş mesaj (ajan çalışırken yazılan).
    var pending = false
}

/// Bir oturumun dökümünü baştan okuyup sohbet geçmişine çevirir; pencere açıkken her saniye
/// yalnızca yeni satırları ekler. Transcript'ten ayrı tutuldu çünkü burada metnin tamamı lazım,
/// ofis için ise yalnızca özet yetiyor.
@MainActor
@Observable
final class Conversation {
    private(set) var items: [ChatItem] = []
    private(set) var isLoading = true

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var reader: ConversationReader
    @ObservationIgnored private var timer: Timer?
    private static let limit = 600

    init(url: URL) {
        self.url = url
        reader = ConversationReader(url: url)
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var busy = false

    private func refresh() {
        guard !busy else { return }
        busy = true
        let reader = reader
        Task.detached(priority: .userInitiated) {
            let update = await reader.read()
            await MainActor.run {
                self.apply(update)
                self.busy = false
            }
        }
    }

    private func apply(_ update: ConversationReader.Update) {
        isLoading = false
        guard !update.added.isEmpty || !update.failedToolIDs.isEmpty || !update.delivered.isEmpty || !update.dropped.isEmpty else { return }
        var next = items
        next.removeAll { update.dropped.contains($0.id) }
        for i in next.indices where update.delivered.contains(next[i].id) { next[i].pending = false }
        // Hata alan araç adımlarını işaretle
        if !update.failedToolIDs.isEmpty {
            for i in next.indices {
                if case .tool(let name, let summary, false) = next[i].kind, update.failedToolIDs.contains(next[i].id) {
                    next[i] = ChatItem(id: next[i].id, kind: .tool(name: name, summary: summary, failed: true), text: next[i].text, at: next[i].at)
                }
            }
        }
        next += update.added
        if next.count > Self.limit { next.removeFirst(next.count - Self.limit) }
        items = next
    }
}

/// Dosya okuma ana iş parçacığını tutmasın diye ayrı bir aktör.
actor ConversationReader {
    struct Update: Sendable {
        var added: [ChatItem] = []
        var failedToolIDs: Set<String> = []
        /// Kuyruktan ajana teslim edilen / geri çekilen bekleyen mesajların kimlikleri
        var delivered: Set<String> = []
        var dropped: Set<String> = []
    }

    private let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private var seen = Set<String>()
    /// Kuyruktaki mesajlar: metin → sohbet satırı kimliği
    private var queued: [String: String] = [:]
    /// Kuyruktan teslim edilmiş metinler; ardından gelen "queued_command" eki tekrar eklenmesin.
    private var deliveredTexts: [String: Int] = [:]

    init(url: URL) {
        self.url = url
    }

    func read() -> Update {
        var update = Update()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return update }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data(); seen = [] }
        guard size > offset else { return update }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd() else { return update }
        offset += UInt64(chunk.count)

        var buffer = partial
        buffer.append(chunk)
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<nl]
            if !line.isEmpty { parse(Data(line), into: &update) }
            start = buffer.index(after: nl)
        }
        partial = Data(buffer[start...])
        return update
    }

    private func parse(_ line: Data, into update: inout Update) {
        guard let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = e["type"] as? String else { return }
        let at = (e["timestamp"] as? String).flatMap(Transcript.parseDate)
        let uuid = e["uuid"] as? String ?? UUID().uuidString

        func add(_ id: String, _ kind: ChatItem.Kind, _ text: String) {
            guard seen.insert(id).inserted else { return }
            update.added.append(ChatItem(id: id, kind: kind, text: text, at: at))
        }

        switch type {
        case "user":
            guard e["isMeta"] as? Bool != true, let message = e["message"] as? [String: Any] else { return }
            if let text = message["content"] as? String {
                // Görev bildirimleri ve komut çıktıları kullanıcı mesajı değil.
                guard !text.hasPrefix("<") else { return }
                // Kuyruktaki mesaj, tur bitince sıradan bir istek olarak da gelebiliyor: kuyruk balonunu teslim say.
                if let id = queued.removeValue(forKey: text) {
                    update.delivered.insert(id)
                } else {
                    add(uuid, .user, text)
                }
            } else if let blocks = message["content"] as? [[String: Any]] {
                var texts: [String] = []
                for b in blocks {
                    switch b["type"] as? String {
                    case "tool_result":
                        if b["is_error"] as? Bool == true, let id = b["tool_use_id"] as? String { update.failedToolIDs.insert(id) }
                    case "text":
                        if let t = b["text"] as? String, !t.hasPrefix("<"), !t.hasPrefix("[Request interrupted") { texts.append(t) }
                    case "image":
                        texts.append(String(localized: "[Image]"))
                    default: break
                    }
                }
                if !texts.isEmpty { add(uuid, .user, texts.joined(separator: "\n")) }
            }
        case "queue-operation":
            // Ajan çalışırken yazdığınız mesaj önce kuyruğa girer; sohbette hemen "Sırada" diye görünsün.
            guard let content = e["content"] as? String else { return }
            switch e["operation"] as? String {
            case "enqueue":
                guard !content.hasPrefix("<"), queued[content] == nil else { return }
                let id = "queue-" + (e["timestamp"] as? String ?? UUID().uuidString)
                queued[content] = id
                if seen.insert(id).inserted {
                    update.added.append(ChatItem(id: id, kind: .user, text: content, at: at, pending: true))
                }
            case "remove", "dequeue":
                guard let id = queued.removeValue(forKey: content) else { return }
                let reason = e["reason"] as? String ?? ""
                if e["operation"] as? String == "dequeue" || reason.contains("absorbed") || reason.contains("deliver") {
                    update.delivered.insert(id)
                    deliveredTexts[content, default: 0] += 1
                } else {
                    update.dropped.insert(id)
                }
            default: break
            }
        case "attachment":
            // Ajan çalışırken yazılan mesajlar teslim edilince; kuyrukta zaten göründüyse tekrar ekleme.
            if let a = e["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
               (a["commandMode"] as? String ?? "prompt") == "prompt", let text = a["prompt"] as? String {
                if let id = queued.removeValue(forKey: text) {
                    update.delivered.insert(id)
                } else if let n = deliveredTexts[text], n > 0 {
                    // Kuyruk kaydıyla zaten gösterildi
                    deliveredTexts[text] = n - 1
                } else {
                    add(uuid, .user, text)
                }
            }
        case "assistant":
            guard e["isApiErrorMessage"] as? Bool != true,
                  let message = e["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for (i, b) in blocks.enumerated() {
                switch b["type"] as? String {
                case "text":
                    if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        add("\(uuid)#\(i)", .assistant, t)
                    }
                case "tool_use":
                    guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                    let input = b["input"] as? [String: Any] ?? [:]
                    add(id, .tool(name: name, summary: ToolSummary.summarize(name: name, input: input), failed: false), "")
                default: break
                }
            }
        default:
            break
        }
    }
}
