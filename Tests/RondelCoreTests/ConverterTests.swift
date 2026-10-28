import AVFoundation
import Foundation
import Testing
@testable import RondelCore

// These run the real tools on real files. Every test runs once with Core
// Audio alone and, if ffmpeg is installed, once more with ffmpeg.
let coreAudio = Tools(ffmpeg: nil)
let installed = Tools.find()
let engines = [coreAudio] + (installed.ffmpeg == nil ? [] : [installed])

func formats(for tools: Tools) -> [Format] {
    Format.allCases.filter { tools.ffmpeg != nil || !$0.needsFFmpeg }
}

/// A fresh folder per test, removed afterwards.
func withFolder(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rondel-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(folder)
}

/// Writes a 440 Hz sine with Core Audio, so the tests need nothing but a Mac.
/// The extension picks the container.
@discardableResult
func tone(_ name: String, in folder: URL, seconds: Double = 1, rate: Double = 44_100, channels: Int = 2, bits: Int = 16) throws -> URL {
    let url = folder.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: bits,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: url.pathExtension.hasPrefix("aif"),
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    // 440 whole cycles fit in a second, so one second written over and over
    // is a seamless tone and long files don't need the memory to match.
    let frames = AVAudioFrameCount(rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<channels {
        let samples = buffer.floatChannelData![channel]
        for i in 0..<Int(frames) {
            samples[i] = Float(0.5 * sin(2 * .pi * 440 * Double(i) / rate))
        }
    }
    for _ in 0..<Int(seconds) {
        try file.write(from: buffer)
    }
    return url
}

struct Inspection {
    let seconds: Double
    let rate: Double
    let channels: Int
    let bits: Int
}

/// Decodes a file with Core Audio, which is independent of whichever tool
/// wrote it.
func inspect(_ url: URL) throws -> Inspection {
    let file = try AVAudioFile(forReading: url)
    let audio = try #require(Audio(url))
    return Inspection(
        seconds: Double(file.length) / file.fileFormat.sampleRate,
        rate: file.fileFormat.sampleRate,
        channels: audio.channels,
        bits: audio.bits
    )
}

func contents(of folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

func ffmpeg(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = try #require(installed.ffmpeg)
    process.arguments = ["-nostdin", "-loglevel", "error", "-y"] + arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

/// Runs ffprobe and returns its JSON.
func probe(_ url: URL, _ entries: String) throws -> [String: Any] {
    let process = Process()
    process.executableURL = try #require(installed.ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe")
    process.arguments = ["-v", "error", "-show_entries", entries, "-of", "json", url.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test(arguments: engines)
func everyFormatPlaysBackTheSameLengthAndShape(tools: Tools) throws {
    try withFolder { folder in
        let source = try tone("tone.wav", in: folder)
        for format in formats(for: tools) where format != .wav {
            let output = try Converter(tools: tools).convert(source, to: format)
            #expect(output.lastPathComponent == "tone.\(format.fileExtension)" || output.lastPathComponent == "tone 2.m4a")
            let result = try inspect(output)
            // Lossy encoders pad the start and end by a few milliseconds.
            #expect(abs(result.seconds - 1) < 0.08, "\(format.name) came out \(result.seconds)s long")
            #expect(result.channels == 2, "\(format.name)")
            #expect(result.rate == (format == .opus ? 48_000 : 44_100), "\(format.name)")
        }
    }
}

@Test(arguments: engines)
func losslessOutputKeepsA24BitSourceAt24Bits(tools: Tools) throws {
    try withFolder { folder in
        let source = try tone("master.wav", in: folder, rate: 48_000, bits: 24)
        for format in [Format.alac, .flac, .aiff] {
            let output = try Converter(tools: tools).convert(source, to: format)
            #expect(try inspect(output).bits == 24, "\(format.name)")
            #expect(try inspect(output).rate == 48_000, "\(format.name)")
        }
    }
}

@Test(arguments: engines)
func a16BitSourceStays16Bit(tools: Tools) throws {
    // Padding a 16-bit file out to 24 bits would make it half as big again
    // for nothing.
    try withFolder { folder in
        let source = try tone("cd.aiff", in: folder)
        for format in [Format.alac, .flac, .wav] {
            #expect(try inspect(Converter(tools: tools).convert(source, to: format)).bits == 16, "\(format.name)")
        }
    }
}

@Test(arguments: engines)
func monoStaysMono(tools: Tools) throws {
    try withFolder { folder in
        let source = try tone("memo.wav", in: folder, channels: 1)
        for format in [Format.aac, .flac] {
            #expect(try inspect(Converter(tools: tools).convert(source, to: format)).channels == 1)
        }
    }
}

@Test(arguments: engines)
func theOriginalIsLeftExactlyAsItWas(tools: Tools) throws {
    try withFolder { folder in
        let source = try tone("tone.wav", in: folder)
        let before = try Data(contentsOf: source)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        _ = try Converter(tools: tools).convert(source, to: .flac)
        #expect(try Data(contentsOf: source) == before)
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
    }
}

@Test(arguments: engines)
func anExistingFileIsNeverOverwritten(tools: Tools) throws {
    try withFolder { folder in
        let source = try tone("tone.wav", in: folder)
        let existing = folder.appendingPathComponent("tone.flac")
        try Data("keep me".utf8).write(to: existing)

        let first = try Converter(tools: tools).convert(source, to: .flac)
        let second = try Converter(tools: tools).convert(source, to: .flac)

        #expect(first.lastPathComponent == "tone 2.flac")
        #expect(second.lastPathComponent == "tone 3.flac")
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
    }
}

@Test(arguments: engines)
func aFileAlreadyInTheFormatIsSkipped(tools: Tools) throws {
    try withFolder { folder in
        let wav = try tone("tone.wav", in: folder)
        #expect(throws: ConversionError.alreadyThatFormat(.wav)) {
            try Converter(tools: tools).convert(wav, to: .wav)
        }
        // .m4a is either AAC or ALAC, so the converter has to look inside.
        let aac = try Converter(tools: tools).convert(wav, to: .aac)
        #expect(throws: ConversionError.alreadyThatFormat(.aac)) {
            try Converter(tools: tools).convert(aac, to: .aac)
        }
        let alac = try Converter(tools: tools).convert(aac, to: .alac)
        #expect(alac.lastPathComponent == "tone 2.m4a")
        #expect(try contents(of: folder) == ["tone 2.m4a", "tone.m4a", "tone.wav"])
    }
}

@Test(arguments: engines)
func somethingThatIsntAudioFailsAndLeavesNothingBehind(tools: Tools) throws {
    try withFolder { folder in
        let fake = folder.appendingPathComponent("notes.wav")
        try Data("not audio at all".utf8).write(to: fake)
        #expect(throws: ConversionError.self) {
            try Converter(tools: tools).convert(fake, to: .flac)
        }
        #expect(try contents(of: folder) == ["notes.wav"])
    }
}

@Test(arguments: engines)
func aFolderThatCantBeWrittenToIsReportedBeforeConverting(tools: Tools) throws {
    try withFolder { folder in
        let source = try tone("tone.wav", in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(throws: ConversionError.folderNotWritable(folder.path)) {
            try Converter(tools: tools).convert(source, to: .flac)
        }
        #expect(try contents(of: folder) == ["tone.wav"])
    }
}

@Test(arguments: engines)
func awkwardFileNamesConvert(tools: Tools) throws {
    // A leading dash would be read as an option if it reached a tool on its
    // own, and quotes or spaces would break anything built as a shell string.
    try withFolder { folder in
        let source = try tone("-n \"Live\" at Ünïcode Hall & 'Friends'.wav", in: folder)
        let output = try Converter(tools: tools).convert(source, to: .aac)
        #expect(output.lastPathComponent == "-n \"Live\" at Ünïcode Hall & 'Friends'.m4a")
        #expect(try inspect(output).channels == 2)
    }
}

@Test(arguments: engines)
func cancellingMidConversionLeavesNothingBehind(tools: Tools) throws {
    try withFolder { folder in
        let source = try tone("long.wav", in: folder, seconds: 180)
        let format: Format = tools.ffmpeg == nil ? .aac : .mp3
        let batch = Batch(files: [source], format: format, converter: Converter(tools: tools))
        // Wait until the encoder has started writing its hidden output, so
        // this tests killing it and cleaning up after it, rather than
        // stopping it before it begins.
        let lock = NSLock()
        var cancelledAt = Date.distantFuture
        DispatchQueue.global().async {
            let deadline = Date() + 10
            while Date() < deadline, !((try? contents(of: folder)) ?? []).contains(where: { $0.hasPrefix(".") }) {
                usleep(5_000)
            }
            lock.withLock { cancelledAt = Date() }
            batch.cancellation.cancel()
        }

        let results = batch.run()

        // A full encode of three minutes takes two seconds or more, so
        // returning this soon means the encoder was killed, not waited out.
        #expect(Date().timeIntervalSince(lock.withLock { cancelledAt }) < 0.5, "the encoder kept running after the cancel")
        #expect(results.count == 1)
        if case .failure(.cancelled) = results[0] {} else { Issue.record("expected a cancel, got \(results[0])") }
        #expect(try contents(of: folder) == ["long.wav"])
    }
}

@Test func withoutFFmpegMP3AndOpusSayWhatToInstall() throws {
    try withFolder { folder in
        let source = try tone("tone.wav", in: folder)
        for format in [Format.mp3, .opus] {
            #expect(throws: ConversionError.needsFFmpeg(format)) {
                try Converter(tools: coreAudio).convert(source, to: format)
            }
        }
        #expect(ConversionError.needsFFmpeg(.mp3).localizedDescription.contains("brew install ffmpeg"))
        #expect(try contents(of: folder) == ["tone.wav"])
    }
}

@Test(.enabled(if: installed.ffmpeg != nil, "needs ffmpeg"))
func tagsAndCoverArtComeAcross() throws {
    try withFolder { folder in
        let wav = try tone("tone.wav", in: folder)
        let cover = folder.appendingPathComponent("cover.png")
        try ffmpeg(["-f", "lavfi", "-i", "color=red:s=16x16", "-frames:v", "1", cover.path])
        let source = folder.appendingPathComponent("tagged.flac")
        try ffmpeg(["-i", wav.path, "-i", cover.path, "-map", "0", "-map", "1", "-c:a", "flac", "-c:v", "copy",
                    "-disposition:v", "attached_pic", "-metadata", "title=Synthetic Tone", "-metadata", "artist=Test Signal",
                    source.path])

        for format in Format.allCases where format != .flac {
            let output = try Converter(tools: installed).convert(source, to: format)
            let info = try probe(output, "format_tags:stream_tags:stream=codec_type")
            // Ogg keeps tags on the stream, the others on the file; key case varies.
            let streams = info["streams"] as? [[String: Any]] ?? []
            let tagSets = [(info["format"] as? [String: Any])?["tags"]] + streams.map { $0["tags"] }
            let tags = tagSets.compactMap { $0 as? [String: String] }
                .flatMap { $0 }
                .reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
            #expect(tags["title"] == "Synthetic Tone", "\(format.name)")
            #expect(tags["artist"] == "Test Signal", "\(format.name)")

            let hasArt = streams.contains { $0["codec_type"] as? String == "video" }
            #expect(hasArt == [.mp3, .aac, .alac].contains(format), "\(format.name) art")
        }
    }
}

@Test(.enabled(if: installed.ffmpeg != nil, "needs ffmpeg"))
func surroundSoundBecomesStereoForMP3() throws {
    try withFolder { folder in
        let source = try tone("surround.wav", in: folder, rate: 48_000, channels: 6, bits: 24)
        #expect(try inspect(Converter(tools: installed).convert(source, to: .mp3)).channels == 2)
        #expect(try inspect(Converter(tools: installed).convert(source, to: .flac)).channels == 6)
    }
}

@Test(.enabled(if: installed.ffmpeg != nil, "needs ffmpeg"))
func ffmpegReadsFilesCoreAudioCant() throws {
    try withFolder { folder in
        let wav = try tone("tone.wav", in: folder)
        let matroska = folder.appendingPathComponent("tone.mka")
        try ffmpeg(["-i", wav.path, "-c:a", "flac", matroska.path])
        #expect(Audio(matroska) == nil)

        #expect(throws: ConversionError.unreadable) {
            try Converter(tools: coreAudio).convert(matroska, to: .wav)
        }
        #expect(try inspect(Converter(tools: installed).convert(matroska, to: .wav)).channels == 2)
    }
}

@Test func batchConvertsEverythingAndCountsAsItGoes() throws {
    try withFolder { folder in
        var files = try (1...6).map { try tone("take \($0).wav", in: folder) }
        let existingFLAC = folder.appendingPathComponent("done.flac")
        try FileManager.default.copyItem(at: try Converter(tools: coreAudio).convert(files[0], to: .flac), to: existingFLAC)
        files.append(existingFLAC)

        var counts: [Int] = []
        let lock = NSLock()
        let results = Batch(files: files, format: .flac, converter: Converter(tools: coreAudio)).run { n in
            lock.withLock { counts.append(n) }
        }

        #expect(counts.sorted() == Array(1...7))
        #expect(results.filter { (try? $0.get()) != nil }.count == 6)
        #expect(Batch.summary(results, format: .flac) == "6 converted\n1 already FLAC")
    }
}

@Test func ffmpegIsFoundOnPATHFirstThenInTheUsualPlaces() throws {
    try withFolder { folder in
        let fake = folder.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        #expect(Tools.find(environment: ["PATH": "/usr/bin:\(folder.path)"]).ffmpeg == fake)

        // Finder gives apps a PATH without Homebrew on it.
        let fromFinder = Tools.find(environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(fromFinder.ffmpeg == installed.ffmpeg)
    }
}
