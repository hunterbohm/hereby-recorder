import SwiftUI
import LMLCore

/// A quiet line above the Home footer when a newer release is out. It never opens anything by itself; the update
/// starts only from its link.
struct UpdateRow: View {
    let store: PanelStore

    var body: some View {
        if let notice = store.update {
            VStack(alignment: .leading, spacing: 4) {
                switch notice {
                case .available(let version), .refused(let version, _):
                    updateLink(version)
                    if case .refused(_, let refusal) = notice {
                        Text(PanelCopy.updateRefusal(refusal))
                            .font(Fonts.sub)
                            .foregroundStyle(Palette.record)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .updating(let version):
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(PanelCopy.updating(version)).font(Fonts.sub).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                case .failed(let version, let log):
                    Label(PanelCopy.updateFailed(version), systemImage: "xmark.octagon")
                        .font(Fonts.sub)
                        .foregroundStyle(Palette.record)
                    Text(log)
                        .font(Fonts.tag)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Show log") { store.open(URL(fileURLWithPath: log)) }
                            .buttonStyle(LinkButtonStyle())
                        Button("Try again") { Task { await store.startUpdate() } }
                            .buttonStyle(LinkButtonStyle())
                            .disabled(store.isBusy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func updateLink(_ version: ReleaseVersion) -> some View {
        Button { Task { await store.startUpdate() } } label: {
            Label(PanelCopy.updateTitle(version), systemImage: "arrow.down.circle")
        }
        .buttonStyle(LinkButtonStyle())
        .disabled(store.isBusy)
        .accessibilityHint("Installs the new version and restarts the recorder")
    }
}
