import SwiftUI
import AppKit

// MARK: - 图标网格视图
/// 内容列表只依赖 files；选中高亮由独立 SelectionBadge 订阅 SelectionStore，
/// 避免选择变化时重建整个 LazyVGrid 的数据源身份。
@MainActor
struct FileIconGridView: View, Equatable {
    let files: [FileItem]
    let fileGeneration: UInt64
    let paneId: UUID
    let activity: PaneActivity
    let selectionStore: SelectionStore
    let onDoubleClick: (FileItem) -> Void
    let onActivate: () -> Void
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState
    let onRefresh: () -> Void
    let directory: URL

    /// 列数按最小宽度自适应，列宽再均匀拉伸铺满整行（访达同款），
    /// 不会在两侧留下成片的居中留白。
    /// 下限 96pt：双窗格常见宽度（~450pt）扣除留白后恰好稳定排出 4 列，与访达小图标档密度一致。
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    /// 选择由单元格独立观察；焦点状态不影响网格内容，因此不参与比较。
    nonisolated static func == (lhs: FileIconGridView, rhs: FileIconGridView) -> Bool {
        lhs.paneId == rhs.paneId && lhs.fileGeneration == rhs.fileGeneration
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(files) { file in
                    IconCell(
                        file: file,
                        activity: activity,
                        selectionStore: selectionStore,
                        onActivate: onActivate,
                        onDoubleClick: onDoubleClick,
                        quickAccess: quickAccess,
                        staging: staging,
                        preview: preview,
                        onRefresh: onRefresh
                    )
                }
            }
            .padding(12)
            // 把背后的 NSScrollView 调成浮动滚动条（说明见 OverlayScrollerFixer）
            .background(OverlayScrollerFixer())
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate()
            selectionStore.clear()
        }
        // 网格空白区域：给针对当前目录的操作（单元格上的菜单优先）
        .contextMenu {
            DirectoryContextMenu(directory: directory) { onRefresh() }
        }
    }
}

// MARK: - 浮动滚动条
/// 系统偏好「始终显示滚动条」时，SwiftUI ScrollView 背后的 NSScrollView 用旧式
/// 滚动条并占据约 17pt 布局宽度，宫格会因此少排一列。访达的图标视图用的是
/// 浮动滚动条（滚动时浮现、不占宽），这里沿视图层级找到 NSScrollView 调成同款。
/// 列表视图自己持有 NSScrollView，无需此探针。


// MARK: - 单个图标单元格
/// 只在本 cell 内读取 selectionStore，选择变化时仅重绘相关 cell，不重建父级文件列表。
/// 图标使用 SwiftUI 原生 Image：单元格数量多，逐格建立 AppKit 桥接的代价很高。
private struct IconCell: View {
    let file: FileItem
    let activity: PaneActivity
    let selectionStore: SelectionStore
    let onActivate: () -> Void
    let onDoubleClick: (FileItem) -> Void
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState
    let onRefresh: () -> Void

    /// 图标绘制尺寸（对齐访达的大图标档）
    private static let iconSize: CGFloat = 64

    @State private var icon: NSImage?

    /// 自判双击用：上次单击的时刻与落点
    @State private var lastClickTime: TimeInterval = 0
    @State private var lastClickPoint: CGPoint = .zero

    init(
        file: FileItem,
        activity: PaneActivity,
        selectionStore: SelectionStore,
        onActivate: @escaping () -> Void,
        onDoubleClick: @escaping (FileItem) -> Void,
        quickAccess: QuickAccessManager,
        staging: StagingState,
        preview: PreviewState,
        onRefresh: @escaping () -> Void
    ) {
        self.file = file
        self.activity = activity
        self.selectionStore = selectionStore
        self.onActivate = onActivate
        self.onDoubleClick = onDoubleClick
        self.quickAccess = quickAccess
        self.staging = staging
        self.preview = preview
        self.onRefresh = onRefresh
        // 命中缓存时直接作为初始值，省掉「先占位图、再重绘真实图标」的一轮
        _icon = State(
            initialValue: IconService.shared.cached(
                path: file.url.path(percentEncoded: false),
                size: Self.iconSize
            )
        )
    }

    var body: some View {
        let _ = { if PerfHarness.isEnabled { PerfCounters.iconCellEvals &+= 1 } }()
        VStack(spacing: 6) {
            iconView
                .frame(width: 64, height: 64)

            // 名称颜色下沉到子视图：选择变化只重算这一个 Text，
            // 格子的 body 不再依赖选择集合，点击不会连带重算整个可见网格。
            IconNameLabel(name: file.name, url: file.url, selectionStore: selectionStore)
        }
        .padding(6)
        // 宽度跟随网格列宽：固定宽度一旦超过列宽，选中背景会贴边被裁掉
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .background(
            // 轻微内缩，让选中框与格子边缘留出余量，圆角更接近访达的观感
            IconSelectionBackground(
                activity: activity,
                url: file.url,
                selectionStore: selectionStore
            )
            .padding(2)
        )
        .contentShape(Rectangle())
        // 按下即选中 + 松手时自判双击。
        // 双 click 不再用 onTapGesture(count: 2)：它与按下手势同时识别时，
        // 双击序列里的回调会被扣到系统判定结束才发出。
        // 自判的间隔用系统设置（NSEvent.doubleClickInterval）、落点要求接近，语义与系统一致。
        // 不能用 @State 标志去重按下：手势被拖拽会话或滚动取消时 onEnded 不保证回调，
        // 标志一旦卡在 true，这个格子就永久点不动了。
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // 零距离拖拽的第一次回调一定带 translation == .zero，拿它当按下瞬间的判据
                    guard value.translation == .zero else { return }
                    // 先落选中再切焦点：焦点切换会带一轮窗口重绘，排在选中之前反馈会慢半拍
                    if NSEvent.modifierFlags.contains(.command) {
                        selectionStore.toggle(file.url)
                    } else {
                        selectionStore.replace(with: file.url)
                    }
                    onActivate()
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
                        onDoubleClick(file)
                    } else {
                        lastClickTime = now
                        lastClickPoint = value.startLocation
                    }
                }
        )
        // 拖到侧边栏快速访问用；onDrag 走原生拖拽路径，不用 draggable（后者会拖慢点击）。
        // 必须放在手势外层：同一层时拖拽准备会与手势仲裁，快速连续点击的回调被扣住，
        // 等判定窗结束才一起释放（实测 300~540 ms 迟滞）。列视图正是「手势在内、
        // onDrag 在外」的结构，点击平均 4 ms。
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: file.url as NSURL) }
        .task(id: file.url) {
            await loadIconIfNeeded()
        }
        .contextMenu {
            FileContextMenu(
                files: [file],
                staging: staging,
                preview: preview,
                quickAccess: quickAccess,
                onOpenDirectory: onDoubleClick,
                onRefresh: onRefresh
            )
        }
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
                .aspectRatio(contentMode: .fit)
        }
    }

    /// 单元格出现时取图标：命中缓存立即显示，未命中交给 IconService 排队。
    /// 这里读取 activity 不构成 body 依赖，焦点切换不会让网格重新加载图标。
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

/// 图标选中背景：自己订阅选择集合与窗格活动状态。
/// 选择、焦点变化都只重算这一层，格子的 body 不依赖选择集合，
/// 避免每次点击都连带重算整个可见网格（几十个格子）。
private struct IconSelectionBackground: View {
    let activity: PaneActivity
    let url: URL
    let selectionStore: SelectionStore

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(fill)
    }

    private var fill: Color {
        guard selectionStore.contains(url) else { return .clear }
        // 焦点不在内容区（例如点了搜索框）时降到弱化色，避免两块高亮同时出现
        return activity.isActive && activity.hasKeyboardFocus
            ? Color.accentColor
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }
}

/// 名称文字：颜色跟随选中，单独订阅选择集合，把观察范围压到最小
private struct IconNameLabel: View {
    let name: String
    let url: URL
    let selectionStore: SelectionStore

    var body: some View {
        Text(name)
            .font(.system(size: 12))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .truncationMode(.middle)
            .foregroundStyle(selectionStore.contains(url) ? Color.white : Color.primary)
    }
}


// MARK: - 自动点击自检探针（SWIFILE_AUTOCLICK=1 时挂载；验证后删）
