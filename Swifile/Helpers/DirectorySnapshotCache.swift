import Foundation

/// 目录缓存键，区分隐藏文件显示策略。
struct DirectoryCacheKey: Hashable, Sendable {
    let path: String
    let showHidden: Bool

    init(url: URL, showHidden: Bool) {
        self.path = url.standardizedFileURL.path(percentEncoded: false)
        self.showHidden = showHidden
    }
}

/// 小容量、线程安全的目录快照 LRU 缓存。
///
/// 导航返回时可在主线程同步取出不可变快照，不需要等待 actor 调度。
final class DirectorySnapshotCache: @unchecked Sendable {
    static let shared = DirectorySnapshotCache()

    private let lock = NSLock()
    private let maximumEntryCount: Int
    private let maximumItemCount: Int
    private var snapshots: [DirectoryCacheKey: DirectorySnapshot] = [:]
    private var recency: [DirectoryCacheKey] = []
    private var itemCount = 0

    init(maximumEntryCount: Int = 32, maximumItemCount: Int = 120_000) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumItemCount = maximumItemCount
    }

    func value(for url: URL, showHidden: Bool) -> DirectorySnapshot? {
        let key = DirectoryCacheKey(url: url, showHidden: showHidden)
        lock.lock()
        defer { lock.unlock() }

        guard let snapshot = snapshots[key] else { return nil }
        touch(key)
        return snapshot
    }

    func insert(_ snapshot: DirectorySnapshot) {
        let key = DirectoryCacheKey(url: snapshot.directory, showHidden: snapshot.showHidden)
        lock.lock()
        defer { lock.unlock() }

        if let previous = snapshots.updateValue(snapshot, forKey: key) {
            itemCount -= previous.items.count
        }
        itemCount += snapshot.items.count
        touch(key)
        trimIfNeeded()
    }

    func invalidate(_ url: URL) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        lock.lock()
        defer { lock.unlock() }

        let keys = snapshots.keys.filter { $0.path == path }
        for key in keys {
            if let removed = snapshots.removeValue(forKey: key) {
                itemCount -= removed.items.count
            }
            recency.removeAll { $0 == key }
        }
    }

    func removeAll() {
        lock.lock()
        snapshots.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
        itemCount = 0
        lock.unlock()
    }

    private func touch(_ key: DirectoryCacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func trimIfNeeded() {
        while snapshots.count > maximumEntryCount || itemCount > maximumItemCount {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = snapshots.removeValue(forKey: oldest) {
                itemCount -= removed.items.count
            }
        }
    }
}
