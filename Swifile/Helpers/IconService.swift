@preconcurrency import AppKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 图标的不可变包装，允许在并发域之间传递 AppKit 图片对象。
final class IconBox: @unchecked Sendable {
    let image: NSImage

    init(_ image: NSImage) {
        self.image = image
    }
}

/// 图标缓存键：路径 + 像素尺寸 + 文件版本（修改时间/大小）。
/// 文件内容被原地覆盖时，路径不变但版本变化，缩略图必须重新生成。
struct IconCacheKey: Hashable, Sendable {
    let path: String
    let pixelSize: Int
    let version: TimeInterval?
    /// 同 mtime 覆盖时文件大小通常还会变化；放进 key 能多覆盖一类外部替换。
    let fileSize: Int64?
}

/// 线程安全的图标缓存。
///
/// 主线程可同步读取，避免每个单元格都跨越 actor 边界等待调度；
/// 目录切换、滚动、焦点补图标都会命中这条热路径。
final class IconCacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [IconCacheKey: IconBox] = [:]
    private var recency: [IconCacheKey] = []
    private let maximumEntryCount = 512

    func image(for key: IconCacheKey) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let box = images[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return box.image
    }

    func insert(_ box: IconBox, for key: IconCacheKey) {
        lock.lock()
        defer { lock.unlock() }
        images[key] = box
        recency.removeAll { $0 == key }
        recency.append(key)
        while images.count > maximumEntryCount, let oldest = recency.first {
            recency.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    /// 删除指定路径及其子路径的图标。FSEvents 报的是真实路径，
    /// 这里同时按“路径本身”和“路径前缀”匹配，目录被改名/替换时也能清干净。
    func remove(paths: Set<String>) {
        let prefixes = Set(paths.map(Self.trimTrailingSlash))
        guard !prefixes.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        let removedKeys = images.keys.filter { key in
            let path = Self.trimTrailingSlash(key.path)
            return prefixes.contains(path) || prefixes.contains { prefix in
                prefix == "/" || path.hasPrefix(prefix + "/")
            }
        }
        for key in removedKeys {
            images.removeValue(forKey: key)
        }
        if !removedKeys.isEmpty {
            let removed = Set(removedKeys)
            recency.removeAll { removed.contains($0) }
        }
    }

    fileprivate static func trimTrailingSlash(_ path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        guard normalized.count > 1, normalized.hasSuffix("/") else { return normalized }
        return String(normalized.dropLast())
    }
}

/// 异步文件图标服务，提供有界 LRU 缓存和相同请求合并。
actor IconService {
    static let shared = IconService()

    /// 图标请求的调度优先级。活动窗格优先于后台窗格，避免多窗格同时补图标时拖慢当前操作。
    enum RequestPriority: Sendable, Equatable {
        case foreground
        case background

        var taskPriority: TaskPriority {
            switch self {
            case .foreground: .userInitiated
            case .background: .utility
            }
        }
    }

    private nonisolated let store = IconCacheStore()
    /// Desktop Services 的图标查询开销较高；全局限制并发可避免多个窗格同时抢占系统服务。
    private let maximumConcurrentLoads = 2
    private struct InflightLoad {
        let token: UUID
        let task: Task<IconBox, Never>
    }
    private var inflight: [IconCacheKey: InflightLoad] = [:]
    private var activeLoadCount = 0
    private var foregroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated static func placeholder(isDirectory: Bool, size: CGFloat) -> NSImage {
        // 目录使用 AppKit 自带的真实文件夹资源，首帧即可显示与 Finder 一致的蓝色图标。
        let image: NSImage
        if isDirectory {
            image = NSImage(named: NSImage.Name("NSFolder"))
                ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: size, height: size))
        } else {
            image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: size, height: size))
        }
        image.size = NSSize(width: size, height: size)
        return image
    }

    /// 同步读取缓存。命中时调用方无需等待 actor 调度，可直接在主线程使用。
    nonisolated func cached(
        path: String,
        size: CGFloat,
        version: Date? = nil,
        fileSize: Int64? = nil
    ) -> NSImage? {
        store.image(for: Self.makeKey(
            path: path,
            size: size,
            version: version,
            fileSize: fileSize
        ))
    }

    func icon(
        for path: String,
        size: CGFloat,
        version: Date? = nil,
        fileSize: Int64? = nil,
        priority: RequestPriority = .background
    ) async -> NSImage {
        let key = Self.makeKey(
            path: path,
            size: size,
            version: version,
            fileSize: fileSize
        )
        if let image = store.image(for: key) {
            return image
        }
        if let load = inflight[key] {
            return await load.task.value.image
        }

        let token = UUID()
        let task = Task.detached(priority: priority.taskPriority) { [service = self] in
            await service.acquireLoadPermit(priority: priority)
            let box: IconBox
            if let thumbnail = await Self.quickLookThumbnail(path: path, size: size) {
                box = IconBox(thumbnail)
            } else {
                box = autoreleasepool {
                    let source = NSWorkspace.shared.icon(forFile: path)
                    let image = (source.copy() as? NSImage) ?? source
                    image.size = NSSize(width: size, height: size)
                    return IconBox(image)
                }
            }
            await service.releaseLoadPermit()
            return box
        }
        inflight[key] = InflightLoad(token: token, task: task)

        let box = await task.value
        // 如果等待期间发生了 invalidate/新版本请求，旧结果不能再写回缓存。
        if let current = inflight[key], current.token == token {
            inflight.removeValue(forKey: key)
            if !task.isCancelled {
                store.insert(box, for: key)
            }
        }
        return box.image
    }

    /// 文件/目录在外部变化后清掉对应图标缓存。
    func invalidate(paths: Set<String>) {
        let prefixes = Set(paths.map(IconCacheStore.trimTrailingSlash))
        guard !prefixes.isEmpty else { return }

        let removedKeys = inflight.keys.filter { key in
            Self.path(key.path, matches: prefixes)
        }
        for key in removedKeys {
            inflight[key]?.task.cancel()
            inflight.removeValue(forKey: key)
        }
        store.remove(paths: paths)
    }

    func removeAll() {
        for load in inflight.values {
            load.task.cancel()
        }
        inflight.removeAll(keepingCapacity: true)
        store.removeAll()
    }

    /// 图片、PDF、视频、音频、文本和办公文档都交给 QuickLook；
    /// 目录、包和符号链接仍用系统图标（与访达的别名/应用图标行为一致）。
    nonisolated private static func quickLookThumbnail(
        path: String,
        size: CGFloat
    ) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .contentTypeKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true || values.isDirectory == true {
            return nil
        }

        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard let type, Self.supportsQuickLookThumbnail(type) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else {
            return nil
        }
        return Self.thumbnailImage(from: representation.cgImage, maxPointSize: size)
    }

    /// QuickLook 返回的位图保持原图比例。NSImage 的逻辑尺寸必须一起按比例设置，
    /// 否则 SwiftUI/NSImageView 会把缩略图横向或纵向拉满，和访达显示不一致。
    nonisolated static func thumbnailImage(
        from cgImage: CGImage,
        maxPointSize: CGFloat
    ) -> NSImage {
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        guard pixelWidth > 0, pixelHeight > 0 else {
            return NSImage(cgImage: cgImage, size: NSSize(width: maxPointSize, height: maxPointSize))
        }
        let scale = min(maxPointSize / pixelWidth, maxPointSize / pixelHeight)
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: pixelWidth * scale, height: pixelHeight * scale)
        )
    }

    nonisolated private static func supportsQuickLookThumbnail(_ type: UTType) -> Bool {
        type.conforms(to: .image)
            || type.conforms(to: .pdf)
            || type.conforms(to: .movie)
            || type.conforms(to: .audio)
            || type.conforms(to: .text)
            || type.conforms(to: .spreadsheet)
            || type.conforms(to: .presentation)
            || type.conforms(to: .compositeContent)
    }

    nonisolated static func makeKey(
        path: String,
        size: CGFloat,
        version: Date? = nil,
        fileSize: Int64? = nil
    ) -> IconCacheKey {
        IconCacheKey(
            path: path.precomposedStringWithCanonicalMapping,
            pixelSize: Int((size * 2).rounded()),
            version: version?.timeIntervalSince1970,
            fileSize: fileSize
        )
    }

    nonisolated private static func path(_ path: String, matches prefixes: Set<String>) -> Bool {
        let normalized = IconCacheStore.trimTrailingSlash(path)
        return prefixes.contains(normalized) || prefixes.contains { prefix in
            prefix == "/" || normalized.hasPrefix(prefix + "/")
        }
    }

    /// 获取全局图标加载许可。许可交接不降低 activeLoadCount，保证并发上限恒定。
    private func acquireLoadPermit(priority: RequestPriority) async {
        if activeLoadCount < maximumConcurrentLoads {
            activeLoadCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            switch priority {
            case .foreground:
                foregroundWaiters.append(continuation)
            case .background:
                backgroundWaiters.append(continuation)
            }
        }
    }

    private func releaseLoadPermit() {
        if !foregroundWaiters.isEmpty {
            // 最新交互产生的请求最有价值；旧窗格遗留请求放到队列尾部慢慢完成。
            foregroundWaiters.removeLast().resume()
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().resume()
        } else {
            activeLoadCount -= 1
        }
    }
}
