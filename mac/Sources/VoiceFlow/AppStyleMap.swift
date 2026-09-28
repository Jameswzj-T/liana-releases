import Foundation





enum AppStyleMap {

    private static let chat: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.WeChat",      // 微信
        "com.tencent.WeWorkMac",                            // 企业微信
        "com.apple.MobileSMS",                              // 信息
        "com.tinyspeck.slackmacgap",                        // Slack
        "ru.keepcoder.Telegram", "org.telegram.desktop",    // Telegram
        "com.tencent.qq",                                   // QQ
        "com.hnc.Discord",                                  // Discord
        "com.electron.lark", "com.bytedance.macos.feishu",  // 飞书
        "com.laiwang.DingTalk",                             // 钉钉
        "net.whatsapp.WhatsApp", "WhatsApp",                // WhatsApp
    ]

    private static let code: Set<String> = [
        "com.apple.dt.Xcode",                               // Xcode
        "com.apple.Terminal",                               // 终端
        "com.googlecode.iterm2",                            // iTerm2
        "com.mitchellh.ghostty",                            // Ghostty
        "dev.warp.Warp-Stable",                             // Warp
        "org.alacritty", "co.zeit.hyper",                   // Alacritty / Hyper
        "com.todesktop.230313mzl4w4u92",                    // Cursor
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",  // VS Code
        "com.jetbrains.intellij", "com.jetbrains.pycharm",  // JetBrains
        "com.sublimetext.4", "com.sublimetext.3",           // Sublime
        "dev.zed.Zed", "dev.zed.Zed-Preview",               // Zed
    ]


    static func style(for bundleID: String?) -> String? {
        guard let id = bundleID else { return nil }
        if chat.contains(id) { return "message" }
        if code.contains(id) { return "verbatim" }
        return nil
    }

















    private static let multilineSafe: Set<String> = [

        "com.apple.dt.Xcode",
        "com.sublimetext.4", "com.sublimetext.3",
        "dev.zed.Zed", "dev.zed.Zed-Preview",

        "com.apple.Notes", "com.apple.TextEdit",
        "md.obsidian", "notion.id", "net.shinyfrog.bear",
        "com.lukilabs.lukiapp",                             // Craft
        "com.ulyssesapp.mac", "pro.writer.mac",             // Ulysses / iA Writer
    ]


    static func multiline(for bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return multilineSafe.contains(id)
    }
}
