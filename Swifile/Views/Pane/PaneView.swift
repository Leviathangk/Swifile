import SwiftUI

// MARK: - 单个窗格视图
/// 内容区不订阅窗格的活动状态，避免焦点切换时触发表格重建。
struct PaneView: View {
    let pane: PaneState
    let onActivate: () -> Void
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState

    /// 文件拖到窗格上时的高亮与提示
    @State private var isDropTarget = false

    var body: some View {
        PaneBodyView(
            pane: pane,
            onActivate: onActivate,
            quickAccess: quickAccess,
            staging: staging,
            preview: preview
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        // 窗格 = 容器：内容超出边界一律裁掉（等价 HTML overflow: hidden）。
        // 分栏视图横向滚动时，祖先列会移到窗格左缘之外，不裁剪的话会画到
        // 相邻窗格、甚至半透明侧栏底下透出来。
        .clipped()
        // 从暂存区或访达拖进来的文件默认复制到当前目录；需要移动时用暂存区的移动按钮。
        // 冲突询问、结果提示统一走窗格级告警框，和右键粘贴共用同一个展示位。
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            PaneOperations.copyDropped(files, into: pane)
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .alert(dialogTitle, isPresented: dialogBinding) {
            dialogButtons
        } message: {
            Text(pane.dialogs.content?.message ?? "")
        }
        .onAppear { pane.ensureLoaded() }
    }

    private var dialogTitle: String {
        pane.dialogs.content?.title ?? ""
    }

    private var dialogBinding: Binding<Bool> {
        Binding(
            get: { pane.dialogs.content != nil },
            set: { if !$0 { pane.dialogs.dismiss() } }
        )
    }

    @ViewBuilder
    private var dialogButtons: some View {
        if let content = pane.dialogs.content {
            switch content {
            case .conflict(let prompt):
                Button(prompt.presentation.skipButtonTitle) {
                    prompt.resolve(.skip)
                }
                Button(prompt.presentation.overwriteButtonTitle, role: .destructive) {
                    prompt.resolve(.overwrite)
                }
                Button("取消", role: .cancel) {
                    pane.dialogs.dismiss()
                }
            case .result:
                Button("好", role: .cancel) {
                    pane.dialogs.dismiss()
                }
            }
        }
    }
}

// MARK: - 窗格内容区
/// 只观察 pane 的内容/加载/视图模式字段，不读取活动状态或选择集合。
private struct PaneBodyView: View {
    let pane: PaneState
    let onActivate: () -> Void
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState

    var body: some View {
        // 内容区只依赖 pane 内容字段，不读取 activity
        let _ = {
            if PerfHarness.isEnabled {
                PerfCounters.recordPaneBodyEvaluation(for: pane.id)
            }
        }()

        if pane.isLoading && pane.filteredFiles.isEmpty && !pane.hasLoadedOnce {
            loadingView
        } else if let error = pane.errorMessage {
            errorView(error)
        } else if pane.filteredFiles.isEmpty && pane.viewMode != .column {
            emptyView
        } else {
            switch pane.viewMode {
            case .list:
                FileTableView(
                    files: pane.filteredFiles,
                    fileGeneration: pane.fileGeneration,
                    activity: pane.activity,
                    selectionStore: pane.selectionStore,
                    onDoubleClick: handleDoubleClick,
                    paneId: pane.id,
                    onActivate: onActivate,
                    quickAccess: quickAccess,
                    staging: staging,
                    preview: preview,
                    onRefresh: { pane.refresh() },
                    directory: pane.currentDirectory,
                    pane: pane,
                    renameRequest: pane.renameRequest,
                    sortField: pane.sortField,
                    sortOrder: pane.sortOrder,
                    onSortChange: handleSortChange,
                    isExpanded: { pane.isExpanded($0) },
                    isExpanding: { pane.isExpanding($0) },
                    onToggleExpand: { pane.toggleExpanded($0.url) }
                )
                .equatable()

            case .icon:
                FileIconGridView(
                    files: pane.filteredFiles,
                    fileGeneration: pane.fileGeneration,
                    paneId: pane.id,
                    activity: pane.activity,
                    selectionStore: pane.selectionStore,
                    onDoubleClick: handleDoubleClick,
                    onActivate: onActivate,
                    quickAccess: quickAccess,
                    staging: staging,
                    preview: preview,
                    directory: pane.currentDirectory,
                    pane: pane,
                    renameRequest: pane.renameRequest
                )
                .equatable()

            case .column:
                FileColumnView(
                    pane: pane,
                    activity: pane.activity,
                    onActivate: onActivate,
                    quickAccess: quickAccess,
                    staging: staging,
                    preview: preview
                )
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("加载中…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("无法读取目录")
                .font(.system(size: 12, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button("重试") { pane.refresh() }
                .controlSize(.small)
            if pane.isPermissionError {
                Button("打开系统设置") {
                    SystemPermissionChecker.openFilesAndFoldersSettings()
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text(pane.searchQuery.isEmpty ? "空文件夹" : "无搜索结果")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
        // 空目录也要能右键新建/粘贴，否则「空文件夹」反而是唯一没法往里放东西的地方
        .contextMenu {
            DirectoryContextMenu(pane: pane, directory: pane.currentDirectory)
        }
    }

    private func handleDoubleClick(_ file: FileItem) {
        if file.isDirectory {
            pane.navigate(to: file.url)
        } else {
            FileActions.openFile(at: file.url)
        }
    }

    private func handleSortChange(_ field: SortField) {
        if pane.sortField == field {
            pane.sortOrder = pane.sortOrder.toggled
        } else {
            pane.sortField = field
            pane.sortOrder = .ascending
        }
    }
}
