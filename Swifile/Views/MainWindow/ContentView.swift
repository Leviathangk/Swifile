import AppKit
import SwiftUI

// MARK: - 主窗口布局
/// 原生窗口结构：NavigationSplitView 承载侧边栏（系统毛玻璃列、可拖宽）与详情区，
/// 工具栏交给系统 .toolbar —— macOS 升级带来的新窗口样式（玻璃质感等）自动跟随。
struct ContentView: View {
    let appState: AppStateManager
    let onOpenSettings: () -> Void

    var body: some View {
        NavigationSplitView {
            SidebarView(
                sidebar: appState.sidebar,
                paneFocus: appState.paneFocus,
                staging: appState.staging,
                quickAccess: appState.quickAccess,
                favorites: appState.favorites,
                preview: appState.preview,
                onRefreshPanes: { appState.panes.forEach { $0.refresh() } }
            )
            .navigationSplitViewColumnWidth(min: 110, ideal: 150, max: 280)
            // 系统开关在侧栏收起时会被挪进溢出菜单（Tahoe 行为），改用下方自绘开关
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                PaneGridContainer(
                    panes: appState.panes,
                    layoutMode: appState.layoutMode,
                    quickAccess: appState.quickAccess,
                    staging: appState.staging,
                    preview: appState.preview,
                    onActivate: { pane in
                        appState.paneFocus.activate(pane)
                        // 用户点了这个窗格：键盘焦点回到内容区，选中恢复强调色
                        pane.activity.setKeyboardFocus(true)
                        // 操作焦点转入内容区：侧边栏的快速访问高亮（代表「当前导航目标」）随之清除
                        appState.sidebar.selectedQuickAccessId = nil
                    }
                )
                // 文件表格由窗口可用区域约束，避免以完整目录高度参与 SwiftUI 的父级尺寸协商。
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                StatusBarView(
                    paneFocus: appState.paneFocus,
                    diskUsed: appState.diskUsed,
                    diskTotal: appState.diskTotal
                )
            }
            .toolbar {
                // 自绘侧栏开关：系统开关在侧栏收起时会被系统挪进溢出菜单，
                // 自绘按钮始终留在工具栏最左。动作与系统开关一致（responder chain），
                // 折叠状态仍由系统维护；macOS 26 上隐藏共享胶囊背景，避免和搜索框
                // 合并成同一个玻璃胶囊
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) {
                        sidebarToggleButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        sidebarToggleButton
                    }
                }

                // 搜索靠左（访达同款位置：侧栏开关右侧），不占用工具栏中央位
                ToolbarItem(placement: .navigation) {
                    ActivePaneSearchField(paneFocus: appState.paneFocus)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    ActivePaneViewModeButtons(paneFocus: appState.paneFocus)

                    LayoutSwitcher(
                        layoutMode: appState.layoutMode,
                        onSetLayout: { appState.setLayout($0) }
                    )

                    // 打开独立设置窗口（⌘, 同样可用）
                    Button {
                        onOpenSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .help("设置")
                }
            }
            .navigationTitle("")
        }
        .onAppear {
            appState.loadAllPanes()
            // 自动化性能基准（SWIFILE_PERF_BENCH=1）
            PerfHarness.runIfNeeded(appState: appState)
        }
        // 兜底同步：应用回到前台时，检查目录是否在监听之外发生过变化
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            appState.panes.forEach { $0.refreshIfDirectoryChangedExternally() }
        }
        // 空格呼出的应用内悬浮预览（与分栏预览列共用 FilePreviewPanel 组件）
        .overlay {
            if let file = appState.preview.item {
                FloatingPreviewOverlay(file: file) {
                    appState.preview.item = nil
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: appState.preview.item?.url)
        .background(PreviewHotkeys(paneFocus: appState.paneFocus, preview: appState.preview))
        // 文件区快捷键：⌘C / ⌘X / ⌘V / ⌘D / ⌘⌫ / ⌘A / ⌘O / Return
        .background(FileEditHotkeys(paneFocus: appState.paneFocus, preview: appState.preview))
    }
}

// MARK: - 工具栏条目

extension ContentView {
    /// 自绘侧栏开关按钮：图标恒定（Finder 同款），动作向 responder chain 发
    /// toggleSidebar，折叠状态由系统维护（窄窗口自动折叠也保持同步）
    @ViewBuilder
    private var sidebarToggleButton: some View {
        Button {
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
        }
        .help("显示/隐藏边栏")
    }
}

/// 原 GlobalToolbarView 的控件，迁入系统 toolbar；实现不变，只换了宿主。

/// 活动窗格搜索：放大镜、清除按钮、焦点环、深浅色都由系统绘制
private struct ActivePaneSearchField: View {
    let paneFocus: PaneFocus

    var body: some View {
        let pane = paneFocus.activePane
        NativeSearchField(
            text: Bindable(pane).searchQuery,
            onFocusChange: { focused in
                // 焦点进了搜索框，说明内容区不再响应：正在输入的窗格选中要降到弱化色，
                // 否则搜索框的焦点环和列表的强调色会同时亮着
                guard focused else { return }
                paneFocus.activePane.activity.setKeyboardFocus(false)
            }
        )
        .frame(width: 190)
    }
}

/// 活动窗格视图模式：官方分段控件，键盘方向键、按下动效、无障碍都由系统提供
private struct ActivePaneViewModeButtons: View {
    let paneFocus: PaneFocus

    var body: some View {
        let pane = paneFocus.activePane
        Picker("视图模式", selection: Bindable(pane).viewMode) {
            Image(systemName: "square.grid.2x2").tag(ViewMode.icon)
            Image(systemName: "list.bullet").tag(ViewMode.list)
            Image(systemName: "sidebar.right").tag(ViewMode.column)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(.accentColor)
        .frame(width: 116)
        .help("切换视图模式")
    }
}

/// 布局切换分段控件
private struct LayoutSwitcher: View {
    let layoutMode: LayoutMode
    let onSetLayout: (LayoutMode) -> Void

    var body: some View {
        let selection = Binding(
            get: { layoutMode },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    onSetLayout(newValue)
                }
            }
        )
        Picker("窗格布局", selection: selection) {
            Image(systemName: "square").tag(LayoutMode.single)
            Image(systemName: "rectangle.split.2x1").tag(LayoutMode.dual)
            Image(systemName: "square.grid.2x2.fill").tag(LayoutMode.quad)
            Image(systemName: "rectangle.split.1x2.fill").tag(LayoutMode.onePlusTwo)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(.accentColor)
        .frame(width: 152)
        .help("切换窗格布局")
    }
}
