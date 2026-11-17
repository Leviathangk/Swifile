import Foundation

/// 视图与目录引擎之间的稳定接口。
enum FileSystemHelper {
    static func loadSnapshot(
        at url: URL,
        showHidden: Bool,
        useCache: Bool,
        priority: DirectoryLoadPriority = .background
    ) async throws -> DirectorySnapshot {
        try await DirectoryLoadCoordinator.shared.snapshot(
            at: url,
            showHidden: showHidden,
            useCache: useCache,
            priority: priority
        )
    }

    static func cachedSnapshot(at url: URL, showHidden: Bool) -> DirectorySnapshot? {
        DirectorySnapshotCache.shared.value(for: url, showHidden: showHidden)
    }

    static func invalidateCache(for url: URL) async {
        await DirectoryLoadCoordinator.shared.invalidate(url)
    }

    static func removeAllCachedSnapshots() async {
        await DirectoryLoadCoordinator.shared.removeAll()
    }
}
