import Darwin
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
    private(set) var isPermissionError = false
    private(set) var totalItemCount = 0

    @ObservationIgnored let selectionStore = SelectionStore()
    @ObservationIgnored let activity = PaneActivity()
    /// 窗格级告警框：拖放、粘贴、制作副本、重命名共用同一个展示位
    @ObservationIgnored let dialogs = PaneDialogs()

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
    @ObservationIgnored private var externalRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var cacheValidationTask: Task<Void, Never>?
    /// 根目录刚被删除时的复核任务：给同路径重建留一个合并窗口，避免直接退父。
    @ObservationIgnored private var rootRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var loadToken: UInt64 = 0
    @ObservationIgnored private var rebuildToken: UInt64 = 0
    @ObservationIgnored private var suppressQueryChange = false
    @ObservationIgnored private let monitor = DirectoryMonitor()
    /// 读取目录快照前记下的 FSEvents 事件 ID，读取完成后从该位置补事件。
    @ObservationIgnored private var monitorSinceEventID: UInt64?
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

    deinit {
        // 先断开 FSEvents，再让 monitor 自己释放；避免回调持有正在销毁的窗格。
        monitor.stop()
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }
    var files: [FileItem] { snapshot.items }

    /// ⌘L 请求头部进入路径编辑；每触发一次加一，由窗格头部观察。
    private(set) var pathEditRequestToken: UInt64 = 0

    func requestPathEditing() {
        pathEditRequestToken &+= 1
    }

    // MARK: - 行内重命名

    /// 一次行内改名请求。带 token 是为了支持对同一个文件再次进入改名。
    struct RenameRequest: Equatable {
        let token: UInt64
        let url: URL
        let initialName: String
    }

    /// 由视图消费的改名请求：列表、图标、分栏三种视图各自把它落到自己的行上。
    private(set) var renameRequest: RenameRequest?

    /// 下一次内容提交后要选中的目标。新建、粘贴、改名之后用；
    /// 目标还没出现在列表里时先记着，出现的那一帧再选中。
    @ObservationIgnored private var pendingSelectionURLs: Set<URL>?

    func requestRename(url: URL, initialName: String) {
        let token = (renameRequest?.token ?? 0) &+ 1
        renameRequest = RenameRequest(
            token: token,
            url: url.standardizedFileURL,
            initialName: initialName
        )
    }

    func consumeRenameRequest(token: UInt64) {
        guard renameRequest?.token == token else { return }
        renameRequest = nil
    }

    func selectWhenAvailable(_ urls: [URL]) {
        let normalized = Set(urls.map { $0.standardizedFileURL })
        guard !normalized.isEmpty else { return }
        pendingSelectionURLs = normalized
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
        refreshExternally()
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
                    // 展开是用户主动读取，强制绕过快照缓存；
                    // 收起期间的外部变化可能没有对应事件，不能拿旧缓存充数。
                    useCache: false,
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
        let directory = Self.normalizeDirectoryURL(directory)
        loadTask?.cancel()
        rebuildTask?.cancel()
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
        cacheValidationTask?.cancel()
        cacheValidationTask = nil
        rootRecoveryTask?.cancel()
        rootRecoveryTask = nil
        monitor.stop()
        monitorSinceEventID = DirectoryMonitor.currentEventID()

        currentDirectory = directory
        selectionStore.clear()
        // 换目录后，上一个目录里发起的改名请求和待选中目标都不再适用
        renameRequest = nil
        pendingSelectionURLs = nil
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
        cacheValidationTask?.cancel()
        cacheValidationTask = nil
        loadTask?.cancel()
        loadToken &+= 1
        let token = loadToken
        let directory = currentDirectory
        let hidden = showHidden
        let priority: DirectoryLoadPriority = activity.isActive ? .foreground : .background

        // 首次加载（或监听安装失败后重试）从当前事件 ID 起补事件；
        // 正常刷新沿用已运行的监听，不重置事件游标。
        if monitor.watchedPath == nil, monitorSinceEventID == nil {
            monitorSinceEventID = DirectoryMonitor.currentEventID()
        }

        // 重试期间保留错误页，直到新快照真正提交；否则会把过期列表又露出一帧。
        isLoading = true

        if !force, let cached = FileSystemHelper.cachedSnapshot(at: directory, showHidden: hidden) {
            apply(snapshot: cached, loadToken: token)
            // 缓存只负责首帧；返回旧目录时再后台核对一次，避免把过期快照当实时数据。
            scheduleCacheRevalidation(for: directory)
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
                self.rebuildTask?.cancel()
                self.rebuildTask = nil
                self.rebuildToken &+= 1
                self.selectionStore.clear()
                self.totalItemCount = 0

                if Self.isMissingDirectoryError(error) {
                    // 删除目录时 FSEvents 可能先补一个普通事件，触发这次读取失败。
                    // 不能立刻退父，统一交给复核窗口判断是否真的消失。
                    self.scheduleRootMissingResolution()
                    return
                }

                // 外部刷新失败时不能继续展示旧快照，否则用户会误以为目录没有变化。
                self.isPermissionError = Self.isPermissionError(error)
                self.errorMessage = self.isPermissionError
                    ? "没有访问「\(self.displayName)」的权限。请在系统设置 → 隐私与安全性 → 文件与文件夹中检查 Swifile 的访问权限，或检查该文件夹本身的权限。"
                    : error.localizedDescription
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
        errorMessage = nil
        isPermissionError = false
        // 目录已经成功读到，说明删除只是一次瞬时窗口（或已恢复），取消待执行的退父。
        rootRecoveryTask?.cancel()
        rootRecoveryTask = nil
        let since = monitorSinceEventID
        monitorSinceEventID = nil
        monitor.watch(currentDirectory, since: since) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleDirectoryEvent(event)
            }
        }
        scheduleContentRebuild(
            delayNanoseconds: 0,
            // 常见目录直接提交，避免读取完成后再等待一次任务调度。
            immediate: newSnapshot.items.count <= Self.immediateContentItemLimit
        )
    }

    /// 应用回到前台时兜底检查：监听若被系统延迟或安装失败，目录仍可能发生变化。
    /// 失败状态不受 `hasLoadedOnce` 限制，授权恢复后切回应用会自动重试。
    func refreshIfDirectoryChangedExternally() {
        guard loadTask == nil else { return }
        let directory = currentDirectory
        let loadedAt = snapshot.loadedAt
        let hasError = errorMessage != nil
        let hasLoaded = hasLoadedOnce
        let hasMonitor = monitor.watchedPath != nil
        Task { [weak self] in
            let state = await Task.detached(priority: .utility) {
                let status = DirectoryMonitor.status(of: directory)
                let modified = try? directory.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                return (status, modified)
            }.value
            guard let self, !Task.isCancelled,
                  Self.pathKey(self.currentDirectory) == Self.pathKey(directory) else { return }

            switch state.0 {
            case .missing:
                self.scheduleRootMissingResolution()
                return
            case .denied, .other:
                // 权限拒绝/网络卷瞬时异常交给真实读取流程展示错误，不能误判成目录删除。
                self.refreshExternally()
                return
            case .directory:
                break
            }

            // 监听没装上时目录 mtime 不可靠，直接重读一次。
            if hasError || !hasLoaded || !hasMonitor {
                self.refreshExternally()
                return
            }
            guard let modified = state.1, modified > loadedAt else { return }
            self.refreshExternally()
        }
    }

    /// FSEvents 回调只做路径归类，真正的读取统一走这里。
    private func handleDirectoryEvent(_ event: DirectoryMonitor.Event) {
        // 回调是异步投递到主线程的；用户可能已经切到别的目录。
        // 上一个监视根的事件必须丢弃，否则 rootMoved/rootMissing 会把新目录带跑。
        guard !event.root.isEmpty,
              DirectoryMonitor.canonicalPath(currentDirectory) == event.root else { return }

        if let moved = event.rootMovedTo {
            rootRecoveryTask?.cancel()
            rootRecoveryTask = nil
            followDirectoryMove(to: URL(fileURLWithPath: moved, isDirectory: true))
            return
        }
        if event.rootMissing {
            scheduleRootMissingResolution()
            return
        }
        if event.rootReplaced {
            // 旧 stream/fd 还盯着被替换掉的 inode，重新安装监听后再读。
            rootRecoveryTask?.cancel()
            rootRecoveryTask = nil
            monitor.stop()
            monitorSinceEventID = DirectoryMonitor.currentEventID()
            refreshExternally(changedPaths: event.paths)
            return
        }

        guard hasLoadedOnce else { return }
        let currentKey = DirectoryMonitor.canonicalPath(currentDirectory)
        var reloadCurrent = event.mustScanSubDirs
        var expandedToReload: Set<String> = []
        var collapsedCacheToDrop: Set<String> = []

        if event.mustScanSubDirs {
            expandedToReload = expandedPaths
            collapsedCacheToDrop.formUnion(
                childItems.keys.filter { !expandedPaths.contains($0) }
            )
        } else {
            for path in event.paths {
                let key = DirectoryMonitor.canonicalPath(URL(fileURLWithPath: path))
                // 当前目录本身或它的直接子项变化：刷新顶层列表。
                if key == currentKey || Self.parentPath(key) == currentKey {
                    reloadCurrent = true
                }
                // 事件落在已展开目录内部：只刷新那一层子项。
                for expanded in expandedPaths {
                    let expandedKey = DirectoryMonitor.canonicalPath(
                        URL(fileURLWithPath: expanded, isDirectory: true)
                    )
                    if key == expandedKey || key.hasPrefix(expandedKey + "/") {
                        expandedToReload.insert(expanded)
                    }
                }
                // 收起过的展开目录仍留着旧子项缓存；期间的外部变化要清掉，
                // 下次展开时重新读取，不能继续显示离开时的内容。
                for cachedKey in childItems.keys where !expandedPaths.contains(cachedKey) {
                    let cachedCanonical = DirectoryMonitor.canonicalPath(
                        URL(fileURLWithPath: cachedKey, isDirectory: true)
                    )
                    if key == cachedCanonical || key.hasPrefix(cachedCanonical + "/") {
                        collapsedCacheToDrop.insert(cachedKey)
                    }
                }
            }
            // 分栏视图的子列不在 expandedPaths 里；任何更深层变化都让顶层
            // 重新提交一帧，FileColumnView 会据此失效并重读各列缓存。
            if viewMode == .column, !event.paths.isEmpty {
                reloadCurrent = true
            }
        }

        for key in collapsedCacheToDrop {
            childItems.removeValue(forKey: key)
        }
        guard reloadCurrent || !expandedToReload.isEmpty else { return }
        refreshExternally(
            changedPaths: event.paths,
            reloadCurrent: reloadCurrent,
            expandedDirectories: expandedToReload
        )
    }

    /// 当前目录被改名（或它的上级被改名）：把历史里的当前项换成新路径，继续停在同一目录。
    private func followDirectoryMove(to url: URL) {
        let target = Self.normalizeDirectoryURL(url)
        // FSEvents 说目标存在，但投递到主线程时可能又被改走/改回。
        // 目标已经不在时先重读原路径；原路径也真的没了，读取错误会自然退父。
        guard DirectoryMonitor.status(of: target) == .directory else {
            monitor.stop()
            monitorSinceEventID = DirectoryMonitor.currentEventID()
            refreshExternally()
            return
        }
        guard Self.pathKey(target) != Self.pathKey(currentDirectory) else {
            monitor.stop()
            monitorSinceEventID = DirectoryMonitor.currentEventID()
            refreshExternally()
            return
        }
        if historyIndex < history.count {
            history[historyIndex] = target
        }
        beginNavigation(to: target)
    }

    /// 根目录刚被删除时先等一个合并窗口：原子替换/快速重建会在同路径重新出现。
    /// 窗口结束仍是目录就留下重读；真的没了才退到最近存在的上级。
    private func scheduleRootMissingResolution() {
        // 同一次删除可能同时产生 rootMissing 和普通文件事件，只保留最早建立的复核窗口；
        // 重复重置窗口会一直被后续事件顺延，反而退不了父。
        guard rootRecoveryTask == nil else { return }
        let directory = currentDirectory
        rootRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled,
                  Self.pathKey(self.currentDirectory) == Self.pathKey(directory) else { return }
            self.rootRecoveryTask = nil

            if DirectoryMonitor.status(of: directory) == .directory {
                self.monitor.stop()
                self.monitorSinceEventID = DirectoryMonitor.currentEventID()
                self.refreshExternally()
            } else {
                self.navigateToNearestExistingParent()
            }
        }
    }

    /// 对齐访达：当前目录被删除时退到最近仍存在的上级目录。
    private func navigateToNearestExistingParent() {
        var parent = currentDirectory.deletingLastPathComponent()
        var parentStatus = DirectoryMonitor.status(of: parent)
        while Self.pathKey(parent) != "/",
              parentStatus != .directory,
              parentStatus != .denied {
            parent = parent.deletingLastPathComponent()
            parentStatus = DirectoryMonitor.status(of: parent)
        }
        guard Self.pathKey(parent) != Self.pathKey(currentDirectory),
              parentStatus == .directory || parentStatus == .denied else {
            monitor.stop()
            monitorSinceEventID = nil
            isLoading = false
            errorMessage = "当前目录已不存在，也没有可返回的上级目录。"
            return
        }
        if historyIndex < history.count {
            history[historyIndex] = parent
        }
        beginNavigation(to: parent)
    }

    private func refreshExternally(
        changedPaths: Set<String> = [],
        reloadCurrent: Bool = true,
        expandedDirectories: Set<String>? = nil
    ) {
        externalRefreshTask?.cancel()
        let target = currentDirectory
        let targetKey = Self.pathKey(target)
        let directories = expandedDirectories ?? expandedPaths

        externalRefreshTask = Task { [weak self] in
            guard let self else { return }
            if !changedPaths.isEmpty {
                await IconService.shared.invalidate(paths: changedPaths)
            } else if reloadCurrent {
                await IconService.shared.invalidate(
                    paths: [DirectoryMonitor.canonicalPath(target)]
                )
            }

            for key in directories {
                guard !Task.isCancelled, self.expandedPaths.contains(key) else { continue }
                let url = URL(fileURLWithPath: key, isDirectory: true)
                await FileSystemHelper.invalidateCache(for: url)
                do {
                    let snapshot = try await FileSystemHelper.loadSnapshot(
                        at: url,
                        showHidden: self.showHidden,
                        useCache: false,
                        priority: self.activity.isActive ? .foreground : .background
                    )
                    guard !Task.isCancelled,
                          Self.pathKey(self.currentDirectory) == targetKey else { return }
                    // 用户在读取期间收起了这个目录，跳过它，但不要中止同批的其他刷新。
                    guard self.expandedPaths.contains(key) else { continue }
                    self.childItems[key] = snapshot.items
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.expandedPaths.remove(key)
                    self.childItems.removeValue(forKey: key)
                }
            }

            guard !Task.isCancelled,
                  Self.pathKey(self.currentDirectory) == targetKey else { return }
            if reloadCurrent {
                await FileSystemHelper.invalidateCache(for: target)
                guard !Task.isCancelled else { return }
                self.loadCurrentDirectory(force: true)
            } else {
                self.scheduleContentRebuild(delayNanoseconds: 0)
            }
        }
    }

    /// 缓存命中后补一次后台强刷：返回旧目录、目录被删或权限变化时，
    /// 首帧仍能立即显示，但不会一直停在过期快照上。
    private func scheduleCacheRevalidation(for directory: URL) {
        cacheValidationTask?.cancel()
        cacheValidationTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled,
                  Self.pathKey(self.currentDirectory) == Self.pathKey(directory) else { return }
            self.loadCurrentDirectory(force: true)
        }
    }

    private static func parentPath(_ path: String) -> String {
        DirectoryMonitor.canonicalPath(
            URL(fileURLWithPath: path).deletingLastPathComponent()
        )
    }

    nonisolated static func isExistingDirectory(_ url: URL) -> Bool {
        DirectoryMonitor.status(of: url) == .directory
    }

    /// TCC 目录权限和普通 POSIX 权限都会表现为读取失败；
    /// 只有这类错误才展示权限引导，其他 I/O 错误保留系统文案。
    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    private static func isMissingDirectoryError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           (nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR)) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingDirectoryError(underlying)
        }
        return false
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
        var nextSelection = selectionStore.urls.intersection(validURLs)
        // 新建、粘贴、改名后要把选中落到新条目上：目标出现的那一帧才提交，
        // 提前提交会被这里的有效性过滤掉，表现为「建好了但没选中」。
        if let pending = pendingSelectionURLs {
            let matched = pending.intersection(validURLs)
            if !matched.isEmpty {
                nextSelection = matched
                pendingSelectionURLs = nil
            }
        }
        selectionStore.set(nextSelection)
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
