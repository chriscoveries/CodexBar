import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Self-driving diagnostic for provider tab-switch rendering artifacts. Inert
/// unless `CODEXBAR_FLICKER_PROBE_DIR` is set at launch. When armed it opens the
/// merged menu, switches provider tabs programmatically, and captures the menu
/// window's *own* composited frames plus a window-frame timeline for offline
/// analysis.
///
/// Two quirks shape the implementation:
/// - `openMenuFromShortcut` blocks in NSMenu's synchronous tracking loop, where
///   Swift Concurrency main-actor jobs do not run; all main-thread driving uses
///   a common-modes `Timer`.
/// - The interesting frames appear while the main thread is busy rebuilding the
///   menu, so captures run on a background thread: `CGWindowListCreateImage`
///   reads the WindowServer's current composite without touching AppKit.
@MainActor
enum MenuSwitchFlickerProbe {
    private nonisolated static let processStart = DispatchTime.now()

    /// Appends timestamped diagnostic lines from production code paths while the
    /// probe env var is set; inert otherwise.
    nonisolated static func debugLog(_ line: @autoclosure () -> String) {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_FLICKER_PROBE_DIR"],
              !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("padding-log.txt")
        // Read the start anchor before now(): the lazy static initializes on first
        // access, so the reverse order makes start > now and underflows UInt64.
        let startNs = self.processStart.uptimeNanoseconds
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = nowNs >= startNs ? Double(nowNs - startNs) / 1_000_000 : 0
        let text = String(format: "[%9.1fms] ", elapsedMs) + line() + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func startIfRequested(controller: StatusItemController) {
        guard let dir = ProcessInfo.processInfo.environment["CODEXBAR_FLICKER_PROBE_DIR"],
              !dir.isEmpty else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        // Two sessions: the second verifies open-time behavior with state carried
        // over from the first (e.g. the stable-height session floor).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            ProbeSession(controller: controller, directory: directory).begin()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ProbeSession(
                    controller: controller,
                    directory: directory.appendingPathComponent("second")).begin()
            }
        }
    }

    /// Background frame grabber: samples the window's WindowServer composite and
    /// bounds on a dedicated thread so main-thread stalls cannot hide frames.
    /// Frames are encoded to disk immediately — retaining full-resolution
    /// captures in memory would grow to gigabytes over a session — so only the
    /// lightweight bounds timeline is kept in memory.
    final class BackgroundFrameGrabber: @unchecked Sendable {
        struct Sample {
            let elapsedMs: Double
            let bounds: CGRect
            let wroteFrame: Bool
        }

        private static let maxFrameCount = 2000

        private let windowID: CGWindowID
        private let start: DispatchTime
        private let directory: URL
        private let lock = NSLock()
        private var storage: [Sample] = []
        private var frameIndex = 0
        private var running = true

        init(windowID: CGWindowID, start: DispatchTime, directory: URL) {
            self.windowID = windowID
            self.start = start
            self.directory = directory
            self.storage.reserveCapacity(Self.maxFrameCount)
            Thread.detachNewThread { [weak self] in
                Thread.current.name = "MenuSwitchFlickerProbe.grabber"
                self?.loop()
            }
        }

        func stop() -> [Sample] {
            self.lock.lock()
            self.running = false
            let result = self.storage
            self.lock.unlock()
            return result
        }

        private func loop() {
            while true {
                self.lock.lock()
                let keepRunning = self.running
                let index = self.frameIndex
                self.lock.unlock()
                guard keepRunning, index < Self.maxFrameCount else { return }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.start.uptimeNanoseconds)
                    / 1_000_000
                // Include framing so the window shadow / material edge is captured too.
                let image = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    self.windowID,
                    [.bestResolution])
                let bounds = self.currentBounds() ?? .null
                var wroteFrame = false
                if let image {
                    let name = String(format: "frame-%04d-%07.1fms.png", index, elapsed)
                    MenuSwitchFlickerProbe.writePNG(image, to: self.directory.appendingPathComponent(name))
                    wroteFrame = true
                }
                self.lock.lock()
                self.frameIndex += 1
                self.storage.append(Sample(elapsedMs: elapsed, bounds: bounds, wroteFrame: wroteFrame))
                self.lock.unlock()
                usleep(3000)
            }
        }

        private func currentBounds() -> CGRect? {
            guard let info = CGWindowListCopyWindowInfo(
                .optionIncludingWindow,
                self.windowID) as? [[String: Any]],
                let record = info.first,
                let boundsDict = record[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            return CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0)
        }
    }

    @MainActor
    final class ProbeSession {
        private let controller: StatusItemController
        private let directory: URL
        private var timer: Timer?
        private var log: [String] = []
        private var startedAt: DispatchTime?
        private var switchScheduleIndex = 0
        private var searchTicks = 0
        private weak var menu: NSMenu?
        private var grabber: BackgroundFrameGrabber?
        private var originalSegment: Int?
        private var targetSegment: Int?

        init(controller: StatusItemController, directory: URL) {
            self.controller = controller
            self.directory = directory
        }

        func begin() {
            try? FileManager.default.createDirectory(
                at: self.directory,
                withIntermediateDirectories: true)
            let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            // Blocks in menu tracking until `cancelTracking()`; the timer keeps firing.
            self.controller.openMenuFromShortcut()
            self.finish()
        }

        /// Three away/back cycles give slower external captures several chances
        /// to land on any transient artifact. Always ends on the original segment.
        private static let switchScheduleMs = [400, 1000, 1600, 2200, 2800, 3400]
        private static let sessionEndMs = 4200

        private func tick() {
            guard let startedAt = self.startedAtOrLocateMenu() else { return }
            let now = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
            if now >= Self.sessionEndMs {
                self.timer?.invalidate()
                self.timer = nil
                self.menu?.cancelTracking()
                return
            }
            guard self.switchScheduleIndex < Self.switchScheduleMs.count,
                  now >= Self.switchScheduleMs[self.switchScheduleIndex] else { return }
            let switchIndex = self.switchScheduleIndex
            self.switchScheduleIndex += 1
            let segment = switchIndex.isMultiple(of: 2) ? self.targetSegment : self.originalSegment
            let handled = segment.map { self.switchSegment($0) } ?? false
            self.log.append("switch#\(switchIndex) to segment \(String(describing: segment)) " +
                "at \(now)ms handled=\(handled)")
        }

        private func startedAtOrLocateMenu() -> DispatchTime? {
            if let startedAt = self.startedAt { return startedAt }
            self.searchTicks += 1
            if let menu = self.controller.openMenus.values.first,
               menu.items.first?.view is ProviderSwitcherView,
               let window = menu.items.compactMap(\.view?.window).first
            {
                self.menu = menu
                self.resolveSegments()
                let start = DispatchTime.now()
                self.startedAt = start
                self.grabber = BackgroundFrameGrabber(
                    windowID: CGWindowID(window.windowNumber),
                    start: start,
                    directory: self.directory)
                self.log.append("menu located, windowNumber=\(window.windowNumber) " +
                    "frame=\(window.frame) original=\(String(describing: self.originalSegment)) " +
                    "target=\(String(describing: self.targetSegment))")
                return start
            }
            if self.searchTicks > 1200 {
                self.log.append("gave up locating menu after \(self.searchTicks) ticks")
                self.timer?.invalidate()
                self.timer = nil
                self.controller.openMenus.values.first?.cancelTracking()
            }
            return nil
        }

        /// Segment order mirrors the switcher: optional Overview first, then the
        /// display providers. Picks the first provider segment that is not the
        /// current selection so the probe performs a real switch, and restores
        /// the original selection afterwards.
        private func resolveSegments() {
            let enabledProviders = self.controller.store.enabledProvidersForDisplay()
            let includesOverview = self.controller.includesOverviewTab(enabledProviders: enabledProviders)
            let selection = self.controller.resolvedSwitcherSelection(
                enabledProviders: enabledProviders,
                includesOverview: includesOverview)
            var segments: [ProviderSwitcherSelection] = enabledProviders.map { .provider($0) }
            if includesOverview {
                segments.insert(.overview, at: 0)
            }
            self.originalSegment = segments.firstIndex(of: selection)
            self.targetSegment = segments.firstIndex { candidate in
                candidate != selection && candidate != .overview
            }
        }

        private func switchSegment(_ index: Int) -> Bool {
            guard let switcher = self.menu?.items.first?.view as? ProviderSwitcherView else { return false }
            return switcher.handleKeyboardSelection(at: index)
        }

        private func finish() {
            self.timer?.invalidate()
            self.timer = nil
            let samples = self.grabber?.stop() ?? []
            self.log.append("captured \(samples.count) samples")
            var previousBounds = CGRect.null
            for sample in samples where sample.bounds != previousBounds {
                previousBounds = sample.bounds
                self.log.append(String(
                    format: "windowBounds @%.1fms -> %@",
                    sample.elapsedMs,
                    String(describing: sample.bounds)))
            }
            let nilFrames = samples.count(where: { !$0.wroteFrame })
            self.log.append("nil captures: \(nilFrames)")
            let text = self.log.joined(separator: "\n") + "\n"
            try? text.write(
                to: self.directory.appendingPathComponent("probe-log.txt"),
                atomically: true,
                encoding: .utf8)
        }
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
