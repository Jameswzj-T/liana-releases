import Foundation




@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    Lang.isChinese ? zh : en
}

enum Lang {




    static let isChinese: Bool = {
        if let forced = ProcessInfo.processInfo.environment["VF_LANG"]?.lowercased() {
            return forced.hasPrefix("zh") || forced.hasPrefix("cn")
        }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }()
}
