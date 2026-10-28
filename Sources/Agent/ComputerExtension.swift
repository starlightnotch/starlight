import AppKit
import EventKit
import SwiftUI

// MARK: - Approvals

/// An action waiting for your click in the notch: the exact command or file, Run or Cancel.
struct Approval: Identifiable, Equatable {
    let id = UUID()
    /// "Run in Terminal", "Save file", "Read file".
    let title: String
    /// What exactly: the command, the path.
    let detail: String
    /// The button: "Run", "Save", "Read".
    let action: String
    var glyph: Glyph.Kind = .terminal
    /// For files and apps: the name shown big, with its own icon, instead of a command box.
    var subject: String? = nil
    var icon: String? = nil
}

/// Asks you before the agent touches your Mac. Nothing runs until you click; ignoring it
/// (or a minute passing) cancels.
@MainActor
final class Approvals {
    static let shared = Approvals()
    weak var model: NotchModel?
    private var waiting: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    static let timeout: TimeInterval = 60

    /// Shows the request and waits for your answer. Several at once (two files to move) take
    /// turns: each waits for the one before. A request whose turn was dropped meanwhile is
    /// cancelled, and its card taken down.
    func ask(_ approval: Approval) async -> Bool {
        guard (try? await HeadStart.waitForReveal()) != nil else { return false }
        while waiting != nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return false }
        }
        guard !Task.isCancelled, let model else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = (approval.id, continuation)
                withAnimation(model.scaled(Motion.open)) { model.approval = approval }
                Sounds.playApprovalRequest()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in self?.decide(approval.id, false) }
            }
        } onCancel: {
            Task { @MainActor in Approvals.shared.decide(approval.id, false) }
        }
    }

    func decide(_ id: UUID, _ approved: Bool) {
        guard let waiting, waiting.id == id else { return }
        self.waiting = nil
        if let model { withAnimation(model.scaled(Motion.close)) { model.approval = nil } }
        waiting.continuation.resume(returning: approved)
    }

    /// The session ended or the notch is going away: anything waiting is cancelled.
    func cancelAll() {
        if let id = waiting?.id { decide(id, false) }
    }
}

// MARK: - Head start

/// An answer started at a short pause, before you'd clearly finished (LiveAnswers' head start).
/// Anything that acts (saves, adds, opens, asks you) waits until it's due to show, so it never
/// acts on half a sentence: if you go on talking, the turn is dropped before it does.
enum HeadStart {
    @TaskLocal static var revealAt: Date?

    static func waitForReveal() async throws {
        if let reveal = revealAt {
            let wait = reveal.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000)) }
        }
        try Task.checkCancellation()
    }
}

// MARK: - Computer

/// Opt-in: lets the agent use your Mac the way you would in Terminal. It can run shell
/// commands and read and write files. (Starlight's own settings: StarlightSelfExtension.)
///
/// Guard rails, because it acts on speech (yours and, in a meeting, other people's):
/// - Anything that changes your Mac (writes, deletes, installs, settings, sending) is shown in
///   the notch first, exactly as it will run, and runs only when you click. A minute without an
///   answer cancels. Commands that only look (ls, df, git status…) and reading ordinary files
///   run straight away, unless Settings says to ask every time (see SafeCommands).
/// - Only your own words can start an action. A request that came only from the other side of
///   a meeting ("Them:") is refused without asking.
/// - Commands run as you, in your home folder, with a 60-second limit; output is cut to 8,000
///   characters before it goes to the model.
struct ComputerExtension: StarlightExtension {
    let id = "computer"
    let name = "Files, apps & Terminal"
    let summary = "Open, find, read and save files, open apps, run commands. Asks before changes."
    let glyph = Glyph.Kind.terminal
    var optIn: Bool { true }

    static let outputLimit = 8_000
    static let commandTimeout: TimeInterval = 60

    private static var isDryRun: Bool { Dev.env("STARLIGHT_DRY_RUN") != nil }

    func register(_ api: ExtensionAPI) {
        // Whether the user (not the other side of the call) asked for this turn.
        final class Box: @unchecked Sendable { var fromUser = false }
        let box = Box()
        api.onBeforeAsk { request in
            box.fromUser = request.fromUser
            return nil
        }
        let refuse = ToolResult(content: "error: only the user can ask for this; it came from someone else in the meeting. Don't retry.",
                                outcome: .failed("Only you can ask for that"))

        api.registerTool(AgentTool(
            name: "run_command",
            description: "Run a shell command (zsh) on the user's Mac, as the user, in their home folder, for what the other tools can't do: disk space, system info, a macOS setting with `defaults`, git, brew, converting files, and so on. To open, find, list, read, save, move or trash files, or open apps and links, use those tools instead. The user sees the exact command and must click Run, so write the single command that does the job. Prefer read-only commands; never delete files unless the user clearly asked. Returns the exit code and output.",
            parameters: ["type": "object",
                         "properties": ["command": ["type": "string", "description": "e.g. ls -lt ~/Downloads | head -5"]],
                         "required": ["command"]],
            status: "Waiting for you", glyph: .terminal,
            keywords: ["run", "terminal", "command", "shell", "computer", "mac", "folder", "files", "file", "disk", "open", "install",
                       "downloads", "desktop", "documents", "settings", "defaults", "brew", "git"],
            run: { args in
                guard box.fromUser else { return refuse }
                let command = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { return ToolResult(content: "error: empty command") }
                // "open -a Reminders", "open ~/Desktop/plan.pdf": that's opening something, shown as such.
                if let target = Self.openTarget(command) {
                    if Self.isDryRun { return ToolResult(content: "Opened (test run).", outcome: .item("Opened", target, icon: nil)) }
                    return await MainActor.run { MacFiles.open(target, in: nil, reveal: false) }
                }
                let asks = AppSettings.shared.computerAsks == .always || !SafeCommands.isReadOnly(command)
                if Self.isDryRun {
                    return ToolResult(content: "exit 0\n(test run, nothing ran)", outcome: .done(asks ? "Ran after asking (test)" : "Ran (test)", ends: false))
                }
                if asks {
                    let approved = await Approvals.shared.ask(Approval(title: "Run in Terminal", detail: command, action: "Run"))
                    guard approved else { return ToolResult(content: "The user cancelled. Don't retry.", outcome: .failed("Cancelled")) }
                }
                let (status, output) = await Self.shell(command)
                let shown = command.count > 40 ? String(command.prefix(38)) + "…" : command
                return ToolResult(content: "exit \(status)\n" + (output.isEmpty ? "(no output)" : output),
                                  outcome: status == 0 ? .done("Ran \(shown)", ends: false) : .failed("Failed: \(shown)", ends: false))
            }))

        // Files, folders, apps, the clipboard: see MacFiles.
        MacFiles.register(api, fromUser: { box.fromUser }, refuse: refuse)
    }

    /// What a plain `open` command opens: `open -a Notes` → "Notes", `open ~/a.pdf` → the path.
    static func openTarget(_ command: String) -> String? {
        let pattern = #"^open\s+(?:-a\s+)?(?:"([^"]+)"|'([^']+)'|(\S+(?:\s+\S+)?))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: command) { return String(command[range]) }
        }
        return nil
    }

    static func expand(_ path: String) -> String { (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }

    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// Runs `command` in a login zsh, in the home folder. Returns the exit code and output.
    static func shell(_ command: String) async -> (Int32, String) {
        await run("/bin/zsh", ["-lc", command])
    }

    /// Runs a program with arguments (no shell), in the home folder, with the same limits.
    static func run(_ executable: String, _ arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                var output = Data()
                let lock = NSLock()
                let closed = DispatchSemaphore(value: 0)
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { closed.signal(); return }  // the end of the output
                    lock.withLock { if output.count < outputLimit * 2 { output.append(chunk) } }
                }
                do { try process.run() } catch {
                    return continuation.resume(returning: (127, "couldn't start \(executable): \(error.localizedDescription)"))
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timer)
                process.waitUntilExit()
                timer.cancel()
                // Something it started in the background can keep the output open forever
                // (`top | grep`, `cmd &`): wait a moment for the rest, then stop reading.
                _ = closed.wait(timeout: .now() + 1)
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
                let text = lock.withLock { String(decoding: output, as: UTF8.self) }
                var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > outputLimit { trimmed = String(trimmed.prefix(outputLimit)) + "\n… (cut)" }
                let status = process.terminationReason == .uncaughtSignal ? 124 : process.terminationStatus
                continuation.resume(returning: (status, status == 124 ? trimmed + "\n(stopped after \(Int(commandTimeout)) s)" : trimmed))
            }
        }
    }
}

/// Which commands only look. A command runs without asking only if every part of it is on
/// this list, with no way to write, chain or substitute: no `;`, `&&`, `>`, backticks or `$(`,
/// and pipes only into other read-only commands. Anything unsure asks.
enum SafeCommands {
    static let readOnly: Set<String> = [
        "ls", "pwd", "whoami", "date", "cal", "uptime", "uname", "sw_vers", "hostname", "id", "groups",
        "cat", "head", "tail", "wc", "less", "file", "stat", "du", "df", "find", "mdfind", "mdls", "which", "whereis",
        "grep", "egrep", "fgrep", "rg", "sort", "uniq", "cut", "tr", "awk", "column", "nl", "diff", "cmp", "shasum", "md5",
        "ps", "top", "lsof", "pgrep", "vm_stat", "iostat", "netstat", "ifconfig", "ipconfig", "ping", "dig", "nslookup",
        "networksetup", "system_profiler", "pmset", "ioreg", "sysctl", "defaults", "git", "brew", "echo", "printf",
        "tree", "basename", "dirname", "realpath", "locale",
    ]
    /// Subcommands of these that only look; anything else asks.
    static let readOnlySubcommands: [String: Set<String>] = [
        "git": ["status", "log", "diff", "show", "branch", "remote", "rev-parse", "describe", "shortlog", "blame", "ls-files", "tag"],
        "brew": ["list", "info", "search", "outdated", "leaves", "deps", "config", "doctor"],
        "defaults": ["read", "read-type", "domains", "find"],
        "networksetup": ["-listallnetworkservices", "-getinfo", "-getairportnetwork", "-getdnsservers", "-listallhardwareports"],
        "pmset": ["-g"],
    ]

    static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 400 else { return false }
        // Chaining, redirection, substitution, background jobs, sudo: always ask.
        for bad in [";", "&", ">", "<", "`", "$(", "\n", "sudo ", "\\"] where trimmed.contains(bad) { return false }
        for segment in trimmed.split(separator: "|") {
            let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = words.first, readOnly.contains(first) else { return false }
            if let allowed = readOnlySubcommands[first] {
                guard words.count > 1, allowed.contains(words[1]) else { return false }
            }
            switch first {
            // Write to a file through a flag or a second argument.
            case "sort": if words.contains(where: { $0 == "-o" || $0.hasPrefix("--output") }) { return false }
            case "tree": if words.contains(where: { $0 == "-o" }) { return false }
            case "uniq": if words.dropFirst().filter({ !$0.hasPrefix("-") }).count > 1 { return false }
            case "git":
                // Listing only: branch, tag and remote with no arguments; nothing written to files.
                if ["branch", "tag", "remote"].contains(words[1]), words.count > 2, words[2] != "-v", words[2] != "-a" { return false }
                if words.contains(where: { $0.hasPrefix("--output") || $0 == "-o" }) { return false }
            case "find": if words.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fls"].contains($0) }) { return false }
            case "sysctl": if words.contains("-w") || words.contains(where: { $0.contains("=") }) { return false }
            case "awk": if segment.contains("system") || segment.contains("print >") { return false }
            case "top": if !words.contains("-l") { return false }  // interactive top never ends
            case "ping": if !words.contains("-c") { return false }
            default: break
            }
            if words.dropFirst().contains(where: isSensitive) { return false }
            // Globs and quotes can spell a sensitive path without naming it: ask.
            if words.dropFirst().contains(where: { $0.contains(where: { "*?[]{}'\"~".contains($0) }) && $0.contains("/") }) { return false }
        }
        return true
    }

    /// Keys, passwords, tokens and browser data: reading these always asks.
    static func isSensitive(_ path: String) -> Bool {
        let p = path.lowercased()
        let markers = [".ssh", "id_rsa", "id_ed25519", ".pem", ".p12", ".key", "keychain", ".env", ".netrc", ".npmrc", ".pypirc",
                       ".aws", ".gnupg", "credentials", "secret", "token", "password", "cookies", "login data", ".docker/config",
                       "library/messages", "library/mail", "1password", "bitwarden"]
        return markers.contains { p.contains($0) }
    }
}

// MARK: - Reminders

/// Opt-in: "add buy milk to my to-do list" adds it to Apple Reminders (and so to iPhone,
/// iPad and the web through iCloud). macOS asks once before Starlight may add reminders.
struct RemindersExtension: StarlightExtension {
    let id = "reminders"
    let name = "Reminders"
    let summary = "Add reminders to Apple Reminders."
    let glyph = Glyph.Kind.todo
    var optIn: Bool { true }

    private static let store = EKEventStore()

    func register(_ api: ExtensionAPI) {
        api.registerTool(AgentTool(
            name: "add_todo",
            description: "Add an item to the user's to-do list (Apple Reminders) when they ask to add, remind or put something on their list. Title it as a short task (\"Send Dana the deck\"). Optional due date as ISO 8601 when they gave one.",
            parameters: ["type": "object",
                         "properties": ["title": ["type": "string"],
                                        "due": ["type": "string", "description": "ISO 8601, e.g. 2026-10-14T09:00:00, only if they said when"],
                                        "list": ["type": "string", "description": "A list name, only if they named one"]],
                         "required": ["title"]],
            status: "Adding to Reminders", glyph: .todo,
            keywords: ["todo", "to-do", "reminder", "reminders", "remind", "task", "list", "add"],
            run: { args in
                let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return ToolResult(content: "error: no title") }
                if Dev.env("STARLIGHT_DRY_RUN") != nil {
                    return ToolResult(content: "Added (test run, nothing saved).", outcome: .done("Added \u{201C}\(title)\u{201D} (test)"))
                }
                do {
                    guard try await Self.store.requestFullAccessToReminders() else {
                        await PermissionAsk.shared.need("reminders")
                        return ToolResult(content: "error: no access to Reminders", outcome: .failed("Starlight can't use Reminders. Allow it in System Settings → Privacy"))
                    }
                    let reminder = EKReminder(eventStore: Self.store)
                    reminder.title = title
                    let named = (args["list"] as? String).flatMap { name in
                        Self.store.calendars(for: .reminder).first { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
                    }
                    reminder.calendar = named ?? Self.store.defaultCalendarForNewReminders()
                    if let due = (args["due"] as? String).flatMap(Self.date) {
                        reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                        reminder.addAlarm(EKAlarm(absoluteDate: due))
                    }
                    try Self.store.save(reminder, commit: true)
                    let when = (args["due"] as? String).flatMap(Self.date).map { ", " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
                    let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders")?.path
                    return ToolResult(content: "Added to \(reminder.calendar?.title ?? "Reminders")\(when).",
                                      outcome: .item("Added to Reminders\(when)", title, icon: app))
                } catch {
                    return ToolResult(content: "error: \(error.localizedDescription)", outcome: .failed("Couldn't add \u{201C}\(title)\u{201D}"))
                }
            }))
    }

    private static func date(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return format == "yyyy-MM-dd" ? date.addingTimeInterval(9 * 3600) : date }
        }
        return nil
    }
}
