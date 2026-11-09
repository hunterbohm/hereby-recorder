import SwiftUI
import LMLCore

struct AfterView: View {
    let content: AfterContent
    let store: PanelStore

    var body: some View {
        PanelLayout {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if content.pinned {
                        Button { store.back() } label: { Label("Back", systemImage: "chevron.left") }
                            .buttonStyle(LinkButtonStyle())
                            .keyboardShortcut(isConfirming ? nil : .cancelAction)
                    }
                    FilingPill(state: content.state)
                    Spacer(minLength: 8)
                    if let facts = PanelText.afterFacts(content, in: store.timeZone, locale: store.locale) {
                        Text(facts).font(Fonts.tag).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(content.title)
                    .font(Fonts.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBanner(store: store).padding(.bottom, store.health.isOK ? 0 : 12)
                status
                if !content.summary.isEmpty {
                    SectionLabel("Summary").padding(.top, 16)
                    Bullets(items: content.summary)
                }
                moments
                ActionFooter(store: store).padding(.top, store.action == .idle ? 0 : 12)
            }
        } footer: {
            HStack(spacing: 10) {
                if let note = content.noteURL {
                    Button("Open note") { store.open(note) }
                        .buttonStyle(PanelButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
                Button("Forget") { Task { await store.perform(.forget(sid: content.sid)) } }
                    .buttonStyle(PanelButtonStyle())
                    .accessibilityLabel("Forget this call")
                Spacer(minLength: 0)
                if !content.pinned {
                    Button("All recent") { store.navigate(.list) }
                        .buttonStyle(LinkButtonStyle())
                        .accessibilityLabel("All recent meetings")
                }
            }
            .disabled(store.isBusy)
        }
    }

    private var isConfirming: Bool { if case .confirming = store.action { true } else { false } }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch content.state {
            case .filed:
                if let note = content.note { InfoRow(symbol: "doc.text", text: "Notes \(note)") }
                if let review = content.review {
                    let copy = PanelText.review(review)
                    InfoRow(symbol: "iphone", text: copy.line, detail: copy.detail)
                }
                if content.note == nil && content.review == nil { InfoRow(symbol: "doc.text", text: "Notes written.") }
            case .filing:
                InfoRow(symbol: "pencil.line", text: "Writing notes now.", detail: "Usually under 5 minutes")
            case .waiting:
                if let until = content.heldUntil {
                    InfoRow(symbol: "phone.arrow.down.left", text: "If this call comes back, recording continues here.",
                            detail: "Otherwise it files at \(PanelText.clock(until, in: store.timeZone, locale: store.locale)).")
                } else {
                    InfoRow(symbol: "arrow.up.circle", text: store.hasMini ? "The transcript is still syncing to the mini." : "The transcript is saved on this Mac.")
                }
            case .skipped:
                InfoRow(symbol: "minus.circle", text: "Not filed: \(content.note ?? "no reason given").")
            case .failed:
                InfoRow(symbol: "exclamationmark.circle", text: "Notes weren't written.",
                        detail: "The mini tries again within the hour.", tint: Palette.record)
            }
        }
    }

    @ViewBuilder private var moments: some View {
        if let moments = content.moments {
            SectionLabel("Marked moments").padding(.top, 16)
            if moments.isEmpty {
                Text("None marked").font(Fonts.sub).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(moments.enumerated()), id: \.offset) { _, moment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(PanelText.stamp(moment.at, since: content.startedAt, in: store.timeZone, locale: store.locale))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(Palette.record)
                                .fixedSize()
                            Text(moment.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } else if let marks = content.marks, marks > 0, content.state == .waiting || content.state == .filing {
            SectionLabel("Marked moments").padding(.top, 16)
            Text("\(marks) marked. They show here once the notes are written.")
                .font(Fonts.sub)
                .foregroundStyle(.secondary)
        }
    }
}
