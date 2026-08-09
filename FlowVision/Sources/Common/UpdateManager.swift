//
//  UpdateManager.swift
//  FlowVision
//

import Cocoa

final class FlowVisionUpdateManager {
    static let shared = FlowVisionUpdateManager()

    static let repositoryURL = URL(string: "https://github.com/mcxen/flowvision")!
    static let latestReleaseURL = URL(string: "https://github.com/mcxen/flowvision/releases/latest")!
    static let stableDownloadURL = URL(string: "https://github.com/mcxen/flowvision/releases/latest/download/FlowVision-macOS.zip")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle

    private init() {}

    static func version(fromReleaseURL url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let releasesIndex = components.firstIndex(of: "releases"),
              components.indices.contains(releasesIndex + 2),
              components[releasesIndex + 1] == "tag" else { return nil }
        let tag = components[releasesIndex + 2]
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty,
              version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return version
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(candidateParts.count, currentParts.count)
        for index in 0..<count {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    func checkForUpdates(manual: Bool) {
        guard state != .checking, state != .installing else { return }
        state = .checking

        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        request.setValue("FlowVision-Updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.fail(error.localizedDescription, showAlert: manual)
                    return
                }
                guard let finalURL = response?.url,
                      let latestVersion = Self.version(fromReleaseURL: finalURL) else {
                    self.fail(self.localized(
                        english: "GitHub returned an invalid latest-release address.",
                        simplifiedChinese: "GitHub 返回的最新版本地址无效。",
                        traditionalChinese: "GitHub 傳回的最新版本位址無效。"
                    ), showAlert: manual)
                    return
                }

                if Self.isVersion(latestVersion, newerThan: self.currentVersion) {
                    self.state = .available(latestVersion)
                    self.presentAvailableUpdate(version: latestVersion)
                } else {
                    self.state = .upToDate
                    if manual { self.presentUpToDate() }
                }
            }
        }.resume()
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func presentAvailableUpdate(version: String) {
        let alert = NSAlert()
        alert.messageText = localized(
            english: "FlowVision \(version) is available",
            simplifiedChinese: "FlowVision \(version) 已发布",
            traditionalChinese: "FlowVision \(version) 已發佈"
        )
        alert.informativeText = localized(
            english: "Current version: \(currentVersion). Download the latest release from GitHub and install it now?",
            simplifiedChinese: "当前版本：\(currentVersion)。是否立即从 GitHub 下载最新版并安装？",
            traditionalChinese: "目前版本：\(currentVersion)。是否立即從 GitHub 下載最新版並安裝？"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: localized(english: "Download and Install", simplifiedChinese: "下载并安装", traditionalChinese: "下載並安裝"))
        alert.addButton(withTitle: localized(english: "Later", simplifiedChinese: "稍后", traditionalChinese: "稍後"))
        if alert.runModal() == .alertFirstButtonReturn {
            installLatestVersion()
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = localized(english: "FlowVision is up to date", simplifiedChinese: "FlowVision 已是最新版本", traditionalChinese: "FlowVision 已是最新版本")
        alert.informativeText = localized(
            english: "You are running FlowVision \(currentVersion).",
            simplifiedChinese: "当前运行版本为 FlowVision \(currentVersion)。",
            traditionalChinese: "目前執行版本為 FlowVision \(currentVersion)。"
        )
        alert.runModal()
    }

    private func installLatestVersion() {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let parentURL = appURL.deletingLastPathComponent()
        guard appURL.lastPathComponent == "FlowVision.app" else {
            fail(localized(
                english: "Automatic updates are available only from the packaged FlowVision.app.",
                simplifiedChinese: "自动更新仅适用于正式打包的 FlowVision.app。",
                traditionalChinese: "自動更新僅適用於正式封裝的 FlowVision.app。"
            ), showAlert: true)
            return
        }
        guard FileManager.default.isWritableFile(atPath: parentURL.path) else {
            fail(localized(
                english: "FlowVision cannot update this installation location. Download the latest release from GitHub, or upgrade it with the package manager that installed it.",
                simplifiedChinese: "FlowVision 无法写入当前安装位置。请从 GitHub 下载最新版，或使用原安装工具升级。",
                traditionalChinese: "FlowVision 無法寫入目前安裝位置。請從 GitHub 下載最新版，或使用原安裝工具升級。"
            ), showAlert: true)
            return
        }

        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/FlowVisionUpdater", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            fail(localized(
                english: "The updater helper is missing from this copy of FlowVision.",
                simplifiedChinese: "当前 FlowVision 缺少更新助手。",
                traditionalChinese: "目前 FlowVision 缺少更新助手。"
            ), showAlert: true)
            return
        }

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            Self.stableDownloadURL.absoluteString,
            appURL.path
        ]
        do {
            try process.run()
            state = .installing
            NSApp.terminate(nil)
        } catch {
            fail(error.localizedDescription, showAlert: true)
        }
    }

    private func fail(_ message: String, showAlert: Bool) {
        state = .failed(message)
        guard showAlert else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized(english: "Unable to update FlowVision", simplifiedChinese: "无法更新 FlowVision", traditionalChinese: "無法更新 FlowVision")
        alert.informativeText = message
        alert.addButton(withTitle: localized(english: "OK", simplifiedChinese: "好", traditionalChinese: "好"))
        alert.addButton(withTitle: localized(english: "Open GitHub", simplifiedChinese: "打开 GitHub", traditionalChinese: "開啟 GitHub"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Self.repositoryURL.appendingPathComponent("releases/latest"))
        }
    }

    private func localized(
        english: String,
        simplifiedChinese: String,
        traditionalChinese: String
    ) -> String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if language.hasPrefix("zh-hans") || language.hasPrefix("zh-cn") {
            return simplifiedChinese
        }
        if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") {
            return traditionalChinese
        }
        return english
    }
}
