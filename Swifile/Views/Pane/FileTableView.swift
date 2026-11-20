import SwiftUI
import AppKit
import Observation

// MARK: - 高性能 NSTableView 桥接
/// - 行/单元格复用
/// - O(1) fileGeneration 判断是否 reload
/// - 选择写入独立 SelectionStore，不经过 PaneState，避免内容树刷新
/// - 通过 withObservationTracking 监听 store.generation，外部清空时仍能同步
/// - 图标经 IconService 异步加载
@MainActor
struct FileTableView: NSViewRepresentable, Equatable {
    let files: [FileItem]
    let fileGeneration: UInt64
    let activity: PaneActivity
    let selectionStore: SelectionStore
    let onDoubleClick: (FileItem) -> Void
    let paneId: UUID
    let onActivate: () -> Void
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState
    let onRefresh: () -> Void
    /// 当前目录：空白区域右键的菜单作用于它
    let directory: URL
    let sortField: SortField
    let sortOrder: SortOrder
    let onSortChange: (SortField) -> Void
    /// 查询目录是否处于原地展开状态（单元格渲染用）
    let isExpanded: (URL) -> Bool
    /// 查询目录子项是否仍在读取中（单元格渲染用）
    let isExpanding: (URL) -> Bool
    /// 点击展开三角
    let onToggleExpand: (FileItem) -> Void

    /// 父级因工具栏、焦点等无关状态重算时，不触发其它窗格的 AppKit 桥接更新。
    /// 文件内容由 fileGeneration 表示；选择和活动状态各自由 Coordinator 直接观察。
    nonisolated static func == (lhs: FileTableView, rhs: FileTableView) -> Bool {
        lhs.paneId == rhs.paneId &&
            lhs.fileGeneration == rhs.fileGeneration
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // 浮动滚动条（访达同款）：滚动时浮现、不占布局宽度。
        // 「始终显示滚动条」偏好下的旧式滚动条会把可用宽度压掉一条。
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        let tableView = SwifileTableView()
        let coordinator = context.coordinator
        tableView.onEmptyAreaClick = { [weak coordinator] in
            // 仅空白区域：激活 + 清空选择
            coordinator?.handleEmptyClick()
        }
        tableView.onRowClickActivate = { [weak coordinator] in
            coordinator?.parent.onActivate()
        }
        tableView.onFocusChange = { [weak coordinator] in
            coordinator?.handleFocusChange($0)
        }
        // 与访达同款外观：内缩圆角选中 + 交替行背景（斑马纹）。
        // 这两项本来就是 AppKit 的原生能力，先前被关掉后改为自行绘制，反而与系统不一致。
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        // 访达列表的默认行高即 24pt
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.headerView = FileTableHeaderView()
        // 内容背景色：交替行背景（斑马纹）以它为基准绘制，透明背景会让斑马纹不可见
        tableView.backgroundColor = .controlBackgroundColor
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)

        // 图标与名称合并在同一列：展开子项时三角、图标、名称整体右移，与访达一致
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "名称"
        nameCol.width = 200
        nameCol.minWidth = 120
        nameCol.isEditable = false
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        // 名称列吃掉表格的剩余宽度（访达同款）。不用系统的 autoresizingMask：
        // 它只在窗口拖动这类活 resize 里生效，切换视图/布局的一次性 frame 变化
        // 不触发重算，名称列会保持初始宽把右侧列挤出可视区。改为表格自己在
        // layout() 里吸收宽度差值（见 SwifileTableView.syncNameColumnWidth）。
        nameCol.resizingMask = .userResizingMask
        tableView.addTableColumn(nameCol)

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "修改日期"
        dateCol.width = 140
        dateCol.minWidth = 100
        dateCol.isEditable = false
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
        dateCol.resizingMask = .userResizingMask
        dateCol.headerCell.alignment = .left
        tableView.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "大小"
        sizeCol.width = 60
        sizeCol.minWidth = 50
        sizeCol.maxWidth = 80
        sizeCol.isEditable = false
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        sizeCol.resizingMask = .userResizingMask
        sizeCol.headerCell.alignment = .left
        tableView.addTableColumn(sizeCol)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "类型"
        typeCol.width = 80
        typeCol.minWidth = 60
        typeCol.isEditable = false
        typeCol.sortDescriptorPrototype = NSSortDescriptor(key: "type", ascending: true)
        typeCol.resizingMask = .userResizingMask
        tableView.addTableColumn(typeCol)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.target = context.coordinator
        // 双击打开的自判路径：cc >= 2 的点击不交给原生处理（见 mouseDown），判定成立后由这里打开
        tableView.onRowDoubleClick = { [weak coordinator] row in
            coordinator?.openRow(row)
        }
        tableView.menu = createContextMenu(coordinator: context.coordinator)
        // 空白区域返回目录级菜单，行上仍是文件菜单
        tableView.emptyAreaMenu = context.coordinator.makeDirectoryMenu()

        context.coordinator.tableView = tableView
        context.coordinator.currentFiles = files
        context.coordinator.lastPaneId = paneId
        context.coordinator.lastFileGeneration = fileGeneration
        context.coordinator.rebuildIndex()
        context.coordinator.lastIsActive = activity.isActive
        context.coordinator.activity = activity
        context.coordinator.selectionStore = selectionStore
        context.coordinator.lastSelectionGeneration = selectionStore.generation
        context.coordinator.applySelectionToTable(selectionStore.urls, tableView: tableView)
        context.coordinator.startObservingSelection()
        context.coordinator.startObservingActivity()

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        let coordinator = context.coordinator

        coordinator.parent = self
        if coordinator.activity !== activity {
            coordinator.activity = activity
            coordinator.lastIsActive = activity.isActive
            coordinator.startObservingActivity()
        }
        if coordinator.selectionStore !== selectionStore {
            coordinator.selectionStore = selectionStore
            coordinator.lastSelectionGeneration = selectionStore.generation
            coordinator.startObservingSelection()
        }

        // 1) 文件数据：O(1) generation。切换布局后若窗格位置变化，也必须刷新数据源。
        // 数据源和行号索引必须与表格重载同时生效：提前替换会让「点击行号 → 文件」的换算
        // 在表格仍显示旧内容的这段时间里指向错误的文件。
        if coordinator.lastPaneId != paneId || coordinator.lastFileGeneration != fileGeneration {
            coordinator.lastPaneId = paneId
            coordinator.lastFileGeneration = fileGeneration
            coordinator.scheduleReload(
                files: files,
                scrollView: scrollView,
                selectionStore: selectionStore
            )
            return
        }

        // 2) 活动状态由 Coordinator 直接监听，不参与内容树更新
        // 3) 选择（父视图因其他原因刷新时顺带对齐）
        if coordinator.lastSelectionGeneration != selectionStore.generation {
            coordinator.lastSelectionGeneration = selectionStore.generation
            coordinator.applySelectionToTable(selectionStore.urls, tableView: tableView)
        }

        // 4) 排序指示：同步给表格，系统才会在表头绘制升降序箭头
        let desiredKey = sortField.rawValue
        let desiredAscending = sortOrder == .ascending
        let currentDescriptor = tableView.sortDescriptors.first
        if currentDescriptor?.key != desiredKey || currentDescriptor?.ascending != desiredAscending {
            coordinator.isSyncingSort = true
            tableView.sortDescriptors = [NSSortDescriptor(key: desiredKey, ascending: desiredAscending)]
            tableView.highlightedTableColumn = tableView.tableColumns.first {
                $0.identifier.rawValue == desiredKey
            }
            coordinator.isSyncingSort = false
        }
    }

    /// 列表视图的行右键菜单。标题、图标、顺序都取自 FileMenuCommand，
    /// 与列视图、图标视图的 SwiftUI 菜单共用同一份定义。
    private func createContextMenu(coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = coordinator

        func item(_ command: FileMenuCommand, _ action: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: command.title, action: action, keyEquivalent: key)
            i.target = coordinator
            i.image = command.menuImage
            return i
        }

        menu.addItem(item(.open, #selector(Coordinator.menuOpen(_:))))
        menu.addItem(coordinator.makeRowOpenWithItem())
        menu.addItem(item(.quickLook, #selector(Coordinator.menuQuickLook(_:))))
        menu.addItem(.separator())
        menu.addItem(item(.revealInFinder, #selector(Coordinator.menuRevealInFinder(_:))))
        menu.addItem(item(.openInTerminal, #selector(Coordinator.menuOpenInTerminal(_:))))
        menu.addItem(.separator())
        menu.addItem(item(.copy, #selector(Coordinator.menuCopy(_:)), key: "c"))
        menu.addItem(item(.copyPath, #selector(Coordinator.menuCopyPath(_:))))
        menu.addItem(.separator())

        // 快速访问是单一扁平列表，直接用一个菜单项添加
        menu.addItem(item(.addToQuickAccess, #selector(Coordinator.menuAddToQuickAccess(_:))))
        menu.addItem(item(.addToStaging, #selector(Coordinator.menuAddToStaging(_:))))

        menu.addItem(.separator())
        menu.addItem(item(.moveToTrash, #selector(Coordinator.menuMoveToTrash(_:)), key: "\u{8}"))
        return menu
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var parent: FileTableView
        var currentFiles: [FileItem] = []
        var rowIndexByURL: [URL: Int] = [:]
        weak var tableView: NSTableView?

        var isSyncing = false
        var lastSyncedSelection: Set<URL> = []
        var lastIsActive: Bool = false
        var lastPaneId: UUID
        var lastFileGeneration: UInt64 = 0
        var lastSelectionGeneration: UInt64 = 0
        var activity: PaneActivity?
        var selectionStore: SelectionStore?
        private var observingSelection = false
        private var observingActivity = false
        private var reloadScheduled = false
        /// 等待与表格重载同时生效的数据源
        private var pendingFiles: [FileItem]?
        /// 回写排序指示时的防重入标志
        var isSyncingSort = false
        /// 「打开方式」子菜单控制器。NSMenu.delegate 是弱引用，必须在这里持有
        private var openWithMenuControllers: [OpenWithMenuController] = []

        init(parent: FileTableView) {
            self.parent = parent
            self.currentFiles = parent.files
            self.lastIsActive = parent.activity.isActive
            self.lastPaneId = parent.paneId
            self.lastFileGeneration = parent.fileGeneration
            self.activity = parent.activity
            self.selectionStore = parent.selectionStore
            super.init()
            rebuildIndex()
        }

        func rebuildIndex() {
            var map: [URL: Int] = [:]
            map.reserveCapacity(currentFiles.count)
            for (i, file) in currentFiles.enumerated() {
                map[file.url] = i
            }
            rowIndexByURL = map
        }

        func startObservingSelection() {
            guard !observingSelection else { return }
            observingSelection = true
            trackSelection()
        }

        func startObservingActivity() {
            guard !observingActivity else { return }
            observingActivity = true
            trackActivity()
        }

        private func trackActivity() {
            guard observingActivity, let activity, self.tableView != nil else { return }
            withObservationTracking {
                _ = activity.isActive
                _ = activity.hasKeyboardFocus
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let activity = self.activity, let tableView = self.tableView else { return }
                    let becameActive = activity.isActive && !self.lastIsActive
                    self.lastIsActive = activity.isActive
                    // 选中高亮的强调/弱化由「窗格是否活动」加「是否持有键盘焦点」共同决定：
                    // 列视图与图标视图是纯 SwiftUI，不接管第一响应者，只能显式告知。
                    self.refreshVisibleRows(tableView)
                    // 只有窗格刚被激活时才把第一响应者收过来（方向键选行等键盘行为依赖它）。
                    // 键盘焦点变化绝不能走这一步，否则点搜索框会被立刻抢回焦点。
                    if becameActive,
                       let window = tableView.window,
                       window.firstResponder !== tableView {
                        window.makeFirstResponder(tableView)
                    }
                    // 非活动窗格只显示占位图标；获得焦点时只升级当前可见单元格的图标。
                    // 整表 reloadData 会丢弃复用池并重新测量全部行，实测单次约 57ms，因此不再使用。
                    if becameActive {
                        self.upgradeVisibleIcons(in: tableView)
                    }
                    self.trackActivity()
                }
            }
        }

        /// 让可见行重绘一次；绘制时会重新查询窗格活动状态，因此不需要传值进来。
        private func refreshVisibleRows(_ tableView: NSTableView) {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<(visible.location + visible.length) {
                tableView.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
        }

        /// 获得焦点时只补齐当前可见单元格的图标，不做整表 reload。
        /// 不可见的行会在滚动进入可视区时由 makeIconCell 正常发起加载。
        private func upgradeVisibleIcons(in tableView: NSTableView) {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<(visible.location + visible.length) {
                guard row < currentFiles.count,
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileNameCell,
                      !cell.hasLoadedIcon,
                      cell.iconTask == nil else { continue }
                applyIcon(for: currentFiles[row], to: cell, priority: .foreground)
            }
        }

        private func trackSelection() {
            guard observingSelection, let store = selectionStore else { return }
            withObservationTracking {
                _ = store.generation
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let store = self.selectionStore, let tableView = self.tableView else { return }
                    if self.lastSelectionGeneration != store.generation {
                        self.lastSelectionGeneration = store.generation
                        self.applySelectionToTable(store.urls, tableView: tableView)
                    }
                    // Observation 一次性回调，需重新注册
                    self.trackSelection()
                }
            }
        }

        /// 记录待生效的数据源，并在下一轮主线程与表格重载一起生效。
        /// 重复调度时只覆盖待生效数据，保证最终生效的是最新一帧。
        func scheduleReload(files: [FileItem], scrollView: NSScrollView, selectionStore: SelectionStore) {
            pendingFiles = files
            guard !reloadScheduled else { return }
            reloadScheduled = true

            DispatchQueue.main.async { [weak self, weak scrollView, weak selectionStore] in
                guard let self, let scrollView, let selectionStore else { return }
                self.reloadTableView(in: scrollView, selectionStore: selectionStore)
            }
        }

        /// 原地更新行数和可见单元格，保留滚动容器、表头和复用池。
        /// 切换目录时不替换 NSTableView，避免 AppKit 重新建立整棵布局树。
        private func reloadTableView(in scrollView: NSScrollView, selectionStore: SelectionStore) {
            guard let table = scrollView.documentView as? SwifileTableView else {
                reloadScheduled = false
                return
            }

            let oldOrigin = scrollView.contentView.bounds.origin
            tableView = table
            reloadScheduled = false

            // 数据源与行号索引先落到新的一帧，再重载表格，两者对 AppKit 是同一时刻。
            if let files = pendingFiles {
                pendingFiles = nil
                currentFiles = files
                rebuildIndex()
            }

            table.beginUpdates()
            table.noteNumberOfRowsChanged()
            table.endUpdates()
            table.reloadData()
            applySelectionToTable(selectionStore.urls, tableView: table)

            let maxY = max(0, table.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: oldOrigin.x, y: min(oldOrigin.y, maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func applySelectionToTable(_ selection: Set<URL>, tableView: NSTableView) {
            lastSyncedSelection = selection
            let selectedIndices = NSMutableIndexSet()
            for url in selection {
                if let row = rowIndexByURL[url] {
                    selectedIndices.add(row)
                }
            }
            let asIndexSet = selectedIndices as IndexSet
            if tableView.selectedRowIndexes != asIndexSet {
                isSyncing = true
                tableView.selectRowIndexes(asIndexSet, byExtendingSelection: false)
                isSyncing = false
            }
        }

        func handleEmptyClick() {
            parent.onActivate()
            selectionStore?.clear()
        }

        /// 表格的键盘焦点进出：写入 activity，可见行的选中色随之在强调/弱化间切换
        func handleFocusChange(_ focused: Bool) {
            activity?.setKeyboardFocus(focused)
        }

        // MARK: - DataSource

        func numberOfRows(in tableView: NSTableView) -> Int { currentFiles.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < currentFiles.count, let column = tableColumn else { return nil }
            let file = currentFiles[row]
            switch column.identifier.rawValue {
            case "name":
                return makeNameCell(for: file, tableView: tableView)
            case "size":
                return makeTextCell(text: file.formattedSize, identifier: column.identifier, tableView: tableView, color: .secondaryLabelColor)
            case "date":
                return makeTextCell(text: file.formattedDate, identifier: column.identifier, tableView: tableView, color: .secondaryLabelColor)
            case "type":
                return makeTextCell(text: file.fileType, identifier: column.identifier, tableView: tableView, color: .secondaryLabelColor)
            default:
                return nil
            }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("PaneRowView")
            let rowView: PaneRowView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? PaneRowView {
                rowView = reused
            } else {
                rowView = PaneRowView()
                rowView.identifier = identifier
            }
            let activity = self.activity
            rowView.emphasizedProvider = { [weak activity] in
                guard let activity else { return false }
                return activity.isActive && activity.hasKeyboardFocus
            }
            return rowView
        }

        // MARK: - Selection → Store（不经过 PaneState）

        /// 表格就是选中的权威来源：变化时立即同步到 SelectionStore。
        /// 原先经一轮主线程调度再提交，会让「表格已经高亮」与「其它视图看到的选中」
        /// 短暂不一致，跨窗格点击时表现为高亮先落到别处再修正。
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing else { return }
            guard let tableView = notification.object as? NSTableView else { return }

            var newSelection = Set<URL>()
            newSelection.reserveCapacity(tableView.selectedRowIndexes.count)
            for index in tableView.selectedRowIndexes where index < currentFiles.count {
                newSelection.insert(currentFiles[index].url)
            }

            lastSyncedSelection = newSelection
            guard let store = selectionStore, store.urls != newSelection else { return }
            store.set(newSelection)
            lastSelectionGeneration = store.generation
        }

        // MARK: - Sort / Double click

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            // 由 updateNSView 回写排序指示时不再反向触发排序，避免自激
            guard !isSyncingSort else { return }
            guard let sortDesc = tableView.sortDescriptors.first, let key = sortDesc.key else { return }
            let fieldMap: [String: SortField] = [
                "name": .name, "size": .size, "date": .date, "type": .type
            ]
            if let field = fieldMap[key] {
                parent.onSortChange(field)
            }
        }

        @objc func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            // 兜底路径（带修饰键的双击等仍走原生 doubleAction）：系统 clickCount
            // 不区分落在哪一行，这里仍补一道「同一行」校验
            if let table = sender as? SwifileTableView, !table.consumeDoubleClick(row: row) {
                return
            }
            openRow(row)
        }

        /// 打开一行：自判双击（cc >= 2 的无修饰键点击）与原生 doubleAction 共用
        func openRow(_ row: Int) {
            guard row >= 0, row < currentFiles.count else { return }
            parent.onDoubleClick(currentFiles[row])
        }

        // MARK: - Context menu

        /// 空白区域菜单：作用于当前目录本身
        func makeDirectoryMenu() -> NSMenu {
            let menu = NSMenu()

            func item(_ command: FileMenuCommand, _ action: Selector, key: String = "") -> NSMenuItem {
                let i = NSMenuItem(title: command.title, action: action, keyEquivalent: key)
                i.target = self
                i.image = command.menuImage
                return i
            }

            menu.addItem(item(.newFolder, #selector(menuCreateFolder(_:))))
            menu.addItem(.separator())
            menu.addItem(item(.revealInFinder, #selector(menuRevealDirectory(_:))))
            menu.addItem(item(.openInTerminal, #selector(menuOpenDirectoryInTerminal(_:))))
            menu.addItem(makeDirectoryOpenWithItem())
            menu.addItem(.separator())
            menu.addItem(item(.copyDirectoryPath, #selector(menuCopyDirectoryPath(_:))))
            menu.addItem(.separator())
            menu.addItem(item(.refresh, #selector(menuRefresh(_:))))
            return menu
        }

        // MARK: 打开方式子菜单

        /// 行菜单的「打开方式」：目标取当前选中的文件（多选时作用于全部）
        func makeRowOpenWithItem() -> NSMenuItem {
            makeOpenWithItem { [weak self] in
                self?.contextFiles.map(\.url) ?? []
            }
        }

        /// 空白区域菜单的「打开方式」：目标就是当前目录
        func makeDirectoryOpenWithItem() -> NSMenuItem {
            makeOpenWithItem { [weak self] in
                guard let directory = self?.parent.directory else { return [] }
                return [directory]
            }
        }

        private func makeOpenWithItem(urlsProvider: @escaping () -> [URL]) -> NSMenuItem {
            let item = NSMenuItem(
                title: FileMenuCommand.openWith.title,
                action: nil,
                keyEquivalent: ""
            )
            item.image = FileMenuCommand.openWith.menuImage
            let controller = OpenWithMenuController(urlsProvider: urlsProvider)
            openWithMenuControllers.append(controller)
            item.submenu = controller.menu
            return item
        }

        @objc func menuCreateFolder(_ sender: NSMenuItem) {
            FileActions.createFolder(in: parent.directory) { [weak self] in
                self?.parent.onRefresh()
            }
        }

        @objc func menuRevealDirectory(_ sender: NSMenuItem) {
            FileActions.reveal(parent.directory)
        }

        @objc func menuOpenDirectoryInTerminal(_ sender: NSMenuItem) {
            FileActions.openInTerminal(at: parent.directory)
        }

        @objc func menuCopyDirectoryPath(_ sender: NSMenuItem) {
            FileActions.copyPath(parent.directory)
        }

        @objc func menuRefresh(_ sender: NSMenuItem) {
            parent.onRefresh()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView = tableView else { return }
            let clickedRow = tableView.clickedRow
            if clickedRow >= 0 && !tableView.selectedRowIndexes.contains(clickedRow) {
                tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
        }

        private var contextFiles: [FileItem] {
            guard let tableView = tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { index in
                index < currentFiles.count ? currentFiles[index] : nil
            }
        }

        // 菜单动作统一走 FileActions，与列视图、图标视图的右键菜单共用同一套实现
        @objc func menuOpen(_ sender: NSMenuItem) {
            FileActions.open(contextFiles) { file in
                parent.onDoubleClick(file)
            }
        }

        @objc func menuRevealInFinder(_ sender: NSMenuItem) {
            FileActions.revealInFinder(contextFiles)
        }

        @objc func menuOpenInTerminal(_ sender: NSMenuItem) {
            guard let file = contextFiles.first else { return }
            FileActions.openInTerminal(file)
        }

        @objc func menuQuickLook(_ sender: NSMenuItem) {
            if let first = contextFiles.first {
                parent.preview.item = first
            }
        }

        @objc func menuCopy(_ sender: NSMenuItem) {
            FileActions.copyURLs(contextFiles)
        }

        @objc func menuCopyPath(_ sender: NSMenuItem) {
            FileActions.copyPaths(contextFiles)
        }

        @objc func menuAddToStaging(_ sender: NSMenuItem) {
            FileActions.addToStaging(contextFiles, staging: parent.staging)
        }

        @objc func menuAddToQuickAccess(_ sender: NSMenuItem) {
            FileActions.addToQuickAccess(contextFiles, manager: parent.quickAccess)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row < currentFiles.count else { return nil }
            return currentFiles[row].url as NSURL
        }

        @objc func menuMoveToTrash(_ sender: NSMenuItem) {
            FileActions.moveToTrash(contextFiles) {
                self.parent.onRefresh()
            }
        }

        // MARK: - Cells

        /// 图标加载的唯一入口：非活动窗格只保留占位图，活动窗格才发起真实请求。
        private func applyIcon(
            for file: FileItem,
            to cell: FileNameCell,
            priority: IconService.RequestPriority
        ) {
            let urlPath = file.url.path(percentEncoded: false)
            let generation = parent.fileGeneration
            // 路径和版本未变且已拿到真实图标时不重来，避免滚动往返闪占位图；
            // 文件内容变化时 FileItem 的修改时间或整表 generation 会变化，必须重新取图。
            if cell.currentPath == urlPath,
               cell.loadedGeneration == generation,
               cell.hasLoadedIcon {
                return
            }

            let token = cell.nextToken()
            cell.iconTask?.cancel()
            cell.iconTask = nil
            cell.currentPath = urlPath
            cell.loadedGeneration = generation
            cell.hasLoadedIcon = false
            cell.imageView?.image = IconService.placeholder(isDirectory: file.isDirectory, size: 16)

            guard activity?.isActive ?? false else { return }

            cell.iconTask = Task(priority: priority.taskPriority) { [weak cell] in
                if let cached = IconService.shared.cached(
                    path: urlPath,
                    size: 16,
                    version: file.modificationDate,
                    fileSize: file.size
                ) {
                    await MainActor.run {
                        guard let cell, cell.currentPath == urlPath, cell.token == token else { return }
                        cell.imageView?.image = cached
                        cell.hasLoadedIcon = true
                        cell.iconTask = nil
                    }
                    return
                }
                let icon = await IconService.shared.icon(
                    for: urlPath,
                    size: 16,
                    version: file.modificationDate,
                    fileSize: file.size,
                    priority: priority
                )
                await MainActor.run {
                    guard let cell, cell.currentPath == urlPath, cell.token == token else { return }
                    cell.imageView?.image = icon
                    cell.hasLoadedIcon = true
                    cell.iconTask = nil
                }
            }
        }

        /// 名称列：三角 + 图标 + 文件名，整体按层级右移。
        /// 三角是独立按钮，点击只触发展开/折叠，不改变表格选中。
        private func makeNameCell(for file: FileItem, tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("name")
            let cell: FileNameCell
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileNameCell {
                cell = reused
            } else {
                cell = FileNameCell()
                cell.identifier = identifier
            }
            cell.configure(
                name: file.name,
                depth: file.depth,
                isDirectory: file.isDirectory,
                isExpanded: file.isDirectory && parent.isExpanded(file.url),
                isExpanding: file.isDirectory && parent.isExpanding(file.url)
            ) { [weak self] in
                self?.parent.onToggleExpand(file)
            }
            applyIcon(for: file, to: cell, priority: .foreground)
            return cell
        }

        private func makeTextCell(
            text: String,
            identifier: NSUserInterfaceItemIdentifier,
            tableView: NSTableView,
            color: NSColor
        ) -> NSView {
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                textField.cell?.truncatesLastVisibleLine = true
                textField.font = .systemFont(ofSize: 13)
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.textField?.stringValue = text
            cell.textField?.textColor = color
            return cell
        }
    }
}

// MARK: - 名称 Cell（展开三角 + 图标 + 层级缩进）

/// 名称列单元格：三角、图标、文件名作为一个整体按层级右移，展开的子项与访达一致地整体缩进。
/// 三角由独立按钮承载：点击只展开/折叠，既不改动表格选中，也不用和双击手势抢响应。
final class FileNameCell: NSTableCellView {
    /// 每一层的缩进宽度
    private static let indentPerLevel: CGFloat = 14
    /// 三角占位宽度；同层级的文件与目录因此对齐到同一条竖线
    private static let disclosureSlot: CGFloat = 16
    /// 图标尺寸与图标槽宽度
    private static let iconSize: CGFloat = 16
    private static let iconSlot: CGFloat = 20

    private let disclosure = NSButton()
    private var onToggle: (() -> Void)?
    /// 三角左边缘约束，按层级调整
    private var disclosureLeading: NSLayoutConstraint?

    // 图标加载状态（随单元格复用一并重置）
    var currentPath: String = ""
    /// 当前图标对应的目录 generation；外部刷新后即使路径不变也要重新取图
    var loadedGeneration: UInt64 = 0
    /// 当前单元格是否已显示真实图标（false 表示仍在显示占位图）
    var hasLoadedIcon = false
    private(set) var token: UInt64 = 0
    var iconTask: Task<Void, Never>?

    func nextToken() -> UInt64 {
        token &+= 1
        return token
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleProportionallyDown
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        disclosure.target = self
        disclosure.action = #selector(handleToggle)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosure)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignCenter
        addSubview(icon)
        imageView = icon

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        addSubview(label)
        textField = label

        let leading = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        disclosureLeading = leading
        NSLayoutConstraint.activate([
            leading,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: Self.disclosureSlot),
            disclosure.heightAnchor.constraint(equalToConstant: Self.disclosureSlot),

            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Self.iconSlot - Self.iconSize),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        iconTask?.cancel()
        iconTask = nil
        currentPath = ""
        loadedGeneration = 0
        hasLoadedIcon = false
        super.prepareForReuse()
    }

    func configure(
        name: String,
        depth: Int,
        isDirectory: Bool,
        isExpanded: Bool,
        isExpanding: Bool,
        onToggle: @escaping () -> Void
    ) {
        textField?.stringValue = name
        self.onToggle = onToggle

        // 三角、图标、文字整体右移：缩进作用于整个内容块，而不是只推文字
        let indent = CGFloat(max(0, depth)) * Self.indentPerLevel
        disclosureLeading?.constant = 2 + indent

        guard isDirectory else {
            disclosure.isHidden = true
            disclosure.image = nil
            return
        }
        disclosure.isHidden = false
        disclosure.alphaValue = isExpanding ? 0.35 : 1
        disclosure.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: isExpanded ? "折叠" : "展开"
        )
    }

    /// 选中行背景被强调时三角转为白色，与系统列表的对比表现一致
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            disclosure.contentTintColor = backgroundStyle == .emphasized
                ? .alternateSelectedControlTextColor
                : .secondaryLabelColor
        }
    }

    @objc private func handleToggle() {
        onToggle?()
    }
}

// MARK: - 行视图

/// 行选中高亮跟随「窗格活动 + 键盘焦点在内容区」：两者都满足才用强调色。
/// 焦点不在内容区（例如刚点了搜索框）时降到弱化色，避免两块高亮同时出现。
/// 状态在绘制时实时查询，不用推送：漏掉一次变更通知就会把错误的高亮留在屏幕上。
final class PaneRowView: NSTableRowView {
    /// 查询当前是否应当用强调色画选中
    var emphasizedProvider: (() -> Bool)?

    override var isEmphasized: Bool {
        get {
            // 窗口失去焦点时，系统把选中整体降为弱化色
            guard window?.isKeyWindow ?? true else { return false }
            return emphasizedProvider?() ?? true
        }
        set { super.isEmphasized = newValue }
    }
}

// MARK: - 自定义 NSTableView

final class SwifileTableView: NSTableView {
    var onEmptyAreaClick: (() -> Void)?
    var onRowClickActivate: (() -> Void)?
    /// 空白区域使用的菜单（作用于当前目录）
    var emptyAreaMenu: NSMenu?
    /// 键盘焦点进入/离开表格
    var onFocusChange: ((Bool) -> Void)?


    /// 本次 / 上一次 mouseDown 落到的行（-1 表示空白区域）；双击校验用
    private(set) var lastClickRow = -1
    private(set) var previousClickRow = -1

    /// 双击打开某一行：cc >= 2 的点击由本视图自判后回调，不再走原生 doubleAction
    var onRowDoubleClick: ((Int) -> Void)?

    /// 双击校验：系统的 clickCount 判定不看两次点击是否落在同一行，快速点相邻两行
    /// （点第一行再点第二行）也会累计成双击、把第二行打开。这里要求「触发双击的
    /// 这次点击」与「上一次点击」落在同一行才算双击；校验后重置记录，防止三击再触发一次。
    func consumeDoubleClick(row: Int) -> Bool {
        defer {
            previousClickRow = -1
            lastClickRow = -1
        }
        return previousClickRow == row
    }

    /// 空白区域给目录级操作，行上仍用文件菜单。
    /// 空白区域右键先清掉高亮：菜单作用于目录，残留的选中行会让人误以为作用于那个文件。
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if row(at: point) < 0, let emptyAreaMenu {
            deselectAll(nil)
            return emptyAreaMenu
        }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: localPoint)
        // 点击行序：双击校验要知道「本次」与「上一次」分别落在哪一行
        previousClickRow = lastClickRow
        lastClickRow = clickedRow
        if clickedRow < 0 {
            onEmptyAreaClick?()
            deselectAll(nil)
        } else {
            // 先完成选中，再切换窗格焦点。焦点切换会带动一轮窗口重绘，
            // 排在选中之前会让点击那一行的反馈慢半拍。
            if !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            onRowClickActivate?()
            // 双击起手的点击（clickCount >= 2）不交给 NSTableView 的默认处理：
            // 1. 它会把「第一击的行 + 当前行」一起选中，快速点相邻两行会出现两行同时高亮；
            // 2. 它的内部跟踪循环（等 mouseUp）会占住事件派发，快速连点时后续点击延迟几百毫秒；
            // 3. 不交给它也就不会再有 doubleAction，双击打开改由这里判定并回调。
            // 双击成立条件：与上一次点击落在同一行（系统的 clickCount 不区分落在哪一行）。
            if event.clickCount >= 2,
               !NSEvent.modifierFlags.contains(.command),
               !NSEvent.modifierFlags.contains(.shift) {
                let sameRow = previousClickRow == clickedRow
                // 重置行序，防止三击再打开一次
                previousClickRow = -1
                lastClickRow = -1
                if sameRow {
                    onRowDoubleClick?(clickedRow)
                }
                return
            }
            super.mouseDown(with: event)
        }
    }

    /// 键盘焦点进入/离开表格：选中色要跟着焦点变强调或弱化
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func layout() {
        super.layout()
        syncColumnsForVisibleWidth()
    }

    /// 侧栏展开动画期间，右侧内容区只逐帧右移、宽度到动画结束才提交，
    /// 表格的 clip 宽度全程不变；因此监听滚动视图的原点/尺寸变化，
    /// 用「窗口右边缘 − 表格起点」算出真正可见宽度，提前收缩名称列。
    private var frameObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installFrameObserversIfNeeded()
    }

    private func installFrameObserversIfNeeded() {
        guard frameObservers.isEmpty, let scrollView = enclosingScrollView else { return }
        scrollView.postsFrameChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.syncColumnsForVisibleWidth()
        }
        for (name, object) in [
            (NSView.frameDidChangeNotification, scrollView),
            (NSView.frameDidChangeNotification, scrollView.contentView),
            (NSView.boundsDidChangeNotification, scrollView.contentView)
        ] {
            frameObservers.append(
                center.addObserver(forName: name, object: object, queue: .main, using: handler)
            )
        }
    }

    deinit {
        for observer in frameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 名称列吸收剩余宽度（访达同款）。
    /// 宽度基准取「真正可见的宽度」而不是 clip 宽度：侧栏展开动画期间
    /// clip 宽度不变、只有起点右移，用 clip 宽度算会让右侧列被推出窗口。
    /// 名称列按绝对值计算（不做差值累加），避免动画中间帧把列宽推歪；
    /// 名称压到 minWidth 后仍溢出时，右侧列依次压到 minWidth 兜底。
    func syncColumnsForVisibleWidth() {
        guard let scrollView = enclosingScrollView, let window else { return }
        let clipWidth = scrollView.contentView.bounds.width
        guard clipWidth > 1 else { return }
        let originX = scrollView.convert(.zero, to: window.contentView).x
        let windowWidth = window.contentView?.bounds.width ?? window.frame.width
        let visibleWidth = min(clipWidth, max(0, windowWidth - originX))
        guard visibleWidth > 1 else { return }

        guard let nameCol = tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) else { return }
        let fixedColumns = tableColumns.filter { $0 !== nameCol }

        let othersWidth = fixedColumns.reduce(0) { $0 + $1.width }
        let target = max(visibleWidth - othersWidth, nameCol.minWidth)
        if abs(nameCol.width - target) > 0.5 {
            nameCol.width = target
        }

        // 名称列压到 minWidth 还放不下时，右侧列依次压到 minWidth 兜底
        var overflow = tableColumns.reduce(0) { $0 + $1.width } - visibleWidth
        if overflow > 0 {
            for col in fixedColumns {
                let shrinkable = col.width - col.minWidth
                guard shrinkable > 0 else { continue }
                let shrink = min(shrinkable, overflow)
                col.width -= shrink
                overflow -= shrink
                if overflow <= 0 { break }
            }
        }
    }
}

// MARK: - 表头

final class FileTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        // 跟随系统外观取色，避免硬编码浅色在深色模式下错色
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
