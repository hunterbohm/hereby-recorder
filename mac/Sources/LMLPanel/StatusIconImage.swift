import AppKit

public extension StatusIcon {
    var symbolName: String {
        switch self {
        case .idle: "waveform"
        case .armed: "ear"
        case .recording: "record.circle"
        case .paused: "pause.circle"
        case .filed: "checkmark.circle"
        case .marked: "bookmark.fill"
        case .markMissed: "bookmark.slash"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    @MainActor func image() -> NSImage? {
        let base = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let colored: NSImage.SymbolConfiguration? = switch self {
        case .recording: base.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        case .problem: base.applying(.preferringMulticolor())
        case .idle, .armed, .paused, .filed, .marked, .markMissed: nil
        }
        let name = PanelCopy.accessibilityName(self)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: name)?
            .withSymbolConfiguration(colored ?? base) else { return nil }
        image.isTemplate = colored == nil
        return image
    }
}
