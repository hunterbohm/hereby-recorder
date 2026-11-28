import AppKit
import SwiftUI
import LMLCore

/// The one-time setup window, set like a short contents page: a serif title, then each permission as a line with its
/// macOS name, a dotted leader, and its button where the page number would be, with what Hereby uses it for under it.
/// The next button to press is filled. When a permission turns on, its leader becomes that channel's signal.
public struct SetupView: View {
    let store: PanelStore
    static let width: CGFloat = 400

    public init(store: PanelStore) { self.store = store }

    public var body: some View {
        let content = SetupContent(store.snapshot.access, asking: store.asking, canRestart: store.canRestart,
                                   restarting: store.restarting)
        VStack(alignment: .leading, spacing: 0) {
            Text(PanelCopy.setupTitle)
                .font(.system(size: 22, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(PanelCopy.setupSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 20) {
                ForEach(content.rows) { row in
                    SetupLine(row: row, filled: row.permission == content.next, store: store)
                        .padding(.top, row.permission == .screen ? 8 : 0)
                }
            }
            .padding(.top, 28)
            if content.ready {
                HStack {
                    Spacer()
                    Button("Done") { store.dismissSetup() }
                        .buttonStyle(InkButtonStyle(filled: content.next == nil))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 28)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 16)
        .padding(.bottom, 32)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SetupLine: View {
    let row: SetupRow
    let filled: Bool
    let store: PanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                Text(" ")
                    .font(Leader.font)
                    .frame(maxWidth: .infinity)
                    .overlay { Leader(permission: row.permission, level: row.done ? 1 : 0) }
                    .accessibilityHidden(true)
                trailing.fixedSize()
            }
            .frame(height: 24)
            Text(row.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .animation(.easeOut(duration: 0.6), value: row.done)
    }

    @ViewBuilder private var trailing: some View {
        if row.done {
            Text("On").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let action = row.action {
            let title = PanelCopy.setupButton(action)
            Button(title) { Task { await store.fixAccess(row.permission) } }
                .buttonStyle(InkButtonStyle(filled: filled))
                .accessibilityLabel("\(title) \(row.name)")
        } else if let status = row.status {
            Text(status).font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }
}

/// The leader, whole characters wide and set flush against the button: dots until the permission is on, then the
/// channel's signal drawn in from the left.
private struct Leader: View, Animatable {
    static let font = Font.system(size: 11, design: .monospaced)
    static let advance: CGFloat = ("0" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]).width

    let permission: Permission
    var level: Double

    nonisolated var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let count = max(0, Int(proxy.size.width / Self.advance))
            let drawn = min(count, Int((level * Double(count)).rounded()))
            text(String(PanelCopy.signal(permission, count: count).prefix(drawn)) + String(repeating: " ", count: count - drawn))
                .font(Self.font)
                .lineLimit(1)
                .fixedSize()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
    }

    /// The signal in ink, lighter for the optional screen, and the dots wherever it is quiet.
    private func text(_ line: String) -> Text {
        var text = Text(verbatim: "")
        var rest = Substring(line)
        while let first = rest.first {
            let quiet = first == " "
            let run = rest.prefix { ($0 == " ") == quiet }
            rest = rest.dropFirst(run.count)
            let part = quiet ? Text(String(repeating: PanelCopy.flat, count: run.count)).foregroundStyle(.quaternary)
                : Text(run).foregroundStyle(permission == .screen ? .secondary : .primary)
            text = Text("\(text)\(part)")
        }
        return text
    }
}

/// A small button in ink: filled for the one thing to press next, outlined otherwise.
private struct InkButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, filled: filled) }

    private struct Face: View {
        let configuration: ButtonStyleConfiguration
        let filled: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(filled ? Palette.primaryText : .primary)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(filled ? Palette.primaryFill : Color.primary.opacity(hovering ? 0.06 : 0), in: shape)
                .overlay(shape.strokeBorder(filled ? Color.clear : Color.primary.opacity(0.18)))
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .onHover { hovering = $0 }
                .fixedSize()
        }
    }
}
