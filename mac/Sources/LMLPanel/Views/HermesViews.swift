import SwiftUI
import LMLCore

/// "Send Hermes" beside Join on the next call: Hermes's notetaker joins this Google Meet call.
struct SendHermesButton: View {
    let target: HermesTarget
    let store: PanelStore

    var body: some View {
        Button("Send Hermes") { Task { await store.setHermes(target, .join) } }
            .buttonStyle(PanelButtonStyle())
            .disabled(store.isBusy || store.isHermesPending(target.key))
            .help("Hermes joins this call as a notetaker")
            .accessibilityHint("Hermes joins this call as a notetaker")
    }
}

/// Where Hermes stands for one call, with Cancel (Remove once it is in the call) and the chat switch. Used under Join,
/// above the conversation, and under the call's title when the list is open during a call.
struct HermesCard: View {
    let target: HermesTarget
    let store: PanelStore

    var body: some View {
        let state = store.hermes(target)
        let waiting = store.isBusy || store.isHermesPending(target.key)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                icon(state).frame(width: 14)
                Text(PanelCopy.hermesLine(state, start: target.start, now: store.now, in: store.timeZone, locale: store.locale))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.phase == .failed ? Palette.record : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if state.isOn {
                    Button(PanelCopy.hermesStop(state)) { Task { await store.setHermes(target, .leave) } }
                        .buttonStyle(PanelButtonStyle(small: true))
                        .disabled(waiting)
                        .accessibilityLabel("\(PanelCopy.hermesStop(state)) Hermes")
                }
            }
            if state.isOn && state.phase != .failed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(PanelCopy.hermesChatLabel)
                        Spacer(minLength: 8)
                        Toggle(PanelCopy.hermesChatLabel, isOn: Binding(
                            get: { state.chat },
                            set: { on in Task { await store.setHermes(target, .chat(on)) } }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(waiting)
                    }
                    Text(PanelCopy.hermesChatHint(on: state.chat))
                        .font(Fonts.sub)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func icon(_ state: PanelHermes) -> some View {
        switch state.phase {
        case .joining, .waitingRoom:
            ProgressView().controlSize(.mini)
        case .scheduled:
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.secondary)
        case .inCall:
            Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.record)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        case .off:
            EmptyView()
        }
    }
}

/// The small switch on a Later today row. It sits beside the row's button, not inside it, so clicking it never opens
/// the row, and it stays out of the keyboard focus so the arrow keys and Return keep working from the ask field.
struct HermesRowSwitch: View {
    let target: HermesTarget
    let selected: Bool
    let store: PanelStore

    var body: some View {
        let state = store.hermes(target)
        let waiting = store.isBusy || store.isHermesPending(target.key)
        HStack(spacing: 5) {
            Text(PanelCopy.hermesShort(state))
                .font(Fonts.stamp)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : (state.phase == .failed ? Palette.record : Color.secondary))
                .fixedSize()
            Toggle("Hermes joins \(target.title)", isOn: Binding(
                get: { state.isOn },
                set: { on in Task { await store.setHermes(target, on ? .join : .leave) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(selected ? Color.white.opacity(0.5) : nil)
                .focusable(false)
                .disabled(waiting)
        }
        .help(state.isOn ? "Hermes joins this call. Turn off to cancel." : "Send Hermes to this call")
        .accessibilityElement(children: .combine)
    }
}
