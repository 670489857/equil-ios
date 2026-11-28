//
//  AapsUIKit.swift
//  EquilController
//
//  AAPS / Equil 视觉语言的少量原语。
//
//  参照的是 Equil 参数页那几个特征：白卡片、16 圆角、标题 17pt、
//  下面一行灰色范围说明、值显示成浅蓝药丸或浅描边输入框；
//  概览页则是「一张表 + 实物图 + 两块大按钮」。
//
//  全部用语义色，深色模式下不会出现白底白字。
//

import SwiftUI
import UIKit

enum AapsUI {
    /// 页面底色。AAPS 用 surfaceVariant，iOS 上等价于 grouped 背景。
    static let background = Color(uiColor: .systemGroupedBackground)
    /// 卡片底色。浅色模式下是纯白。
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    /// 分隔线。比 Divider 细一点，接近 AAPS 的 outlineVariant。
    static let hairline = Color(uiColor: .separator).opacity(0.55)
    /// 表格网格线（概览页）。与 hairline 分开是有原因的：
    /// hairline 只有 0.5pt，在 3x 屏上是 1.5px，落在不同 y 上会被光栅化成
    /// 1px 或 2px，于是同一张表里横线有的深有的浅。网格线固定「1 个设备像素」
    /// （1/displayScale），最坏情况是抗锯齿成两行 50%，不会出现 2px 那种偏深。
    /// 颜色按对照图取样：白底上线是 #E7E7E7 左右，即 separator 再淡一点。
    static let tableLine = Color(uiColor: .separator).opacity(0.45)
    /// 输入框描边。
    static let fieldBorder = Color(uiColor: .separator).opacity(0.45)

    static let accent = Color(red: 0.16, green: 0.44, blue: 0.90)
    static let softBlue = Color(red: 0.84, green: 0.89, blue: 1.00)
    static let tileTint = Color(red: 0.91, green: 0.92, blue: 0.98)

    static let corner: CGFloat = 16
}

// MARK: - 卡片

struct AapsCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AapsUI.card)
            .clipShape(RoundedRectangle(cornerRadius: AapsUI.corner, style: .continuous))
    }
}

/// 卡片里的标题 + 可选小字说明。对应图3 每张卡的「标题 / 范围」两行。
struct CardTitle: View {
    let title: String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let caption {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 值显示

/// 浅蓝药丸。图3 里「声音和震动」「0.05 U/s」都是这个。
struct ValuePill: View {
    let text: String
    var tint: Color = AapsUI.accent
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 15, weight: .medium))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 输入框外壳。图3 的输入框是白底 + 浅灰描边 + 左对齐文本。
struct FieldShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .font(.system(size: 17))
            .padding(.horizontal, 12)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AapsUI.card)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AapsUI.fieldBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 大按钮

/// 图2 底部那两块：浅紫底、圆角、图标在上文字在下、整块可点。
struct TileAction: View {
    let title: String
    let systemImage: String
    let tint: Color
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? tint : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(enabled ? AapsUI.tileTint : Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - 概览表格

/// 图2 那种两列的表行：左边标签、右边值，两边都居中，
/// 两列之间一条竖线，行底一条横线，横竖同色同粗。
///
/// 竖线画在行内而不是整表 overlay，是为了让它随行高自然贯穿 —— 每行一段，
/// 拼起来就是一条连续的竖线，横线穿过它时不会出现断口。
struct TableRow: View {
    let label: String
    let value: String
    var level: StatusLevel = .unspecified
    /// 固定值颜色。用于「不管 level 是什么都要某种颜色」的行，
    /// 例如运行模式的 `-` 也要是绿色。传了就优先于 level 推导出的颜色。
    var valueTint: Color? = nil
    /// 标签列宽度。nil 时两列等分（概览页传实算值，按对照图的 40% 偏窄）。
    var labelWidth: CGFloat? = nil
    var showsBottomLine: Bool = true

    @Environment(\.displayScale) private var displayScale

    static let height: CGFloat = 42

    /// 1 个设备像素：3x 屏是 0.333pt，2x 屏是 0.5pt。
    private var lineWidth: CGFloat { 1 / max(displayScale, 1) }

    var body: some View {
        HStack(spacing: 0) {
            if let labelWidth {
                labelText.frame(width: labelWidth)
            } else {
                labelText.frame(maxWidth: .infinity)
            }

            Rectangle()
                .fill(AapsUI.tableLine)
                .frame(width: lineWidth)

            // 黑字、常规字重。1.16 试过加粗，比对照图重一档，这里退回 16pt regular；
            // 只有异常/强调态（橙/红/绿）才上颜色。
            // 不用 .monospacedDigit()：等宽数字会让窄字形（尤其 1）在自己的
            // advance 里居中，连着的「11」看起来像「1 1」，中间空一截。
            // 对照图（AAPS）用的是比例数字，紧挨着。列对齐靠居中 + 补零日期保证。
            Text(value)
                .font(.system(size: 16))
                .foregroundStyle(valueTint ?? (level == .unspecified ? Color.primary : level.valueColor))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            if showsBottomLine {
                Rectangle()
                    .fill(AapsUI.tableLine)
                    .frame(height: lineWidth)
            }
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: 16))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - 泵示意图

/// 产品图。只保留泵体本体，外围那圈半透明敷贴胶布已经抠掉。
///
/// 分离依据不是"亮不亮"这么简单：胶布是中性浅灰（~213），泵体是白（~242），
/// 泵体自己的透明药仓又会透出胶布色，所以顶部用亮度阈值、左右用实测边缘、
/// 底部用弧形高光定位，三段拼成一条闭合轮廓。
///
/// 边缘做了反预乘（C = (I-(1-a)B)/a，B 由 inpaint 得到），羽化 1px，
/// 落在 #F2F2F7 或纯黑底上都不会出现灰边或描边。
///
/// 比例前后校过三次：
/// - 1.4 把右半边裁掉 5px，白体只剩 203px 而模块 208px，白体显得小一圈；
/// - 1.7 补回右侧，3% 放大，但真机上差异只有 1pt，看着还是"齐平"；
/// - 1.8 按实物再放大到 5.8%：白体 219px、模块 207px，白体左右各凸出约 1pt
///   （224 × 314，缩放到高 104 时宽 74.1pt，仍在 86pt 槽位以内）。
///
/// 1.8 同时把右侧那圈阴影清掉了：原照片里泵体右侧压着一道 12px 宽的投影，
/// 之前的蒙版把它算进了本体，反预乘后变成一圈 180~200 的灰边。这次按逐行
/// 亮度重定左右边界（<218 视为背景/投影），底部再用圆弧收口，暗带就不再进图。
struct PumpIllustration: View {
    /// 槽位（与 1.1 一致，避免整页高度跳动）
    private let slotWidth: CGFloat = 86
    private let slotHeight: CGFloat = 104

    var body: some View {
        Group {
            if let photo = UIImage(named: "EquilPump") {
                Image(uiImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // 资源没打进包时退回矢量轮廓，宁可难看也不要留白
                VectorPump()
            }
        }
        .frame(maxWidth: slotWidth)
        .frame(height: slotHeight)
        .accessibilityHidden(true)
    }
}

/// 老版本的矢量轮廓，只作为图片缺失时的兜底。
private struct VectorPump: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AapsUI.hairline, lineWidth: 1)
                )

            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 26)
                    .overlay(
                        Text("13:14")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    )
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AapsUI.accent.opacity(0.45))
                            .frame(width: 26, height: 10)
                    }
                HStack(spacing: 1.5) {
                    ForEach(0..<11, id: \.self) { i in
                        Rectangle()
                            .fill(Color.secondary.opacity(i % 3 == 0 ? 0.55 : 0.28))
                            .frame(width: i % 2 == 0 ? 2 : 1, height: 14)
                    }
                }
                Text("EQUIL")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .tracking(1.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .frame(width: 86, height: 104)
    }
}
