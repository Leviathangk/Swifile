import Foundation

/// 目录读取的调度优先级。活动窗格优先，后台窗格不抢占当前导航。
enum DirectoryLoadPriority: Sendable {
    case foreground
    case background

    var taskPriority: TaskPriority {
        switch self {
        case .foreground: .userInitiated
        case .background: .utility
        }
    }
}

/// 在后台线程执行一次目录枚举，并生成 UI 可直接消费的不可变快照。
enum DirectoryReader {
    static func read(directory: URL, showHidden: Bool) throws -> DirectorySnapshot {
        let normalized = URL(
            fileURLWithPath: directory.standardizedFileURL.path(percentEncoded: false),
            isDirectory: true
        )
        let manager = FileManager()
        let urls = try manager.contentsOfDirectory(
            at: normalized,
            includingPropertiesForKeys: Array(FileItem.resourceKeys),
            options: []
        )

        let sizeFormatter = FileItem.makeSizeFormatter()
        let dateFormatter = FileItem.makeDateFormatter()

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)

        for url in urls {
            if Task.isCancelled { throw CancellationError() }

            try autoreleasepool {
                let values = try url.resourceValues(forKeys: FileItem.resourceKeys)
                let name = url.lastPathComponent
                let isHidden = values.isHidden ?? name.hasPrefix(".")
                if !showHidden && isHidden { return }

                items.append(
                    FileItem(
                        url: url,
                        values: values,
                        sizeFormatter: sizeFormatter,
                        dateFormatter: dateFormatter
                    )
                )
            }
        }

        return DirectorySnapshot(
            directory: normalized,
            items: items,
            showHidden: showHidden,
            loadedAt: Date()
        )
    }
}

/// 负责相同目录请求合并与后台执行的协调器。
actor DirectoryLoadCoordinator {
    static let shared = DirectoryLoadCoordinator()

    private struct InflightRequest {
        let token: UUID
        let task: Task<DirectorySnapshot, Error>
    }

    private var inflight: [DirectoryCacheKey: InflightRequest] = [:]
    private let maximumConcurrentReads = 2
    private var activeReadCount = 0
    private var foregroundWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    func snapshot(
        at url: URL,
        showHidden: Bool,
        useCache: Bool,
        priority: DirectoryLoadPriority = .background
    ) async throws -> DirectorySnapshot {
        let key = DirectoryCacheKey(url: url, showHidden: showHidden)
        if useCache, let cached = DirectorySnapshotCache.shared.value(for: url, showHidden: showHidden) {
            return cached
        }
        if useCache, let request = inflight[key] {
            return try await request.task.value
        }

        let token = UUID()
        let task = Task.detached(priority: priority.taskPriority) { [coordinator = self] () throws -> DirectorySnapshot in
            await coordinator.acquireReadPermit(priority: priority)
            do {
                let snapshot = try DirectoryReader.read(directory: url, showHidden: showHidden)
                await coordinator.releaseReadPermit()
                return snapshot
            } catch {
                await coordinator.releaseReadPermit()
                throw error
            }
        }
        if useCache {
            inflight[key] = InflightRequest(token: token, task: task)
        }

        do {
            let snapshot = try await task.value
            DirectorySnapshotCache.shared.insert(snapshot)
            if inflight[key]?.token == token {
                inflight.removeValue(forKey: key)
            }
            return snapshot
        } catch {
            if inflight[key]?.token == token {
                inflight.removeValue(forKey: key)
            }
            throw error
        }
    }

    func invalidate(_ url: URL) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let keys = inflight.keys.filter { $0.path == path }
        for key in keys {
            inflight[key]?.task.cancel()
            inflight.removeValue(forKey: key)
        }
        DirectorySnapshotCache.shared.invalidate(url)
    }

    func removeAll() {
        for request in inflight.values {
            request.task.cancel()
        }
        inflight.removeAll(keepingCapacity: true)
        DirectorySnapshotCache.shared.removeAll()
    }

    private func acquireReadPermit(priority: DirectoryLoadPriority) async {
        if activeReadCount < maximumConcurrentReads {
            activeReadCount += 1
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

    private func releaseReadPermit() {
        if !foregroundWaiters.isEmpty {
            foregroundWaiters.removeLast().resume()
        } else if !backgroundWaiters.isEmpty {
            backgroundWaiters.removeFirst().resume()
        } else {
            activeReadCount -= 1
        }
    }
}

/// 纯内存的过滤和排序管线，可放入后台任务执行。
enum FileContentPipeline {
    /// 目录优先，再按指定字段排序；字段相同的按名称升序，保证顺序稳定。
    /// 列表视图的表头排序走同一个实现（见 FileItemSortComparator），两边不会各排各的。
    static func compare(
        _ lhs: FileItem,
        _ rhs: FileItem,
        sortField: SortField,
        sortOrder: SortOrder
    ) -> ComparisonResult {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory ? .orderedAscending : .orderedDescending
        }

        let comparison: ComparisonResult
        switch sortField {
        case .name:
            comparison = lhs.name.localizedStandardCompare(rhs.name)
        case .size:
            comparison = compare(lhs.size ?? 0, rhs.size ?? 0)
        case .date:
            comparison = compare(lhs.modificationDate ?? .distantPast, rhs.modificationDate ?? .distantPast)
        case .type:
            comparison = lhs.fileType.localizedStandardCompare(rhs.fileType)
        }

        if comparison == .orderedSame {
            return lhs.name.localizedStandardCompare(rhs.name)
        }
        if sortOrder == .ascending {
            return comparison
        }
        return Self.reversed(comparison)
    }

    /// 降序：把比较结果取反
    private static func reversed(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    /// 目录优先，再按指定字段排序。顶层列表与展开出来的子项共用同一套顺序。
    static func makeComparator(
        sortField: SortField,
        sortOrder: SortOrder
    ) -> (FileItem, FileItem) -> Bool {
        { compare($0, $1, sortField: sortField, sortOrder: sortOrder) == .orderedAscending }
    }

    static func process(
        items: [FileItem],
        query: String,
        sortField: SortField,
        sortOrder: SortOrder
    ) -> ContentSnapshot {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [FileItem]
        if normalizedQuery.isEmpty {
            result = items
        } else {
            result = items.filter { $0.nameLowercased.localizedStandardContains(normalizedQuery) }
        }

        result.sort(by: makeComparator(sortField: sortField, sortOrder: sortOrder))

        return ContentSnapshot(files: result, query: query, totalCount: result.count)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
