import AVFoundation
import Foundation

/// Turns one audio file into another beside it, using ffmpeg if it's
/// installed and Core Audio's afconvert if it isn't.
///
/// ffmpeg is preferred because it carries tags and cover art across, which
/// afconvert drops, and because it's the only one of the two that can write
/// MP3 or Opus. afconvert ships with every Mac, so the five formats Core
/// Audio can encode still work on a machine with nothing installed.
///
/// The original is never touched and nothing is ever overwritten. Output is
/// written to a hidden file in the same folder and renamed into place only
/// once it's complete, so a failure, a cancel or a crash never leaves a
/// half-written file under a real name.
public struct Converter: Sendable {
    public let tools: Tools

    public init(tools: Tools = .find()) {
        self.tools = tools
    }

    /// Returns the URL of the new file. Throws ConversionError.
    public func convert(_ source: URL, to format: Format, cancellation: Cancellation = Cancellation()) throws -> URL {
        if cancellation.isCancelled { throw ConversionError.cancelled }
        guard FileManager.default.fileExists(atPath: source.path) else { throw ConversionError.notFound }
        let audio = Audio(source)
        if audio?.format == format { throw ConversionError.alreadyThatFormat(format) }

        let folder = source.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw ConversionError.folderNotWritable(folder.path)
        }
        // The stem is cut short so a name already near the 255-byte limit
        // doesn't go over it once the temporary suffix is added.
        let stem = source.deletingPathExtension().lastPathComponent.prefix(80)
        let temp = folder.appendingPathComponent(".\(stem).\(UUID().uuidString.prefix(8)).rondel.\(format.fileExtension)")
        // Once the rename succeeds there's nothing here to remove; until
        // then, this is what cleans up after a failure or a cancel.
        defer { try? FileManager.default.removeItem(at: temp) }

        let (tool, arguments) = try command(source, audio, format, temp)
        try run(tool, arguments, cancellation)
        return try moveIntoPlace(temp, source: source, format: format)
    }

    private func command(_ source: URL, _ audio: Audio?, _ format: Format, _ output: URL) throws -> (URL, [String]) {
        if let ffmpeg = tools.ffmpeg {
            return (ffmpeg, ffmpegArguments(source, audio, format, output))
        }
        if format.needsFFmpeg { throw ConversionError.needsFFmpeg(format) }
        guard let audio else { throw ConversionError.unreadable }
        return (Tools.afconvert, try afconvertArguments(source, audio, format, output))
    }

    func ffmpegArguments(_ source: URL, _ audio: Audio?, _ format: Format, _ output: URL) -> [String] {
        let bits = audio?.pcmBits ?? 16
        var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", source.path, "-map", "0:a:0"]
        // Cover art travels as a video stream. These four containers can hold
        // it; WAV, AIFF and Ogg would refuse the whole conversion. The "?"
        // makes it optional, so a file without art still converts.
        if [.mp3, .aac, .alac, .flac].contains(format) {
            arguments += ["-map", "0:v?", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }
        switch format {
        case .mp3:
            // V0, the highest-quality VBR setting. ID3v2.3 because Windows
            // Explorer and older car stereos can't read the default 2.4.
            arguments += ["-c:a", "libmp3lame", "-q:a", "0", "-id3v2_version", "3"]
        case .aac:
            arguments += ["-c:a", "aac", "-b:a", audio?.channels == 1 ? "128k" : "256k"]
        case .alac:
            arguments += ["-c:a", "alac", "-sample_fmt", bits == 16 ? "s16p" : "s32p"]
        case .flac:
            arguments += ["-c:a", "flac", "-sample_fmt", bits == 16 ? "s16" : "s32"]
        case .wav:
            // RF64 only kicks in past 4 GB, where a plain WAV header overflows.
            arguments += ["-c:a", "pcm_s\(bits)le", "-rf64", "auto"]
        case .aiff:
            arguments += ["-c:a", "pcm_s\(bits)be", "-write_id3v2", "1"]
        case .opus:
            arguments += ["-c:a", "libopus", "-b:a", "128k"]
        }
        return arguments + [output.path]
    }

    func afconvertArguments(_ source: URL, _ audio: Audio, _ format: Format, _ output: URL) throws -> [String] {
        // afconvert keeps a lossless source's bit depth for ALAC and FLAC on
        // its own, but PCM needs telling.
        let options: [String] = switch format {
        case .aac: ["-f", "m4af", "-d", "aac", "-b", audio.channels == 1 ? "128000" : "256000"]
        case .alac: ["-f", "m4af", "-d", "alac"]
        case .flac: ["-f", "flac", "-d", "flac"]
        case .wav: ["-f", "WAVE", "-d", "LEI\(audio.pcmBits)"]
        case .aiff: ["-f", "AIFF", "-d", "BEI\(audio.pcmBits)"]
        case .mp3, .opus: throw ConversionError.needsFFmpeg(format)
        }
        return options + [source.path, output.path]
    }

    private func run(_ tool: URL, _ arguments: [String], _ cancellation: Cancellation) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        guard try cancellation.start(process) else { throw ConversionError.cancelled }
        // Read before waiting: a damaged file can make ffmpeg print an error
        // per frame, and once the pipe's buffer fills it would block forever
        // on a write nobody reads.
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        cancellation.finished(process)

        if cancellation.isCancelled { throw ConversionError.cancelled }
        guard process.terminationStatus == 0 else {
            let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            let message = lines.last.map(String.init) ?? "\(tool.lastPathComponent) exited with status \(process.terminationStatus)"
            throw ConversionError.toolFailed(message)
        }
    }

    private func moveIntoPlace(_ temp: URL, source: URL, format: Format) throws -> URL {
        guard FileManager.default.fileExists(atPath: temp.path) else {
            throw ConversionError.toolFailed("the converter finished without writing anything")
        }
        let folder = source.deletingLastPathComponent()
        for attempt in 1... {
            let destination = folder.appendingPathComponent(outputName(for: source, format: format, attempt: attempt))
            // With RENAME_EXCL the rename fails if the name is taken, and the
            // check and the rename are one step, so two conversions finishing
            // together can't both take "song.mp3".
            if renamex_np(temp.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            switch errno {
            case EEXIST:
                continue
            case ENOTSUP, EINVAL:
                // Some external drives (exFAT, SMB shares) don't support the
                // flag. Checking first and then moving leaves a gap a second
                // writer could slip into, but only on those drives.
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                do {
                    try FileManager.default.moveItem(at: temp, to: destination)
                    return destination
                } catch {
                    throw ConversionError.toolFailed("couldn't save the result: \(error.localizedDescription)")
                }
            default:
                throw ConversionError.toolFailed("couldn't save the result: \(String(cString: strerror(errno)))")
            }
        }
        fatalError("unreachable")
    }
}

public enum ConversionError: LocalizedError, Equatable, Sendable {
    case alreadyThatFormat(Format)
    case notFound
    case needsFFmpeg(Format)
    case unreadable
    case folderNotWritable(String)
    case toolFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyThatFormat(let format):
            "It's already \(format.name)."
        case .notFound:
            "The file isn't there any more. It may have been moved or deleted."
        case .needsFFmpeg(let format):
            "\(format.name) needs ffmpeg, which isn't installed. Install it with: brew install ffmpeg"
        case .unreadable:
            "This isn't audio Core Audio can read. Installing ffmpeg (brew install ffmpeg) adds many more formats."
        case .folderNotWritable(let folder):
            "Can't save into \(folder). Copy the file somewhere you can write to and try again."
        case .toolFailed(let message):
            message
        case .cancelled:
            "Stopped before it finished."
        }
    }
}

/// Where the converter finds ffmpeg and afconvert.
public struct Tools: Sendable, CustomStringConvertible {
    public var ffmpeg: URL?
    public static let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")

    public init(ffmpeg: URL?) {
        self.ffmpeg = ffmpeg
    }

    /// An app opened from Finder gets a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin)
    /// that doesn't include Homebrew, so the usual install locations are
    /// searched after whatever PATH there is.
    public static func find(environment: [String: String] = ProcessInfo.processInfo.environment) -> Tools {
        let folders = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let ffmpeg = folders.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        return Tools(ffmpeg: ffmpeg)
    }

    public var description: String { ffmpeg.map { "ffmpeg at \($0.path)" } ?? "Core Audio only" }
}

/// Lets a batch be stopped part-way. Conversions that haven't started don't,
/// and running ones are killed; the converter then deletes what they'd written.
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var running = Set<Process>()

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let processes = lock.withLock {
            cancelled = true
            return running
        }
        processes.forEach { $0.terminate() }
    }

    /// Starts the process unless the batch is already cancelled. Starting it
    /// under the lock means a cancel can't land between the check and the
    /// start and miss it.
    func start(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !cancelled else { return false }
            try process.run()
            running.insert(process)
            return true
        }
    }

    func finished(_ process: Process) {
        _ = lock.withLock { running.remove(process) }
    }
}

/// What Core Audio can tell about a file before it's converted.
struct Audio {
    let format: Format?  // the wheel format it already is, if any
    let bits: Int
    let channels: Int

    /// The bit depth to write PCM at: the source's own, rounded up to one
    /// WAV and AIFF both support.
    var pcmBits: Int { bits <= 16 ? 16 : bits <= 24 ? 24 : 32 }

    /// Nil if Core Audio can't open the file, which ffmpeg may still manage.
    init?(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let description = file.fileFormat.streamDescription.pointee
        let ext = url.pathExtension.lowercased()
        channels = Int(description.mChannelsPerFrame)

        let codec: Format?
        switch description.mFormatID {
        case kAudioFormatLinearPCM:
            // Floating-point sources come out as 24-bit integers, which AIFF
            // can hold and which keeps more detail than anyone can hear.
            let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
            bits = isFloat ? 24 : Int(description.mBitsPerChannel)
            codec = [.wav, .aiff].contains(Format(fileExtension: ext)) ? Format(fileExtension: ext) : nil
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // Lossless codecs record the original bit depth in the format
            // flags. mBitsPerChannel is zero for them.
            bits = [1: 16, 2: 20, 3: 24, 4: 32][description.mFormatFlags] ?? 16
            codec = description.mFormatID == kAudioFormatFLAC ? .flac : .alac
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
            bits = 16
            codec = .aac
        case kAudioFormatMPEGLayer3:
            bits = 16
            codec = .mp3
        case kAudioFormatOpus:
            bits = 16
            codec = .opus
        default:
            bits = 16
            codec = nil
        }
        // FLAC inside an .m4a, or AAC in a .caf, isn't what anyone means by
        // "already FLAC": converting it still gives them the file they want.
        let sameContainer = codec?.fileExtension == ext || (codec == .aiff && ext == "aif")
        format = sameContainer ? codec : nil
    }
}
