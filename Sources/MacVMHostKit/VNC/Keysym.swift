import Foundation

/// A single key transition to send as an RFB KeyEvent.
struct KeyStroke: Equatable {
    let keysym: UInt32
    let down: Bool
}

/// X11 keysyms and helpers to translate text and key names into RFB key events.
///
/// For printable ASCII the keysym equals the character's code point; characters
/// that require Shift on a US keyboard (uppercase letters and the shifted symbol
/// row) are wrapped in Shift press/release, following the noVNC/TigerVNC convention.
enum Keysym {
    static let shift: UInt32 = 0xffe1
    static let control: UInt32 = 0xffe3
    static let alt: UInt32 = 0xffe9 // Option on macOS guests
    static let meta: UInt32 = 0xffe7
    static let command: UInt32 = 0xffeb // Super_L; macOS maps this to Command
    static let returnKey: UInt32 = 0xff0d
    static let tab: UInt32 = 0xff09
    static let escape: UInt32 = 0xff1b
    static let backspace: UInt32 = 0xff08
    static let delete: UInt32 = 0xffff
    static let space: UInt32 = 0x20
    static let left: UInt32 = 0xff51
    static let up: UInt32 = 0xff52
    static let right: UInt32 = 0xff53
    static let down: UInt32 = 0xff54
    static let home: UInt32 = 0xff50
    static let end: UInt32 = 0xff57
    static let pageUp: UInt32 = 0xff55
    static let pageDown: UInt32 = 0xff56

    /// Symbols that require Shift on a US layout (besides uppercase letters).
    private static let shiftedSymbols = Set<Character>("~!@#$%^&*()_+{}|:\"<>?")

    /// Named keys accepted by the `keys` command (case-insensitive). Modifier names
    /// are resolved separately by `modifier(named:)`.
    static func named(_ name: String) -> UInt32? {
        let lowered = name.lowercased()
        switch lowered {
        case "return", "enter", "\n": return returnKey
        case "tab": return tab
        case "esc", "escape": return escape
        case "backspace": return backspace
        case "delete", "del": return delete
        case "space": return space
        case "left": return left
        case "up": return up
        case "right": return right
        case "down": return down
        case "home": return home
        case "end": return end
        case "pageup", "pgup": return pageUp
        case "pagedown", "pgdn": return pageDown
        default:
            // A single printable character maps to its code point.
            if name.count == 1, let scalar = name.unicodeScalars.first, scalar.value >= 0x20, scalar.value < 0x7f {
                return scalar.value
            }
            return nil
        }
    }

    static func modifier(named name: String) -> UInt32? {
        switch name.lowercased() {
        case "shift": return shift
        case "ctrl", "control": return control
        case "alt", "opt", "option": return alt
        case "meta": return meta
        case "cmd", "command", "super", "win": return command
        default: return nil
        }
    }

    static func needsShift(_ character: Character) -> Bool {
        if character.isLetter, character.isUppercase { return true }
        return shiftedSymbols.contains(character)
    }

    /// Expand `text` into the down/up key events required to type it.
    static func keystrokes(forTyping text: String) -> [KeyStroke] {
        var strokes: [KeyStroke] = []
        for character in text {
            let keysym: UInt32
            if character == "\n" || character == "\r" {
                keysym = returnKey
            } else if character == "\t" {
                keysym = tab
            } else if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
                keysym = scalar.value
            } else {
                continue // skip characters we can't represent as a single keysym
            }

            if needsShift(character) {
                strokes.append(KeyStroke(keysym: shift, down: true))
                strokes.append(KeyStroke(keysym: keysym, down: true))
                strokes.append(KeyStroke(keysym: keysym, down: false))
                strokes.append(KeyStroke(keysym: shift, down: false))
            } else {
                strokes.append(KeyStroke(keysym: keysym, down: true))
                strokes.append(KeyStroke(keysym: keysym, down: false))
            }
        }
        return strokes
    }

    /// Parse a chord token like `cmd+space` or `ctrl+c` into modifier keysyms plus
    /// the terminal key. Returns nil if the terminal key is unknown.
    static func parseChord(_ token: String) -> (modifiers: [UInt32], key: UInt32)? {
        var parts = token.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        // A literal "+" key (e.g. "shift++") leaves an empty terminal — treat the
        // trailing empty as the "+" character.
        if token.hasSuffix("+"), parts.count >= 1 {
            parts.append("+")
        }
        guard let last = parts.last, let key = named(last) else { return nil }

        var modifiers: [UInt32] = []
        for part in parts.dropLast() {
            guard let modifier = modifier(named: part) else { return nil }
            modifiers.append(modifier)
        }
        return (modifiers, key)
    }
}
