import SwiftUI

/// Colori del logo FPM: ciano → blu → viola → magenta su blu notte.
enum Theme {
    static let bg = Color(red: 0.027, green: 0.035, blue: 0.11)
    static let bg2 = Color(red: 0.05, green: 0.055, blue: 0.16)
    static let panel = Color(red: 0.075, green: 0.08, blue: 0.21)
    static let line = Color(red: 0.17, green: 0.17, blue: 0.36)
    static let ink = Color(red: 0.95, green: 0.96, blue: 1.0)
    static let soft = Color(red: 0.62, green: 0.64, blue: 0.82)
    static let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)
    static let blue = Color(red: 0.31, green: 0.48, blue: 1.0)
    static let violet = Color(red: 0.56, green: 0.36, blue: 1.0)
    static let magenta = Color(red: 0.88, green: 0.3, blue: 0.98)
    static let warn = Color(red: 1.0, green: 0.75, blue: 0.3)

    static let gradient = LinearGradient(gradient: Gradient(colors: [cyan, blue, violet, magenta]), startPoint: .leading, endPoint: .trailing)
    static let background = LinearGradient(gradient: Gradient(colors: [bg, Color(red: 0.06, green: 0.03, blue: 0.16)]), startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Panel<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title {
                HStack(spacing: 8) {
                    if let i = icon { Image(systemName: i).foregroundColor(Theme.cyan) }
                    Text(t.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundColor(Theme.soft)
                }
            }
            content()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
    }
}

struct NeonButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundColor(.white)
            .background(
                Group {
                    if prominent { RoundedRectangle(cornerRadius: 10).fill(Theme.gradient) }
                    else { RoundedRectangle(cornerRadius: 10).fill(Theme.bg2) }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(prominent ? Color.clear : Theme.line, lineWidth: 1))
            .shadow(color: prominent ? Theme.violet.opacity(0.45) : .clear, radius: configuration.isPressed ? 2 : 8)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct Chip: View {
    var text: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundColor(selected ? .white : Theme.soft)
                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.bg2)))
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

/// Disposizione a capo automatico per i tag (compatibile con macOS 12).
struct FlowLayoutView<Data: RandomAccessCollection, Item: View>: View where Data.Element: Hashable {
    var items: Data
    var spacing: CGFloat = 6
    var content: (Data.Element) -> Item
    @State private var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            self.generate(in: geo)
        }.frame(height: height)
    }

    private func generate(in g: GeometryProxy) -> some View {
        var width = CGFloat.zero, heightAcc = CGFloat.zero
        let list = Array(items)
        return ZStack(alignment: .topLeading) {
            ForEach(list, id: \.self) { item in
                content(item)
                    .padding(.trailing, spacing).padding(.bottom, spacing)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > g.size.width { width = 0; heightAcc -= d.height }
                        let r = width
                        if item == list.last { width = 0 } else { width -= d.width }
                        return r
                    }
                    .alignmentGuide(.top) { _ in
                        let r = heightAcc
                        if item == list.last { heightAcc = 0 }
                        return r
                    }
            }
        }.background(GeometryReader { p in Color.clear.preference(key: FlowHeightKey.self, value: p.size.height) })
         .onPreferenceChange(FlowHeightKey.self) { height = $0 }
    }
}

private struct FlowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

func formatTime(_ s: Double) -> String {
    let t = max(0, Int(s.rounded(.down)))
    return String(format: "%d:%02d", t / 60, t % 60)
}

/// Larghezza disponibile per la sezione: le viste passano da colonne affiancate a colonne una sotto l'altra.
private struct ContentWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 1200 }
extension EnvironmentValues {
    var contentWidth: CGFloat {
        get { self[ContentWidthKey.self] }
        set { self[ContentWidthKey.self] = newValue }
    }
}

/// Due colonne affiancate se c'è spazio, altrimenti una sotto l'altra.
struct AdaptiveColumns<Left: View, Right: View>: View {
    var width: CGFloat
    var threshold: CGFloat
    var rightWidth: CGFloat
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right
    var body: some View {
        if width >= threshold {
            HStack(alignment: .top, spacing: 12) { left(); right().frame(width: rightWidth) }
        } else {
            VStack(alignment: .leading, spacing: 12) { left(); right() }
        }
    }
}
