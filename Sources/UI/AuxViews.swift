//
//  AuxViews.swift
//  EquilController
//
//  两个辅助页：BLE 扫描（AAPS 的 BleScanStep）与大剂量输入。
//  大剂量是 AAPS 主页面的功能，独立 App 必须自带。
//

import SwiftUI

// MARK: - 扫描

struct ScannerView: View {
    @ObservedObject var model: EquilControllerModel
    /// 传入时列表可点选（从设置页进来直接换泵）；nil 则只做浏览。
    var onPick: ((EquilControllerModel.DiscoveredDevice) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            // 过滤状态：让人一眼知道列表里为什么只有这么几台
            Section {
                HStack(spacing: 10) {
                    Image(systemName: model.showAllDevices
                          ? "exclamationmark.triangle.fill"
                          : "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(model.showAllDevices ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.showAllDevices ? "诊断模式：显示全部蓝牙设备" : "只显示 Equil 泵")
                            .font(.subheadline.weight(.medium))
                        Text(model.showAllDevices
                             ? "附近的手环、耳机、音箱都会出现，请只认 Equil 开头的名字。"
                             : "名称不以 Equil 开头的设备已被隐藏。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if model.isPaired {
                    HStack {
                        Text("当前已配对")
                        Spacer()
                        Text(String(model.pairedDevice.prefix(8)) + "…")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if model.discovered.isEmpty {
                    emptyState
                } else {
                    ForEach(model.discovered) { dev in
                        if let onPick {
                            Button { onPick(dev); dismiss() } label: { row(dev) }
                                .buttonStyle(.plain)
                        } else {
                            row(dev)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(model.showAllDevices ? "附近 BLE 设备" : "附近的 Equil 泵")
                    Spacer()
                    Text("\(model.discovered.count) 台")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(onPick == nil
                         ? "这只是被动收听广播，不连接、不写入。配对要从「配对」向导里走，因为配对会改写泵的绑定关系。"
                         : "点一下要配对的泵，回到向导里输密码。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("扫描设备")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.scanning ? "停止" : "扫描") {
                    model.scanning ? model.stopScan() : model.startScan()
                }
                .disabled(model.busy)
            }
        }
        .onAppear {
            if !model.scanning { model.startScan() }
        }
        .onDisappear {
            if model.scanning { model.stopScan() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.scanning {
                    ProgressView()
                }
                Text(model.scanning ? "扫描中…" : "尚未扫描")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !model.scanning {
                Text(model.showAllDevices
                     ? "点右上角「扫描」列出附近全部蓝牙设备。"
                     : "点右上角「扫描」查找 Equil 泵。若一台都没有：确认泵已装电池并开机、没被泵控制器 连着、距离 1 米内。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ dev: EquilControllerModel.DiscoveredDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: dev.matchesSerial ? "checkmark.circle.fill" : signalSymbol(dev.rssi))
                .foregroundStyle(dev.matchesSerial ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(dev.matchesSerial ? .green : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(dev.serial.map { "SN \($0)" } ?? "名字里没有 SN")
                    .font(.caption2)
                    .foregroundStyle(dev.serial == nil ? .orange : .secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(dev.rssi) dBm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if dev.matchesSerial {
                    Text("已配对过").font(.caption2).foregroundStyle(.green)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// RSSI 分档：≥-55 强，≥-70 中，其余弱。
    private func signalSymbol(_ rssi: Int) -> String {
        if rssi >= -55 { return "wifi" }
        if rssi >= -70 { return "wifi" }
        return "wifi.exclamationmark"
    }
}

// MARK: - 大剂量输入

struct BolusSheet: View {
    @ObservedObject var model: EquilControllerModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    /// 当前输入值。解析失败按 0 处理，但不会写回输入框。
    private var currentUnits: Double { Double(model.bolusUnits) ?? 0 }
    /// +/− 能加到的上限。跟闸门一致（单次上限与泵侧上限取小），
    /// 避免点上去才发现被拒。
    private var cap: Double { min(model.safety.maxSingleDose, model.pumpConfig.maxBolus) }
    private var stepText: String { Self.format(model.safety.bolusStep) }

    /// 输注速率和预计耗时。速度调到 12 U/min 时 5 U 只要 25 秒，
    /// 而标准 1.5 U/min 要 200 秒 —— 差这么多，不该让人点完才反应过来。
    private var rateHint: String {
        let speed = model.pumpConfig.bolusSpeed
        let units = Double(model.bolusUnits) ?? 0
        guard units > 0 else { return "输注速率 \(speed.label)" }
        let seconds = max(1, (units * Double(speed.secondsPerUnit)).rounded())
        return "输注速率 \(speed.label) · 预计 \(Int(seconds)) 秒"
    }

    /// 按一步增减。始终吸附到步长网格，不然 0.025 连加会攒出 0.07500000000000001。
    private func nudge(_ direction: Double) {
        let step = model.safety.bolusStep
        var v = currentUnits + direction * step
        v = (v / step).rounded() * step
        if v < 0 { v = 0 }
        if v > cap { v = cap }
        model.bolusUnits = Self.format(v)
        focused = false
    }

    /// 去掉尾随零：0.050 → "0.05"，1.000 → "1"。
    private static func format(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "0" : s
    }

    private func stepButton(systemName: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.weight(.bold))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
        .disabled(!enabled)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("大剂量 · 步长 \(stepText) U")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(rateHint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    HStack(alignment: .center, spacing: 16) {
                        stepButton(systemName: "minus", enabled: currentUnits > 0) {
                            nudge(-1)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            TextField("0.00", text: $model.bolusUnits)
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.center)
                                .focused($focused)
                                .fixedSize(horizontal: true, vertical: false)
                            Text("U")
                                .font(.title2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        stepButton(systemName: "plus", enabled: currentUnits < cap) {
                            nudge(1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .padding(.top, 24)

                // 快捷剂量。第一项跟着步长走：步长 0.05 时就是 0.05。
                HStack(spacing: 8) {
                    ForEach([stepText, "0.5", "1", "2", "5"], id: \.self) { v in
                        Button(v) { model.bolusUnits = v }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .font(.footnote)

                VStack(spacing: 8) {
                    InfoRow(label: "泵内余量",
                            value: model.reservoirUnits.map { "\($0) U" } ?? "未读取",
                            level: model.reservoirUnits == nil ? .warning : .unspecified)
                    InfoRow(label: "运行模式", value: model.runMode.displayName,
                            level: model.runMode == .run ? .unspecified : .warning)
                    InfoRow(label: "这一小时已用",
                            value: String(format: "%.2f / %.1f U",
                                          model.safety.usedLastHour(), model.safety.maxPerHour))
                    InfoRow(label: "单次上限",
                            value: String(format: "%.2f U", model.safety.maxSingleDose))
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 20)

                Spacer()

                Button {
                    focused = false
                    dismiss()
                    // 交给安全闸门：可能直接拒绝，也可能弹长按确认页
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        model.sendBolus()
                    }
                } label: {
                    Text("继续")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .disabled(model.busy || !model.activationCompleted)
            }
            .navigationTitle("输注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .onAppear { focused = true }
    }
}
