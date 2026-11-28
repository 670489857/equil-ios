//
//  AuditLog.swift
//  EquilController
//
//  输注审计日志 —— 追加写 JSONL，落盘在 App 沙盒里，可导出。
//
//  为什么必须有这个：
//   这一版 App 没有 Nightscout 同步、没有云端备份。一旦出现"我到底打没打、
//   打了多少、什么时候打的"这种疑问，内存里的滚动日志（重启即失）说明不了任何问题。
//   审计文件按行追加，崩溃也不会丢已写入的部分。
//
//  隐私：日志里不写配对密码、不写 device 密文。只记 SN 的后 6 位和剂量。
//

import Foundation
import OSLog

final class AuditLog {

    static let shared = AuditLog()

    private let queue = DispatchQueue(label: "app.equil.audit", qos: .utility)
    private let logger = Logger(subsystem: "app.equil.controller", category: "audit")
    /// 时间戳用带本地偏移的 ISO8601（2026-11-09T16:00:26.123+08:00）。
    ///
    /// 以前不设 timeZone，ISO8601DateFormatter 默认按 GMT 输出，
    /// 于是东八区用户看到的历史记录整体慢 8 小时。存带偏移的绝对时刻既无歧义，
    /// 导出的 JSONL 用文本编辑器打开也是本地时间。
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone.current
        return f
    }()

    private init() {
        ensureDirectory()
    }

    // MARK: 事件定义

    enum Event: String {
        case appLaunch      = "app_launch"
        case pairing        = "pairing"
        case bolusRequested = "bolus_requested"
        case bolusBlocked   = "bolus_blocked"
        case bolusConfirmed = "bolus_confirmed"
        case bolusResult    = "bolus_result"
        case tempBasalSet   = "temp_basal_set"
        case runModeChange  = "run_mode_change"
        case resumeSuspend  = "resume_suspend"
        case reservoirQuery = "reservoir_query"
        case settingsChange = "settings_change"
    }

    enum Outcome: String {
        case ok      = "ok"
        case failed  = "failed"
        case denied  = "denied"
        case pending = "pending"
    }

    // MARK: 写入

    /// 追加一条记录。所有参数都进 JSON，写失败只打 os_log，绝不抛错打断主流程。
    func record(_ event: Event,
                units: Double? = nil,
                outcome: Outcome = .ok,
                serialNumber: String? = nil,
                note: String? = nil) {
        var payload: [String: Any] = [
            "ts": isoFormatter.string(from: Date()),
            "event": event.rawValue,
            "outcome": outcome.rawValue,
        ]
        if let units { payload["units"] = units }
        if let serialNumber { payload["sn"] = String(serialNumber.suffix(6)) }
        if let note { payload["note"] = note }
        payload["app"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let message = line
        queue.async { [weak self] in
            guard let self else { return }
            guard let url = self.currentFileURL() else { return }
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let bytes = message.data(using: .utf8) {
                    try handle.write(contentsOf: bytes)
                }
            } catch {
                self.logger.error("审计写入失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        logger.info("\(message, privacy: .public)")
    }

    // MARK: 读取 / 导出

    /// 当前月份的日志文件地址。给 ShareLink 导出用。
    func currentFileURL() -> URL? {
        guard let dir = directoryURL() else { return nil }
        let url = dir.appendingPathComponent(fileName())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// 最近 N 条记录，按时间正序返回。UI 里做"最近输注"面板用。
    func recentLines(limit: Int = 50) -> [String] {
        guard let dir = directoryURL() else { return [] }
        let url = dir.appendingPathComponent(fileName())
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(limit))
    }

    /// 列出所有历史日志文件（按月份），供导出全部。
    func allFileURLs() -> [URL] {
        guard let dir = directoryURL() else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: 私有

    private func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "audit-\(f.string(from: Date())).jsonl"
    }

    private func directoryURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("EquilAudit", isDirectory: true)
    }

    private func ensureDirectory() {
        guard let dir = directoryURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
