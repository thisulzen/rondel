import Foundation

/// Converts several files to one format, as many at once as there are cores.
public final class Batch: @unchecked Sendable {
    public let files: [URL]
    public let format: Format
    public let cancellation = Cancellation()
    private let converter: Converter

    public init(files: [URL], format: Format, converter: Converter = Converter()) {
        self.files = files
        self.format = format
        self.converter = converter
    }

    /// Blocks until every file is done, calling `progress` with the count
    /// finished so far after each one. Results come back in the order of
    /// `files`.
    public func run(progress: (Int) -> Void = { _ in }) -> [Result<URL, ConversionError>] {
        var results = [Result<URL, ConversionError>?](repeating: nil, count: files.count)
        var done = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let result: Result<URL, ConversionError>
            do {
                result = .success(try converter.convert(files[i], to: format, cancellation: cancellation))
            } catch let error as ConversionError {
                result = .failure(error)
            } catch {
                result = .failure(.toolFailed(error.localizedDescription))
            }
            let finished = lock.withLock {
                results[i] = result
                done += 1
                return done
            }
            progress(finished)
        }
        return results.map { $0! }
    }

    /// A few short lines for the middle of the wheel, such as
    /// "3 converted" and "1 already MP3".
    public static func summary(_ results: [Result<URL, ConversionError>], format: Format) -> String {
        var converted = 0, already = 0, failed = 0, stopped = 0
        for result in results {
            switch result {
            case .success: converted += 1
            case .failure(.alreadyThatFormat): already += 1
            case .failure(.cancelled): stopped += 1
            case .failure: failed += 1
            }
        }
        var lines: [String] = []
        if converted > 0 { lines.append("\(converted) converted") }
        if already > 0 { lines.append("\(already) already \(format.name)") }
        if failed > 0 { lines.append("\(failed) failed") }
        if stopped > 0 { lines.append("\(stopped) stopped") }
        return lines.joined(separator: "\n")
    }
}
