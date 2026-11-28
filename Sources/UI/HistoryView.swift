//
//  HistoryView.swift
//  EquilController
//
//  对应 AAPS 4.0 的 EquilHistoryScreen。
//
//  两套记录并存，来源不同：
//  - 「泵端历史」：泵自己写的事件库，按绝对序号寻址（1…2000 环形），
//    每条一条 CmdHistoryGet，读到本机后按序号倒序显示。换手机也还在。
//  - 「输注与操作记录」：本机审计日志，只记这台手机下发过什么，换手机就没了。
//  AAPS 会在每次连接后自动补读泵端新增记录；这里没有后台循环，改成手动触发、
//  一次最多 20 条，避免长时间占用 BLE。
//

import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: EquilControllerModel

    @State private var lines: [String] = []
    /// 未识别记录默认折叠。
    @State private var showUnmapped = false

    /// 认得出语义的记录，按泵给的时间顺序（读取时已按序号倒序）。
    private var knownRecords: [PumpHistoryRecord] {
        model.pumpHistory.filter { !$0.isUnmapped }
    }
    /// 语义未公开的记录，折叠显示。
    private var unmappedRecords: [PumpHistoryRecord] {
        model.pumpHistory.filter { $0.isUnmapped }
    }

    @ViewBuilder
    private static func historyRow(_ rec: PumpHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(rec.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(rec.severity.tint)
                Spacer()
                Text(Self.fmt(rec.time))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(rec.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(rec.isUnmapped ? 2 : 1)
        }
        .padding(.vertical, 1)
    }

    var body: some View {
        List {
            Section {
                if let t = model.lastDataTime {
                    InfoLine("最后通信", Self.fmt(t))
                } else {
                    InfoLine("最后通信", "—")
                }
                InfoLine("电池", model.batteryPercent.map { "\($0)%" } ?? "—")
                InfoLine("胰岛素余量", model.reservoirUnits.map { "\($0) U" } ?? "—")
                InfoLine("运行模式", model.runMode.displayName)
            } header: {
                Text("泵状态快照")
            }

            Section {
                if let c = model.pumpClock {
                    InfoLine("泵时钟", Self.fmt(c))
                    InfoLine("与手机相差", Self.offsetText(from: c))
                    if Self.clockLooksUnset(c) {
                        Text("泵的时钟还停在 \(Calendar.current.component(.year, from: c)) 年（没校过时），所以泵端记录的时间都不对。点下面的「校时」把手机时间写进泵，之后的记录就一致了。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("读一次泵端历史就能看到泵时钟")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.syncPumpTime()
                } label: {
                    HStack(spacing: 8) {
                        Text(model.busy ? "校时中…" : "校时（写入手机时间）")
                        Spacer()
                        if model.busy { ProgressView() }
                    }
                }
                .disabled(model.busy || !model.isPaired)
            } header: {
                Text("泵时钟")
            } footer: {
                Text("泵端记录里的年月日时分秒取自泵自己的时钟，跟手机无关。校时只影响之后新写的记录，旧记录不会改。")
            }

            Section {
                if model.pumpHistoryReading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.pumpHistoryMessage).font(.subheadline)
                        Spacer()
                    }
                } else if model.pumpHistory.isEmpty {
                    Text(model.pumpHistoryMessage.isEmpty
                         ? "点右上角「读取」从泵里取最近 20 条事件"
                         : model.pumpHistoryMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knownRecords) { rec in
                        Self.historyRow(rec)
                    }
                    // 泵会不停写「没有公开语义」的记录（port 4 / type 0 这类），
                    // 一条条顶在列表里全是「未识别」，把真正的事件挤下去了。
                    // 默认折叠：列表只留认识的事件，原始三元组放在展开项里备查。
                    if !unmappedRecords.isEmpty {
                        DisclosureGroup(isExpanded: $showUnmapped) {
                            ForEach(unmappedRecords) { rec in
                                Self.historyRow(rec)
                            }
                        } label: {
                            Text("未识别记录 \(unmappedRecords.count) 条")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("泵端历史")
                    Spacer()
                    if !model.pumpHistory.isEmpty {
                        Button("更早 20 条") { model.loadOlderPumpHistory() }
                            .font(.caption)
                            .disabled(model.pumpHistoryReading || !model.isPaired || model.busy
                                      || (model.pumpHistory.last?.index ?? 1) <= 1)
                    }
                    Button(model.pumpHistoryReading ? "读取中…" : "读取") {
                        model.readPumpHistory()
                    }
                    .font(.caption)
                    .disabled(model.pumpHistoryReading || !model.isPaired || model.busy)
                }
            } footer: {
                Text("泵内事件库，按绝对序号寻址，每条一次命令往返。一次读最近 20 条；点「更早 20 条」往回翻，直到序号 1。换手机也还在。")
            }

            Section {
                if lines.isEmpty {
                    Text("暂无记录").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, raw in
                        AuditRow(raw: raw)
                    }
                }
            } header: {
                HStack {
                    Text("输注与操作记录")
                    Spacer()
                    Button("刷新") { load() }.font(.caption)
                }
            } footer: {
                Text("来自本机审计日志，按行追加，崩溃不丢已写入部分。")
            }
        }
        .listStyle(.insetGrouped)
        .onAppear(perform: load)
        .navigationTitle("历史")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() {
        lines = AuditLog.shared.recentLines(limit: 300)
    }

    private static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    /// 泵时钟与手机的差值。正值＝泵慢（手机走在前头）。
    ///
    /// 只在读历史/校时那一刻有意义，所以标签写「相差」而不是实时值。
    private static func offsetText(from pump: Date) -> String {
        let diff = Int(Date().timeIntervalSince(pump).rounded())
        let a = abs(diff)
        if a < 60 { return "一致" }
        let h = a / 3600
        let m = (a % 3600) / 60
        let s = a % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) 小时") }
        if m > 0 { parts.append("\(m) 分") }
        if h == 0, s > 0 { parts.append("\(s) 秒") }
        return (diff > 0 ? "泵慢 " : "泵快 ") + parts.joined(separator: " ")
    }

    /// 泵 RTC 没设过时会停在 2000-01-01，这种年份明显不是「差几分钟」而是根本没校时。
    private static func clockLooksUnset(_ d: Date) -> Bool {
        Calendar.current.component(.year, from: d) < 2020
    }
}

private struct InfoLine: View {
    let label: String
    let value: String
    init(_ l: String, _ v: String) { label = l; value = v }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}

/// 把一行 JSONL 渲染成可读的两列。解析失败就原样显示——审计日志宁可难看也不能丢。
private struct AuditRow: View {
    let raw: String

    var body: some View {
        if let obj = Self.parse(raw) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(eventLabel(obj["event"] as? String ?? "?"))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let units = obj["units"] as? Double, units > 0 {
                        Text(String(format: "%.2f U", units))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    if let ts = obj["ts"] as? String {
                        Text(shortTime(ts)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let outcome = obj["outcome"] as? String {
                        Text(outcomeText(outcome))
                            .font(.caption2)
                            .foregroundStyle(outcomeColor(outcome))
                    }
                    if let note = obj["note"] as? String, !note.isEmpty {
                        Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 1)
        } else {
            Text(raw).font(.system(size: 10, design: .monospaced)).lineLimit(2)
        }
    }

    private static func parse(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return o
    }

    /// 把 ISO8601 时间戳转成本地时区显示。
    ///
    /// 1.17 及更早版本写的是 `2026-11-09T08:00:26.123Z`（UTC），
    /// 旧实现直接截第 11–19 位，于是东八区看到的时间整体早 8 小时。
    /// 这里改成真正解析再按本地时区排版：老记录（Z）和新记录（+08:00）都能正确显示。
    private func shortTime(_ iso: String) -> String {
        guard let date = Self.parseISO(iso) else {
            // 解析不了才退回原来的截取，宁可不好看也不丢原始串。
            guard iso.count >= 19 else { return iso }
            let idx = iso.index(iso.startIndex, offsetBy: 11)
            let end = iso.index(iso.startIndex, offsetBy: 19)
            return String(iso[idx..<end])
        }
        // 跨天的记录补上日期，否则昨天的 07:55 和今天的 07:55 长得一样。
        let f = Calendar.current.isDateInToday(date) ? Self.sameDayClock : Self.otherDayClock
        return f.string(from: date)
    }

    private static func parseISO(_ s: String) -> Date? {
        if let d = fracISO.date(from: s) { return d }
        return plainISO.date(from: s)
    }

    private static let fracISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let sameDayClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private static let otherDayClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()

    private func eventLabel(_ e: String) -> String {
        switch e {
        case "app_launch":      return "启动"
        case "pairing":         return "配对"
        case "bolus_requested": return "请求大剂量"
        case "bolus_blocked":   return "被拦截"
        case "bolus_confirmed": return "确认大剂量"
        case "bolus_result":    return "输注结果"
        case "temp_basal_set":  return "设置临时基础率"
        case "run_mode_change": return "切换运行模式"
        case "resume_suspend":  return "暂停/恢复"
        case "reservoir_query": return "查询余量"
        case "settings_change": return "修改设置"
        default:                return e
        }
    }

    private func outcomeText(_ o: String) -> String {
        switch o {
        case "ok":      return "成功"
        case "failed":  return "失败"
        case "denied":  return "已阻止"
        case "pending": return "进行中"
        default:        return o
        }
    }

    private func outcomeColor(_ o: String) -> Color {
        switch o {
        case "ok":      return .green
        case "failed":  return .red
        case "denied":  return .orange
        default:        return .secondary
        }
    }
}
