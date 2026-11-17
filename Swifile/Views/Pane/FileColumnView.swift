import SwiftUI
import AppKit

// MARK: - 分栏浏览视图
/// Finder 风格的列视图：点击目录在右侧展开新列，对应视图模式 .column
struct FileColumnView: View {
    @Bindable var pane: PaneState
    let activity: PaneActivity
    let onActivate: () -> Void
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState

    @State private var columnDirs: [URL] = []
    /// 分栏视图右侧预览列的目标文件；选中目录时清空（预览列随之收起）
    @State private var columnPreviewFile: FileItem?
    /// 刷新令牌：窗格 refresh（右键新建/删除等）后各列重读自己的快照缓存
    @State private var refreshToken: UInt64 = 0
    /// 新增列/预览列时要求滚动到最右端
    @State private var scrollToken: Int = 0

    var body: some View {
        GeometryReader { geo in
            let previewWidth: CGFloat = columnPreviewFile == nil ? 0 : previewColumnWidth(in: geo.size.width)
            let totalWidth = CGFloat(columnDirs.count) * 221 + (columnPreviewFile == nil ? 0 : previewWidth + 1)

            ColumnScrollContainer(contentWidth: totalWidth, scrollToken: scrollToken) {
                HStack(alignment: .top, spacing: 0) {
                    // 以目录 URL 作为身份：列被替换时旧列的选中状态随之销毁，不会串到新列
                    ForEach(columnDirs, id: \.self) { dir in
                        ColumnPanel(
                            directory: dir,
                            showHidden: pane.showHidden,
                            sortField: pane.sortField,
                            sortOrder: pane.sortOrder,
                            query: pane.searchQuery,
                            activity: activity,
                            quickAccess: quickAccess,
                            staging: staging,
                            preview: preview,
                            refreshToken: refreshToken,
                            onRefresh: { pane.refresh() },
                            onSelectDirectory: { url in
                                // 锚点用目录本身而不是下标：body 被 equatable 跳过后
                                // 闭包会跨帧复用，下标会失效
                                columnPreviewFile = nil
                                handleSelect(url: url, from: dir)
                            },
                            onSelectFile: { file in
                                onActivate()
                                pane.selectionStore.replace(with: file.url)
                                columnPreviewFile = file
                            },
                            onDoubleClickFile: { file in
                                if file.isDirectory {
                                    pane.navigate(to: file.url)
                                } else {
                                    NSWorkspace.shared.open(file.url)
                                }
                            },
                            onActivate: onActivate
                        )
                        // 没变化的列整块跳过：否则点任意一列，所有列都要重建一次 List
                        .equatable()
                        .frame(width: 220)

                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                    }

                    // 选中文件时右侧出现预览列（访达分栏同款），与空格悬浮预览共用一套组件
                    if let file = columnPreviewFile {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)

                        FilePreviewPanel(file: file)
                            .frame(width: previewWidth)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // 新增列 / 预览列出现：通知容器滚到最右端
            .onChange(of: columnDirs) { _, _ in scrollToken &+= 1 }
            .onChange(of: columnPreviewFile) { _, file in
                if file != nil { scrollToken &+= 1 }
            }
        }
        .onAppear { resetColumns() }
        .onChange(of: pane.currentDirectory) { _, _ in resetColumns() }
        .onChange(of: pane.fileGeneration) { _, _ in
            // 列面板各自读快照缓存：新建/删除这类操作走的是窗格 refresh，
            // 把各列目录的缓存一并失效再发重载令牌，列内容才能看出变化
            Task {
                for dir in columnDirs {
                    await FileSystemHelper.invalidateCache(for: dir)
                }
                refreshToken &+= 1
            }
        }
    }

    /// 预览列宽 = 滚动区剩余宽度（访达同款）：预览不是普通列，不吃 220 的列宽，
    /// 也不该在右边留出「像还有一栏」的空白。列开太多时保底 240，超出横向滚动。
    private func previewColumnWidth(in containerWidth: CGFloat) -> CGFloat {
        let columnsWidth = CGFloat(columnDirs.count) * 221 // 每列 220 + 1 分隔线
        return max(240, containerWidth - columnsWidth - 1)
    }

    private func resetColumns() {
        columnDirs = [pane.currentDirectory]
        columnPreviewFile = nil
    }

    /// 选中某一列里的目录：截断它右侧的旧列，再把新目录作为新的一列接上
    private func handleSelect(url: URL, from columnDirectory: URL) {
        onActivate()
        guard let column = columnDirs.firstIndex(of: columnDirectory) else { return }
        var updated = Array(columnDirs.prefix(column + 1))
        if updated.last != url {
            updated.append(url)
        }
        columnDirs = updated
    }
}

// MARK: - 单列面板

/// 单列的加载标识：只要影响列表内容的设置变了就重新读取
private struct ColumnLoadKey: Equatable {
    let directory: URL
    let showHidden: Bool
    let sortField: SortField
    let sortOrder: SortOrder
    let query: String
    let refreshToken: UInt64
}

private struct ColumnPanel: View, Equatable {
    let directory: URL
    let showHidden: Bool
    let sortField: SortField
    let sortOrder: SortOrder
    let query: String
    let activity: PaneActivity
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState
    /// 变化即触发本列重读（窗格刷新后的联动信号）
    let refreshToken: UInt64
    let onRefresh: () -> Void
    let onSelectDirectory: (URL) -> Void
    let onSelectFile: (FileItem) -> Void
    let onDoubleClickFile: (FileItem) -> Void
    let onActivate: () -> Void

    /// 每列的选中是这一列自己的状态：用外部手搓的 Binding 时，List 的读取不算依赖，
    /// 跨列的选中更新会丢失，表现为点第 2、3 列没反应。
    @State private var selectedURL: URL?
    @State private var files: [FileItem] = []
    @State private var isLoading = false
    @State private var loadToken: UInt64 = 0

    /// 只有影响本列内容的设置变了才重算这一列。
    /// 点任意一列的目录都会让父视图重跑 body，没有这道守卫时每一列都要重建一次 List、
    /// 各做一遍按条目数的行身份比对，跨列点击就是这么卡起来的。
    /// 闭包、activity、各类 manager 都是稳定引用，不参与比较（与图标视图同一套做法）。
    /// refreshToken 必须参与比较：它是窗格刷新后的重载令牌，被 == 跳过的话
    /// 右键新建/删除后列内容永远不更新（NSLog 探针实测：令牌变了、task(id:) 不重启）。
    static func == (lhs: ColumnPanel, rhs: ColumnPanel) -> Bool {
        lhs.directory == rhs.directory &&
            lhs.showHidden == rhs.showHidden &&
            lhs.sortField == rhs.sortField &&
            lhs.sortOrder == rhs.sortOrder &&
            lhs.query == rhs.query &&
            lhs.refreshToken == rhs.refreshToken
    }

    var body: some View {
        // 试验：改用官方 List，斑马纹与圆角选中由系统提供
        List(selection: $selectedURL) {
            ForEach(files) { file in
                ColumnRow(
                    file: file,
                    activity: activity,
                    // 按下即选中：List 的选中由系统在 mouseUp 才提交，等它就慢半拍。
                    // 在行内手势按下那一刻直接选中并分发（目标状态幂等，mouseUp 时系统路径再来一次无害）。
                    onSelect: { select(file) },
                    onDoubleClick: { onDoubleClickFile(file) }
                )
                .tag(file.url)
                // 拖到侧边栏快速访问用。这里用 onDrag 而不是 draggable：
                // draggable 会插入拖拽判定，拖慢每次点击，onDrag 走的是原生拖拽路径。
                .onDrag { NSItemProvider(object: file.url as NSURL) }
                .contextMenu {
                    FileContextMenu(
                        files: [file],
                        staging: staging,
                        preview: preview,
                        quickAccess: quickAccess,
                        onOpenDirectory: onDoubleClickFile,
                        onRefresh: onRefresh
                    )
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .environment(\.defaultMinListRowHeight, 24)
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        // 列的空白区域：给针对本列目录的操作（行上的菜单优先）
        .contextMenu {
            DirectoryContextMenu(directory: directory) { onRefresh() }
        }
        .onChange(of: selectedURL) { _, newValue in
            handleSelectionChange(newValue)
        }
        .task(id: ColumnLoadKey(
            directory: directory,
            showHidden: showHidden,
            sortField: sortField,
            sortOrder: sortOrder,
            query: query,
            refreshToken: refreshToken
        )) { await loadFiles() }
    }

    /// 行上按下即选中：目录接上新的一列，文件记入窗格选中。
    /// 手势路径与 onChange 路径分发同一套动作，目标状态幂等，重复到达无害。
    private func select(_ file: FileItem) {
        selectedURL = file.url
        onActivate()
        if file.isDirectory {
            onSelectDirectory(file.url)
        } else {
            onSelectFile(file)
        }
    }

    /// List 的选中由系统驱动（键盘导航等），选中变化后再分发到展开新列或选中文件
    private func handleSelectionChange(_ url: URL?) {
        guard let url, let file = files.first(where: { $0.url == url }) else { return }
        onActivate()
        if file.isDirectory {
            onSelectDirectory(url)
        } else {
            onSelectFile(file)
        }
    }

    @MainActor
    private func loadFiles() async {
        loadToken &+= 1
        let token = loadToken
        isLoading = true
        defer {
            if token == loadToken { isLoading = false }
        }

        let field = sortField
        let order = sortOrder
        let text = query
        do {
            // 统一走 DirectoryCache / FileSystemHelper，后台完成全部 I/O 与预格式化
            let priority: DirectoryLoadPriority = activity.isActive ? .foreground : .background
            let snapshot = try await FileSystemHelper.loadSnapshot(
                at: directory,
                showHidden: showHidden,
                useCache: true,
                priority: priority
            )
            guard token == loadToken else { return }
            // 过滤与排序与其他视图走同一条管线，避免列视图的顺序和搜索结果自成一套
            let processed = await Task.detached(priority: .userInitiated) {
                FileContentPipeline.process(
                    items: snapshot.items,
                    query: text,
                    sortField: field,
                    sortOrder: order
                ).files
            }.value
            guard token == loadToken else { return }
            files = processed
        } catch {
            guard token == loadToken else { return }
            files = []
        }
    }
}

// MARK: - 列行

private struct ColumnRow: View {
    let file: FileItem
    let activity: PaneActivity
    /// 按下即选中（展开下一列或记入窗格选中）
    let onSelect: () -> Void
    /// 双击：进入目录或打开文件
    let onDoubleClick: () -> Void

    @State private var icon: NSImage?
    /// 自判双击用：上次单击的时刻与落点
    @State private var lastClickTime: TimeInterval = 0
    @State private var lastClickPoint: CGPoint = .zero

    private static let iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            iconView
                .frame(width: Self.iconSize, height: Self.iconSize)

            Text(file.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 按下即选中 + 松手时自判双击。
        // 双击不再用 TapGesture(count: 2)：它与按下手势同时识别时，双击序列里的回调
        // 会被扣到系统判定结束（约 350 ms）才发出，双击与快速连点明显迟滞。
        // 自判的间隔用系统设置（NSEvent.doubleClickInterval）、落点要求接近，语义与系统一致。
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // 零距离拖拽的第一次回调一定带 translation == .zero，拿它当按下瞬间的判据
                    guard value.translation == .zero else { return }
                    onSelect()
                }
                .onEnded { value in
                    // 移动超过微小抖动的算拖拽，不参与点击判定
                    guard abs(value.translation.width) < 4, abs(value.translation.height) < 4 else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    let distance = hypot(
                        value.startLocation.x - lastClickPoint.x,
                        value.startLocation.y - lastClickPoint.y
                    )
                    if now - lastClickTime < NSEvent.doubleClickInterval, distance < 4 {
                        lastClickTime = 0
                        onDoubleClick()
                    } else {
                        lastClickTime = now
                        lastClickPoint = value.startLocation
                    }
                }
        )
        .task(id: file.url) { await loadIconIfNeeded() }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(nsImage: IconService.placeholder(isDirectory: file.isDirectory, size: Self.iconSize))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }

    /// 行出现时取图标：命中缓存立即显示，未命中交给 IconService 排队。
    private func loadIconIfNeeded() async {
        guard icon == nil else { return }
        let path = file.url.path(percentEncoded: false)
        if let cached = IconService.shared.cached(path: path, size: Self.iconSize) {
            icon = cached
            return
        }
        let priority: IconService.RequestPriority = activity.isActive ? .foreground : .background
        let loaded = await IconService.shared.icon(for: path, size: Self.iconSize, priority: priority)
        guard !Task.isCancelled else { return }
        icon = loaded
    }
}
