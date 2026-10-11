import Foundation

/// Minimal reader for `~/.config/parrot/config.toml`.
///
/// This is intentionally NOT a general TOML parser — parrot's config is a
/// flat `key = "value"` / `key = true` file with no tables or arrays, so a
/// tiny line-based parser covers it without pulling in a new dependency.
/// If the format ever grows real TOML features, replace this with a proper
/// library (this is the M7 config work from `.plan/plan.md`, done partially:
/// only `model` and `hotkey` are wired up so far — `inject_mode` and
/// `overlay` are still read as no-ops).
struct ParrotConfig {
    var model: String?
    var hotkey: String?

    static let path = ("~/.config/parrot/config.toml" as NSString).expandingTildeInPath

    static func load() -> ParrotConfig {
        var config = ParrotConfig()
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return config
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hashIndex = line.firstIndex(of: "#") {
                line = String(line[line.startIndex..<hashIndex]).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty, let eq = line.firstIndex(of: "=") else { continue }

            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            switch key {
            case "model": config.model = value
            case "hotkey": config.hotkey = value
            default: break
            }
        }

        return config
    }

    /// Writes `model`/`hotkey` back to `config.toml`, preserving any other
    /// lines (comments, `inject_mode`, `overlay`, …) untouched. Creates the
    /// file and its parent directory if neither exists yet.
    static func save(model: String, hotkey: String) throws {
        var lines: [String] = []
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while lines.last?.isEmpty == true { lines.removeLast() }
        }
        lines = upsert(lines, key: "model", value: model)
        lines = upsert(lines, key: "hotkey", value: hotkey)

        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Replaces the value of an existing `key = "..."` line, or appends one
    /// if the key isn't present yet. Comments and untouched keys keep their
    /// original position in the file.
    private static func upsert(_ lines: [String], key: String, value: String) -> [String] {
        var result = lines
        for i in result.indices {
            let trimmed = result[i].trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let lineKey = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            if lineKey == key {
                result[i] = "\(key) = \"\(value)\""
                return result
            }
        }
        result.append("\(key) = \"\(value)\"")
        return result
    }
}
