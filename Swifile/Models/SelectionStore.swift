import Foundation
import Observation

/// 与目录内容状态隔离的选择集合，避免单击文件触发整个窗格重建。
@MainActor
@Observable
final class SelectionStore {
    private(set) var urls: Set<URL> = []
    private(set) var generation: UInt64 = 0

    var count: Int { urls.count }

    func contains(_ url: URL) -> Bool {
        urls.contains(url.standardizedFileURL)
    }

    func replace(with url: URL) {
        set([url.standardizedFileURL])
    }

    func toggle(_ url: URL) {
        let normalized = url.standardizedFileURL
        var next = urls
        if next.contains(normalized) {
            next.remove(normalized)
        } else {
            next.insert(normalized)
        }
        set(next)
    }

    func set(_ newValue: Set<URL>) {
        let normalized = Set(newValue.map(\.standardizedFileURL))
        guard normalized != urls else { return }
        urls = normalized
        generation &+= 1
    }

    func clear() {
        guard !urls.isEmpty else { return }
        urls.removeAll(keepingCapacity: true)
        generation &+= 1
    }
}
