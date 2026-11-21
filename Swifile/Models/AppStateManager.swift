import Foundation
import Observation

// MARK: - 窗格焦点

/// 管理当前活动窗格，并将活动高亮限制在两个 PaneActivity 对象之间更新。
@MainActor
@Observable
final class PaneFocus {
    private(set) var activePane: PaneState

    init(activePane: PaneState) {
        self.activePane = activePane
        activePane.activity.setActive(true)
    }

    var activePaneId: UUID { activePane.id }

    func activate(_ pane: PaneState) {
        guard pane.id != activePane.id else { return }
        activePane.activity.setActive(false)
        activePane = pane
        pane.activity.setActive(true)
    }
}

// MARK: - 侧边栏与暂存区

@MainActor
@Observable
final class SidebarState {
    /// 「收藏 / 硬盘」的选中项（目标目录 URL）；点快速访问条目时置 nil（与快速访问高亮互斥）
    var selectedItem: URL? = nil

    /// 当前打开的快速访问条目：点击后高亮；操作焦点转入内容区（激活窗格）
    /// 或切换位置分组时清除，保证「唯一焦点」的语义。
    var selectedQuickAccessId: UUID? = nil
}

@MainActor
@Observable
final class StagingState {
    private(set) var items: [FileItem] = []

    func stageItems(_ newItems: [FileItem]) {
        let existing = Set(items.map(\.url))
        items.append(contentsOf: newItems.filter { !existing.contains($0.url) })
    }

    func unstageItem(_ item: FileItem) {
        items.removeAll { $0.id == item.id }
    }

    /// 批量移除（移动成功、框选删除等场景）。按 URL 身份精确删除，不改动其他条目。
    func removeItems(withIDs ids: Set<FileItem.ID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
    }

    func clear() {
        items.removeAll(keepingCapacity: true)
    }
}

/// 系统快速预览（QuickLook）的入口状态：
/// 选中文件按空格键或右键「快速预览」时写入，预览面板关闭时清空。
@MainActor
@Observable
final class PreviewState {
    /// 预览目标文件：空格呼出的悬浮预览与右键「快速预览」共用；nil = 未打开
    var item: FileItem? = nil
}

// MARK: - 应用状态

/// 应用级状态只负责组合独立子状态，不参与文件列表热路径。
@MainActor
@Observable
final class AppStateManager {
    private(set) var panes: [PaneState]
    private(set) var layoutMode: LayoutMode = .single
    private(set) var diskUsed: Int64 = 0
    private(set) var diskTotal: Int64 = 0

    let paneFocus: PaneFocus
    let sidebar = SidebarState()
    let staging = StagingState()
    let preview = PreviewState()
    let quickAccess = QuickAccessManager()
    let favorites = SidebarFavoritesSettings()

    @ObservationIgnored private var parkedPanes: [PaneState] = []
    /// 当前这次容量读取；切换目录时取消上一次，避免旧卷的结果覆盖新卷
    @ObservationIgnored private var diskUsageReadTask: Task<Void, Never>?
    /// 低频刷新循环：容量会随文件写入变化，不只在切换卷时更新
    @ObservationIgnored private var diskUsageRefreshTask: Task<Void, Never>?

    init() {
        let initialPane = PaneState(directory: FileManager.default.homeDirectoryForCurrentUser)
        self.panes = [initialPane]
        self.paneFocus = PaneFocus(activePane: initialPane)
        refreshDiskUsage(for: initialPane.currentDirectory)
        startDiskUsageRefreshLoop()
    }

    /// 设置窗格布局，并复用已创建的窗格状态。
    func setLayout(_ mode: LayoutMode) {
        guard mode != layoutMode else { return }
        layoutMode = mode

        var candidates: [PaneState] = [paneFocus.activePane]
        candidates.append(contentsOf: panes.filter { $0.id != paneFocus.activePane.id })
        candidates.append(contentsOf: parkedPanes.filter { parked in
            !candidates.contains { $0.id == parked.id }
        })

        while candidates.count < mode.paneCount {
            candidates.append(PaneState(directory: FileManager.default.homeDirectoryForCurrentUser))
        }

        panes = Array(candidates.prefix(mode.paneCount))
        parkedPanes = Array(candidates.dropFirst(mode.paneCount))
        paneFocus.activate(panes[0])
        loadAllPanes()
    }

    /// 加载当前布局中可见的窗格；重复目录请求由目录协调器自动合并。
    func loadAllPanes() {
        guard !PerfHarness.isEnabled else { return }
        for pane in panes {
            pane.ensureLoaded()
        }
    }

    /// 按目录所在卷刷新可用容量。活动窗格切换目录、切换窗格、挂载变化和应用回到前台时调用。
    func refreshDiskUsage(for directory: URL) {
        diskUsageReadTask?.cancel()
        let path = directory.path(percentEncoded: false)
        diskUsageReadTask = Task { [weak self] in
            let values = await Task.detached(priority: .utility) {
                let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
                let total = (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0
                let free = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                return (total: total, used: max(0, total - free))
            }.value
            guard !Task.isCancelled, let self else { return }
            // 路径暂时不可读（磁盘正在卸载等）时保留上一次的有效值
            guard values.total > 0 else { return }
            // 同值不写回，避免无谓的界面重绘
            if self.diskTotal != values.total || self.diskUsed != values.used {
                self.diskTotal = values.total
                self.diskUsed = values.used
            }
        }
    }

    /// 每 30 秒核对一次当前卷容量；一次文件系统属性读取，主线程开销可忽略
    private func startDiskUsageRefreshLoop() {
        guard !PerfHarness.isEnabled else { return }
        diskUsageRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.refreshDiskUsage(for: self.paneFocus.activePane.currentDirectory)
            }
        }
    }
}
