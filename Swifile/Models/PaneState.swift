import Foundation
import Observation

/// 地址栏路径校验失败的原因，文案直接展示在应用内提示里。
enum PanePathError: LocalizedError {
    case empty
    case notFound(String)
    case notDirectory(String)
    case notReadable(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "请输入路径。"
        case .notFound(let path):
            return "路径不存在：\(path)"
        case .notDirectory(let path):
            return "不是文件夹：\(path)"
        case .notReadable(let path):
            return "没有权限读取：\(path)"
        }
    }
}

/// 单个文件窗格的主线程状态。
///
/// 目录读取、过滤和排序均在后台执行；主线程只提交不可变结果。
@MainActor
@Observable
final class PaneState: Identifiable {
    nonisolated let id = UUID()

    private(set) var currentDirectory: URL
    private(set) var filteredFiles: [FileItem] = []
    private(set) var fileGeneration: UInt64 = 0
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var errorMessage: String?
    private(set) var totalItemCount = 0

    @ObservationIgnored let selectionStore = SelectionStore()
    @ObservationIgnored let activity = PaneActivity()

    var viewMode: ViewMode = .list
    var sortField: SortField = .name {
        didSet {
            guard sortField != oldValue else { return }
            // 排序会重排整个平铺列表，展开出来的子项不再贴住父项，先收起
            expandedPaths.removeAll()
            scheduleContentRebuild(delayNanoseconds: 0)
        }
    }
    var sortOrder: SortOrder = .ascending {
        didSet {
            guard sortOrder != oldValue else { return }
            expandedPaths.removeAll()
            scheduleContentRebuild(delayNanoseconds: 0)
        }
    }
    var searchQuery: String = "" {
        didSet {
            guard !suppressQueryChange, searchQuery != oldValue else { return }
            let delay: UInt64 = searchQuery.isEmpty ? 0 : 50_000_000
            scheduleContentRebuild(delayNanoseconds: delay)
        }
    }
    var showHidden = false {
        didSet {
            guard showHidden != oldValue else { return }
            // 展开出来的子项按旧口径读取，切换后必须重新读
            childItems.removeAll()
            loadingExpansions.removeAll()
            loadCurrentDirectory(force: false)
        }
    }

    @ObservationIgnored private var snapshot: DirectorySnapshot
    @ObservationIgnored private var history: [URL]
    @ObservationIgnored private var historyIndex: Int
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var loadToken: UInt64 = 0
    @ObservationIgnored private var rebuildToken: UInt64 = 0
    @ObservationIgnored private var suppressQueryChange = false
    @ObservationIgnored private let monitor = DirectoryMonitor()
    /// 已原地展开的目录路径（列表视图用）
    @ObservationIgnored private var expandedPaths: Set<String> = []
    /// 展开目录的子项缓存，保持读取顺序，展示时按当前排序规则排
    @ObservationIgnored private var childItems: [String: [FileItem]] = [:]
    /// 正在读取子项的展开目录，用于三角的等待态
    @ObservationIgnored private var loadingExpansions: Set<String> = []

    /// 小目录的过滤排序成本很低，缓存命中时直接提交可以消除一次任务调度往返。
    /// 只有极小目录适合在主线程立即排序；中型目录也必须后台处理，避免多窗格叠加阻塞交互。
    private static let immediateContentItemLimit = 256

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let normalized = Self.normalizeDirectoryURL(directory)
        self.currentDirectory = normalized
        self.snapshot = .empty(directory: normalized, showHidden: false)
        self.history = [normalized]
        self.historyIndex = 0
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }
    var files: [FileItem] { snapshot.items }

    /// ⌘L 请求头部进入路径编辑；每触发一次加一，由窗格头部观察。
    private(set) var pathEditRequestToken: UInt64 = 0

    func requestPathEditing() {
        pathEditRequestToken &+= 1
    }

    /// 导航到指定目录；缓存命中时立即使用快照，未命中时异步加载。
    func navigate(to url: URL) {
        let normalized = Self.normalizeDirectoryURL(url)
        if Self.pathKey(normalized) == Self.pathKey(currentDirectory), hasLoadedOnce {
            selectionStore.clear()
            return
        }

        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(normalized)
        historyIndex = history.count - 1
        beginNavigation(to: normalized)
    }

    /// 地址栏输入的路径：支持 ~、绝对路径、相对当前目录的路径和首尾引号。
    /// 返回 nil 表示已导航；否则返回可直接展示的错误。
    @discardableResult
    func navigate(toUserPath rawPath: String) -> PanePathError? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2,
           (path.hasPrefix("\"") && path.hasSuffix("\"")) ||
           (path.hasPrefix("'") && path.hasSuffix("'")) {
            path = String(path.dropFirst().dropLast())
        }
        guard !path.isEmpty else { return .empty }

        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if (expanded as NSString).isAbsolutePath {
            url = URL(fileURLWithPath: expanded)
        } else {
            url = URL(fileURLWithPath: expanded, relativeTo: currentDirectory).standardizedFileURL
        }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            return .notFound(path)
        }
        guard isDirectory.boolValue else {
            return .notDirectory(path)
        }
        guard manager.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            return .notReadable(path)
        }

        navigate(to: url)
        return nil
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        beginNavigation(to: history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        beginNavigation(to: history[historyIndex])
    }

    func goUp() {
        let parent = currentDirectory.deletingLastPathComponent()
        guard Self.pathKey(parent) != Self.pathKey(currentDirectory) else { return }
        navigate(to: parent)
    }

    /// 强制从文件系统重新读取当前目录。
    func refresh() {
        loadCurrentDirectory(force: true)
    }

    /// 该目录当前是否处于原地展开状态。
    func isExpanded(_ url: URL) -> Bool {
        expandedPaths.contains(Self.pathKey(url))
    }

    /// 该目录是否正在读取子项（三角显示为等待态）。
    func isExpanding(_ url: URL) -> Bool {
        loadingExpansions.contains(Self.pathKey(url))
    }

    /// 展开或折叠一个目录。首次展开需要读取子目录内容。
    func toggleExpanded(_ url: URL) {
        let key = Self.pathKey(url)
        if expandedPaths.contains(key) {
            expandedPaths.remove(key)
            scheduleContentRebuild(delayNanoseconds: 0)
            return
        }

        expandedPaths.insert(key)
        if childItems[key] != nil {
            scheduleContentRebuild(delayNanoseconds: 0)
        } else {
            // 读取可能被系统授权弹窗挂住，先立起等待态，让点开的那一下有反馈
            loadingExpansions.insert(key)
            scheduleContentRebuild(delayNanoseconds: 0)
            loadChildren(for: url, key: key)
        }
    }

    /// 读取展开目录的子项，完成后重建显示列表。
    /// 读取失败（例如受保护目录未授权）时撤销展开，避免留下点了却打不开的空壳。
    private func loadChildren(for url: URL, key: String) {
        // 展开是用户主动操作，活跃窗格按前台优先级读取，不排在导航请求之后
        let priority: DirectoryLoadPriority = activity.isActive ? .foreground : .background
        let hidden = showHidden
        Task { [weak self] in
            do {
                let snapshot = try await FileSystemHelper.loadSnapshot(
                    at: url,
                    showHidden: hidden,
                    useCache: true,
                    priority: priority
                )
                guard let self else { return }
                self.childItems[key] = snapshot.items
                self.loadingExpansions.remove(key)
                self.scheduleContentRebuild(delayNanoseconds: 0)
            } catch {
                guard let self else { return }
                self.loadingExpansions.remove(key)
                self.expandedPaths.remove(key)
                self.scheduleContentRebuild(delayNanoseconds: 0)
            }
        }
    }

    /// 首次显示窗格时触发懒加载。
    func ensureLoaded() {
        guard !hasLoadedOnce, loadTask == nil else { return }
        loadCurrentDirectory(force: false)
    }

    var pathComponents: [(name: String, url: URL)] {
        var result: [(String, URL)] = []
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in currentDirectory.pathComponents where component != "/" {
            cursor.appendPathComponent(component, isDirectory: true)
            result.append((component, cursor))
        }
        return result
    }

    var displayName: String {
        let name = currentDirectory.lastPathComponent
        let localized: [String: String] = [
            "Desktop": "桌面",
            "Documents": "文档",
            "Downloads": "下载",
            "Pictures": "图片",
            "Applications": "应用程序",
            "Library": "资源库"
        ]
        if Self.pathKey(currentDirectory) == Self.pathKey(FileManager.default.homeDirectoryForCurrentUser) {
            return "个人"
        }
        return localized[name] ?? (name.isEmpty ? "/" : name)
    }

    private func beginNavigation(to directory: URL) {
        loadTask?.cancel()
        rebuildTask?.cancel()
        monitor.stop()

        currentDirectory = directory
        selectionStore.clear()
        errorMessage = nil
        suppressQueryChange = true
        searchQuery = ""
        suppressQueryChange = false
        // 换目录后原有的展开状态不再适用
        expandedPaths.removeAll()
        childItems.removeAll()
        loadingExpansions.removeAll()

        snapshot = .empty(directory: directory, showHidden: showHidden)
        // 保留上一目录的可见内容，直到新目录首帧准备好。
        // 这样 SwiftUI 和 NSTableView 不会在切换期间被销毁重建，视觉上也不会闪空。
        hasLoadedOnce = false
        isLoading = true
        loadCurrentDirectory(force: false)
    }

    private func loadCurrentDirectory(force: Bool) {
        loadTask?.cancel()
        loadToken &+= 1
        let token = loadToken
        let directory = currentDirectory
        let hidden = showHidden
        let priority: DirectoryLoadPriority = activity.isActive ? .foreground : .background

        errorMessage = nil
        isLoading = true

        if !force, let cached = FileSystemHelper.cachedSnapshot(at: directory, showHidden: hidden) {
            apply(snapshot: cached, loadToken: token)
            return
        }

        loadTask = Task { [weak self] in
            do {
                let loaded = try await FileSystemHelper.loadSnapshot(
                    at: directory,
                    showHidden: hidden,
                    useCache: !force,
                    priority: priority
                )
                guard !Task.isCancelled else { return }
                self?.apply(snapshot: loaded, loadToken: token)
            } catch is CancellationError {
                return
            } catch {
                guard let self, token == self.loadToken else { return }
                self.loadTask = nil
                self.isLoading = false
                if self.filteredFiles.isEmpty {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func apply(
        snapshot newSnapshot: DirectorySnapshot,
        loadToken token: UInt64
    ) {
        guard token == loadToken,
              Self.pathKey(newSnapshot.directory) == Self.pathKey(currentDirectory),
              newSnapshot.showHidden == showHidden else { return }

        loadTask = nil
        snapshot = newSnapshot
        hasLoadedOnce = true
        monitor.watch(currentDirectory) { [weak self] in
            self?.refreshFromMonitor()
        }
        scheduleContentRebuild(
            delayNanoseconds: 0,
            // 常见目录直接提交，避免读取完成后再等待一次任务调度。
            immediate: newSnapshot.items.count <= Self.immediateContentItemLimit
        )
    }


    private func refreshFromMonitor() {
        Task {
            await FileSystemHelper.invalidateCache(for: currentDirectory)
            guard !Task.isCancelled else { return }
            loadCurrentDirectory(force: true)
        }
    }

    private func scheduleContentRebuild(
        delayNanoseconds: UInt64,
        immediate: Bool = false
    ) {
        rebuildTask?.cancel()
        rebuildToken &+= 1
        let token = rebuildToken
        let items = snapshot.items
        let query = searchQuery
        let field = sortField
        let order = sortOrder
        let expanded = expandedPaths
        let children = childItems
        let priority: TaskPriority = activity.isActive ? .userInitiated : .utility

        if immediate,
           delayNanoseconds == 0,
           items.count <= Self.immediateContentItemLimit {
            let content = Self.makeContent(
                items: items,
                query: query,
                sortField: field,
                sortOrder: order,
                expanded: expanded,
                children: children
            )
            commit(content: content, token: token)
            return
        }

        rebuildTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled else { return }
            }
            let content = await Task.detached(priority: priority) {
                Self.makeContent(
                    items: items,
                    query: query,
                    sortField: field,
                    sortOrder: order,
                    expanded: expanded,
                    children: children
                )
            }.value
            guard !Task.isCancelled, let self, token == self.rebuildToken else { return }

            self.commit(content: content, token: token)
        }
    }

    /// 过滤排序之后，把已展开目录的子项就地插入，形成带层级的显示顺序。
    /// 搜索时保持平铺结果，方便跨层级查找。
    private nonisolated static func makeContent(
        items: [FileItem],
        query: String,
        sortField: SortField,
        sortOrder: SortOrder,
        expanded: Set<String>,
        children: [String: [FileItem]]
    ) -> ContentSnapshot {
        let base = FileContentPipeline.process(
            items: items,
            query: query,
            sortField: sortField,
            sortOrder: sortOrder
        )
        guard !expanded.isEmpty,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return base
        }

        var result: [FileItem] = []
        result.reserveCapacity(base.files.count)
        let comparator = FileContentPipeline.makeComparator(sortField: sortField, sortOrder: sortOrder)
        for item in base.files {
            appendExpanded(
                item,
                depth: 0,
                expanded: expanded,
                children: children,
                comparator: comparator,
                into: &result
            )
        }
        // 计数仍按顶层条目，展开出来的子项不计入
        return ContentSnapshot(files: result, query: query, totalCount: base.totalCount)
    }

    private nonisolated static func appendExpanded(
        _ item: FileItem,
        depth: Int,
        expanded: Set<String>,
        children: [String: [FileItem]],
        comparator: (FileItem, FileItem) -> Bool,
        into result: inout [FileItem]
    ) {
        result.append(item.atDepth(depth))
        guard item.isDirectory,
              expanded.contains(pathKey(item.url)),
              let kids = children[pathKey(item.url)] else { return }
        for child in kids.sorted(by: comparator) {
            appendExpanded(
                child,
                depth: depth + 1,
                expanded: expanded,
                children: children,
                comparator: comparator,
                into: &result
            )
        }
    }

    /// 在主线程一次性提交一帧目录内容，避免多次触发观察通知。
    private func commit(content: ContentSnapshot, token: UInt64) {
        guard token == rebuildToken else { return }

        rebuildTask = nil
        filteredFiles = content.files
        totalItemCount = content.totalCount
        fileGeneration &+= 1
        isLoading = false

        let validURLs = Set(content.files.map(\.url))
        let retainedSelection = selectionStore.urls.intersection(validURLs)
        selectionStore.set(retainedSelection)
    }

    static func normalizeDirectoryURL(_ url: URL) -> URL {
        URL(
            fileURLWithPath: url.standardizedFileURL.path(percentEncoded: false),
            isDirectory: true
        )
    }

    nonisolated static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}
