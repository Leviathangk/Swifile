@preconcurrency import AppKit
import Foundation

/// 图标的不可变包装，允许在并发域之间传递 AppKit 图片对象。
final class IconBox: @unchecked Sendable {
    let image: NSImage

    init(_ image: NSImage) {
        self.image = image
    }
}

/// 图标缓存键：路径 + 像素尺寸。
struct IconCacheKey: Hashable, Sendable {
    let path: String
    let pixelSize: Int
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
    private var inflight: [IconCacheKey: Task<IconBox, Never>] = [:]
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
    nonisolated func cached(path: String, size: CGFloat) -> NSImage? {
        store.image(for: Self.makeKey(path: path, size: size))
    }

    func icon(
        for path: String,
        size: CGFloat,
        priority: RequestPriority = .background
    ) async -> NSImage {
        let key = Self.makeKey(path: path, size: size)
        if let image = store.image(for: key) {
            return image
        }
        if let task = inflight[key] {
            return await task.value.image
        }

        let task = Task.detached(priority: priority.taskPriority) { [service = self] in
            await service.acquireLoadPermit(priority: priority)
            let box = autoreleasepool {
                let source = NSWorkspace.shared.icon(forFile: path)
                let image = (source.copy() as? NSImage) ?? source
                image.size = NSSize(width: size, height: size)
                return IconBox(image)
            }
            await service.releaseLoadPermit()
            return box
        }
        inflight[key] = task

        let box = await task.value
        inflight.removeValue(forKey: key)
        store.insert(box, for: key)
        return box.image
    }

    func removeAll() {
        for task in inflight.values {
            task.cancel()
        }
        inflight.removeAll(keepingCapacity: true)
        store.removeAll()
    }

    nonisolated static func makeKey(path: String, size: CGFloat) -> IconCacheKey {
        IconCacheKey(path: path, pixelSize: Int((size * 2).rounded()))
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
