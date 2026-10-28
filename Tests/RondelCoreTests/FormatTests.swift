import CoreGraphics
import Foundation
import Testing
@testable import RondelCore

@Test func extensionsThatNameOneFormat() {
    #expect(Format(fileExtension: "MP3") == .mp3)
    #expect(Format(fileExtension: "aif") == .aiff)
    #expect(Format(fileExtension: "aiff") == .aiff)
    #expect(Format(fileExtension: "wav") == .wav)
}

@Test func m4aCouldBeEitherAACOrALAC() {
    #expect(Format(fileExtension: "m4a") == nil)
    #expect(Format.aac.fileExtension == Format.alac.fileExtension)
}

@Test func outputNamesCountUpLikeFinderCopies() {
    let source = URL(fileURLWithPath: "/tmp/Interview take.wav")
    #expect(outputName(for: source, format: .mp3, attempt: 1) == "Interview take.mp3")
    #expect(outputName(for: source, format: .mp3, attempt: 2) == "Interview take 2.mp3")
    #expect(outputName(for: source, format: .alac, attempt: 3) == "Interview take 3.m4a")
}

@Test func outputNamesOnlyReplaceTheLastExtension() {
    let source = URL(fileURLWithPath: "/tmp/mix.v2.final.aiff")
    #expect(outputName(for: source, format: .flac, attempt: 1) == "mix.v2.final.flac")
}

let wheel = Wheel(slices: Format.allCases.count, inner: 50, outer: 140)

@Test func sliceZeroIsAtTwelveOClock() {
    #expect(wheel.slice(at: CGPoint(x: 0, y: 100)) == 0)
    // Just either side of twelve o'clock is still slice 0.
    #expect(wheel.slice(at: CGPoint(x: -5, y: 100)) == 0)
    #expect(wheel.slice(at: CGPoint(x: 5, y: 100)) == 0)
}

@Test func slicesGoClockwise() {
    for slice in 0..<wheel.slices {
        let angle = wheel.centreAngle(of: slice)
        let point = CGPoint(x: 100 * cos(angle), y: 100 * sin(angle))
        #expect(wheel.slice(at: point) == slice)
    }
    // With seven slices, three o'clock falls in slice 2 (centred at about 103 degrees clockwise).
    #expect(wheel.slice(at: CGPoint(x: 100, y: 0)) == 2)
    #expect(wheel.slice(at: CGPoint(x: -100, y: 0)) == 5)
}

@Test func theHoleAndOutsideTheRingAreNoSlice() {
    #expect(wheel.slice(at: .zero) == nil)
    #expect(wheel.slice(at: CGPoint(x: 0, y: 49)) == nil)
    #expect(wheel.slice(at: CGPoint(x: 0, y: 50)) == 0)
    #expect(wheel.slice(at: CGPoint(x: 0, y: 140)) == 0)
    #expect(wheel.slice(at: CGPoint(x: 0, y: 141)) == nil)
    #expect(wheel.slice(at: CGPoint(x: 100, y: 100)) == nil)  // a corner of the window, past the rim
}

@Test func labelsSitHalfwayAcrossTheRing() {
    let point = wheel.labelPoint(of: 0)
    #expect(abs(point.x) < 0.001)
    #expect(abs(point.y - 95) < 0.001)
}
