import AppKit
import Quartz

/// A quick look at a photo without opening it: the same Quick Look window
/// Finder shows. Force click a photo, or choose Quick Look from its menu.
/// The arrow keys go through the rest of the line, and Space or Escape
/// closes it.
///
/// The line never takes the keyboard from the app you are in, so Space over
/// a photo cannot open it; the window takes the keyboard once it is open.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var urls: [URL] = []

    func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        // Quick Look asks the responder chain who controls it; with no
        // window of ours that is the app delegate, which hands it to us.
        panel.updateController()
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
    }

    func take(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func release(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        urls = []
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    // MARK: QLPreviewPanelDelegate

    /// Left and right go to the photo before or after it on the line.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, let panel else { return false }
        let step: Int
        switch Int(event.keyCode) {
        case 123: step = -1 // left arrow
        case 124: step = 1 // right arrow
        default: return false
        }
        return MainActor.assumeIsolated {
            let next = panel.currentPreviewItemIndex + step
            guard urls.indices.contains(next) else { return true }
            panel.currentPreviewItemIndex = next
            return true
        }
    }
}
