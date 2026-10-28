import AppKit
import RondelCore

/// Rondel has no Dock icon and no main window. Finder hands it files in one
/// of three ways (the Convert Audio… service, Open With, or a drop on the
/// app's icon) and each set of files gets a wheel at the mouse pointer. Once
/// every wheel has closed, the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wheels: [WheelController] = []
    private var choosingFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        // Files named on the command line, as in `Rondel song.wav`.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !paths.isEmpty {
            show(paths.map { URL(fileURLWithPath: $0) })
        } else if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true {
            // Opened by itself, not by Finder with files: ask for some.
            chooseFiles()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        show(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if wheels.isEmpty { chooseFiles() }
        return false
    }

    /// The Convert Audio… item in Finder's right-click menu. The name has to
    /// match NSMessage in Info.plist.
    @objc func convertAudio(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.files(on: pasteboard)
        if urls.isEmpty {
            error.pointee = "No files were selected." as NSString
        } else {
            show(urls)
        }
    }

    /// Reading NSURL objects covers both the file URLs Finder sends today
    /// and the list of paths older apps still put on the pasteboard.
    static func files(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func show(_ files: [URL]) {
        // A new right-click replaces a wheel nobody has used yet, but never
        // one that's converting.
        wheels.filter(\.isChoosing).forEach { $0.close() }
        let wheel = WheelController(files: files, tools: Tools.find())
        wheel.onClose = { [weak self] closed in
            self?.wheels.removeAll { $0 === closed }
            self?.quitIfIdle()
        }
        wheels.append(wheel)
        wheel.show()
    }

    private func chooseFiles() {
        guard !choosingFiles else { return }
        choosingFiles = true
        defer { choosingFiles = false }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Choose"
        panel.message = "Choose audio to convert. Next time you can right-click it in Finder and choose Convert Audio…"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            show(panel.urls)
        } else {
            quitIfIdle()
        }
    }

    private func quitIfIdle() {
        if wheels.isEmpty && !choosingFiles { NSApp.terminate(nil) }
    }
}

/// One wheel on screen and the batch it starts.
final class WheelController: NSObject, NSWindowDelegate {
    var onClose: (WheelController) -> Void = { _ in }
    private let files: [URL]
    private let tools: Tools
    let view: WheelView
    private let panel: WheelPanel
    private var batch: Batch?
    private var outsideClicks: Any?

    var isChoosing: Bool { if case .choosing = view.state { true } else { false } }

    init(files: [URL], tools: Tools) {
        self.files = files
        self.tools = tools
        let unavailable = Format.allCases.reduce(into: [Format: String]()) { reasons, format in
            reasons[format] = reasonUnavailable(format, files: files, tools: tools)
        }
        view = WheelView(files: files, unavailable: unavailable)
        panel = WheelPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.contentView = view.background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        view.onChoose = { [weak self] in self?.convert(to: $0) }
        view.onCancel = { [weak self] in self?.cancel() }
    }

    func show() {
        // Centre on the pointer, which after a right-click is where the
        // user's attention already is, but keep the whole wheel on screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var frame = panel.frame
        frame.origin = CGPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height / 2)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }

        // A click anywhere else dismisses the wheel, like any menu. This
        // works even if macOS didn't let the app take focus.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.isChoosing == true { self?.close() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if isChoosing { close() }
    }

    func close() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        panel.orderOut(nil)
        onClose(self)
    }

    private func cancel() {
        switch view.state {
        case .choosing, .finished: close()
        case .converting: batch?.cancellation.cancel()
        }
    }

    private func convert(to format: Format) {
        let batch = Batch(files: files, format: format, converter: Converter(tools: tools))
        self.batch = batch
        view.state = .converting(format, done: 0, total: files.count)
        DispatchQueue.global(qos: .userInitiated).async {
            let results = batch.run { done in
                DispatchQueue.main.async { self.view.state = .converting(format, done: done, total: self.files.count) }
            }
            DispatchQueue.main.async { self.finish(results, format: format) }
        }
    }

    private func finish(_ results: [Result<URL, ConversionError>], format: Format) {
        var failures: [(URL, ConversionError)] = []
        for (file, result) in zip(files, results) {
            if case .failure(let error) = result, error != .alreadyThatFormat(format), error != .cancelled {
                failures.append((file, error))
            }
        }
        let converted = results.contains { (try? $0.get()) != nil }
        view.state = .finished(ok: failures.isEmpty && converted, message: Batch.summary(results, format: format))

        guard !failures.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.close() }
            return
        }
        // The disc only has room for counts; the alert says which files and why.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "Couldn't convert \(failures[0].0.lastPathComponent)"
            : "Couldn't convert \(failures.count) of \(files.count) files"
        let shown = failures.prefix(8).map { failures.count == 1 ? $1.localizedDescription : "\($0.lastPathComponent): \($1.localizedDescription)" }
        alert.informativeText = (shown + (failures.count > 8 ? ["and \(failures.count - 8) more"] : [])).joined(separator: "\n\n")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        close()
    }
}

/// A borderless panel can't become the key window unless it says so, and it
/// has to be key to hear Esc and the arrow keys.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
