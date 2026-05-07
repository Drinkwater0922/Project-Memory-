import Foundation

public enum ActivityClassifier {
    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS",
        "ru.keepcoder.Telegram",
        "com.tencent.xinWeChat",
        "com.alibaba.DingTalk",
        "com.hnc.Discord"
    ]

    private static let socialBundleIDs: Set<String> = [
        "com.atebits.Tweetie2",
        "com.bilibili.bilibili-mac"
    ]

    private static let workBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "md.obsidian",
        "com.electron.lark",
        "com.electron.lark.iron",
        "com.openai.chat"
    ]

    private static let chatHosts: [String] = [
        "slack.com", "discord.com", "telegram.org", "wx.qq.com", "web.dingtalk.com"
    ]

    private static let socialHosts: [String] = [
        "twitter.com", "x.com", "weibo.com", "reddit.com",
        "bilibili.com", "xiaohongshu.com", "instagram.com"
    ]

    private static let workHosts: [String] = [
        "github.com", "swift.org", "developer.apple.com",
        "stackoverflow.com", "notion.so", "linear.app"
    ]

    public static func classify(_ candidate: ActivityCandidate) -> ActivityCategory {
        if chatBundleIDs.contains(candidate.bundleID) { return .chat }
        if socialBundleIDs.contains(candidate.bundleID) { return .socialMedia }
        if workBundleIDs.contains(candidate.bundleID) { return .work }

        if SupportedBrowsers.bundleIDs.contains(candidate.bundleID) {
            if let url = candidate.browserURL,
               let host = URLComponents(string: url)?.host?.lowercased() {
                if chatHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return .chat
                }
                if socialHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return .socialMedia
                }
                if workHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return .work
                }
            }
            return .other
        }

        return .other
    }
}
