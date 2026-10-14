import AppKit
import ScreenCaptureKit

/// Select, start, scroll manually or automatically, then review in the editor.
@MainActor
final class ScrollingCapture: NSObject, NSWindowDelegate {
    static let shared = ScrollingCapture()
    var onSaved: (URL) -> Void = { _ in }
    var onActivityChanged: (Bool) -> Void = { _ in }
    private(set) var isActive = false

    private var session = UUID()
    private var task: Task<Void, Never>?
    private var overlays: [NSWindow] = []
    private var outline: NSWindow?
    private var controls: NSPanel?
    private var panelContent: CaptureControlsView?
    private var status: NSTextField?
    private var autoButton: NSButton?
    private var finishButton: NSButton?
    private var cancelButton: NSButton?
    private var direction: NSSegmentedControl?
    private var preview: CapturePreviewView?
    private var previewScroll: NSScrollView?
    private var pieces: [CGImage] = []
    private var footer: CGImage?
    private var previous: CapturePixels?
    private var insets: ScrollInsets?
    private var length = 0
    private var count = 0
    private var axis: ScrollAxis = .vertical
    private var capturing = false
    private var saving = false
    private var automatic = false
    private var lastStep = Date.distantPast
    private var unchangedSteps = 0
    private var captureRect = CGRect.zero
    private var frontApp: NSRunningApplication?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var displayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?

    func start() {
        guard !isActive else { controls?.orderFrontRegardless(); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermission(
                L("Allow screen recording to capture a scrolling area"),
                detail: L("Enable Tendedero in System Settings → Privacy & Security → Screen Recording, then try again. You may need to reopen Tendedero."),
                pane: "Privacy_ScreenCapture")
            return
        }
        frontApp = NSWorkspace.shared.frontmostApplication
        isActive = true
        session = UUID()
        let token = session
        onActivityChanged(true)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        task = Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard isActive, session == token, !Task.isCancelled else { return }
                showSelection(content: content)
            } catch {
                guard isActive, session == token else { return }
                fail(error)
            }
        }
    }

    private func showSelection(content: SCShareableContent) {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let window = CaptureSelectionWindow(on: screen)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = CaptureSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onCancel = { [weak self] in self?.cancel() }
            view.onSelected = { [weak self] rect in
                self?.select(rect, screen: screen, display: display, content: content)
            }
            window.contentView = view
            overlays.append(window)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
        }
        if overlays.isEmpty { fail(CocoaError(.featureUnsupported)) }
    }

    private func select(_ rect: CGRect, screen: NSScreen, display: SCDisplay, content: SCShareableContent) {
        clearOverlays()
        let scale = screen.backingScaleFactor
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard ImageEditing.validSize(width: width, height: height) else { fail(CocoaError(.fileReadTooLarge)); return }
        filter = SCContentFilter(display: display,
            excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier },
            exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.captureResolution = .best
        self.configuration = configuration
        displayID = display.displayID
        let displayBounds = CGDisplayBounds(display.displayID)
        captureRect = rect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
        let cocoaRect = NSRect(x: screen.frame.minX + rect.minX,
                               y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        showOutline(cocoaRect, on: screen)
        showControls(on: screen, around: cocoaRect)
        frontApp?.activate(options: [])
    }

    private func showOutline(_ rect: NSRect, on screen: NSScreen) {
        let frame = rect.insetBy(dx: -3, dy: -3)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frame.size), styleMask: .borderless,
                              backing: .buffered, defer: false, screen: screen)
        window.setFrameOrigin(frame.origin)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = CaptureOutlineView(frame: NSRect(origin: .zero, size: window.frame.size))
        outline = window
        window.orderFrontRegardless()
    }

    private func showControls(on screen: NSScreen, around rect: NSRect) {
        let size = NSSize(width: 430, height: 370)
        let visible = screen.visibleFrame
        let candidates = [
            NSPoint(x: rect.maxX + 12, y: rect.maxY - size.height),
            NSPoint(x: rect.minX - size.width - 12, y: rect.maxY - size.height),
            NSPoint(x: rect.minX, y: rect.minY - size.height - 12),
            NSPoint(x: rect.minX, y: rect.maxY + 12),
        ]
        let origin = candidates.first(where: { visible.contains(NSRect(origin: $0, size: size)) })
            ?? NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false, screen: screen)
        panel.title = L("Scrolling Capture")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let preview = CapturePreviewView(frame: NSRect(x: 0, y: 0, width: 398, height: 180))
        let content = CaptureControlsView(preview: preview, target: self,
            startAction: #selector(beginCapture), autoAction: #selector(toggleAutoScroll),
            doneAction: #selector(finish), cancelAction: #selector(cancel))
        panel.titlebarAppearsTransparent = true
        panel.contentView = content
        panel.setContentSize(NSSize(width: max(430, content.fittingSize.width), height: 370))
        panel.setFrameOrigin(NSPoint(x: max(visible.minX, min(origin.x, visible.maxX - panel.frame.width)),
                                     y: max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))))
        content.layoutSubtreeIfNeeded()
        self.preview = preview
        previewScroll = content.scroll
        self.direction = content.direction
        self.status = content.status
        autoButton = content.auto
        finishButton = content.done
        cancelButton = content.cancel
        panelContent = content
        content.metrics.stringValue = ImageToolsUI.dimensions(width: configuration?.width ?? 0, height: configuration?.height ?? 0)
        content.setPhase(.ready)
        controls = panel
        panel.orderFrontRegardless()
    }

    @objc private func beginCapture() {
        guard !capturing, !saving, let configuration, let displayID else { return }
        axis = direction?.selectedSegment == 1 ? .horizontal : .vertical
        autoButton?.image = NSImage(systemSymbolName: axis == .vertical ? "arrow.down" : "arrow.right", accessibilityDescription: L("Auto-scroll"))
        direction?.isEnabled = false
        capturing = true
        panelContent?.setPhase(.starting)
        status?.stringValue = L("Capturing the first frame…")
        frontApp?.activate(options: [])
        let token = session
        task = Task {
            do {
                // The selection query precedes creation of our controls. Query
                // again so accessory-app windows are excluded even if this app
                // had no visible windows when selection began.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard isActive, session == token, !Task.isCancelled,
                      let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let applications = content.applications.filter { $0.processID == ownPID }
                let filter = applications.isEmpty
                    ? SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == ownPID })
                    : SCContentFilter(display: display, excludingApplications: applications, exceptingWindows: [])
                self.filter = filter
                beginSampling(filter: filter, configuration: configuration)
            } catch {
                guard isActive, session == token else { return }
                fail(error)
            }
        }
    }

    private func beginSampling(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        let token = session
        task = Task {
            do {
                while !Task.isCancelled {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    guard isActive, session == token, !saving, !Task.isCancelled else { return }
                    let result = await analyze(image)
                    guard isActive, session == token, !saving, !Task.isCancelled else { return }
                    let match = accept(image, analysis: result)
                    advanceAutomatically(after: match)
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
            } catch is CancellationError {
                // Done waits for this task before taking its final frame.
            } catch {
                guard isActive, session == token, !saving else { return }
                stopAutoScroll()
                if pieces.isEmpty { fail(error) }
                else {
                    panelContent?.setPhase(.paused)
                    status?.stringValue = L("Capture paused. Click Done to save what is shown in the preview.")
                }
            }
        }
    }

    private func analyze(_ image: CGImage) async -> (CapturePixels, ScrollAlignment)? {
        let previous = self.previous, axis = self.axis, insets = self.insets
        return await Task.detached(priority: .userInitiated) {
            guard let pixels = ImageEditing.pixels(image) else { return nil }
            let alignment = previous.map { ScrollMatcher.align(previous: $0, next: pixels, axis: axis, insets: insets) }
                ?? ScrollAlignment(result: .unchanged, insets: ScrollInsets())
            return (pixels, alignment)
        }.value
    }

    private func strip(_ image: CGImage, start: Int, length: Int) -> CGImage? {
        guard length > 0 else { return nil }
        let rect = axis == .vertical
            ? CGRect(x: 0, y: start, width: image.width, height: length)
            : CGRect(x: start, y: 0, width: length, height: image.height)
        return ImageEditing.compactCrop(image, to: rect)
    }

    private func accept(_ image: CGImage, analysis: (CapturePixels, ScrollAlignment)?) -> ScrollMatch {
        guard let (pixels, alignment) = analysis else { return .noOverlap }
        let extent = axis == .vertical ? image.height : image.width
        if previous == nil {
            pieces = [image]
            length = extent
            count = 1
            previous = pixels
            panelContent?.setPhase(.capturing)
            status?.stringValue = automatic ? L("Auto-scroll is running.") : L("Scroll slowly, or use Auto-scroll.")
            updatePreview()
            updateStatus()
            return .unchanged
        }
        switch alignment.result {
        case .unchanged:
            return .unchanged
        case .noOverlap:
            status?.stringValue = L("Waiting for matching content. Scroll back slightly, or click Done to save the preview.")
            return .noOverlap
        case .append(let added):
            let trailing = alignment.insets.trailing
            let total = length + added + (insets == nil ? 0 : trailing)
            let width = axis == .vertical ? image.width : total
            let height = axis == .vertical ? total : image.height
            guard ImageEditing.validSize(width: width, height: height) else {
                stopAutoScroll()
                task?.cancel()
                autoButton?.isEnabled = false
                status?.stringValue = L("Capture size limit reached. Click Done to save.")
                return .noOverlap
            }
            guard let tail = strip(image, start: extent - trailing - added, length: added) else { return .noOverlap }
            if insets == nil {
                // Keep fixed leading chrome once and defer the fixed footer
                // until the end, instead of repeating it at every seam.
                if trailing > 0, let first = pieces.first,
                   let body = strip(first, start: 0, length: extent - trailing) {
                    pieces = [body]
                    length -= trailing
                }
                insets = alignment.insets
            }
            footer = trailing > 0 ? strip(image, start: extent - trailing, length: trailing) : nil
            pieces.append(tail)
            length += added
            previous = pixels
            count += 1
            updatePreview()
            updateStatus()
            status?.stringValue = automatic ? L("Auto-scroll is running.") : L("Scroll slowly, or use Auto-scroll.")
            return .append(added)
        }
    }

    private func updateStatus() {
        guard let first = pieces.first else { return }
        let total = length + (insets?.trailing ?? 0)
        let width = axis == .vertical ? first.width : total
        let height = axis == .vertical ? total : first.height
        let values = [count, width, height].map { $0.formatted(.number.locale(Locale(identifier: "en_CA"))) }
        let format = count == 1 ? L("%@ frame · %@ × %@ pixels") : L("%@ frames · %@ × %@ pixels")
        panelContent?.metrics.stringValue = String(format: format, values[0], values[1], values[2])
    }

    private func updatePreview() {
        preview?.update(pieces + (footer.map { [$0] } ?? []), axis: axis)
        guard let preview, let scroll = previewScroll else { return }
        let point = axis == .vertical
            ? NSPoint(x: 0, y: max(0, preview.frame.height - scroll.contentSize.height))
            : NSPoint(x: max(0, preview.frame.width - scroll.contentSize.width), y: 0)
        scroll.contentView.scroll(to: point)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func toggleAutoScroll() {
        guard capturing, !saving, !pieces.isEmpty else { return }
        if automatic { stopAutoScroll(); status?.stringValue = L("Auto-scroll paused. Click Auto-scroll to resume."); return }
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            showPermission(L("Allow Accessibility to use Auto-scroll"),
                detail: L("Enable Tendedero in System Settings → Privacy & Security → Accessibility. You can still scroll manually without this permission."),
                pane: "Privacy_Accessibility")
            return
        }
        frontApp?.activate(options: [])
        CGWarpMouseCursorPosition(CGPoint(x: captureRect.midX, y: captureRect.midY))
        automatic = true
        unchangedSteps = 0
        lastStep = .distantPast
        autoButton?.title = L("Pause")
        autoButton?.setAccessibilityLabel(L("Pause"))
        status?.stringValue = L("Auto-scroll is running.")
        autoButton?.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: L("Pause"))
        updateStatus()
    }

    private func stopAutoScroll() {
        automatic = false
        autoButton?.title = L("Auto-scroll")
        autoButton?.setAccessibilityLabel(L("Auto-scroll"))
        autoButton?.image = NSImage(systemSymbolName: axis == .vertical ? "arrow.down" : "arrow.right", accessibilityDescription: L("Auto-scroll"))
        unchangedSteps = 0
    }

    private func advanceAutomatically(after match: ScrollMatch) {
        guard automatic else { return }
        guard let point = CGEvent(source: nil)?.location, captureRect.contains(point) else {
            stopAutoScroll()
            status?.stringValue = L("Auto-scroll paused. Click Auto-scroll to resume.")
            return
        }
        guard match != .noOverlap else { stopAutoScroll(); return }
        if case .append = match { unchangedSteps = 0 }
        guard Date().timeIntervalSince(lastStep) >= 0.6 else { return }
        if match == .unchanged { unchangedSteps += 1 }
        if unchangedSteps >= 5 {
            stopAutoScroll()
            status?.stringValue = L("No more movement detected. Click Done to open the editor.")
            return
        }
        let extent = axis == .vertical ? captureRect.height : captureRect.width
        let delta = -Int32(max(12, min(160, extent / 5)))
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: axis == .vertical ? delta : 0,
                            wheel2: axis == .horizontal ? delta : 0, wheel3: 0)
        event?.location = CGPoint(x: captureRect.midX, y: captureRect.midY)
        event?.post(tap: .cghidEventTap)
        lastStep = Date()
    }

    @objc private func finish() {
        guard !saving, !pieces.isEmpty, let filter, let configuration else { return }
        saving = true
        panelContent?.setPhase(.saving)
        stopAutoScroll()
        let sampling = task
        task?.cancel()
        finishButton?.isEnabled = false
        autoButton?.isEnabled = false
        cancelButton?.isEnabled = false
        status?.stringValue = L("Joining the capture…")
        let token = session
        task = Task {
            do {
                await sampling?.value
                guard isActive, session == token else { return }
                // Try the settled final viewport, but never trap Done in an
                // overlap-recovery loop. The visible preview is always savable.
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let last = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                    let result = await analyze(last)
                    guard isActive, session == token else { return }
                    _ = accept(last, analysis: result)
                }
                status?.stringValue = L("Joining the capture…")
                let pieces = self.pieces + (footer.map { [$0] } ?? []), axis = self.axis
                let data = try await Task.detached(priority: .userInitiated) {
                    guard let image = ImageEditing.join(pieces, axis: axis) else { throw CocoaError(.fileWriteUnknown) }
                    return try ImageEditing.png(image)
                }.value
                guard isActive, session == token else { return }
                let url = try ImageEditing.savePNG(data, name: "Scrolling capture")
                end()
                onSaved(url)
            } catch {
                guard isActive, session == token else { return }
                saving = false
                panelContent?.setPhase(.paused)
                status?.stringValue = error.localizedDescription
            }
        }
    }

    @objc func cancel() { let app = frontApp; end(); app?.activate(options: []) }

    private func end() {
        task?.cancel()
        task = nil
        session = UUID()
        clearOverlays()
        outline?.orderOut(nil)
        outline = nil
        controls?.orderOut(nil)
        controls = nil
        status = nil
        panelContent = nil
        autoButton = nil
        finishButton = nil
        cancelButton = nil
        direction = nil
        preview = nil
        previewScroll = nil
        pieces = []
        footer = nil
        previous = nil
        insets = nil
        length = 0
        count = 0
        capturing = false
        saving = false
        automatic = false
        let wasActive = isActive
        isActive = false
        frontApp = nil
        filter = nil
        configuration = nil
        displayID = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if wasActive { onActivityChanged(false) }
    }

    private func clearOverlays() { overlays.forEach { $0.orderOut(nil) }; overlays = [] }

    private func showPermission(_ message: String, detail: String, pane: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func fail(_ error: Error) {
        end()
        let alert = NSAlert()
        alert.messageText = L("Could not capture the scrolling area")
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !saving }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === controls { cancel() }
    }
}

@MainActor
private final class CaptureOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}

/// Draw retained pieces directly: growing the preview never creates a second
/// full-resolution panoramic bitmap on each frame.
@MainActor
private final class CapturePreviewView: NSView {
    private var pieces: [CGImage] = []
    private var axis: ScrollAxis = .vertical
    private var scale: CGFloat = 1
    override var isFlipped: Bool { true }

    func update(_ pieces: [CGImage], axis: ScrollAxis) {
        self.pieces = pieces
        self.axis = axis
        guard let first = pieces.first else { return }
        scale = axis == .vertical ? min(1, 380 / CGFloat(first.width)) : min(1, 170 / CGFloat(first.height))
        let width = axis == .vertical ? first.width : pieces.reduce(0) { $0 + $1.width }
        let height = axis == .vertical ? pieces.reduce(0) { $0 + $1.height } : first.height
        setFrameSize(NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        if pieces.isEmpty {
            let message = L("Preview appears when capture starts.") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12),
            ]
            let size = message.size(withAttributes: attributes)
            message.draw(at: NSPoint(x: max(12, (bounds.width - size.width) / 2),
                                     y: max(12, (bounds.height - size.height) / 2)), withAttributes: attributes)
        }
        var position: CGFloat = 0
        for piece in pieces {
            let size = NSSize(width: CGFloat(piece.width) * scale, height: CGFloat(piece.height) * scale)
            let rect = NSRect(x: axis == .vertical ? 0 : position, y: axis == .vertical ? position : 0,
                              width: size.width, height: size.height)
            if rect.intersects(dirtyRect) {
                NSImage(cgImage: piece, size: size).draw(in: rect, from: .zero,
                    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            position += axis == .vertical ? size.height : size.width
        }
    }
}

@MainActor
final class CaptureSelectionWindow: NSWindow {
    convenience init(on screen: NSScreen) {
        self.init(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                  backing: .buffered, defer: false, screen: screen)
        setFrameOrigin(screen.frame.origin)
    }
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class CaptureSelectionView: NSView {
    var onSelected: (CGRect) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private var first: NSPoint?
    private var last: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var selection: CGRect? {
        guard let first, let last else { return nil }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(first.x - last.x), height: abs(first.y - last.y)).intersection(bounds)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        first = convert(event.locationInWindow, from: nil)
        last = first
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        last = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        last = convert(event.locationInWindow, from: nil)
        guard let selection, selection.width >= 32, selection.height >= 48 else {
            first = nil
            last = nil
            needsDisplay = true
            return
        }
        onSelected(selection.integral.intersection(bounds))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let selection {
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            path.stroke()
        }
        let message = L("Drag to select the scrolling area. Escape cancels.") as NSString
        message.draw(at: NSPoint(x: 24, y: 48), withAttributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
        ])
    }
}
