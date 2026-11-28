//
//  BolusConfirmView.swift
//  EquilController
//
//  输注二次确认页。长按 1.5 秒才放行 —— 单击误触不会打出胰岛素。
//
//  这里刻意不做"输入相同数值"的确认方式：小剂量（0.05U）时输入太轻率，
//  反而比长按更容易蒙混过关。长按的物理连续性更接近"我确实要这么做"。
//

import SwiftUI
import UIKit

struct BolusConfirmView: View {

    let units: Double
    let reason: String
    /// 非 nil = 方波，值为时长（分钟）。确认页要把「匀速推完」讲清楚，
    /// 否则长按确认的人会以为是立刻推完这么多。
    var extendedMinutes: Int? = nil
    let reservoirUnits: Int?
    let maxSingleDose: Double
    let maxPerHour: Double
    let usedLastHour: Double
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var progress: CGFloat = 0
    @State private var pressing = false
    @Environment(\.dismiss) private var dismiss

    private let holdDuration: Double = 1.5

    var body: some View {
        VStack(spacing: 20) {

            // 标题
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(extendedMinutes == nil ? "确认输注" : "确认方波")
                    .font(.headline)
            }
            .padding(.top, 8)

            // 剂量
            VStack(spacing: 4) {
                Text(String(format: "%.2f", units))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.red)
                    .monospacedDigit()
                Text(extendedMinutes.map { "单位 (U) · 方波 \($0) 分钟" } ?? "单位 (U) 大剂量")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 触发原因
            Text(reason)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            Divider()

            // 上下文
            VStack(spacing: 8) {
                row("泵内余量", reservoirUnits.map { "\($0) U" } ?? "未读取")
                row("预计输注后", reservoirUnits.map { String(format: "≈%.1f U", Double($0) - units) } ?? "未知")
                if let m = extendedMinutes, m > 0 {
                    row("方波速率", String(format: "%.2f U/h", units * 60 / Double(m)))
                    row("结束时间",
                        Date().addingTimeInterval(Double(m) * 60)
                            .formatted(date: .omitted, time: .shortened))
                }
                row("单次上限", String(format: "%.2f U", maxSingleDose))
                row("这一小时已用", String(format: "%.2f / %.1f U", usedLastHour, maxPerHour))
            }
            .font(.subheadline)

            Spacer(minLength: 4)

            // 长按确认
            ZStack {
                Circle()
                    .stroke(Color.red.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Image(systemName: pressing ? "drop.fill" : "hand.tap")
                        .font(.title2)
                    Text(pressing ? "继续按住…" : "按住 1.5 秒")
                        .font(.caption2)
                }
                .foregroundStyle(.red)
            }
            .frame(width: 110, height: 110)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 60) {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                onConfirm()
                dismiss()
            } onPressingChanged: { isPressing in
                pressing = isPressing
                if isPressing {
                    withAnimation(.linear(duration: holdDuration)) { progress = 1 }
                } else {
                    withAnimation(.linear(duration: 0.15)) { progress = 0 }
                }
            }
            .padding(.bottom, 4)

            Button(role: .cancel) {
                onCancel()
                dismiss()
            } label: {
                Text("取消")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(pressing)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
