import Darwin
import Foundation

private let allowedDownloadURL = URL(string: "https://github.com/mcxen/flowvision/releases/latest/download/FlowVision-macOS.zip")!
private let expectedAppName = "FlowVision.app"
private let expectedExecutable = "Contents/MacOS/FlowVision"

enum UpdateError: LocalizedError {
    case invalidArguments
    case invalidPID
    case invalidURL
    case invalidDestination
    case downloadFailed(Int32)
    case extractionFailed(Int32)
    case invalidArchive
    case appDidNotExit

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Invalid updater arguments."
        case .invalidPID: return "Invalid FlowVision process identifier."
        case .invalidURL: return "The update download address is not allowed."
        case .invalidDestination: return "The FlowVision installation path is not allowed."
        case let .downloadFailed(status): return "Update download failed (status \(status))."
        case let .extractionFailed(status): return "Update extraction failed (status \(status))."
        case .invalidArchive: return "The downloaded archive does not contain a valid FlowVision.app."
        case .appDidNotExit: return "FlowVision did not exit before the update timeout."
        }
    }
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func reopen(_ appURL: URL) {
    _ = try? run("/usr/bin/open", [appURL.path])
}

private func processIsRunning(_ pid: pid_t) -> Bool {
    errno = 0
    return kill(pid, 0) == 0 || errno == EPERM
}

private func performUpdate() throws {
    guard CommandLine.arguments.count == 4 else { throw UpdateError.invalidArguments }
    guard let pid = pid_t(CommandLine.arguments[1]), pid > 1 else { throw UpdateError.invalidPID }
    guard let suppliedURL = URL(string: CommandLine.arguments[2]),
          suppliedURL.scheme?.lowercased() == "https",
          suppliedURL.host?.lowercased() == allowedDownloadURL.host?.lowercased(),
          suppliedURL.path == allowedDownloadURL.path else {
        throw UpdateError.invalidURL
    }

    let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).standardizedFileURL
    guard destination.lastPathComponent == expectedAppName,
          destination.pathExtension.lowercased() == "app",
          FileManager.default.fileExists(atPath: destination.path) else {
        throw UpdateError.invalidDestination
    }

    let fileManager = FileManager.default
    let workDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("FlowVisionUpdate-\(UUID().uuidString)", isDirectory: true)
    let archiveURL = workDirectory.appendingPathComponent("FlowVision-macOS.zip")
    let extractedDirectory = workDirectory.appendingPathComponent("Extracted", isDirectory: true)
    try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workDirectory) }

    let curlStatus = try run("/usr/bin/curl", [
        "--fail", "--location", "--retry", "3", "--proto", "=https",
        "--output", archiveURL.path, suppliedURL.absoluteString
    ])
    guard curlStatus == 0 else { throw UpdateError.downloadFailed(curlStatus) }

    let dittoStatus = try run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractedDirectory.path])
    guard dittoStatus == 0 else { throw UpdateError.extractionFailed(dittoStatus) }

    let extractedApp = extractedDirectory.appendingPathComponent(expectedAppName, isDirectory: true)
    let extractedExecutable = extractedApp.appendingPathComponent(expectedExecutable)
    guard fileManager.fileExists(atPath: extractedApp.path),
          fileManager.isExecutableFile(atPath: extractedExecutable.path) else {
        throw UpdateError.invalidArchive
    }

    let deadline = Date().addingTimeInterval(60)
    while processIsRunning(pid), Date() < deadline {
        usleep(200_000)
    }
    guard !processIsRunning(pid) else { throw UpdateError.appDidNotExit }

    let parent = destination.deletingLastPathComponent()
    guard fileManager.isWritableFile(atPath: parent.path) else { throw UpdateError.invalidDestination }
    let backup = parent.appendingPathComponent(".FlowVision.app.update-backup-\(UUID().uuidString)", isDirectory: true)
    var movedOriginal = false

    do {
        try fileManager.moveItem(at: destination, to: backup)
        movedOriginal = true
        try fileManager.moveItem(at: extractedApp, to: destination)
        try? fileManager.removeItem(at: backup)
        reopen(destination)
    } catch {
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        if movedOriginal, fileManager.fileExists(atPath: backup.path) {
            try? fileManager.moveItem(at: backup, to: destination)
        }
        reopen(destination)
        throw error
    }
}

do {
    try performUpdate()
} catch {
    fputs("FlowVisionUpdater: \(error.localizedDescription)\n", stderr)
    if CommandLine.arguments.count == 4 {
        let destination = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).standardizedFileURL
        if destination.lastPathComponent == expectedAppName {
            reopen(destination)
        }
    }
    exit(EXIT_FAILURE)
}
