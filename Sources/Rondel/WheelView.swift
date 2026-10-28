import AppKit
import RondelCore

/// The radial menu: a ring of formats around a hole that says what's going on.
///
/// It draws everything itself except the frosted background, which is an
/// NSVisualEffectView so it matches the menus around it in both light and
/// dark mode. The wheel sits inside `background` rather than the other way
/// round, because a view's subviews always draw on top of the view itself.
/// After a format is picked the ring goes away and the hole stays on screen
/// as a small progress disc.
final class WheelView: NSView {
    enum State {
        case choosing
        case converting(Format, done: Int, total: Int)
        case finished(ok: Bool, message: String)
    }

    let wheel = Wheel(slices: Format.allCases.count, inner: 60, outer: 144)
    let files: [URL]
    let unavailable: [Format: String]
    var onChoose: (Format) -> Void = { _ in }
    var onCancel: () -> Void = {}

    var state = State.choosing {
        didSet {
            needsDisplay = true
            spinner.isHidden = !isConverting
            isConverting ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
            background.maskImage = disc(radius: isChoosing ? wheel.outer : wheel.inner)
            window?.invalidateShadow()
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    /// Put this in the window; the wheel is inside it.
    let background = NSVisualEffectView()
    private var highlighted: Int? {
        didSet { if highlighted != oldValue { needsDisplay = true } }
    }
    private let spinner = NSProgressIndicator()
    private lazy var sliceElements = Format.allCases.indices.map { makeElement(for: $0) }

    private var isChoosing: Bool { if case .choosing = state { true } else { false } }
    private var isConverting: Bool { if case .converting = state { true } else { false } }
    private var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    init(files: [URL], unavailable: [Format: String]) {
        self.files = files
        self.unavailable = unavailable
        let side = (wheel.outer + 12) * 2
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))

        background.frame = bounds
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = disc(radius: wheel.outer)
        background.addSubview(self)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.sizeToFit()
        spinner.frame.origin = CGPoint(x: centre.x - spinner.frame.width / 2, y: centre.y + 6)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .choosing:
            drawRing()
            if let highlighted {
                let format = Format.allCases[highlighted]
                drawCentre(format.name, unavailable[format] ?? format.blurb)
            } else {
                let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
                drawCentre(what, "Convert to…")
            }
        case .converting(let format, let done, let total):
            drawCentre(nil, total == 1 ? "To \(format.name)\nEsc to stop" : "\(done) of \(total)\nEsc to stop", below: true)
        case .finished(let ok, let message):
            let symbol = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 22, weight: .medium).applying(.init(paletteColors: [.white, ok ? .systemGreen : .systemOrange])))!
            symbol.draw(in: NSRect(x: centre.x - symbol.size.width / 2, y: centre.y + 4, width: symbol.size.width, height: symbol.size.height))
            drawCentre(nil, message, below: true)
        }
    }

    private func drawRing() {
        for (i, format) in Format.allCases.enumerated() {
            let angle = wheel.centreAngle(of: i)
            let blocked = unavailable[format] != nil
            if i == highlighted {
                (blocked ? NSColor.quaternaryLabelColor : NSColor.controlAccentColor).setFill()
                sector(from: angle - wheel.span / 2, to: angle + wheel.span / 2).fill()
            }
            let colour: NSColor = blocked ? .tertiaryLabelColor : i == highlighted ? .alternateSelectedControlTextColor : .labelColor
            let label = NSAttributedString(string: format.name, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: colour,
            ])
            let point = wheel.labelPoint(of: i)
            label.draw(at: CGPoint(x: centre.x + point.x - label.size().width / 2, y: centre.y + point.y - label.size().height / 2))
        }

        NSColor.separatorColor.setStroke()
        for i in 0..<wheel.slices {
            let angle = wheel.centreAngle(of: i) + wheel.span / 2
            let line = NSBezierPath()
            line.move(to: CGPoint(x: centre.x + wheel.inner * cos(angle), y: centre.y + wheel.inner * sin(angle)))
            line.line(to: CGPoint(x: centre.x + wheel.outer * cos(angle), y: centre.y + wheel.outer * sin(angle)))
            line.stroke()
        }
        NSBezierPath(ovalIn: NSRect(x: centre.x - wheel.inner, y: centre.y - wheel.inner, width: wheel.inner * 2, height: wheel.inner * 2)).stroke()
    }

    /// A title and up to three lines of detail, centred in the hole. With
    /// `below`, the text sits under the spinner or symbol instead.
    private func drawCentre(_ title: String?, _ detail: String, below: Bool = false) {
        // A long file name loses its middle, which keeps the end people
        // tell takes apart by; the detail wraps instead.
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byTruncatingMiddle
        let detailStyle = NSMutableParagraphStyle()
        detailStyle.alignment = .center
        let text = NSMutableAttributedString()
        if let title {
            text.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: titleStyle,
            ]))
        }
        text.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: detailStyle,
        ]))
        // The widest box that fits inside the hole at this height.
        let width = wheel.inner * 1.7
        let height = text.boundingRect(with: CGSize(width: width, height: 200), options: .usesLineFragmentOrigin).height
        let top = below ? centre.y - 2 : centre.y + height / 2
        text.draw(with: NSRect(x: centre.x - width / 2, y: top - height, width: width, height: height), options: .usesLineFragmentOrigin)
    }

    private func sector(from start: CGFloat, to end: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let degrees = { (radians: CGFloat) in radians * 180 / .pi }
        path.appendArc(withCenter: centre, radius: wheel.outer, startAngle: degrees(start), endAngle: degrees(end))
        path.appendArc(withCenter: centre, radius: wheel.inner, startAngle: degrees(end), endAngle: degrees(start), clockwise: true)
        path.close()
        return path
    }

    private func disc(radius: CGFloat) -> NSImage {
        NSImage(size: bounds.size, flipped: false) { [centre] _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
    }

    // MARK: Mouse and keyboard

    private func slice(under event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return wheel.slice(at: CGPoint(x: point.x - centre.x, y: point.y - centre.y))
    }

    override func mouseMoved(with event: NSEvent) {
        if isChoosing { highlighted = slice(under: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if isChoosing { highlighted = nil }
    }

    override func mouseDown(with event: NSEvent) {
        switch state {
        case .choosing:
            if let i = slice(under: event) { choose(i) } else { onCancel() }
        case .converting:
            break  // a stray click shouldn't stop a conversion; Esc does
        case .finished:
            onCancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        let count = wheel.slices
        switch event.keyCode {
        case 53:  // Esc
            onCancel()
        case 123, 126:  // left, up: anticlockwise
            if isChoosing { highlighted = ((highlighted ?? 0) - 1 + count) % count }
        case 124, 125:  // right, down: clockwise
            if isChoosing { highlighted = highlighted.map { ($0 + 1) % count } ?? 0 }
        case 36, 76, 49:  // return, enter, space
            if isChoosing, let highlighted { choose(highlighted) }
        default:
            // 1 to 7 pick a slice directly, counting clockwise from the top.
            if isChoosing, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...count).contains(digit) {
                choose(digit - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func choose(_ slice: Int) {
        let format = Format.allCases[slice]
        if unavailable[format] == nil {
            onChoose(format)
        } else {
            highlighted = slice  // show the reason instead
            NSSound.beep()
        }
    }

    // MARK: Accessibility

    // While choosing, each slice is a button VoiceOver can find and press.
    // Afterwards the view reads out its status instead.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        switch state {
        case .choosing: "Convert \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files") to"
        case .converting(let format, let done, let total): "Converting to \(format.name), \(done) of \(total) done"
        case .finished(_, let message): message.replacingOccurrences(of: "\n", with: ", ")
        }
    }

    override func accessibilityChildren() -> [Any]? {
        isChoosing ? sliceElements : []
    }

    private func makeElement(for slice: Int) -> SliceElement {
        let format = Format.allCases[slice]
        let element = SliceElement { [weak self] in
            guard let self, self.isChoosing, self.unavailable[format] == nil else { return false }
            self.onChoose(format)
            return true
        }
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.button)
        element.setAccessibilityLabel("\(format.name), \(unavailable[format] ?? format.blurb)")
        element.setAccessibilityEnabled(unavailable[format] == nil)
        let point = wheel.labelPoint(of: slice)
        element.setAccessibilityFrameInParentSpace(NSRect(x: centre.x + point.x - 30, y: centre.y + point.y - 15, width: 60, height: 30))
        return element
    }
}

private final class SliceElement: NSAccessibilityElement {
    let press: () -> Bool

    init(press: @escaping () -> Bool) {
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool { press() }
}
