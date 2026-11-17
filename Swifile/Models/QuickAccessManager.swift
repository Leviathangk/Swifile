import Foundation
import Observation

// MARK: - 快速访问模型

/// 快速访问里的一条引用：只记录文件或文件夹路径，不复制内容。
@MainActor
@Observable
final class QuickAccessItem: Identifiable {
    let id: UUID
    let url: URL
    private(set) var exists: Bool

    init(id: UUID = UUID(), url: URL, exists: Bool = true) {
        self.id = id
        self.url = url.standardizedFileURL
        self.exists = exists
    }

    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path(percentEncoded: false) : name
    }

    func setExists(_ value: Bool) {
        guard value != exists else { return }
        exists = value
    }
}

// MARK: - 持久化记录

private struct QuickAccessItemRecord: Codable, Sendable {
    let id: UUID
    let path: String
}

private struct QuickAccessArchive: Codable, Sendable {
    static let currentVersion = 1
    static let empty = QuickAccessArchive(version: currentVersion, items: [])

    let version: Int
    let items: [QuickAccessItemRecord]
}

/// 将快速访问 JSON 串行写入应用支持目录，避免阻塞 UI。
private final class QuickAccessRepository: @unchecked Sendable {
    static let shared = QuickAccessRepository()

    private let queue = DispatchQueue(label: "com.swifile.quickaccess", qos: .utility)
    private let fileURL: URL

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swifile", isDirectory: true)
        fileURL = root.appendingPathComponent("quick-access.json", isDirectory: false)
    }

    func load() -> QuickAccessArchive {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(QuickAccessArchive.self, from: data) else {
            return .empty
        }
        return archive
    }

    func save(_ archive: QuickAccessArchive) {
        let destination = fileURL
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(archive).write(to: destination, options: .atomic)
            } catch {
                NSLog("保存快速访问失败：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 快速访问管理

/// 侧栏「快速访问」的数据源：单一扁平列表。
@MainActor
@Observable
final class QuickAccessManager {
    private(set) var items: [QuickAccessItem]

    @ObservationIgnored private let repository = QuickAccessRepository.shared

    init() {
        self.items = repository.load().items.map {
            QuickAccessItem(id: $0.id, url: URL(fileURLWithPath: $0.path), exists: true)
        }

        Task { [weak self] in
            await self?.checkAllItems()
        }
    }

    /// 批量添加引用；已存在的路径自动跳过，重复拖入不会产生重复行。
    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }

        var known = Set(items.map { Self.pathKey($0.url) })
        var added = false
        for url in urls {
            let normalized = url.standardizedFileURL
            guard known.insert(Self.pathKey(normalized)).inserted else { continue }
            items.append(QuickAccessItem(url: normalized))
            added = true
        }

        guard added else { return }
        persist()
        // 不在添加后做异步存在性检查：路径来自刚完成的拖放或文件列表，
        // 二次更新会让新行先出现再重绘。启动时的 checkAllItems 已兜底。
    }

    /// 目录 URL 可能带尾斜杠，去重时统一按不带尾斜杠的路径比较（根目录除外）。
    private static func pathKey(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    func remove(_ item: QuickAccessItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll(keepingCapacity: true)
        persist()
    }

    /// 启动时检查引用是否仍然存在；失效条目在侧栏显示警告，不自动删除。
    func checkAllItems() async {
        let entries = items.map { (id: $0.id, path: $0.url.path(percentEncoded: false)) }
        let states = await Task.detached(priority: .utility) {
            var result: [UUID: Bool] = [:]
            result.reserveCapacity(entries.count)
            for entry in entries {
                result[entry.id] = FileManager.default.fileExists(atPath: entry.path)
            }
            return result
        }.value

        for item in items {
            if let exists = states[item.id] {
                item.setExists(exists)
            }
        }
    }

    private func persist() {
        let records = items.map {
            QuickAccessItemRecord(id: $0.id, path: $0.url.path(percentEncoded: false))
        }
        repository.save(QuickAccessArchive(version: QuickAccessArchive.currentVersion, items: records))
    }
}
