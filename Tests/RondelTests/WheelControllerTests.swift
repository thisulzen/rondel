import AppKit
import Testing
@testable import Rondel
@testable import RondelCore

/// Runs the main run loop until `done` is true or the time is up, so the
/// controller's hops between the main thread and the batch can happen.
@MainActor
func wait(seconds: Double, until done: () -> Bool) async {
    let deadline = Date() + seconds
    while !done() && Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor @Test func pickingAFormatConvertsShowsTheCountAndCloses() async throws {
    _ = NSApplication.shared
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rondel-wheel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = try speech("memo.aiff", in: folder)

    let controller = WheelController(files: [source], tools: Tools(ffmpeg: nil))
    var closed = false
    controller.onClose = { _ in closed = true }

    controller.view.onChoose(.flac)
    #expect(controller.isChoosing == false)

    await wait(seconds: 10) { if case .finished = controller.view.state { true } else { false } }
    guard case .finished(let ok, let message) = controller.view.state else {
        Issue.record("never finished: \(controller.view.state)")
        return
    }
    #expect(ok)
    #expect(message == "1 converted")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("memo.flac").path))

    await wait(seconds: 3) { closed }
    #expect(closed, "the wheel should close itself after showing the result")
}

/// A short clip of the Mac's own voice, so the test needs no audio files.
func speech(_ name: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(name)
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, "Testing the wheel"]
    try say.run()
    say.waitUntilExit()
    return url
}

@MainActor @Test func theServiceReadsEveryFileFinderSends() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("rondel-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let files = [URL(fileURLWithPath: "/music/one.wav"), URL(fileURLWithPath: "/music/two & three.flac")]

    pasteboard.clearContents()
    pasteboard.writeObjects(files as [NSURL])
    #expect(AppDelegate.files(on: pasteboard) == files)

    // The older form: a property list of paths.
    pasteboard.clearContents()
    pasteboard.setPropertyList(files.map(\.path), forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    #expect(AppDelegate.files(on: pasteboard) == files)

    // A web link isn't a file and is ignored.
    pasteboard.clearContents()
    pasteboard.writeObjects([URL(string: "https://example.com/song.mp3")! as NSURL])
    #expect(AppDelegate.files(on: pasteboard).isEmpty)
}
