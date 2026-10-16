import AppKit

/// A setting in the menu you can tick without the menu closing, so several
/// can be changed in one go and each change stays in view. The menu goes
/// away as usual with a click anywhere else, Escape or another item.
///
/// macOS closes a menu on any click on a normal item; an item drawn by its
/// own view keeps it open. So this one draws itself, the way the system
/// draws its items: tick, title and the rounded highlight. Return still
/// picks it and closes the menu, like any item.
@MainActor
final class StayOpenMenuItem: NSMenuItem {
    private let handler: () -> Void
    private let isOn: () -> Bool

    init(_ title: String, isOn: @escaping () -> Bool, handler: @escaping () -> Void) {
        self.handler = handler
        self.isOn = isOn
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = isOn() ? .on : .off
        view = StayOpenItemView(item: self)
    }

    required init(coder: NSCoder) { fatalError() }

    override var toolTip: String? {
        didSet { view?.toolTip = toolTip }
    }

    @objc private func fire() { handler() }

    /// A click: change the setting, then show every setting in this menu as
    /// it is now, since one choice can untick another, as with sizes.
    fileprivate func clicked() {
        handler()
        for case let item as StayOpenMenuItem in menu?.items ?? [] { item.refresh() }
    }

    private func refresh() {
        state = isOn() ? .on : .off
        view?.needsDisplay = true
        view?.setAccessibilityValue(state == .on)
    }
}

private final class StayOpenItemView: NSView {
    private weak var item: StayOpenMenuItem?

    // The system's own measures for a menu item.
    private static let height: CGFloat = 24
    private static let inset: CGFloat = 5
    private static let tickX: CGFloat = 12
    private static let titleX: CGFloat = 30
    private static let font = NSFont.menuFont(ofSize: 0)

    init(item: StayOpenMenuItem) {
        self.item = item
        let width = (item.title as NSString).size(withAttributes: [.font: Self.font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width) + Self.titleX + 24, height: Self.height))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(item.title)
        setAccessibilityValue(item.state == .on)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let highlighted = item.isHighlighted && item.isEnabled
        if highlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: Self.inset, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let color: NSColor = !item.isEnabled ? .disabledControlTextColor
            : highlighted ? .selectedMenuItemTextColor : .controlTextColor
        if item.state == .on, let tick = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.font.pointSize - 2, weight: .semibold)) {
            let tinted = NSImage(size: tick.size, flipped: false) { rect in
                tick.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: Self.tickX, y: (bounds.height - tick.size.height) / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        let title = NSAttributedString(string: item.title, attributes: [.font: Self.font, .foregroundColor: color])
        let size = title.size()
        title.draw(at: NSPoint(x: Self.titleX, y: (bounds.height - size.height) / 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item, item.isEnabled else { return }
        item.clicked()
    }
}
