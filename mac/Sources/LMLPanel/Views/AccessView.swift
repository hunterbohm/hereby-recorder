import SwiftUI
import LMLCore

struct AccessView: View {
    let content: AccessContent
    let store: PanelStore

    var body: some View {
        let copy = PanelCopy.access(content, now: store.now, in: store.timeZone, locale: store.locale)
        PanelLayout {
            HStack {
                Pill(text: "Needs access", symbol: "exclamationmark.triangle", tone: .warn)
                Spacer(minLength: 8)
                HealthLine(micOK: content.micOK, audioOK: content.audioOK)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBanner(store: store, includeCapture: false).padding(.bottom, store.health.miniReachable ? 0 : 12)
                Text(copy.title).font(Fonts.titleSmall)
                Text(copy.detail)
                    .font(Fonts.sub)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if let next = copy.next {
                    Text(next)
                        .font(Fonts.sub)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .accessibilityElement(children: .combine)
        } footer: {
            HStack {
                if let url = copy.settingsURL {
                    Button("Open System Settings") { store.open(url) }
                        .buttonStyle(PanelButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
                Spacer(minLength: 0)
                Button("All recent") { store.navigate(.list) }
                    .buttonStyle(LinkButtonStyle())
                    .accessibilityLabel("All recent meetings")
            }
        }
    }
}
