import AppKit
import RondelCore

let usage = """
    usage: Rondel --to FORMAT FILE...

    Converts each FILE into a new file beside it. Nothing is overwritten.
    FORMAT is one of: \(Format.allCases.map(\.rawValue).joined(separator: " "))

    """

/// `Rondel --to mp3 FILE...` converts without the wheel, for scripts.
/// Exits 0 if nothing failed (files already in the format don't count),
/// 1 if something did, 64 for a usage mistake.
func commandLine(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 3, arguments[0] == "--to", let format = Format(rawValue: arguments[1].lowercased()) else {
        FileHandle.standardError.write(Data(usage.utf8))
        return 64
    }
    let files = arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
    let batch = Batch(files: files, format: format)

    // Ctrl-C stops the batch properly, so no hidden partial files are left.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { batch.cancellation.cancel() }
    interrupt.resume()

    let results = batch.run()
    var failed = false
    for (file, result) in zip(files, results) {
        switch result {
        case .success(let output):
            print("\(file.path) -> \(output.path)")
        case .failure(.alreadyThatFormat):
            print("\(file.path): skipped, it's already \(format.name)")
        case .failure(let error):
            failed = true
            FileHandle.standardError.write(Data("\(file.path): \(error.localizedDescription)\n".utf8))
        }
    }
    return failed ? 1 : 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--help", "-h":
    print(usage, terminator: "")
case "--to":
    exit(commandLine(arguments))
default:
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    // Info.plist's LSUIElement does this for the app bundle; this covers
    // running the bare binary from a terminal.
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
