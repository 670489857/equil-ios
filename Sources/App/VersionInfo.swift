import Foundation

/// 版本号来自 Info.plist，CI 每次构建自动递增，保证「包名 / App 内」一致。
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    static var text: String { "v\(short) · b\(build)" }
}
