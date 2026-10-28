import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The Computer extension's everyday actions, done the Mac way (Finder, Spotlight, Launch
/// Services) rather than as shell commands:
///
///   open_item     a file, folder, app or link; or show it in Finder
///   find_files    Spotlight: by name or contents, or what you used recently
///   list_folder   what's in a folder, newest first
///   read_file     text from documents: plain text, Markdown, PDF, Word, RTF, Pages-free formats
///   save_file     a new file (straight away), or replace/add to one (asks); can open it after
///   file_action   move, copy, rename, new folder, or move to the Trash (never deletes outright)
///   clipboard     what's on it, or put something on it
///
/// Asking: looking, opening and creating something new happen straight away. Anything that
/// changes or moves what's already there asks first, with the exact paths; so does touching
/// keys, passwords and the like (SafeCommands.isSensitive). Settings → Computer → "Every
/// command" makes everything ask.
enum MacFiles {
    static let listLimit = 40
    static let readLimit = 20_000

    private static var isDryRun: Bool { Dev.env("STARLIGHT_DRY_RUN") != nil }
    private static var alwaysAsk: Bool { AppSettings.shared.computerAsks == .always }

    // MARK: Paths

    /// "~/Desktop/a.txt", "Desktop/a.txt", "/Users/…" → an absolute path. A bare file name
    /// lands on the Desktop.
    static func resolve(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        if path.hasPrefix("/") { return path }
        let home = NSHomeDirectory()
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        if ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library", "Applications"].contains(first) {
            return home + "/" + path
        }
        return home + "/Desktop/" + path
    }

    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// Desktop, Documents, Downloads (and folders in them), not hidden: where new files can go
    /// without asking. Everywhere else asks.
    static func isEverydayPlace(_ path: String) -> Bool {
        let standard = (path as NSString).standardizingPath
        let home = NSHomeDirectory()
        let allowed = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 + "/" }
        guard allowed.contains(where: { standard.hasPrefix($0) }) else { return false }
        return !standard.dropFirst(home.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    private static func ask(_ title: String, _ detail: String, action: String, glyph: Glyph.Kind,
                            subject: String? = nil, icon: String? = nil) async -> Bool {
        await Approvals.shared.ask(Approval(title: title, detail: detail, action: action, glyph: glyph, subject: subject, icon: icon))
    }

    private static let cancelled = ToolResult(content: "The user cancelled. Don't retry.", outcome: .failed("Cancelled"))

    // MARK: Tools

    static func register(_ api: ExtensionAPI, fromUser: @escaping () -> Bool, refuse: ToolResult) {
        api.registerTool(AgentTool(
            name: "open_item",
            description: "Open something on the user's Mac: a file or folder (by path, in its usual app or one they name), an app by name (\"Safari\", \"Notes\"), or a web link. To search something in their browser, open https://www.google.com/search?q=… (with app set to the browser they named, e.g. Google Chrome). With reveal, show the file in Finder instead. Find a file's path with find_files first if you don't know it.",
            parameters: ["type": "object",
                         "properties": ["target": ["type": "string", "description": "A path (~/Desktop/plan.pdf), an app name, or a URL"],
                                        "app": ["type": "string", "description": "Open the file in this app (e.g. TextEdit, Preview)"],
                                        "reveal": ["type": "boolean", "description": "Show it in Finder instead of opening it"]],
                         "required": ["target"]],
            status: "Opening", glyph: .external,
            keywords: ["open", "launch", "start", "show", "finder", "app", "file", "folder", "website", "link", "reveal"],
            run: { args in
                guard fromUser() else { return refuse }
                let target = (args["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty else { return ToolResult(content: "error: open_item needs a target") }
                if isDryRun { return ToolResult(content: "Opened (test run).", outcome: .done("Opened \(target) (test)")) }
                return await MainActor.run { open(target, in: args["app"] as? String, reveal: SettingsRegistry.asBool(args["reveal"] ?? false) == true) }
            }))

        api.registerTool(AgentTool(
            name: "find_files",
            description: "Find files on the user's Mac with Spotlight: by name or by what's inside, optionally in one folder or of one kind (pdf, image, document, spreadsheet, presentation, folder, app); or recent=true for what they opened or changed lately (\"the file I was just working on\"). Returns paths with dates.",
            parameters: ["type": "object",
                         "properties": ["query": ["type": "string", "description": "Words in the name or the contents; may be empty with recent"],
                                        "folder": ["type": "string", "description": "Only inside this folder, e.g. ~/Documents"],
                                        "kind": ["type": "string", "enum": ["any", "pdf", "image", "document", "spreadsheet", "presentation", "folder", "app"]],
                                        "recent": ["type": "boolean", "description": "Most recently used first"]],
                         "required": []],
            status: "Searching your Mac", glyph: .search,
            keywords: ["find", "where", "search", "file", "files", "document", "pdf", "recent", "latest", "folder", "resume", "photo"],
            run: { args in
                guard fromUser() else { return refuse }
                if isDryRun { return ToolResult(content: "~/Documents/Plan.pdf (test run)", display: "Found 1 (test)") }
                let found = await find(args["query"] as? String ?? "", folder: (args["folder"] as? String).map(resolve),
                                       kind: args["kind"] as? String ?? "any", recent: SettingsRegistry.asBool(args["recent"] ?? false) == true)
                guard !found.isEmpty else { return ToolResult(content: "Nothing found.", display: "Nothing found") }
                return ToolResult(content: found.map(describe).joined(separator: "\n"), display: "Found \(found.count)")
            }))

        api.registerTool(AgentTool(
            name: "list_folder",
            description: "List what's in a folder on the user's Mac (~/Downloads, ~/Desktop…), newest first, with sizes.",
            parameters: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
            status: "Looking", glyph: .folder,
            keywords: ["list", "folder", "downloads", "desktop", "documents", "what's in", "contents"],
            run: { args in
                guard fromUser() else { return refuse }
                let path = resolve(args["path"] as? String ?? "~/Desktop")
                if isDryRun { return ToolResult(content: "(test run: contents of \(path))", display: "Listed (test)") }
                if SafeCommands.isSensitive(path) || alwaysAsk {
                    guard await ask("Look in folder", tilde(path), action: "Look", glyph: .folder) else { return cancelled }
                }
                guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
                    return ToolResult(content: "error: no folder at \(tilde(path))", outcome: .failed("No folder \(name(path))", ends: false))
                }
                let sorted = urls.sorted { modified($0) > modified($1) }
                let lines = sorted.prefix(listLimit).map(describe)
                let more = urls.count > listLimit ? "\n… and \(urls.count - listLimit) more" : ""
                return ToolResult(content: "\(tilde(path)): \(urls.count) items\n" + lines.joined(separator: "\n") + more,
                                  display: "\(name(path)): \(urls.count) items")
            }))

        api.registerTool(AgentTool(
            name: "read_file",
            description: "Read the text of a file on the user's Mac: plain text, Markdown, code, PDF, Word (.docx), RTF, HTML. Use it when they ask what a document says, to summarize it, or to answer from it.",
            parameters: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]],
            status: "Reading", glyph: .file,
            keywords: ["read", "file", "document", "pdf", "contents", "summarize", "says", "what's in"],
            run: { args in
                guard fromUser() else { return refuse }
                let path = resolve(args["path"] as? String ?? "")
                if isDryRun { return ToolResult(content: "(test run: contents of \(path))", outcome: .done("Read (test)", ends: false)) }
                if alwaysAsk || SafeCommands.isSensitive(path) {
                    guard await ask("Read file", tilde(path), action: "Read", glyph: .file) else { return cancelled }
                }
                guard let text = readText(path) else {
                    return ToolResult(content: "error: couldn't read text from \(tilde(path))", outcome: .failed("Couldn't read \(name(path))", ends: false))
                }
                let cut = text.count > readLimit ? String(text.prefix(readLimit)) + "\n… (cut)" : text
                return ToolResult(content: cut, display: "Read \(name(path))")
            }))

        api.registerTool(AgentTool(
            name: "save_file",
            description: "Save text to a file on the user's Mac: a new file (a bare name goes on the Desktop), or replace or add to an existing one. open_after opens it when saved. Write the whole content; for this meeting's transcript use open_transcript instead.",
            parameters: ["type": "object",
                         "properties": ["path": ["type": "string", "description": "e.g. ~/Desktop/ideas.md, or just ideas.md"],
                                        "content": ["type": "string"],
                                        "append": ["type": "boolean", "description": "Add to the end instead of replacing"],
                                        "open_after": ["type": "boolean", "description": "Open the file once it's saved"]],
                         "required": ["path", "content"]],
            status: "Saving", glyph: .file,
            keywords: ["save", "write", "file", "create", "note", "append", "desktop", "documents", "textedit"],
            run: { args in
                guard fromUser() else { return refuse }
                let raw = (args["path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, raw != "/", raw != "~" else { return ToolResult(content: "error: save_file needs a file name or path.") }
                let path = resolve(raw)
                let content = args["content"] as? String ?? ""
                let append = SettingsRegistry.asBool(args["append"] ?? false) == true
                let openAfter = SettingsRegistry.asBool(args["open_after"] ?? false) == true
                if isDryRun { return ToolResult(content: "Saved (test run, nothing written).", outcome: .done("Saved \(name(path)) (test)")) }
                let exists = FileManager.default.fileExists(atPath: path)
                // New files in your own folders just happen; changing one you already have, or
                // writing anywhere else (Library, hidden files, startup items), asks.
                if exists || alwaysAsk || SafeCommands.isSensitive(path) || !Self.isEverydayPlace(path) {
                    // Where it goes, always, then the start of what's written.
                    let preview = "In " + tilde((path as NSString).deletingLastPathComponent) + "\n"
                        + content.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).joined(separator: "\n")
                    guard await ask(append ? "Add to" : exists ? "Replace" : "Save", preview, action: "Save", glyph: .file,
                                    subject: name(path), icon: exists ? path : nil) else { return cancelled }
                }
                do {
                    let url = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if append, exists, let handle = try? FileHandle(forWritingTo: url) {
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data((content.hasPrefix("\n") ? content : "\n" + content).utf8))
                    } else {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                    }
                    if openAfter { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
                    let verb = append ? "Added to" : exists ? "Updated" : "Saved"
                    return ToolResult(content: "\(verb) \(path)", outcome: .item(openAfter ? "\(verb) and opened" : verb, name(path), icon: path))
                } catch {
                    return ToolResult(content: "error: \(error.localizedDescription)", outcome: .failed("Couldn't save \(name(path))"))
                }
            }))

        api.registerTool(AgentTool(
            name: "file_action",
            description: "Organize files on the user's Mac: move, copy or rename a file or folder, make a new folder, or move something to the Trash (it can be put back; nothing is deleted for good). Moving, renaming and trashing ask the user first.",
            parameters: ["type": "object",
                         "properties": ["action": ["type": "string", "enum": ["move", "copy", "rename", "new_folder", "trash"]],
                                        "path": ["type": "string", "description": "The file or folder (for new_folder: the folder to make)"],
                                        "to": ["type": "string", "description": "Where to (a folder, or a full new path); for rename, the new name"]],
                         "required": ["action", "path"]],
            status: "Organizing", glyph: .folder,
            keywords: ["move", "copy", "rename", "folder", "trash", "delete", "organize", "put", "duplicate"],
            run: { args in
                guard fromUser() else { return refuse }
                let action = args["action"] as? String ?? ""
                let path = resolve(args["path"] as? String ?? "")
                if isDryRun { return ToolResult(content: "Done (test run).", outcome: .done("\(action.capitalized) \(name(path)) (test)")) }
                return await organize(action, path: path, to: args["to"] as? String)
            }))

        api.registerTool(AgentTool(
            name: "clipboard",
            description: "Read what's on the user's clipboard, or put text on it (\"copy that for me\").",
            parameters: ["type": "object",
                         "properties": ["action": ["type": "string", "enum": ["read", "write"]],
                                        "text": ["type": "string", "description": "For write"]],
                         "required": ["action"]],
            status: "Clipboard", glyph: .copy,
            keywords: ["clipboard", "copy", "copied", "paste", "pasted"],
            run: { args in
                guard fromUser() else { return refuse }
                if (args["action"] as? String) == "write" {
                    let text = args["text"] as? String ?? ""
                    await MainActor.run {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    return ToolResult(content: "Copied.", outcome: .done("Copied to the clipboard"))
                }
                let text = await MainActor.run { NSPasteboard.general.string(forType: .string) } ?? ""
                return ToolResult(content: text.isEmpty ? "The clipboard has no text." : String(text.prefix(4000)), display: "Read the clipboard")
            }))
    }

    // MARK: Opening

    /// "https://www.youtube.com/watch?v=…" → "YouTube"; other sites by their domain, without "www.".
    static func siteName(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let known = ["youtube.com": "YouTube", "youtu.be": "YouTube", "google.com": "Google", "gmail.com": "Gmail", "mail.google.com": "Gmail",
                     "github.com": "GitHub", "x.com": "X", "twitter.com": "X", "reddit.com": "Reddit", "netflix.com": "Netflix",
                     "wikipedia.org": "Wikipedia", "en.wikipedia.org": "Wikipedia", "amazon.com": "Amazon", "linkedin.com": "LinkedIn",
                     "instagram.com": "Instagram", "facebook.com": "Facebook", "spotify.com": "Spotify", "open.spotify.com": "Spotify",
                     "chatgpt.com": "ChatGPT", "claude.ai": "Claude", "notion.so": "Notion"]
        return known[host] ?? host
    }

    @MainActor
    static func open(_ target: String, in appName: String?, reveal: Bool) -> ToolResult {
        let workspace = NSWorkspace.shared
        // A link.
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "facetime", "maps"].contains(scheme) {
            // In a browser they named ("search that in Chrome").
            if let appName, let app = application(named: appName) {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return ToolResult(content: "Opened \(target) in \(appName)", outcome: .item("Opened in \(app.deletingPathExtension().lastPathComponent)", siteName(url) ?? target, icon: app.path))
            }
            // The browser it opens in gives the card its icon; the site is named the way people say it.
            let browser = workspace.urlForApplication(toOpen: url)?.path
            return workspace.open(url) ? ToolResult(content: "Opened \(target)", outcome: .item("Opened", siteName(url) ?? target, icon: browser))
                : ToolResult(content: "error: couldn't open \(target)", outcome: .failed("Couldn't open that link"))
        }
        if !target.contains("/"), target.range(of: #"^[\w-]+\.(com|org|net|io|ai|dev|app|co)(/.*)?$"#, options: .regularExpression) != nil,
           let url = URL(string: "https://" + target) {
            workspace.open(url)
            return ToolResult(content: "Opened \(url)", outcome: .item("Opened", target, icon: nil))
        }
        // A file or folder.
        let path = resolve(target)
        if FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if reveal {
                workspace.activateFileViewerSelecting([url])
                return ToolResult(content: "Showed \(path) in Finder", outcome: .item("Showed in Finder", name(path), icon: path))
            }
            if let appName, let app = application(named: appName) {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return ToolResult(content: "Opened \(path) in \(appName)",
                                  outcome: .item("Opened in \(app.deletingPathExtension().lastPathComponent)", name(path), icon: path))
            }
            return workspace.open(url) ? ToolResult(content: "Opened \(path)", outcome: .item("Opened", name(path), icon: path))
                : ToolResult(content: "error: couldn't open \(path)", outcome: .failed("Couldn't open \(name(path))"))
        }
        // An app.
        if let app = application(named: target) {
            workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            return ToolResult(content: "Opened \(app.lastPathComponent)", outcome: .item("Opened", app.deletingPathExtension().lastPathComponent, icon: app.path))
        }
        return ToolResult(content: "error: no file, app or link called \(target). Use find_files to look for it.",
                          outcome: .failed("Couldn't find \(target)", ends: false))
    }

    /// An installed app by its name ("Safari", "VS Code", "notes").
    static func application(named name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let aliases = ["vs code": "visual studio code", "vscode": "visual studio code", "chrome": "google chrome", "settings": "system settings",
                       "system preferences": "system settings", "word": "microsoft word", "excel": "microsoft excel",
                       "powerpoint": "microsoft powerpoint", "teams": "microsoft teams", "outlook": "microsoft outlook"]
        let target = aliases[wanted] ?? wanted
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        var candidates: [URL] = []
        for folder in folders {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                candidates.append(URL(fileURLWithPath: folder).appendingPathComponent(item))
            }
        }
        func appName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.lowercased() }
        return candidates.first { appName($0) == target }
            ?? candidates.first { appName($0).hasPrefix(target) }
            ?? candidates.first { appName($0).contains(target) && target.count >= 4 }
    }

    // MARK: Finding

    static func find(_ query: String, folder: String?, kind: String, recent: Bool) async -> [URL] {
        var predicate: [String] = []
        let q = query.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { predicate.append("(kMDItemFSName == \"*\(q)*\"cd || kMDItemTextContent == \"\(q)\"cd || kMDItemTitle == \"*\(q)*\"cd)") }
        let types = ["pdf": "com.adobe.pdf", "image": "public.image", "document": "public.content", "spreadsheet": "public.spreadsheet",
                     "presentation": "public.presentation", "folder": "public.folder", "app": "com.apple.application-bundle"]
        if let type = types[kind] { predicate.append("kMDItemContentTypeTree == \"\(type)\"") }
        if recent { predicate.append("kMDItemLastUsedDate >= $time.today(-30)") }
        if predicate.isEmpty { predicate.append("kMDItemLastUsedDate >= $time.today(-7)") }
        var arguments = [predicate.joined(separator: " && ")]
        if let folder { arguments = ["-onlyin", folder] + arguments }
        let (_, output) = await ComputerExtension.run("/usr/bin/mdfind", arguments)
        let home = NSHomeDirectory()
        var urls = output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }.filter { url in
            let p = url.path
            return p.hasPrefix(home) && !p.contains("/Library/") && !p.contains("/.") && !SafeCommands.isSensitive(p)
        }
        // Spotlight can be off or behind (excluded folders, a fresh index): look directly.
        if urls.isEmpty { urls = walk(q, folder: folder, kind: kind, recent: recent) }
        urls.sort { (recent ? used($0) : modified($0)) > (recent ? used($1) : modified($1)) }
        return Array(urls.prefix(15))
    }

    /// The same search by walking the usual folders (or `folder`), a few levels deep.
    static func walk(_ query: String, folder: String?, kind: String, recent: Bool) -> [URL] {
        let home = NSHomeDirectory()
        let roots = folder.map { [$0] } ?? ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        let words = query.lowercased().split(separator: " ").map(String.init)
        let extensions: [String: Set<String>] = [
            "pdf": ["pdf"], "image": ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff"],
            "document": ["pdf", "doc", "docx", "pages", "txt", "md", "rtf", "odt"], "spreadsheet": ["xls", "xlsx", "numbers", "csv"],
            "presentation": ["ppt", "pptx", "key"], "app": ["app"],
        ]
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        var found: [URL] = []
        var visited = 0
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                      includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .contentAccessDateKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                visited += 1
                if visited > 40_000 { break }
                if walker.level > 4 { walker.skipDescendants(); continue }
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && url.pathExtension != "app"
                if ["node_modules", ".build", "build", "DerivedData", ".git"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                if kind == "folder" ? !isFolder : isFolder { continue }
                if let wanted = extensions[kind], !wanted.contains(url.pathExtension.lowercased()) { continue }
                let name = url.lastPathComponent.lowercased()
                if !words.isEmpty, !words.allSatisfy({ name.contains($0) }) { continue }
                if recent || words.isEmpty, used(url) < cutoff { continue }
                if SafeCommands.isSensitive(url.path) { continue }
                found.append(url)
            }
        }
        return found
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func used(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? modified(url)
    }

    /// "~/Documents/Plan.pdf · 2.1 MB · Oct 12, 3:04 PM"
    static func describe(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let folder = values?.isDirectory == true && url.pathExtension != "app"
        let size = folder ? "folder" : ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        let date = values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return "\(tilde(url.path)) · \(size) · \(date)"
    }

    // MARK: Reading

    static func readText(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string }
        if ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive"].contains(ext),
           let text = try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    // MARK: Organizing

    static func organize(_ action: String, path: String, to: String?) async -> ToolResult {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: path)
        func failed(_ text: String, _ error: Error? = nil) -> ToolResult {
            ToolResult(content: "error: \(error?.localizedDescription ?? text)", outcome: .failed(text))
        }
        switch action {
        case "new_folder":
            if fm.fileExists(atPath: path) { return ToolResult(content: "It already exists.", outcome: .done("\(name(path)) is already there")) }
            if alwaysAsk || !isEverydayPlace(path) {
                guard await ask("New folder", "In " + tilde((path as NSString).deletingLastPathComponent), action: "Make", glyph: .folder,
                                subject: name(path), icon: nil) else { return cancelled }
            }
            do { try fm.createDirectory(at: source, withIntermediateDirectories: true) } catch { return failed("Couldn't make \(name(path))", error) }
            return ToolResult(content: "Made \(path)", outcome: .item("New folder", name(path), icon: path))
        case "trash":
            guard fm.fileExists(atPath: path) else { return failed("No \(name(path)) there") }
            guard await ask("Move to Trash", tilde((path as NSString).deletingLastPathComponent), action: "Move to Trash", glyph: .trash,
                            subject: name(path), icon: path) else { return cancelled }
            do { try fm.trashItem(at: source, resultingItemURL: nil) } catch { return failed("Couldn't trash \(name(path))", error) }
            return ToolResult(content: "Moved \(path) to the Trash", outcome: .item("Moved to Trash", name(path), icon: nil))
        case "move", "copy", "rename":
            guard fm.fileExists(atPath: path) else { return failed("No \(name(path)) there") }
            guard let to, !to.trimmingCharacters(in: .whitespaces).isEmpty else { return failed("Where to?") }
            var destination: URL
            if action == "rename", !to.contains("/") {
                destination = source.deletingLastPathComponent().appendingPathComponent(to)
            } else {
                destination = URL(fileURLWithPath: resolve(to))
                var isFolder: ObjCBool = false
                if fm.fileExists(atPath: destination.path, isDirectory: &isFolder), isFolder.boolValue {
                    destination.appendPathComponent(source.lastPathComponent)
                }
            }
            if fm.fileExists(atPath: destination.path) { return failed("\(destination.lastPathComponent) is already there") }
            // Copying something new into your own folders just happens; moving and renaming ask,
            // and so does anything going somewhere sensitive.
            if action != "copy" || alwaysAsk || SafeCommands.isSensitive(path) || SafeCommands.isSensitive(destination.path)
                || !Self.isEverydayPlace(destination.path) {
                let verb = action == "rename" ? "Rename" : action.capitalized
                let detail = action == "rename" ? "to \(destination.lastPathComponent)" : "to " + tilde(destination.deletingLastPathComponent().path)
                guard await ask(verb, detail, action: verb, glyph: .folder, subject: name(path), icon: path) else { return cancelled }
            }
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if action == "copy" { try fm.copyItem(at: source, to: destination) } else { try fm.moveItem(at: source, to: destination) }
            } catch {
                return failed("Couldn't \(action) \(name(path))", error)
            }
            let done = action == "copy" ? "Copied" : action == "rename" ? "Renamed" : "Moved"
            return ToolResult(content: "\(done) to \(destination.path)",
                              outcome: .item(action == "rename" ? "Renamed" : "\(done) to \(destination.deletingLastPathComponent().lastPathComponent)",
                                             destination.lastPathComponent, icon: destination.path))
        default:
            return failed("Unknown action \(action)")
        }
    }
}
