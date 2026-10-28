import AppKit
import Testing
@testable import Rondel
@testable import RondelCore

// The wheel is driven here with synthetic events and drawn offscreen, so
// what's tested is the same view the app puts on screen.

@MainActor
final class Harness {
    let view: WheelView
    var chosen: [Format] = []
    var cancelled = 0

    init(files: [String] = ["/music/take.wav"], unavailable: [Format: String] = [:]) {
        view = WheelView(files: files.map { URL(fileURLWithPath: $0) }, unavailable: unavailable)
        view.appearance = NSAppearance(named: .aqua)
        view.onChoose = { [unowned self] in self.chosen.append($0) }
        view.onCancel = { [unowned self] in self.cancelled += 1 }
    }

    /// A point on a slice, halfway between its label and the inner edge,
    /// in the view's coordinates.
    func point(onSlice slice: Int) -> CGPoint {
        let angle = view.wheel.centreAngle(of: slice)
        let radius = view.wheel.inner + 10
        return CGPoint(x: view.bounds.midX + radius * cos(angle), y: view.bounds.midY + radius * sin(angle))
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        type == .mouseMoved ? view.mouseMoved(with: event) : view.mouseDown(with: event)
    }

    func key(_ code: UInt16, _ characters: String = "") {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    func render() -> NSBitmapImageRep {
        let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }
}

/// How blue a pixel is, given the view's coordinates (y up).
func blueness(_ image: NSBitmapImageRep, at point: CGPoint) -> CGFloat {
    let scale = CGFloat(image.pixelsWide) / image.size.width
    let colour = image.colorAt(x: Int(point.x * scale), y: image.pixelsHigh - 1 - Int(point.y * scale))!
        .usingColorSpace(.sRGB)!
    return colour.blueComponent - colour.redComponent
}

@MainActor @Test func hoveringASliceLightsUpThatSliceAndNoOther() {
    let harness = Harness()
    for slice in 0..<harness.view.wheel.slices {
        harness.mouse(.mouseMoved, at: harness.point(onSlice: slice))
        let image = harness.render()
        #expect(blueness(image, at: harness.point(onSlice: slice)) > 0.3, "slice \(slice) isn't lit")
        let other = (slice + 3) % harness.view.wheel.slices
        #expect(blueness(image, at: harness.point(onSlice: other)) < 0.1, "slice \(other) is lit too")
    }
}

@MainActor @Test func clickingASliceChoosesItsFormat() {
    let harness = Harness()
    harness.mouse(.leftMouseDown, at: harness.point(onSlice: 3))
    #expect(harness.chosen == [.flac])
}

@MainActor @Test func clickingTheMiddleOrOutsideTheRingCancels() {
    let harness = Harness()
    harness.mouse(.leftMouseDown, at: CGPoint(x: harness.view.bounds.midX, y: harness.view.bounds.midY))
    harness.mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2))
    #expect(harness.chosen.isEmpty)
    #expect(harness.cancelled == 2)
}

@MainActor @Test func anUnavailableSliceCantBeChosen() {
    let harness = Harness(unavailable: [.mp3: "Needs ffmpeg"])
    harness.mouse(.leftMouseDown, at: harness.point(onSlice: 0))
    harness.key(18, "1")
    #expect(harness.chosen.isEmpty)
    #expect(harness.cancelled == 0)
}

@MainActor @Test func theKeyboardCanDoEverythingTheMouseCan() {
    let harness = Harness()
    harness.key(124)  // right: the first slice
    harness.key(124)  // right again: the second
    harness.key(36)   // return
    #expect(harness.chosen == [.aac])

    harness.key(123)  // left, from the second: back to the first
    harness.key(49, " ")
    #expect(harness.chosen == [.aac, .mp3])

    harness.key(21, "4")
    #expect(harness.chosen == [.aac, .mp3, .flac])

    harness.key(53)  // Esc
    #expect(harness.cancelled == 1)
}

@MainActor @Test func goingLeftFromTheTopWrapsToTheLastSlice() {
    let harness = Harness()
    harness.key(123)
    harness.key(36)
    #expect(harness.chosen == [.opus])
}

@MainActor @Test func voiceOverSeesOneButtonPerFormat() {
    let harness = Harness(unavailable: [.wav: "It's already WAV"])
    let buttons = harness.view.accessibilityChildren() as? [NSAccessibilityElement] ?? []
    #expect(buttons.count == Format.allCases.count)
    #expect(buttons.map { $0.accessibilityLabel() ?? "" }.first == "MP3, Plays on anything")
    #expect(buttons[4].accessibilityLabel() == "WAV, It's already WAV")
    #expect(buttons[4].isAccessibilityEnabled() == false)
    #expect(buttons[4].accessibilityPerformPress() == false)
    #expect(buttons[2].accessibilityPerformPress() == true)
    #expect(harness.chosen == [.alac])
}

@MainActor @Test func onceConvertingTheRingStopsResponding() {
    let harness = Harness(files: ["/a.wav", "/b.wav"])
    harness.view.state = .converting(.mp3, done: 1, total: 2)
    harness.mouse(.leftMouseDown, at: harness.point(onSlice: 2))
    harness.key(36)
    #expect(harness.chosen.isEmpty)
    #expect(harness.cancelled == 0)
    #expect(harness.view.accessibilityChildren()?.isEmpty == true)
    #expect(harness.view.accessibilityLabel() == "Converting to MP3, 1 of 2 done")
    harness.key(53)  // Esc is how to stop it
    #expect(harness.cancelled == 1)
}

/// Not a check: writes each state to a PNG for a person to look at.
/// RONDEL_SNAPSHOTS=folder swift test --filter snapshots
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["RONDEL_SNAPSHOTS"] != nil))
func snapshots() throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RONDEL_SNAPSHOTS"]!)
    let states: [(String, Harness)] = [
        ("idle", Harness(files: ["/music/Interview take 3.wav"])),
        ("hover", Harness(files: ["/music/a.wav", "/music/b.wav", "/music/c.flac"])),
        ("blocked", Harness(unavailable: [.mp3: "Needs ffmpeg:\nbrew install ffmpeg", .opus: "Needs ffmpeg:\nbrew install ffmpeg"])),
        ("converting", Harness(files: ["/a.wav", "/b.wav", "/c.wav"])),
        ("done", Harness()),
    ]
    states[1].1.mouse(.mouseMoved, at: states[1].1.point(onSlice: 3))
    states[2].1.mouse(.mouseMoved, at: states[2].1.point(onSlice: 0))
    states[3].1.view.state = .converting(.mp3, done: 1, total: 3)
    states[4].1.view.state = .finished(ok: true, message: "3 converted\n1 already MP3")
    for (name, harness) in states {
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            harness.view.appearance = NSAppearance(named: appearance)
            try harness.render().representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("\(name)-\(look).png"))
        }
    }
}
