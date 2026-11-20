import AppKit
import Foundation

// MARK: - 可打开的应用

/// 「打开方式」菜单里的一项：应用地址、显示名与菜单图标。
/// bundleID 在系统应用上始终存在；nil 只用于极端兜底场景。
struct OpenableApplication: Identifiable {
    let url: URL
    let bundleID: String?
    let name: String

    var id: String { bundleID ?? url.path(percentEncoded: false) }

    /// 菜单项图标：统一缩放到 16pt，避免不同应用的图标尺寸不一让菜单行高跳动
    @MainActor
    var menuIcon: NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        let scaled = image.copy() as? NSImage ?? image
        scaled.size = NSSize(width: 16, height: 16)
        return scaled
    }
}

// MARK: - 应用目录

/// LaunchServices 的应用查询与终端探测。
/// 右键菜单每次弹出都实时查询会拖慢弹出速度，这里按「UTI + 是否目录」做短时缓存；
/// 缓存过期后重新查询，安装或卸载应用能在半分钟内反映到菜单里。
@MainActor
enum ApplicationCatalog {
    /// 系统终端：任何情况下都可用的兜底
    static let systemTerminalBundleID = "com.apple.Terminal"

    /// 已知终端应用。LaunchServices 不把终端登记为文件夹处理器，
    /// 只能按 bundle ID 主动探测；新增终端只需在这里补一行。
    private static let knownTerminalBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
    ]

    private struct CacheEntry {
        let applications: [OpenableApplication]
        let createdAt: Date
    }

    private static var cache: [String: CacheEntry] = [:]
    private static var terminalsCache: CacheEntry?
    private static var categoryCache: [DefaultAppCategory: CacheEntry] = [:]
    private static let cacheLifetime: TimeInterval = 30

    // MARK: 打开方式

    /// 能打开该文件/目录的应用。
    /// 系统会同时返回 /System 与 /Volumes 下的同一应用，按 bundle ID 去重；
    /// Finder 与 Swifile 自己不参与「用其他应用打开」。
    static func applications(for url: URL) -> [OpenableApplication] {
        let key = cacheKey(for: url)
        if let cached = cache[key], Date().timeIntervalSince(cached.createdAt) < cacheLifetime {
            return cached.applications
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var applications: [OpenableApplication] = []
        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            let bundleID = Bundle(url: appURL)?.bundleIdentifier
            let identity = bundleID ?? appURL.path(percentEncoded: false)
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            if bundleID == "com.apple.finder" || bundleID == ownBundleID { continue }
            applications.append(makeApplication(at: appURL))
        }
        applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        cache[key] = CacheEntry(applications: applications, createdAt: Date())
        return applications
    }

    /// 某个类别能打开的代表性应用。
    /// 系统只按真实文件查关联应用，所以先落一个代表性扩展名的空文件再查询；
    /// 查询结果按类别缓存，设置页刷新不会反复写临时文件。
    static func applications(for category: DefaultAppCategory) -> [OpenableApplication] {
        if let cached = categoryCache[category], Date().timeIntervalSince(cached.createdAt) < cacheLifetime {
            return cached.applications
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwifileTypeSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sample = directory.appendingPathComponent("sample.\(category.sampleExtension)")
        let samplePath = sample.path(percentEncoded: false)
        try? FileManager.default.removeItem(at: sample)
        guard FileManager.default.createFile(atPath: samplePath, contents: Data()) else {
            return []
        }
        defer { try? FileManager.default.removeItem(at: sample) }

        let applications = applications(for: sample)
        categoryCache[category] = CacheEntry(applications: applications, createdAt: Date())
        return applications
    }

    // MARK: 终端

    /// 已安装的终端：系统终端固定在内，已知终端按 bundle ID 探测；
    /// 系统里注册了 ssh 协议处理器的应用也算终端，覆盖不在已知清单里的应用。
    static func installedTerminals() -> [OpenableApplication] {
        if let cached = terminalsCache, Date().timeIntervalSince(cached.createdAt) < cacheLifetime {
            return cached.applications
        }

        var bundleIDs = Set<String>([systemTerminalBundleID])
        for id in knownTerminalBundleIDs where application(withBundleID: id) != nil {
            bundleIDs.insert(id)
        }
        if let sshURL = URL(string: "ssh://localhost") {
            for appURL in NSWorkspace.shared.urlsForApplications(toOpen: sshURL) {
                if let id = Bundle(url: appURL)?.bundleIdentifier {
                    bundleIDs.insert(id)
                }
            }
        }

        let applications = bundleIDs.compactMap { application(withBundleID: $0) }
        let sorted = applications.sorted { lhs, rhs in
            if lhs.bundleID == systemTerminalBundleID { return true }
            if rhs.bundleID == systemTerminalBundleID { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        terminalsCache = CacheEntry(applications: sorted, createdAt: Date())
        return sorted
    }

    /// 按 bundle ID 找到已安装的应用；未安装返回 nil
    static func application(withBundleID bundleID: String) -> OpenableApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return makeApplication(at: url)
    }

    // MARK: 私有

    private static func makeApplication(at url: URL) -> OpenableApplication {
        let path = url.path(percentEncoded: false)
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") {
            name.removeLast(4)
        }
        return OpenableApplication(
            url: url,
            bundleID: Bundle(url: url)?.bundleIdentifier,
            name: name
        )
    }

    /// 同一 UTI 的应用集合相同，用它做缓存键；拿不到 UTI 时退回扩展名
    private static func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.typeIdentifierKey, .isDirectoryKey])
        let type = values?.typeIdentifier ?? url.pathExtension.lowercased()
        return type + ((values?.isDirectory ?? false) ? "|directory" : "|file")
    }
}

// MARK: - 终端启动

/// 用指定终端打开目录。
/// 大多数终端可以直接接收目录参数；少数终端必须走自己的命令行开关，集中在这里适配。
@MainActor
enum TerminalLauncher {
    static func open(directory: URL, using application: OpenableApplication) {
        let path = directory.path(percentEncoded: false)
        let appPath = application.url.path(percentEncoded: false)

        var arguments: [String]
        switch application.bundleID {
        case "com.mitchellh.ghostty":
            // Ghostty 不支持从命令行直接启动终端，官方方式是用 open 传配置键
            arguments = ["-n", "-a", appPath, "--args", "--working-directory=\(path)"]
        case "net.kovidgoyal.kitty":
            arguments = ["-n", "-a", appPath, "--args", "--directory", path]
        case "org.alacritty":
            arguments = ["-n", "-a", appPath, "--args", "--working-directory", path]
        case "com.github.wez.wezterm":
            arguments = ["-n", "-a", appPath, "--args", "start", "--cwd", path]
        default:
            // `--args` 只在新进程启动时生效；上面几个终端必须带 `-n`。
            // 其余终端走 LaunchServices 的“打开文件夹”事件，已运行时也能收到新目录。
            arguments = ["-a", appPath, path]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            NSLog("Failed to open \(application.name) at \(path): \(error)")
        }
    }
}
