//
//  Theme.swift
//  EquilController
//
//  对应 AAPS 4.0 的 StatusLevel / statusLevelToColor。
//  AAPS 用 Material3 的 errorContainer / tertiaryContainer / primaryContainer，
//  iOS 没有动态容器色，这里用低透明度底色 + 高对比前景色的等价做法。
//

import SwiftUI

/// 严重级别。与 AAPS `app.aaps.core.ui.compose.StatusLevel` 一一对应。
enum StatusLevel {
    case unspecified
    /// 正常但需要绿字强调（例如「运行中」）。AAPS 用绿色的场景，对应这里。
    case success
    case normal
    case warning
    case critical
}

extension StatusLevel {
    /// 卡片底色。对应 AAPS 的 `*Container` 系列。
    var containerBackground: Color {
        switch self {
        case .critical:     return Color.red.opacity(0.14)
        case .warning:      return Color.orange.opacity(0.15)
        case .success:      return Color.green.opacity(0.14)
        case .normal:       return Color.blue.opacity(0.12)
        case .unspecified:  return Color(.secondarySystemGroupedBackground)
        }
    }

    /// 值文本颜色。对应 AAPS 的 `statusLevelToColor`。
    var valueColor: Color {
        switch self {
        case .critical:     return .red
        case .warning:      return .orange
        case .success:      return .green
        case .normal:       return .primary
        case .unspecified:  return .primary
        }
    }

    /// 无障碍描述，读屏时跟在文本后面。
    var accessibilityWord: String? {
        switch self {
        case .critical:     return "严重"
        case .warning:      return "警告"
        case .success:      return "正常"
        case .normal:       return nil
        case .unspecified:  return nil
        }
    }

    /// 横幅里的图标。AAPS 没有图标，但 iOS 上纯色块信息密度太低，补一个不喧宾夺主。
    var symbolName: String? {
        switch self {
        case .critical:     return "exclamationmark.octagon.fill"
        case .warning:      return "exclamationmark.triangle.fill"
        case .success:      return "checkmark.circle.fill"
        case .normal:       return "checkmark.circle.fill"
        case .unspecified:  return nil
        }
    }
}

// MARK: - 通用卡片

/// 圆角卡片容器。对应 AAPS 的 `AapsCard`。
struct SectionCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 信息行：左标签、右值。对应 AAPS 的 `InfoRowItem`。
struct InfoRow: View {
    let label: String
    let value: String
    var level: StatusLevel = .unspecified
    var visible: Bool = true

    var body: some View {
        if visible {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(level.valueColor)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(level.accessibilityWord ?? "")
        }
    }
}

/// 行间分隔线。AAPS 用 HorizontalDivider + outlineVariant，这里等价处理。
struct RowDivider: View {
    var body: some View {
        Divider().padding(.vertical, 8)
    }
}
