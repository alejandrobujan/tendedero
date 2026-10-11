import AppKit

/// Capture presentation stays independent of screen access and pixel matching.
@MainActor
final class CaptureControlsView: NSVisualEffectView {
    enum Phase { case ready, starting, capturing, saving, paused }

    let direction = NSSegmentedControl(labels: [L("Vertical"), L("Horizontal")],
                                       trackingMode: .selectOne, target: nil, action: nil)
    let status = ImageToolsUI.caption(L("Start at the top or left, then capture."))
    let metrics = ImageToolsUI.caption()
    let start: NSButton
    let auto: NSButton
    let done: NSButton
    let cancel: NSButton
    let scroll = NSScrollView()
    private let progress = NSProgressIndicator()

    init(preview: NSView, target: AnyObject, startAction: Selector, autoAction: Selector,
         doneAction: Selector, cancelAction: Selector) {
        start = ImageToolsUI.button(L("Start Capture"), symbol: "record.circle", target: target, action: startAction, primary: true)
        auto = ImageToolsUI.button(L("Auto-scroll"), symbol: "arrow.down", target: target, action: autoAction)
        done = ImageToolsUI.button(L("Done"), symbol: "checkmark", target: target, action: doneAction, primary: true)
        cancel = NSButton(title: L("Cancel"), target: target, action: cancelAction)
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 370))
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        direction.selectedSegment = 0
        direction.setAccessibilityLabel(L("Scrolling Capture"))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        for button in [start, done] { button.keyEquivalent = "\r"; button.keyEquivalentModifierMask = [] }
        let title = NSTextField(labelWithString: L("Live preview"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        metrics.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = ImageToolsUI.row([title, headerSpacer, direction])
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true
        scroll.documentView = preview
        scroll.setAccessibilityLabel(L("Live preview"))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel(L("Saving…"))
        let feedback = ImageToolsUI.row([progress, status])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = ImageToolsUI.row([cancel, auto, actionSpacer, start, done])
        let stack = NSStackView(views: [header, scroll, metrics, feedback, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            metrics.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setPhase(.ready)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPhase(_ phase: Phase) {
        direction.isEnabled = phase == .ready
        start.isHidden = phase != .ready
        auto.isHidden = phase == .ready
        auto.isEnabled = phase == .capturing
        done.isHidden = phase == .ready
        done.isEnabled = phase == .capturing || phase == .paused
        cancel.isEnabled = phase != .saving
        progress.isHidden = phase != .starting && phase != .saving
        if phase == .starting || phase == .saving { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        done.title = phase == .saving ? L("Saving…") : L("Done")
        done.setAccessibilityLabel(done.title)
        progress.setAccessibilityLabel(phase == .starting ? L("Start Capture") : L("Saving…"))
        window?.defaultButtonCell = (phase == .ready ? start : done).cell as? NSButtonCell
    }
}
