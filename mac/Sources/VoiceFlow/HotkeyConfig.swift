import AppKit




struct HotkeyConfig: Codable, Equatable {
    var keyCode: Int
    var modifierRaw: UInt          // NSEvent.ModifierFlags rawValue
    var isModifierOnly: Bool
    var display: String

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRaw) }

    static let `default` = HotkeyConfig(
        keyCode: 2,  // 'D'
        modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        isModifierOnly: false,
        display: "⌘⇧D"
    )


    static let editDefault = HotkeyConfig(
        keyCode: 14,  // 'E'
        modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        isModifierOnly: false,
        display: "⌘⇧E"
    )



    static let fixDefault = HotkeyConfig(
        keyCode: 32,  // 'U'
        modifierRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        isModifierOnly: false,
        display: "⌘⇧U"
    )


    static func modifierSymbol(keyCode: Int) -> String? {
        switch keyCode {
        case 55: return "左⌘"; case 54: return "右⌘"
        case 56: return "左⇧"; case 60: return "右⇧"
        case 58: return "左⌥"; case 61: return "右⌥"
        case 59: return "左⌃"; case 62: return "右⌃"
        case 63: return "fn"
        default:  return nil
        }
    }


    var prettyDisplay: String {
        if isModifierOnly, let s = HotkeyConfig.modifierSymbol(keyCode: keyCode) { return s }
        return display
    }

    static func load(key: String, fallback: HotkeyConfig) -> HotkeyConfig {
        if let data = UserDefaults.standard.data(forKey: key),
           let cfg = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            return cfg
        }
        return fallback
    }

    func save(key: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }


    static var current: HotkeyConfig { load(key: "hotkeyConfig", fallback: .default) }
    func save() { save(key: "hotkeyConfig") }


    static var currentEdit: HotkeyConfig { load(key: "editHotkeyConfig", fallback: editDefault) }
    func saveEdit() { save(key: "editHotkeyConfig") }


    static var currentFix: HotkeyConfig { load(key: "fixHotkeyConfig", fallback: fixDefault) }
    func saveFix() { save(key: "fixHotkeyConfig") }
}
