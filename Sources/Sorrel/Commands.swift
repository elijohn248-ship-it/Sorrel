import AppKit

// MARK: - Commands

struct Command {
    let id: String
    let title: String
    let action: () -> Void
}

final class Commands {
    static let shared = Commands()
    private(set) var all: [Command] = []
    private var byID: [String: Command] = [:]

    func register(_ id: String, _ title: String, _ action: @escaping () -> Void) {
        let c = Command(id: id, title: title, action: action)
        all.append(c)
        byID[id] = c
    }

    @discardableResult
    func run(_ id: String) -> Bool {
        guard let c = byID[id] else { return false }
        // Menu commands still work after the last normal window has been closed.
        if let app = AppDelegate.shared, app.main == nil,
           !["window.new", "window.close", "tab.close", "mini.new", "private.new", "settings.open"].contains(id) {
            app.showMainWindow()
        }
        c.action()
        return true
    }

    func title(_ id: String) -> String? { byID[id]?.title }
}

// MARK: - Keybindings

/// Shortcuts live in keybindings.json as { "cmd+shift+c": "tab.copyURL", "cmd+k cmd+s": "sidebar.toggle" }.
/// A space between strokes makes a chord. Setting a key to null removes a default.
final class Keybindings {
    static let shared = Keybindings()

    static let defaults: [(String, String)] = [
        ("cmd+t", "tab.new"),
        ("cmd+l", "tab.editURL"),
        ("cmd+w", "tab.close"),
        ("cmd+shift+t", "tab.reopen"),
        ("cmd+r", "tab.reload"),
        ("cmd+shift+r", "tab.hardReload"),
        ("cmd+d", "tab.togglePin"),
        ("cmd+shift+d", "tab.toggleFavorite"),
        ("cmd+shift+c", "tab.copyURL"),
        ("cmd+shift+o", "tab.openInFallback"),
        ("ctrl+tab", "tab.next"),
        ("ctrl+shift+tab", "tab.previous"),
        ("alt+cmd+down", "tab.next"),
        ("alt+cmd+up", "tab.previous"),
        ("cmd+[", "nav.back"),
        ("cmd+]", "nav.forward"),
        ("cmd+s", "sidebar.toggle"),
        ("cmd+f", "find.show"),
        ("cmd+=", "view.zoomIn"),
        ("cmd+-", "view.zoomOut"),
        ("cmd+0", "view.zoomReset"),
        ("alt+cmd+right", "space.next"),
        ("alt+cmd+left", "space.previous"),
        ("alt+cmd+n", "mini.new"),
        ("cmd+o", "mini.expand"),
        ("cmd+n", "window.new"),
        ("cmd+shift+w", "window.close"),
        ("ctrl+cmd+n", "folder.new"),
        ("cmd+shift+n", "private.new"),
        ("cmd+p", "tab.print"),
        ("alt+cmd+l", "downloads.show"),
        ("cmd+y", "history.show"),
        ("cmd+shift+delete", "data.clearRecent"),
        ("cmd+,", "settings.open"),
        ("cmd+k cmd+r", "config.reload"),
        ("cmd+k cmd+t", "theme.edit"),
        ("ctrl+shift+=", "split.add"),
        ("ctrl+shift+-", "split.separate"),
        ("ctrl+shift+]", "split.focusNext"),
        ("ctrl+shift+[", "split.focusPrevious"),
    ] + (1...9).map { ("ctrl+\($0)", "space.\($0)") }
      + (1...9).map { ("cmd+\($0)", "tab.select.\($0)") }

    private var map: [[String]: String] = [:]
    private var pending: [String] = []
    private var pendingExpiry = Date.distantPast

    private init() { reload() }

    func reload() {
        var merged: [String: String?] = [:]
        for (k, v) in Self.defaults { merged[k] = v }

        // Reference copy of the defaults, rewritten each launch.
        let ref = Dictionary(uniqueKeysWithValues: Self.defaults.map { ($0.0, $0.1) })
        if let data = try? JSONSerialization.data(withJSONObject: ref, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.keybindingDefaults, options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: Paths.keybindings.path) {
            try? "{\n}\n".write(to: Paths.keybindings, atomically: true, encoding: .utf8)
        }
        if let data = try? Data(contentsOf: Paths.keybindings),
           let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in user {
                let key = Self.normalize(sequence: k).joined(separator: " ")
                // A user binding replaces the default that sits on the same keys.
                for existing in merged.keys where Self.normalize(sequence: existing).joined(separator: " ") == key {
                    merged[existing] = nil as String?
                }
                merged[k] = v as? String
            }
        }
        map = [:]
        for (k, v) in merged {
            guard let v, !v.isEmpty else { continue }
            let seq = Self.normalize(sequence: k)
            if !seq.isEmpty { map[seq] = v }
        }
        pending = []
    }

    // MARK: Parsing

    static func normalize(sequence: String) -> [String] {
        sequence.lowercased().split(separator: " ").compactMap { normalize(stroke: String($0)) }
    }

    static func normalize(stroke: String) -> String? {
        var parts = stroke.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" means the plus key.
        if stroke.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard var key = parts.last, !key.isEmpty else { return nil }
        var mods: Set<String> = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "meta", "super": mods.insert("cmd")
            case "ctrl", "control": mods.insert("ctrl")
            case "alt", "opt", "option": mods.insert("alt")
            case "shift": mods.insert("shift")
            default: return nil
            }
        }
        switch key {
        case "return": key = "enter"
        case "esc": key = "escape"
        case "plus": key = "+"
        case "backspace": key = "delete"
        default: break
        }
        let ordered = ["ctrl", "alt", "shift", "cmd"].filter { mods.contains($0) }
        return (ordered + [key]).joined(separator: "+")
    }

    static func stroke(for event: NSEvent) -> String? {
        var key: String
        switch event.keyCode {
        case 48: key = "tab"
        case 36, 76: key = "enter"
        case 53: key = "escape"
        case 49: key = "space"
        case 51: key = "delete"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        default:
            key = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "").lowercased()
        }
        guard !key.isEmpty else { return nil }
        let f = event.modifierFlags
        var mods: [String] = []
        if f.contains(.control) { mods.append("ctrl") }
        if f.contains(.option) { mods.append("alt") }
        if f.contains(.shift) { mods.append("shift") }
        if f.contains(.command) { mods.append("cmd") }
        return (mods + [key]).joined(separator: "+")
    }

    // MARK: Handling

    /// Returns true when the event was a shortcut (or part of a chord) and has been handled.
    func handle(_ event: NSEvent) -> Bool {
        guard let stroke = Self.stroke(for: event) else { return false }
        if Date() > pendingExpiry { pending = [] }

        let candidate = pending + [stroke]
        if let id = map[candidate] {
            pending = []
            return Commands.shared.run(id)
        }
        if map.keys.contains(where: { $0.count > candidate.count && Array($0.prefix(candidate.count)) == candidate }) {
            pending = candidate
            pendingExpiry = Date().addingTimeInterval(1.5)
            return true
        }
        if !pending.isEmpty {
            pending = []
            if let id = map[[stroke]] { return Commands.shared.run(id) }
        }
        return false
    }

    /// The first single-stroke shortcut for a command, for showing in menus.
    func menuEquivalent(for commandID: String) -> (key: String, mask: NSEvent.ModifierFlags)? {
        let strokes = map.filter { $0.value == commandID && $0.key.count == 1 }.map { $0.key[0] }.sorted()
        guard let stroke = strokes.first else { return nil }
        var parts = stroke.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if stroke.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let name = parts.last else { return nil }
        var mask: NSEvent.ModifierFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd": mask.insert(.command)
            case "ctrl": mask.insert(.control)
            case "alt": mask.insert(.option)
            case "shift": mask.insert(.shift)
            default: break
            }
        }
        let key: String
        switch name {
        case "tab": key = "\t"
        case "enter": key = "\r"
        case "escape": key = "\u{1b}"
        case "space": key = " "
        case "delete": key = "\u{08}"
        case "left": key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "up": key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: key = name
        }
        return (key, mask)
    }

    // MARK: Editing from the Settings window

    private func readUserFile() -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.keybindings),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return d
    }

    private func writeUserFile(_ d: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Paths.keybindings, options: .atomic)
        }
        reload()
    }

    /// The command currently on a stroke, if any.
    func command(onStroke stroke: String) -> String? { map[[stroke]] }

    /// Gives a command one shortcut (replacing its others), or none when `stroke` is nil.
    func setShortcut(_ stroke: String?, for commandID: String) {
        var user = readUserFile()
        for (k, v) in user where (v as? String) == commandID { user[k] = nil }
        for (k, v) in Self.defaults where v == commandID {
            if let stroke, Self.normalize(sequence: k) == [stroke] {
                user[k] = nil            // the default already says this
            } else {
                user[k] = NSNull()       // switch the default off
            }
        }
        if let stroke, !Self.defaults.contains(where: { Self.normalize(sequence: $0.0) == [stroke] && $0.1 == commandID }) {
            user[stroke] = commandID
        }
        writeUserFile(user)
    }

    func resetAll() { writeUserFile([:]) }

    /// Every shortcut for a command, readable, shortest first.
    func displayAll(for commandID: String) -> String {
        map.filter { $0.value == commandID }.map { $0.key }
            .sorted { ($0.count, $0.joined()) < ($1.count, $1.joined()) }
            .map { seq in seq.map { Self.pretty($0) }.joined(separator: " ") }
            .joined(separator: "   ")
    }

    static func pretty(_ stroke: String) -> String {
        var parts = stroke.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if stroke.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        let key = parts.last ?? ""
        var out = ""
        for m in parts.dropLast() {
            switch m {
            case "ctrl": out += "⌃"
            case "alt": out += "⌥"
            case "shift": out += "⇧"
            case "cmd": out += "⌘"
            default: break
            }
        }
        let names = ["tab": "⇥", "enter": "↩", "escape": "⎋", "space": "Space", "delete": "⌫",
                     "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return out + (names[key] ?? key.uppercased())
    }

    /// A readable form like ⌘⇧C, for the welcome page and command bar.
    func display(for commandID: String) -> String? {
        let seqs = map.filter { $0.value == commandID }.map { $0.key }.sorted { $0.count < $1.count }
        guard let seq = seqs.first else { return nil }
        return seq.map { stroke -> String in
            var parts = stroke.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            if stroke.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
            let key = parts.last ?? ""
            var out = ""
            for m in parts.dropLast() {
                switch m {
                case "ctrl": out += "⌃"
                case "alt": out += "⌥"
                case "shift": out += "⇧"
                case "cmd": out += "⌘"
                default: break
                }
            }
            let names = ["tab": "⇥", "enter": "↩", "escape": "⎋", "space": "Space", "delete": "⌫",
                         "left": "←", "right": "→", "up": "↑", "down": "↓"]
            return out + (names[key] ?? key.uppercased())
        }.joined(separator: " ")
    }
}
