import Foundation

/// Finds the local Hermes runtime and Obsidian vault so the tray needs no manual paths.
///
/// - Hermes: asks the installed `hermes` launcher itself via its supported
///   `--print-runtime-command` flag, which prints the exact Python and source root it uses.
/// - Vault: reads Obsidian's own vault list. A vault with a `Daily/` folder wins, then the
///   open vault, then the most recently used one.
///
/// Nothing here reads Hermes config, credentials or vault contents.
public enum LocalSetupDetector {
    public struct HermesRuntime: Equatable, Sendable {
        public let python: String
        public let hermesRoot: String
    }

    public static func parseRuntimeCommand(_ data: Data) -> HermesRuntime? {
        guard let argv = try? JSONSerialization.jsonObject(with: data) as? [String],
              let python = argv.first, python.hasPrefix("/"),
              let code = argv.last,
              let start = code.range(of: "sys.path.insert(0, '") else { return nil }
        let tail = code[start.upperBound...]
        guard let end = tail.firstIndex(of: "'") else { return nil }
        let root = String(tail[..<end])
        guard root.hasPrefix("/") else { return nil }
        return HermesRuntime(python: python, hermesRoot: root)
    }

    public static func parseObsidianVaults(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]] else { return nil }
        let manager = FileManager.default
        func isDirectory(_ path: String) -> Bool {
            var directory: ObjCBool = false
            return manager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
        let candidates = vaults.values.compactMap { entry -> (path: String, open: Bool, ts: Double, daily: Bool)? in
            guard let path = entry["path"] as? String, path.hasPrefix("/"), isDirectory(path) else { return nil }
            return (path, entry["open"] as? Bool ?? false, (entry["ts"] as? NSNumber)?.doubleValue ?? 0,
                    isDirectory((path as NSString).appendingPathComponent("Daily")))
        }
        return candidates.max { lhs, rhs in
            (lhs.daily ? 1 : 0, lhs.open ? 1 : 0, lhs.ts) < (rhs.daily ? 1 : 0, rhs.open ? 1 : 0, rhs.ts)
        }?.path
    }

    /// Standard install locations for the `hermes` launcher. GUI apps get no shell PATH.
    public static func hermesLauncherCandidates(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.local/bin/hermes", "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes",
         "\(home)/.hermes/hermes-agent/.hermes/bin/hermes"]
    }

    public static func detectHermes(timeout: TimeInterval = 15) -> HermesRuntime? {
        for launcher in hermesLauncherCandidates() where FileManager.default.isExecutableFile(atPath: launcher) {
            if let output = run(launcher, ["--print-runtime-command"], timeout: timeout),
               let runtime = parseRuntimeCommand(output),
               FileManager.default.isExecutableFile(atPath: runtime.python),
               FileManager.default.fileExists(atPath: "\(runtime.hermesRoot)/tui_gateway/entry.py") {
                return runtime
            }
        }
        return nil
    }

    public static func detectVault(home: String = NSHomeDirectory()) -> String? {
        if let env = ProcessInfo.processInfo.environment["OBSIDIAN_VAULT_PATH"], env.hasPrefix("/"),
           FileManager.default.fileExists(atPath: env) { return env }
        let list = URL(fileURLWithPath: "\(home)/Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: list), data.count < 1_000_000 else { return nil }
        return parseObsidianVaults(data)
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }
}
