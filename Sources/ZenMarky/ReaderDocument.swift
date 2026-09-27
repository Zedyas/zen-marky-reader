import Foundation

enum DocumentFormat {
    case markdown, html

    static let extensions: [String: DocumentFormat] = [
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "html": .html, "htm": .html
    ]

    static func of(_ url: URL) -> DocumentFormat? {
        extensions[url.pathExtension.lowercased()]
    }
}

struct ReaderDocument {
    private static let byteOrderMark = Data([0xEF, 0xBB, 0xBF])

    let url: URL
    let format: DocumentFormat
    var text: String
    // Foundation drops a leading UTF-8 byte order mark when decoding; it is put back on write.
    private let hasByteOrderMark: Bool

    init(url: URL) throws {
        // Symlinks are followed so the file check and the resource directory apply to the real file.
        let url = url.resolvingSymlinksInPath()
        guard url.isFileURL, let format = DocumentFormat.of(url) else { throw DocumentError.unsupportedType }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw DocumentError.unsupportedType }
        guard (values.fileSize ?? 0) <= 10_000_000 else { throw DocumentError.tooLarge }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw DocumentError.notUTF8 }
        self.hasByteOrderMark = data.starts(with: Self.byteOrderMark)
        self.text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        self.url = url
        self.format = format
    }

    func write() throws {
        var data = hasByteOrderMark ? Self.byteOrderMark : Data()
        data.append(contentsOf: Array(text.utf8))
        try data.write(to: url, options: .atomic)
    }
}

enum DocumentError: LocalizedError {
    case unsupportedType, tooLarge, notUTF8, rendererUnavailable, taskNotFound, documentChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Choose a Markdown file (.md, .markdown, .mdown, .mkd) or an HTML file (.html, .htm)."
        case .tooLarge: "This file is larger than 10 MB. Open a smaller file."
        case .notUTF8: "This file is not UTF-8 text. Convert it to UTF-8 and open it again."
        case .rendererUnavailable: "The document renderer could not load. Try rebuilding Zen Marky."
        case .taskNotFound: "The task could not be found in the file. Reload the document and try again."
        case .documentChanged: "The file changed on disk since it was opened, so it was reloaded instead. Click the task again."
        }
    }
}

// Links in the rendered page that ask the app to act. Page scripts are off, so a
// click on one reaches the app as a navigation, which it cancels and handles.
// The URLs are opaque ("marky-task:3"), so the number is read from the full string.
enum PageAction: Equatable {
    case toggleTask(line: Int)
    case copyCode(block: Int)

    init?(_ url: URL) {
        let parts = url.absoluteString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "marky-task": self = .toggleTask(line: number)
        case "marky-copy": self = .copyCode(block: number)
        default: return nil
        }
    }
}

enum TaskList {
    // Flips the rendered checkbox for a line in place. Runs inside a function so
    // nothing is declared in the page's global scope, which would fail on the next call.
    static func checkboxUpdateScript(line: Int) -> String {
        """
        (() => {
          const box = document.querySelector('a.task-toggle[href="marky-task:\(line)"]');
          if (!box) return false;
          box.setAttribute('aria-checked', box.getAttribute('aria-checked') === 'true' ? 'false' : 'true');
          return true;
        })()
        """
    }

    // True when the given line reads the same in both texts, so a checkbox rendered
    // from `rendered` still points at the same item in `current`.
    static func sameLine(_ line: Int, in rendered: String, and current: String) -> Bool {
        let before = rendered.components(separatedBy: "\n")
        let after = current.components(separatedBy: "\n")
        return before.indices.contains(line) && after.indices.contains(line) && before[line] == after[line]
    }

    // Flips the "[ ]" or "[x]" marker of the task item that starts on the given
    // zero-based line. The line numbers come from markdown-it's block map, which
    // counts newline-separated lines the same way this does.
    static func toggling(line: Int, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line),
              let match = lines[line].firstMatch(of: /^\s*(?:[-+*]|\d+[.)])\s+\[([ xX])\](?=\s)/) else { return nil }
        let checked = match.1 != " "
        lines[line].replaceSubrange(match.1.startIndex..<match.1.endIndex, with: checked ? " " : "x")
        return lines.joined(separator: "\n")
    }
}

enum LocalResource {
    // Resolve symlinks before checking containment so a document cannot embed
    // arbitrary files outside its own directory through a relative URL.
    static func resolve(_ request: URL, within directory: URL) -> URL? {
        guard request.scheme == "marky-local", request.host == "document" else { return nil }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let relativePath = String(request.path.drop(while: { $0 == "/" }))
        let requestedFile = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: requestedFile.path) else { return nil }
        let candidate = requestedFile.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }
}

// Files opened most recently, newest first, stored as paths in user defaults.
// Kept by the app because the system recent list is not populated for this app.
enum RecentDocuments {
    static let key = "recentDocuments"
    static let limit = 10

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func note(_ url: URL) {
        UserDefaults.standard.set(Array(noting(url.path, in: UserDefaults.standard.stringArray(forKey: key) ?? [])), forKey: key)
    }

    static func noting(_ path: String, in paths: [String]) -> [String] {
        Array(([path] + paths.filter { $0 != path }).prefix(limit))
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// The files open at quit, by window and tab order, so the next launch can reopen them.
struct ReaderSession: Codable, Equatable {
    struct Window: Codable, Equatable {
        var files: [String]
        var selected: String?
        var frame: String
        var groups: [Group] = []
    }

    // A tab group, with its tabs by file. A file is open in one tab at most, so the path names the tab.
    struct Group: Codable, Equatable {
        var name: String
        var color: GroupColor
        var collapsed: Bool
        var files: [String]
    }

    static let key = "session"
    // Front window first.
    var windows: [Window] = []
    var scrollOffsets: [String: Double] = [:]

    static func load() -> ReaderSession? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ReaderSession.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    // Drops files that no longer exist and the groups and windows left with none.
    func existing(_ exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ReaderSession {
        var kept = self
        kept.windows = windows.compactMap { window in
            var window = window
            window.files = window.files.filter(exists)
            window.groups = window.groups.compactMap { group in
                var group = group
                group.files = group.files.filter(exists)
                return group.files.isEmpty ? nil : group
            }
            return window.files.isEmpty ? nil : window
        }
        return kept
    }
}
