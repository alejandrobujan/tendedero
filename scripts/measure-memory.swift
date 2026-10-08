// Compile with the app sources except main.swift. See docs/memory-usage.md.
import AppKit
import ImageIO

@main
struct MemoryBenchmark {
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return info.phys_footprint
    }

    /// Poll throughout synchronous decoding/encoding as well as animation.
    /// Post-operation samples alone miss buffers freed before a call returns.
    private final class Sampler {
        private let queue = DispatchQueue(label: "memory-sampler")
        private let timer: DispatchSourceTimer
        private let lock = NSLock()
        private var peak: UInt64

        init(initial: UInt64) {
            peak = initial
            timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
        }

        func sample() {
            let bytes = footprint()
            lock.lock()
            peak = max(peak, bytes)
            lock.unlock()
        }

        func finish() -> UInt64 {
            sample()
            timer.cancel()
            queue.sync {}
            lock.lock()
            defer { lock.unlock() }
            return peak
        }
    }

    @MainActor
    private static func copyPNG(_ url: URL) -> Data? {
        #if BASELINE
        // Original Line.pngData implementation, private to that type.
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return pngData(url)
        #endif
    }

    @MainActor
    static func main() {
        precondition(CommandLine.arguments.count == 3, "Usage: benchmark MODE FIXTURE_PATH")
        let mode = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        #if !BASELINE
        if mode == "clipboard-exit" || mode == "clipboard-signal" {
            let board = NSPasteboard.withUniqueName()
            precondition(ClipboardImage.copy(url, to: board))
            if mode == "clipboard-exit" {
                ClipboardImage.materializeForExit()
                print(board.name.rawValue)
            } else {
                signal(SIGTERM, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                source.setEventHandler {
                    ClipboardImage.materializeForExit()
                    exit(0)
                }
                source.resume()
                print(board.name.rawValue)
                fflush(stdout)
                withExtendedLifetime(source) { RunLoop.main.run() }
            }
            return
        }
        #endif
        if mode == "fixture" {
            let c = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000))
            let d = CGImageDestinationCreateWithURL(url as CFURL,
                (url.pathExtension == "jpg" ? "public.jpeg" : "public.png") as CFString, 1, nil)!
            CGImageDestinationAddImage(d, c.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(d))
            return
        }
        _ = NSApplication.shared
        _ = NSScreen.screens
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        let base = footprint()
        let sampler = Sampler(initial: base)
        var pixelBytes = 0
        var images: [NSImage] = []
        var clipboardData: Data?
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.clearContents(); clipboard.releaseGlobally() }
        var watcher: ScreenshotWatcher?
        let count = ["copy", "paste", "markup", "watcher"].contains(mode) ? 1 : 12
        for n in 0..<count {
            autoreleasepool {
                if mode == "copy" || mode == "paste" {
                    #if BASELINE
                    clipboardData = copyPNG(url)
                    precondition(clipboardData != nil)
                    #else
                    precondition(ClipboardImage.copy(url, to: clipboard))
                    if mode == "paste" {
                        clipboardData = clipboard.data(forType: .png)
                        precondition(clipboardData != nil)
                    }
                    #endif
                } else if mode == "markup" {
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
                    defer { try? FileManager.default.removeItem(at: target) }
                    #if BASELINE
                    let image = NSImage(contentsOf: url)!
                    let tiff = image.tiffRepresentation!
                    let data = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
                    try! data.write(to: target, options: .atomic)
                    #else
                    try! writePNG(NSImage(contentsOf: url)!, to: target)
                    #endif
                } else if mode == "watcher" {
                    watcher = ScreenshotWatcher(folder: url, onNew: { _ in }, onChange: {})
                    watcher?.start()
                } else if mode == "falls", let screen = NSScreen.main {
                    let image = makeThumbnail(url)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    let card = CGRect(x: screen.frame.midX - 600 + CGFloat(n * 100), y: screen.frame.maxY - 180,
                                      width: 100, height: 70)
                    CaptureFlight.fall(image: image, card: card, tilt: 2, on: screen)
                } else if mode == "flights", let screen = NSScreen.main {
                    #if BASELINE
                    let maxPixels = 3000
                    #else
                    guard CaptureFlight.canFly else { return }
                    let maxPixels = CaptureFlight.maxImagePixels
                    #endif
                    let image = makeThumbnail(url, maxPixels: maxPixels)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    pixelBytes += image.bytesPerRow * image.height
                    CaptureFlight.fly(image: image, from: screen.frame,
                        to: CGRect(x: screen.frame.midX, y: screen.frame.maxY - 180, width: 100, height: 70),
                        tilt: 2, on: screen, completion: {})
                } else {
                    let thumb = makeThumbnail(url)!
                    let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                    pixelBytes += cg.bytesPerRow * cg.height
                    images.append(thumb)
                }
                sampler.sample()
            }
        }
        if mode == "falls" || mode == "flights" {
            autoreleasepool {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                sampler.sample()
                let windows = NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }
                let area = windows.reduce(0.0) { $0 + $1.frame.width * $1.frame.height }
                print("windows=\(windows.count) window_points=\(Int(area))")
            }
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(1)) }
            print("remaining_windows=\(NSApp.windows.filter { !existing.contains(ObjectIdentifier($0)) }.count)")
        }
        let peak = sampler.finish()
        print("mode=\(mode) base_mib=\(Double(base) / 1048576) peak_mib=\(Double(peak) / 1048576) delta_mib=\(Double(peak - base) / 1048576) decoded_mib=\(Double(pixelBytes) / 1048576)")
        watcher?.stop()
        withExtendedLifetime((images, clipboardData, watcher)) {}
    }
}
