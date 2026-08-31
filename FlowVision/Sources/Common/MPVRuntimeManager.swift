//
//  MPVRuntimeManager.swift
//  FlowVision
//

import Cocoa
import CryptoKit
import Security

/// Downloads and installs FlowVision's optional libmpv runtime without
/// modifying Homebrew, IINA, or any system directory.
final class MPVRuntimeManager {
    static let shared = MPVRuntimeManager()

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let version: String
        let architecture: String
        let url: String
        let sha256: String
        let downloadSize: Int64?
    }

    private enum State {
        case idle
        case fetchingManifest
        case awaitingConsent
        case downloading
        case installing
    }

    private let fileManager = FileManager.default
    private let activeRuntimeKey = "MPVRuntimeActiveDirectory_v1"
    private let maximumManifestSize: Int64 = 1024 * 1024
    private let maximumArchiveSize: Int64 = 200 * 1024 * 1024
    private let maximumInstalledSize: Int64 = 600 * 1024 * 1024
    private let maximumArchiveEntryCount = 4096
    private var state: State = .idle
    private var pendingCompletions: [(Bool) -> Void] = []
    private var hasAutomaticallyPrompted = false

    private init() {}

    /// The directory containing libmpv and its rewritten @loader_path
    /// dependencies, if a previously installed runtime is still intact.
    var activeFrameworksDirectory: String? {
        guard let directoryName = UserDefaults.standard.string(forKey: activeRuntimeKey),
              isSafeDirectoryName(directoryName) else { return nil }
        let directory = runtimeRoot.appendingPathComponent(directoryName, isDirectory: true)
        let frameworks = directory.appendingPathComponent("Frameworks", isDirectory: true)
        let libmpv = frameworks.appendingPathComponent("libmpv.2.dylib")
        let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let frameworkValues = try? frameworks.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let libraryValues = try? libmpv.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard directoryValues?.isDirectory == true,
              directoryValues?.isSymbolicLink != true,
              frameworkValues?.isDirectory == true,
              frameworkValues?.isSymbolicLink != true,
              libraryValues?.isRegularFile == true,
              libraryValues?.isSymbolicLink != true else {
            UserDefaults.standard.removeObject(forKey: activeRuntimeKey)
            return nil
        }
        return frameworks.path
    }

    /// Automatic calls prompt at most once per process. A user-initiated call
    /// from the unsupported-video overlay can always retry.
    func repairIfNeeded(
        presenting window: NSWindow?,
        userInitiated: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        if activeFrameworksDirectory != nil, !userInitiated {
            completion(true)
            return
        }
        if !userInitiated && hasAutomaticallyPrompted {
            completion(false)
            return
        }
        if state != .idle {
            pendingCompletions.append(completion)
            return
        }

        if !userInitiated { hasAutomaticallyPrompted = true }
        pendingCompletions.append(completion)
        state = .fetchingManifest
        fetchManifest(presenting: window, userInitiated: userInitiated)
    }

    private var manifestURL: URL {
        if let override = ProcessInfo.processInfo.environment["FLOWVISION_MPV_RUNTIME_MANIFEST_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://github.com/mcxen/flowvision/releases/latest/download/mpv-runtime-manifest.json")!
    }

    private var runtimeRoot: URL {
        if let override = ProcessInfo.processInfo.environment["FLOWVISION_MPV_RUNTIME_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (appSupport ?? fileManager.temporaryDirectory)
            .appendingPathComponent("FlowVision/Runtime/mpv", isDirectory: true)
    }

    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    private func fetchManifest(presenting window: NSWindow?, userInitiated: Bool) {
        let sourceURL = manifestURL
        loadData(from: sourceURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                do {
                    let data = try result.get()
                    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                    guard manifest.schemaVersion == 1,
                          let asset = manifest.assets.first(where: { $0.architecture == self.architecture }),
                          asset.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                          !asset.version.isEmpty else {
                        throw RuntimeError.invalidManifest
                    }
                    guard let archiveURL = URL(string: asset.url, relativeTo: sourceURL)?.absoluteURL,
                          archiveURL.scheme == "https" || (sourceURL.isFileURL && archiveURL.isFileURL) else {
                        throw RuntimeError.invalidManifest
                    }
                    self.state = .awaitingConsent
                    self.requestConsent(
                        for: asset,
                        archiveURL: archiveURL,
                        presenting: window
                    )
                } catch {
                    self.fail(error, showAlert: userInitiated)
                }
            }
        }
    }

    private func requestConsent(
        for asset: Asset,
        archiveURL: URL,
        presenting window: NSWindow?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localized(
            english: "Install the video playback component?",
            simplifiedChinese: "安装视频播放组件？",
            traditionalChinese: "安裝影片播放元件？"
        )
        let sizeText: String
        if let bytes = asset.downloadSize, bytes > 0 {
            sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else {
            sizeText = localized(english: "about 30 MB", simplifiedChinese: "约 30 MB", traditionalChinese: "約 30 MB")
        }
        alert.informativeText = localized(
            english: "FlowVision needs its signed libmpv component to play this format. Download size: \(sizeText). It is stored only in FlowVision's Application Support folder.",
            simplifiedChinese: "FlowVision 需要下载自身签名的 libmpv 组件才能播放此格式。下载大小：\(sizeText)，仅保存到 FlowVision 的应用支持目录。",
            traditionalChinese: "FlowVision 需要下載自身簽署的 libmpv 元件才能播放此格式。下載大小：\(sizeText)，僅儲存到 FlowVision 的應用程式支援目錄。"
        )
        alert.addButton(withTitle: localized(english: "Download and Repair", simplifiedChinese: "下载并修复", traditionalChinese: "下載並修復"))
        alert.addButton(withTitle: localized(english: "Not Now", simplifiedChinese: "暂不", traditionalChinese: "暫不"))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.finish(success: false)
                return
            }
            self.state = .downloading
            // The user has now explicitly accepted the download, so any
            // download or verification failure should be visible.
            self.download(asset: asset, from: archiveURL, showFailure: true)
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func download(asset: Asset, from archiveURL: URL, showFailure: Bool) {
        loadFile(from: archiveURL) { [weak self] result in
            guard let self else { return }
            do {
                let downloadedURL = try result.get()
                let ownedDownload = self.fileManager.temporaryDirectory
                    .appendingPathComponent("FlowVision-mpv-\(UUID().uuidString).zip")
                if downloadedURL != ownedDownload {
                    try? self.fileManager.removeItem(at: ownedDownload)
                    try self.fileManager.copyItem(at: downloadedURL, to: ownedDownload)
                }
                defer { try? self.fileManager.removeItem(at: ownedDownload) }

                let archiveSize = try ownedDownload.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
                guard archiveSize > 0, archiveSize <= self.maximumArchiveSize else {
                    throw RuntimeError.invalidArchive
                }
                if let expectedSize = asset.downloadSize, expectedSize > 0, archiveSize != expectedSize {
                    throw RuntimeError.checksumMismatch
                }

                guard try self.sha256(of: ownedDownload).caseInsensitiveCompare(asset.sha256) == .orderedSame else {
                    throw RuntimeError.checksumMismatch
                }
                DispatchQueue.main.async { self.state = .installing }
                try self.install(archive: ownedDownload, asset: asset)
                DispatchQueue.main.async { self.finish(success: true) }
            } catch {
                DispatchQueue.main.async { self.fail(error, showAlert: showFailure) }
            }
        }
    }

    private func install(archive: URL, asset: Asset) throws {
        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let staging = runtimeRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let entries = try validatedZipEntries(in: archive)
        guard !entries.isEmpty, entries.allSatisfy(isSafeArchiveEntry) else {
            throw RuntimeError.unsafeArchive
        }
        try run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, staging.path])
        try validateExtractedTree(at: staging)

        let frameworks = staging.appendingPathComponent("Frameworks", isDirectory: true)
        let libmpv = frameworks.appendingPathComponent("libmpv.2.dylib")
        guard fileManager.fileExists(atPath: libmpv.path) else { throw RuntimeError.invalidArchive }
        try validateLibraries(in: frameworks)

        let hashPrefix = String(asset.sha256.prefix(12)).lowercased()
        let directoryName = "\(safeComponent(asset.version))-\(architecture)-\(hashPrefix)"
        guard isSafeDirectoryName(directoryName) else { throw RuntimeError.invalidManifest }
        let destination = runtimeRoot.appendingPathComponent(directoryName, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        UserDefaults.standard.set(directoryName, forKey: activeRuntimeKey)
    }

    private func validateLibraries(in frameworks: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: frameworks,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw RuntimeError.invalidArchive }

        let appTeam = try signingTeamIdentifier(for: Bundle.main.executableURL)
        var dylibCount = 0
        var installedSize: Int64 = 0
        for case let url as URL in enumerator where url.pathExtension == "dylib" {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RuntimeError.invalidArchive
            }
            dylibCount += 1
            installedSize += Int64(values.fileSize ?? 0)
            guard installedSize <= maximumInstalledSize else { throw RuntimeError.invalidArchive }
            let architectureOutput = try run("/usr/bin/lipo", arguments: ["-archs", url.path], captureOutput: true)
            guard architectureOutput.split(whereSeparator: \Character.isWhitespace).contains(Substring(architecture)) else {
                throw RuntimeError.invalidArchive
            }
            let team = try signingTeamIdentifier(for: url, requireValidSignature: true)
            if let appTeam, team != appTeam { throw RuntimeError.signatureMismatch }
        }
        guard dylibCount > 0 else { throw RuntimeError.invalidArchive }
    }

    private func validateExtractedTree(at root: URL) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { throw RuntimeError.invalidArchive }

        let rootPath = root.standardizedFileURL.path + "/"
        var totalSize: Int64 = 0
        var itemCount = 0
        for case let url as URL in enumerator {
            itemCount += 1
            guard itemCount <= maximumArchiveEntryCount,
                  url.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw RuntimeError.invalidArchive
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw RuntimeError.unsafeArchive }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw RuntimeError.unsafeArchive }
            totalSize += Int64(values.fileSize ?? 0)
            guard totalSize <= maximumInstalledSize else { throw RuntimeError.invalidArchive }
        }
    }

    private func signingTeamIdentifier(for url: URL?, requireValidSignature: Bool = false) throws -> String? {
        guard let url else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            if requireValidSignature { throw RuntimeError.invalidSignature }
            return nil
        }
        let validity = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        if validity != errSecSuccess {
            if requireValidSignature { throw RuntimeError.invalidSignature }
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier] as? String
    }

    /// Checks entry type and expanded size before `ditto` sees the archive.
    /// Post-extraction validation remains necessary, but it is too late to
    /// prevent a crafted symlink entry from redirecting a later write outside
    /// the staging directory.
    private func validatedZipEntries(in archive: URL) throws -> [String] {
        let nameOutput = try run(
            "/usr/bin/unzip",
            arguments: ["-Z1", archive.path],
            captureOutput: true
        )
        let entries = nameOutput.split(whereSeparator: \Character.isNewline).map(String.init)
        guard !entries.isEmpty,
              entries.count <= maximumArchiveEntryCount else {
            throw RuntimeError.invalidArchive
        }

        let listingOutput = try run(
            "/usr/bin/unzip",
            arguments: ["-Zl", archive.path],
            captureOutput: true
        )
        let metadataRows = listingOutput.split(whereSeparator: \Character.isNewline).compactMap {
            archiveEntryMetadata(from: String($0))
        }
        guard metadataRows.count == entries.count else {
            throw RuntimeError.unsafeArchive
        }

        var expandedSize: Int64 = 0
        for row in metadataRows {
            guard row.type == "-" || row.type == "d" else {
                throw RuntimeError.unsafeArchive
            }
            expandedSize += row.uncompressedSize
            guard expandedSize <= maximumInstalledSize else {
                throw RuntimeError.invalidArchive
            }
        }
        return entries
    }

    private func archiveEntryMetadata(from line: String) -> (type: Character, uncompressedSize: Int64)? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 4,
              fields[0].count == 10,
              let type = fields[0].first,
              "-dlcbps".contains(type),
              let size = Int64(fields[3]),
              size >= 0 else {
            return nil
        }
        return (type, size)
    }

    private func isSafeArchiveEntry(_ entry: String) -> Bool {
        guard !entry.isEmpty,
              !entry.hasPrefix("/"),
              !entry.contains("\\"),
              entry.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return false
        }
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        let pathComponents = entry.hasSuffix("/") ? components.dropLast() : components[...]
        guard !pathComponents.isEmpty,
              !pathComponents.contains(".."),
              !pathComponents.contains(where: { $0.isEmpty }) else { return false }
        return entry.hasPrefix("Frameworks/") || entry.hasPrefix("LICENSES/") || entry == "README.txt"
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func loadData(from url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        if url.isFileURL {
            DispatchQueue.global(qos: .utility).async {
                completion(Result {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, Int64(size) <= self.maximumManifestSize else {
                        throw RuntimeError.invalidManifest
                    }
                    return try Data(contentsOf: url)
                })
            }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("FlowVision-mpv-runtime/1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.url?.scheme == "https",
                  let data,
                  !data.isEmpty,
                  Int64(data.count) <= self.maximumManifestSize else {
                completion(.failure(RuntimeError.downloadFailed))
                return
            }
            completion(.success(data))
        }.resume()
    }

    private func loadFile(from url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        if url.isFileURL {
            completion(.success(url))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("FlowVision-mpv-runtime/1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: request) { url, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.url?.scheme == "https",
                  let url else {
                completion(.failure(RuntimeError.downloadFailed))
                return
            }
            completion(.success(url))
        }.resume()
    }

    @discardableResult
    private func run(_ executable: String, arguments: [String], captureOutput: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        try process.run()
        let outputData = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RuntimeError.installFailed }
        guard captureOutput else { return "" }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func fail(_ error: Error, showAlert: Bool) {
        log("mpv runtime repair failed: \(error.localizedDescription)", level: .error)
        if showAlert {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = localized(english: "Unable to repair video playback", simplifiedChinese: "无法修复视频播放", traditionalChinese: "無法修復影片播放")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: localized(english: "OK", simplifiedChinese: "好", traditionalChinese: "好"))
            alert.runModal()
        }
        finish(success: false)
    }

    private func finish(success: Bool) {
        state = .idle
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0(success) }
    }

    private func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private func isSafeDirectoryName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    private func localized(english: String, simplifiedChinese: String, traditionalChinese: String) -> String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if language.hasPrefix("zh-hans") || language.hasPrefix("zh-cn") { return simplifiedChinese }
        if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") { return traditionalChinese }
        return english
    }

    private enum RuntimeError: LocalizedError {
        case invalidManifest
        case downloadFailed
        case checksumMismatch
        case unsafeArchive
        case invalidArchive
        case invalidSignature
        case signatureMismatch
        case installFailed

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "The video runtime manifest is invalid or does not support this Mac."
            case .downloadFailed: return "The video runtime could not be downloaded."
            case .checksumMismatch: return "The downloaded video runtime failed its SHA-256 check."
            case .unsafeArchive: return "The video runtime archive contains an unsafe entry."
            case .invalidArchive: return "The video runtime archive is incomplete."
            case .invalidSignature: return "A video runtime library has an invalid code signature."
            case .signatureMismatch: return "The video runtime was not signed by the FlowVision developer."
            case .installFailed: return "The video runtime could not be installed."
            }
        }
    }
}
