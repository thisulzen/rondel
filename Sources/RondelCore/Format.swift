import Foundation

/// The formats on the wheel, clockwise from twelve o'clock.
public enum Format: String, CaseIterable, Sendable {
    case mp3, aac, alac, flac, wav, aiff, opus

    public var name: String {
        switch self {
        case .mp3: "MP3"
        case .aac: "AAC"
        case .alac: "ALAC"
        case .flac: "FLAC"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .opus: "Opus"
        }
    }

    /// One line for the middle of the wheel, so nobody has to know what ALAC is.
    public var blurb: String {
        switch self {
        case .mp3: "Plays on anything"
        case .aac: "Small and sounds good"
        case .alac: "Lossless, for Apple devices"
        case .flac: "Lossless, about half the size of WAV"
        case .wav: "Uncompressed, for editing"
        case .aiff: "Uncompressed, the Mac's WAV"
        case .opus: "Smallest at good quality"
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp3: "mp3"
        case .aac, .alac: "m4a"
        case .flac: "flac"
        case .wav: "wav"
        case .aiff: "aiff"
        case .opus: "opus"
        }
    }

    /// Core Audio can decode MP3 and Opus but has no encoder for either.
    public var needsFFmpeg: Bool { self == .mp3 || self == .opus }

    /// The format a file is already in, judging by its extension alone.
    /// `.m4a` could be AAC or ALAC, so it gives nil and the converter asks
    /// Core Audio instead.
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp3": self = .mp3
        case "flac": self = .flac
        case "wav": self = .wav
        case "aif", "aiff": self = .aiff
        case "opus": self = .opus
        default: return nil
        }
    }
}

/// The name a converted file gets: the original's name with the new
/// extension, then "song 2.mp3", "song 3.mp3" and so on if that's taken,
/// the way Finder names copies.
public func outputName(for source: URL, format: Format, attempt: Int) -> String {
    let stem = source.deletingPathExtension().lastPathComponent
    return attempt == 1 ? "\(stem).\(format.fileExtension)" : "\(stem) \(attempt).\(format.fileExtension)"
}
