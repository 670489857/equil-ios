import Foundation

/// 版本信息统一从这里取，保证「包名 / App 内展示」同源，随每次构建自动递增
enum AppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// 例如 v3.1.12 (build 12)
    static var versionText: String { "v\(shortVersion) · b\(buildNumber)" }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "科研泵"
    }
}
