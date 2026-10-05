import AppKit
import Foundation

/// Bir Claude oturumunun çalıştığı terminal sekmesini bulup ona yazar ya da öne getirir.
///
/// Eşleştirme tty üzerinden: Claude sürecinin terminal hattı (`ps -o tty`) ile iTerm2 /
/// Terminal.app sekmesinin `tty` özelliği aynı. Mesaj, sekmeye sizin yazmışsınız gibi gider
/// ve Enter'a basılır; Claude onu sıradan bir istek olarak alır.
enum TerminalBridge {
    enum Failure: Error {
        case noTTY
        case notFound
        case scriptError(String)

        var message: String {
            switch self {
            case .noTTY: String(localized: "Couldn't find this session's terminal line.")
            case .notFound: String(localized: "No iTerm2 or Terminal tab matches this session.")
            case .scriptError(let s): s
            }
        }
    }

    /// Mesajı oturumun sekmesine yazıp gönderir. Sonuç biraz sonra gelir (terminali bekliyoruz).
    ///
    /// Ölçüm (2026-10-05): iTerm2 `write text` baytları olduğu gibi yolluyor, Enter da gerçek bir CR.
    /// Ama metin ve CR peş peşe gelirse Claude Code bunu yapıştırma sayıp CR'ı satır sonu yapıyor.
    /// Bu yüzden: metni yaz → bekle → yalnızca CR gönder → ekranı okuyup giriş kutusu boşaldı mı bak;
    /// boşalmadıysa bir CR daha, o da olmazsa son çare olarak sekmeyi öne alıp gerçek Enter tuşu.
    @MainActor
    static func send(_ text: String, toPID pid: Int32, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        // Satır sonu Claude'da "gönder" demek; çok satırlı metni tek satıra indiriyoruz.
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { completion(.success(())); return }
        guard let tty = tty(of: pid) else { completion(.failure(.noTTY)); return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        guard running.contains(iTermID) else {
            // Terminal.app'te `do script` metni zaten gönderiyor.
            completion(run(pid: pid, iTerm: "", terminal: "do script \(quoted(line)) in t").map { _ in () })
            return
        }

        let probe = String(line.prefix(24))
        Task { @MainActor in
            // 1) Metni yaz, Claude'un yapıştırma penceresi kapansın diye bekle, CR gönder.
            let first = await osascript(iTermSession(tty: tty, body: """
                tell s to write text \(quoted(line)) newline no
                delay 0.9
                tell s to write text (character id 13) newline no
                delay 0.5
                return contents of s
                """))
            guard let screen = first else { completion(.failure(.notFound)); return }
            if !inputStillHolds(probe, screen: screen) { completion(.success(())); return }

            // 2) Bir CR daha
            let second = await osascript(iTermSession(tty: tty, body: """
                tell s to write text (character id 13) newline no
                delay 0.6
                return contents of s
                """))
            if let second, !inputStillHolds(probe, screen: second) { completion(.success(())); return }

            // 3) Son çare: sekmeyi öne alıp gerçek Enter tuşu, sonra odağı geri ver.
            completion(pressEnterInFront(tty: tty))
        }
    }

    /// Ekrandaki son "❯" giriş satırında hâlâ bizim metnimiz var mı (gönderilmemiş mi)?
    private static func inputStillHolds(_ probe: String, screen: String) -> Bool {
        guard let range = screen.range(of: "❯", options: .backwards) else { return false }
        let tail = screen[range.upperBound...].replacingOccurrences(of: "\n", with: " ")
        return tail.contains(probe)
    }

    @MainActor
    private static func pressEnterInFront(tty: String) -> Result<Void, Failure> {
        _ = execute(iTermSession(tty: tty, body: "select w\n tell t to select\n tell s to select\n activate\n return \"ok\""))
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == iTermID || waitForITerm() else {
            return .failure(.scriptError(String(localized: "iTerm2 didn't come to the front; press Enter in the terminal.")))
        }
        if case .failure(let f) = execute("tell application \"System Events\" to key code 36") { return .failure(f) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.activate() }
        return .success(())
    }

    /// tty'si eşleşen iTerm2 oturumu üzerinde `body` çalıştıran betik; eşleşme yoksa "missing" döner.
    private static func iTermSession(tty: String, body: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            \(body)
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    /// Bekleme içeren betikleri arayüzü dondurmadan ayrı bir `osascript` sürecinde çalıştırır.
    private static func osascript(_ source: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", source]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                p.waitUntilExit()
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (text == "missing" || p.terminationStatus != 0) ? nil : text)
            }
        }
    }

    /// iTerm2'nin öne gelmesini en fazla ~0,6 sn bekler; Enter yanlış uygulamaya gitmesin.
    @MainActor
    private static func waitForITerm() -> Bool {
        for _ in 0..<12 {
            RunLoop.current.run(until: .now + 0.05)
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == iTermID { return true }
        }
        return false
    }

    /// Oturumu düzgünce kapatır: Claude'a `/exit` gönderir, süreç bitince sekmeyi kapatır.
    /// Süreç birkaç saniyede kapanmazsa sekmeye dokunmaz; yarım iş kaybolmasın.
    @MainActor
    static func close(pid: Int32, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        guard let tty = tty(of: pid) else { completion(.failure(.noTTY)); return }
        send("/exit", toPID: pid) { result in
            if case .failure(let f) = result { completion(.failure(f)); return }
            waitAndCloseTab(pid: pid, tty: tty, completion: completion)
        }
    }

    @MainActor
    private static func waitAndCloseTab(pid: Int32, tty: String, completion: @escaping @MainActor (Result<Void, Failure>) -> Void) {
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(300))
                if kill(pid, 0) != 0, errno == ESRCH { break }
            }
            guard kill(pid, 0) != 0, errno == ESRCH else {
                completion(.failure(.scriptError(String(localized: "The session didn't exit; check its terminal."))))
                return
            }
            let script = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                tell s to close
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
            _ = execute(script)
            completion(.success(()))
        }
    }

    /// Oturumun sekmesini seçip terminali öne getirir.
    @MainActor
    static func focus(pid: Int32) -> Result<Void, Failure> {
        run(pid: pid,
            iTerm: "select w\n tell t to select\n tell s to select\n activate",
            terminal: "set selected of t to true\n set frontmost of w to true\n activate")
            .map { _ in () }
    }

    private static let iTermID = "com.googlecode.iterm2"
    private static let terminalID = "com.apple.Terminal"

    @MainActor
    /// Başarılıysa işi yapan terminalin bundle kimliğini döner.
    private static func run(pid: Int32, iTerm: String, terminal: String) -> Result<String, Failure> {
        guard let tty = tty(of: pid) else { return .failure(.noTTY) }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

        if running.contains(iTermID) {
            let script = """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                \(iTerm)
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "missing"
            """
            switch execute(script) {
            case .success("ok"): return .success(iTermID)
            case .failure(let f): return .failure(f)
            default: break
            }
        }
        if running.contains(terminalID) {
            let script = """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            \(terminal)
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
            """
            switch execute(script) {
            case .success("ok"): return .success(terminalID)
            case .failure(let f): return .failure(f)
            default: break
            }
        }
        return .failure(.notFound)
    }

    @MainActor
    private static func execute(_ source: String) -> Result<String, Failure> {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? String(localized: "The terminal didn't respond.")
            return .failure(.scriptError(message))
        }
        return .success(result?.stringValue ?? "")
    }

    /// "ttys012" → "/dev/ttys012"
    private static func tty(of pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !out.isEmpty, out != "??" else { return nil }
        return out.hasPrefix("/dev/") ? out : "/dev/" + out
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
