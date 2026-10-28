import Foundation

/// Your own extension: a folder in ~/Library/Application Support/Starlight/Extensions/ with an
/// extension.json. Each tool runs a command (any language) that gets the arguments as JSON on
/// stdin and prints its result on stdout. Like pi's extensions folder, minus the TypeScript.
///
///     {
///       "name": "Weather",
///       "summary": "Current weather for a city.",
///       "context": "Optional text added to the model's instructions before every question.",
///       "tools": [{
///         "name": "get_weather",
///         "description": "Current weather for a city.",
///         "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]},
///         "command": ["./weather.sh"],
///         "status": "Checking the weather"
///       }]
///     }
///
/// Commands run in the extension's folder with a 15 second limit. They run as you, with your
/// permissions, so only install extensions you trust.
struct ScriptExtension: StarlightExtension {
    struct Manifest: Decodable {
        struct Tool: Decodable {
            let name: String
            let description: String
            let parameters: JSONValue?
            let command: [String]
            let status: String?
        }
        let name: String
        let summary: String?
        let context: String?
        let tools: [Tool]?
    }

    enum Failure: LocalizedError {
        case noManifest, badCommand(String)
        var errorDescription: String? {
            switch self {
            case .noManifest: "no extension.json"
            case .badCommand(let tool): "tool \(tool) has an empty command"
            }
        }
    }

    let id: String
    let name: String
    let summary: String
    let glyph = Glyph.Kind.puzzle
    var isBuiltIn: Bool { false }
    let folder: URL
    let manifest: Manifest

    init(folder: URL) throws {
        let url = folder.appendingPathComponent("extension.json")
        guard let data = try? Data(contentsOf: url) else { throw Failure.noManifest }
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
        for tool in manifest.tools ?? [] where tool.command.isEmpty { throw Failure.badCommand(tool.name) }
        self.folder = folder
        id = "script." + folder.lastPathComponent
        name = manifest.name
        summary = manifest.summary ?? manifest.tools?.first?.description ?? ""
    }

    var toolNames: [String] { manifest.tools?.map(\.name) ?? [] }

    func register(_ api: ExtensionAPI) {
        if let context = manifest.context { api.onBeforeAsk { _ in context } }
        for tool in manifest.tools ?? [] {
            let parameters = (tool.parameters?.any as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
            api.registerTool(AgentTool(
                name: tool.name, description: tool.description, parameters: parameters,
                status: tool.status ?? manifest.name, glyph: .puzzle,
                run: { args in try await Self.run(tool.command, in: folder, input: args) }))
            api.markUserOnly(tool.name)
        }
    }

    private static func run(_ command: [String], in folder: URL, input: [String: Any]) async throws -> ToolResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let first = command[0]
                let executable = first.hasPrefix("/") ? URL(fileURLWithPath: first) : folder.appendingPathComponent(first)
                if FileManager.default.isExecutableFile(atPath: executable.path) {
                    process.executableURL = executable
                    process.arguments = Array(command.dropFirst())
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")  // e.g. ["python3", "tool.py"]
                    process.arguments = command
                }
                process.currentDirectoryURL = folder
                let stdin = Pipe(), stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    return continuation.resume(returning: ToolResult(content: "error: couldn't start \(first): \(error.localizedDescription)"))
                }
                // The time limit starts before anything else, so a script that never reads or never
                // ends can't hang the tool.
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                let json = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                // A script that exits without reading its input mustn't take Starlight down with it
                // (SIGPIPE is ignored at launch; the write just fails).
                try? stdin.fileHandleForWriting.write(contentsOf: json)
                try? stdin.fileHandleForWriting.close()
                // Collected as it arrives, until the script exits (or is stopped): a child process
                // that keeps stdout open can't make this wait forever.
                let collected = Collected()
                let reader = stdout.fileHandleForReading
                reader.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if collected.append(chunk) > 200_000, process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.05)  // the last chunk
                reader.readabilityHandler = nil
                let output = collected.data
                timeout.cancel()
                let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus != 0 {
                    continuation.resume(returning: ToolResult(content: "error (exit \(process.terminationStatus)): \(text.prefix(1000))"))
                } else {
                    let firstLine = text.split(separator: "\n").first.map(String.init)
                    continuation.resume(returning: ToolResult(content: String(text.prefix(4000)), display: firstLine.map { String($0.prefix(80)) }))
                }
            }
        }
    }

    /// Written once when the folder is created. Its name starts with "_", so it isn't loaded;
    /// copy it to a new name to try it.
    static func writeExample(in dir: URL) {
        let example = dir.appendingPathComponent("_example-dice", isDirectory: true)
        try? FileManager.default.createDirectory(at: example, withIntermediateDirectories: true)
        let manifest = """
        {
          "name": "Dice",
          "summary": "Rolls dice. An example extension: copy this folder without the underscore to load it.",
          "tools": [{
            "name": "roll_dice",
            "description": "Roll dice, e.g. when the user asks to roll a die or pick a random number.",
            "parameters": {"type": "object", "properties": {"sides": {"type": "integer", "description": "Sides per die, default 6"}}},
            "command": ["./roll.sh"],
            "status": "Rolling"
          }]
        }
        """
        let script = """
        #!/bin/sh
        # Starlight passes the tool's arguments as JSON on stdin, e.g. {"sides": 20}.
        # Whatever this prints is the result the model reads.
        input=$(cat)
        sides=$(echo "$input" | sed -n 's/.*"sides"[^0-9]*\\([0-9][0-9]*\\).*/\\1/p')
        sides=${sides:-6}
        echo "Rolled a $(( $(od -An -N2 -tu2 /dev/urandom) % sides + 1 )) on a d$sides"
        """
        try? manifest.write(to: example.appendingPathComponent("extension.json"), atomically: true, encoding: .utf8)
        let scriptURL = example.appendingPathComponent("roll.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let readme = """
        # Starlight extensions

        Each folder here is an extension. Starlight loads every folder that has an extension.json,
        except folders whose name starts with "_". After changes, open Settings → Answers → More settings → Reload extensions.

        A tool's command gets its arguments as JSON on stdin and prints the result on stdout.
        The first line of the output is also shown in the notch. Commands run in the extension's
        folder, as you, with a 15 second limit, so only install extensions you trust.

        See _example-dice for a working example.
        """
        try? readme.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }
}

/// Decodes any JSON (for a tool's parameter schema) and hands it back as Foundation objects.
enum JSONValue: Decodable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var any: Any {
        switch self {
        case .object(let o): o.mapValues(\.any)
        case .array(let a): a.map(\.any)
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        }
    }
}

/// Output gathered from a background reader.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    var data: Data { lock.withLock { buffer } }
    /// Adds a chunk; returns the total so far.
    func append(_ chunk: Data) -> Int { lock.withLock { buffer.append(chunk); return buffer.count } }
}
