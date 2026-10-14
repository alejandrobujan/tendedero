import AppKit

/// Native controls shared by the editor and the capture panel.
@MainActor
enum ImageToolsUI {
    static func surface() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    static func button(_ title: String, symbol: String, target: AnyObject?, action: Selector?,
                       primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
        if primary { button.bezelColor = .controlAccentColor }
        button.setAccessibilityLabel(title)
        return button
    }

    static func icon(_ title: String, symbol: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = self.button("", symbol: symbol, target: target, action: action)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.imagePosition = .imageOnly
        return button
    }

    static func caption(_ text: String = "") -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        return row
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_CA")))
    }

    static func dimensions(width: Int, height: Int) -> String {
        String(format: L("%@ × %@ pixels"), number(width), number(height))
    }
}

/// Keep small images centred while preserving scrolling for large images.
@MainActor
final class ImageToolsClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        let frame = documentView.frame
        if frame.width < result.width { result.origin.x = frame.minX - (result.width - frame.width) / 2 }
        if frame.height < result.height { result.origin.y = frame.minY - (result.height - frame.height) / 2 }
        return result
    }
}
