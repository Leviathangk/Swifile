import SwiftUI
import AppKit

// MARK: - 侧边栏视图

/// 左侧导航栏：收藏 + 硬盘 + 快速访问（扁平引用列表，拖入即添加）+ 暂存区
struct SidebarView: View {
    let sidebar: SidebarState
    let paneFocus: PaneFocus
    let staging: StagingState
    let quickAccess: QuickAccessManager
    let favorites: SidebarFavoritesSettings
    let preview: PreviewState
    /// 文件搬运后刷新所有窗格（暂存区的复制/移动可能改变任意窗格看到的目录）
    let onRefreshPanes: () -> Void

    /// 清空快速访问前的确认框
    @State private var showsClearConfirmation = false

    /// 当前挂载的可浏览卷（内置硬盘 + 外接盘）；挂载/卸载时自动刷新
    @State private var volumes: [VolumeEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // 固定项改用 List + Section：选中高亮、键盘导航、缩进交给系统
            List(selection: Bindable(sidebar).selectedItem) {
                Section {
                    ForEach(favorites.selectedLocations) { item in
                        sidebarRow(icon: item.icon, color: item.iconColor, title: item.title)
                            .tag(item.url)
                    }
                } header: {
                    Text("收藏")
                }

                // 硬盘区：根卷 + 外接盘，插入/拔出自动增删
                Section {
                    ForEach(volumes) { volume in
                        sidebarRow(
                            icon: volume.isInternal ? "internaldrive" : "externaldrive",
                            color: Color.secondary,
                            title: volume.name
                        )
                        .tag(volume.url)
                    }
                } header: {
                    Text("硬盘")
                }

                quickAccessSection()
            }
            .listStyle(.sidebar)
            // 行高收紧到 20：默认侧边栏行高偏松，快速访问条目之间显得空
            .environment(\.defaultMinListRowHeight, 20)
            .scrollContentBackground(.hidden)
            .onChange(of: sidebar.selectedItem) { _, newValue in
                // 只有「选中了一个具体位置」才清快速访问高亮；
                // 点快速访问条目时程序会把 selectedItem 置 nil（互斥动作），
                // 那个变化不能再把刚点亮的高亮清掉，否则要连点两次才亮。
                if newValue != nil {
                    sidebar.selectedQuickAccessId = nil
                }
                if let url = newValue {
                    paneFocus.activePane.navigate(to: url)
                }
            }
            .task { reloadVolumes() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                reloadVolumes()
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
                reloadVolumes()
            }

            Spacer(minLength: 0)
            StagingAreaView(
                staging: staging,
                paneFocus: paneFocus,
                preview: preview,
                onRefreshPanes: onRefreshPanes
            )
        }
        // 清空动作统一走系统告警框：键盘处理、模态语义、按钮样式都交给系统
        .alert("清空快速访问？", isPresented: $showsClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { quickAccess.clear() }
        } message: {
            Text("将移除所有快速访问引用，不影响实际文件。")
        }
    }

    // MARK: - 侧边栏项（收藏）

    /// 固定项行：选中高亮与背景由 List 绘制，这里只放图标与标题（tag 由调用方按 URL 加）
    private func sidebarRow(icon: String, color: Color, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)

            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                // 显式保持清晰色：窗口失焦时 List 会把选中行的文字降级为灰，
                // 只有背景该变灰（与 Finder 的失焦表现一致）
                .foregroundStyle(.primary)
        }
    }

    /// 重新枚举当前挂载的可浏览卷：根卷（Macintosh HD）+ 外接盘。
    /// 排除 /System/Volumes 下的系统辅助挂载（Data 等影子卷）。
    private func reloadVolumes() {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsInternalKey]
        ) else {
            volumes = []
            return
        }
        var entries: [VolumeEntry] = []
        for url in urls {
            if url.path.hasPrefix("/System/Volumes/") { continue }
            let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsBrowsableKey, .volumeIsInternalKey]
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.volumeIsBrowsable == true else { continue }
            entries.append(VolumeEntry(
                url: url,
                name: values?.volumeName ?? url.lastPathComponent,
                isInternal: values?.volumeIsInternal ?? false
            ))
        }
        // 内置盘排前、其余按名称：顺序稳定，Macintosh HD 永远在最上（访达同款）
        entries.sort {
            $0.isInternal != $1.isInternal ? $0.isInternal : $0.name < $1.name
        }
        volumes = entries
    }

    // MARK: - 快速访问区域

    /// 单一扁平列表；标题行、条目行和空状态都可接收拖放。
    @ViewBuilder
    private func quickAccessSection() -> some View {
        Section {
            ForEach(quickAccess.items) { item in
                QuickAccessItemRow(
                    item: item,
                    isSelected: sidebar.selectedQuickAccessId == item.id,
                    onOpen: {
                        sidebar.selectedQuickAccessId = item.id
                        sidebar.selectedItem = nil
                        paneFocus.activePane.navigate(to: item.url)
                    },
                    onRemove: { quickAccess.remove(item) }
                )
                .dropDestination(for: URL.self) { urls, _ in
                    addToQuickAccess(urls)
                }
            }

            // 空状态提示行同时也是拖放落区
            if quickAccess.items.isEmpty {
                Text("拖入文件或文件夹以添加")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .dropDestination(for: URL.self) { urls, _ in
                        addToQuickAccess(urls)
                    }
            }
        } header: {
            HStack {
                Text("快速访问")
                Spacer()
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                addToQuickAccess(urls)
            }
            .contextMenu {
                if !quickAccess.items.isEmpty {
                    Button("清空快速访问", role: .destructive) {
                        showsClearConfirmation = true
                    }
                }
            }
        }
    }

    /// 文件列表与 Finder 拖来的 URL 都走这里；重复路径由数据层去重。
    private func addToQuickAccess(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        quickAccess.add(urls: urls)
        return true
    }
}

// MARK: - 快速访问条目行视图

private struct QuickAccessItemRow: View {
    let item: QuickAccessItem
    let isSelected: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: {
            guard item.exists else { return }
            onOpen()
        }) {
            HStack(spacing: 8) {
                // 文件图标（异步 IconService，不堵主线程）：尺寸与内容区列表一致
                QuickAccessFileIcon(url: item.url, size: 16)
                    .frame(width: 20, height: 20)
                    .opacity(item.exists ? 1 : 0.4)

                // 显示名称：字号与固定项行一致，左对齐
                Text(item.displayName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isSelected ? Color.white : (item.exists ? .primary : .secondary))
                    .lineLimit(1)
                    .strikethrough(!item.exists, color: .secondary)

                Spacer()

                // ⚠️ 文件不存在时的警告图标
                if !item.exists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("该路径不存在：\(item.url.path(percentEncoded: false))")
                }
            }
            .frame(height: 24)
            // 与「收藏 / 硬盘」的顶格行对齐，不再额外缩进
            .padding(.trailing, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 选中背景与内容区列表同款强调色实底（右列表的 selectedContentBackgroundColor）
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                .padding(.horizontal, 4)
        )
        .opacity(item.exists ? 1 : 0.7)
        .contextMenu {
            if item.exists {
                Button("打开") { onOpen() }
                Divider()
            }
            Button("从快速访问移除", role: .destructive) { onRemove() }
        }
    }
}

// MARK: - 快速访问图标

/// 快速访问条目的图标：命中缓存立即显示，未命中交给 IconService 排队。
/// 与其他视图走同一条图标路径，不再为单行图标包一层 AppKit 视图。
private struct QuickAccessFileIcon: View {
    let url: URL
    let size: CGFloat

    @State private var icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? IconService.placeholder(isDirectory: false, size: size))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .task(id: url) { await loadIfNeeded() }
    }

    private func loadIfNeeded() async {
        guard icon == nil else { return }
        let path = url.path(percentEncoded: false)
        if let cached = IconService.shared.cached(path: path, size: size) {
            icon = cached
            return
        }
        let loaded = await IconService.shared.icon(for: path, size: size, priority: .background)
        guard !Task.isCancelled else { return }
        icon = loaded
    }
}

// MARK: - 磁盘卷条目

/// 「硬盘」分区的条目：挂载点 URL + 显示名 + 内置/外接（决定图标）
struct VolumeEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    let isInternal: Bool

    var id: URL { url }
}
