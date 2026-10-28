import CoreGraphics
import Foundation

/// The shape of the radial menu, kept apart from the drawing so the hit
/// testing can be checked without a screen.
///
/// Slice 0 is centred on twelve o'clock and the rest follow clockwise, like
/// a clock face. Points are relative to the centre with y pointing up, which
/// is what AppKit uses.
public struct Wheel: Sendable {
    public let slices: Int
    public let inner: CGFloat  // radius of the hole in the middle
    public let outer: CGFloat

    public init(slices: Int, inner: CGFloat, outer: CGFloat) {
        self.slices = slices
        self.inner = inner
        self.outer = outer
    }

    public var span: CGFloat { 2 * .pi / CGFloat(slices) }

    /// The slice under a point, or nil in the hole or outside the ring.
    public func slice(at point: CGPoint) -> Int? {
        let distance = hypot(point.x, point.y)
        guard distance >= inner, distance <= outer else { return nil }
        // atan2(x, y) rather than atan2(y, x) measures clockwise from twelve
        // o'clock. Adding half a slice puts slice 0's edges either side of it.
        var angle = atan2(point.x, point.y) + span / 2
        if angle < 0 { angle += 2 * .pi }
        return Int(angle / span) % slices
    }

    /// The angle of a slice's centre in AppKit's convention: radians,
    /// anticlockwise from three o'clock.
    public func centreAngle(of slice: Int) -> CGFloat {
        .pi / 2 - CGFloat(slice) * span
    }

    /// Where a slice's label goes, relative to the centre.
    public func labelPoint(of slice: Int) -> CGPoint {
        let angle = centreAngle(of: slice)
        let radius = (inner + outer) / 2
        return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
    }
}
