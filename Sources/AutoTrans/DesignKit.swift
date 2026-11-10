import SwiftUI

// 统一的界面零件：浅灰底 + 白卡片（豆腐块）+ 细分割线；四级字号；两种按钮；状态徽章。
// 新界面一律用这些，不要再各写各的。

extension Theme {
    static let canvas = Color(hex: 0xF2F4F6)      // 页面底色：浅灰，衬出白卡片
    static let hairline = Color(hex: 0xDCE2E7)    // 卡片边框、卡片内分割线
    static let okBg = Color(hex: 0xE2F3EB)        // ✓ 徽章底色
    static let warnBg = Color(hex: 0xFBE8E5)      // ✗ 徽章底色
    static let accentBg = Color(hex: 0xE6F2EE)    // 选中 / 当前步骤的浅绿底

    static var pageTitle: Font { f(26, .bold) }   // 页面标题
    static var cardTitle: Font { f(19, .semibold) } // 卡片标题
    static var text: Font { f(18) }               // 卡片里的正文
    static var caption: Font { f(16) }            // 说明文字（深灰，不用浅灰）
}

/// 页面顶部：大标题 + 一句说明
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.pageTitle).foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle).font(Theme.caption).foregroundStyle(Theme.inkSoft).lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

/// 白色圆角卡片。可选标题 + 说明 + 右上角附件（比如状态徽章）
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle
        self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title { Text(title).font(Theme.cardTitle).foregroundStyle(Theme.ink) }
                        if let subtitle {
                            Text(subtitle).font(Theme.caption).foregroundStyle(Theme.inkSoft)
                                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
                CardDivider()
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .font(Theme.text)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// 卡片内的分割线（左右贴边）
struct CardDivider: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, inset)
    }
}

/// 卡片内一行：左边标题 + 说明，右边控件。多行之间用 CardDivider 隔开
struct CardRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.f(18, .semibold))
                if let detail {
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

/// ✓ / ✗ 状态徽章：图标 + 文字 + 底色（不只靠颜色）
struct StatusBadge: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            Text(text)
        }
        .font(Theme.f(16, .semibold))
        .foregroundStyle(ok ? Theme.accent : Theme.warn)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(ok ? Theme.okBg : Theme.warnBg))
        .fixedSize()
    }
}

/// 带编号的步骤说明（1. 2. 3.），编号是绿色小圆
struct NumberedSteps: View {
    let steps: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(i + 1)").font(Theme.f(15, .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 26 * Theme.scale, height: 26 * Theme.scale)
                        .background(Circle().fill(Theme.accentBg))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 6 * Theme.scale }
                    Text(steps[i]).font(Theme.text).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 输入框统一样式：白底、圆角、细边，字和框一样高
struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
    }
}
extension View { func fieldBox() -> some View { modifier(FieldBox()) } }

/// 两种按钮：.primary 绿底白字（每屏最多一个），.secondary 白底细边深字
enum ButtonKind { case primary, secondary, danger }

struct AppButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(kind: kind, configuration: configuration)
    }
}

private struct AppButtonBody: View {
    let kind: ButtonKind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    // 不能点时：灰底深灰字（不调透明度，字仍看得清）
    private var fill: Color {
        guard enabled else { return Theme.canvas }
        switch kind {
        case .primary: return Theme.accent
        case .secondary, .danger: return hover ? Theme.canvas : .white
        }
    }
    private var fg: Color {
        guard enabled else { return Theme.inkSoft }
        switch kind {
        case .primary: return .white
        case .secondary: return Theme.ink
        case .danger: return Theme.warn
        }
    }

    var body: some View {
        configuration.label
            .font(Theme.f(17, .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind == .primary && enabled ? Theme.accent : Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hover = $0 }
            .fixedSize()
    }
}

extension View {
    func appButton(_ kind: ButtonKind = .secondary) -> some View { buttonStyle(AppButtonStyle(kind: kind)) }
}

/// 设置页每个标签页：浅灰底、可滚动、卡片竖排
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(24)
                .tint(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}
