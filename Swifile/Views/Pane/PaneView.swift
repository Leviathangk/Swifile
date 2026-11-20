import SwiftUI

// MARK: - 告警框状态

/// 拖入窗格时等待用户决定覆盖/跳过的请求。
private struct PendingDropConflict {
    let files: [URL]
    let target: URL
    let presentation: FileConflictPresentation
}

/// 窗格同一时间只展示一个窗口内告警框：冲突询问或结果提示。
private enum PaneDialog {
    case conflict(PendingDropConflict)
    case result(title: String, message: String)

    var message: String {
        switch self {
        case .conflict(let pending): return pending.presentation.message
        case .result(_, let message): return message
        }
    }
}

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
    @State private var activeDialog: PaneDialog?

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
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .alert(Text(dialogTitle), isPresented: dialogBinding, presenting: activeDialog) { dialog in
            switch dialog {
            case .conflict(let pending):
                Button(pending.presentation.skipButtonTitle) {
                    resolveConflict(pending, policy: .skip)
                }
                Button(pending.presentation.overwriteButtonTitle, role: .destructive) {
                    resolveConflict(pending, policy: .overwrite)
                }
                Button("取消", role: .cancel) {}
            case .result:
                Button("好", role: .cancel) {}
            }
        } message: { dialog in
            Text(dialog.message)
        }
        .onAppear { pane.ensureLoaded() }
    }

    private var dialogTitle: String {
        switch activeDialog {
        case .conflict(let pending): return pending.presentation.title
        case .result(let title, _): return title
        case nil: return ""
        }
    }

    private var dialogBinding: Binding<Bool> {
        Binding(
            get: { activeDialog != nil },
            set: { if !$0 { activeDialog = nil } }
        )
    }

    /// 接收 Finder/暂存区等外部拖入：复制到当前窗格目录。
    private func handleDrop(_ urls: [URL]) -> Bool {
        let target = pane.currentDirectory
        // 过滤掉本来就在当前目录里的项，避免把窗格内拖动误判成一次复制失败。
        let files = urls.filter {
            $0.isFileURL && !isAlreadyInDirectory($0, directory: target)
        }
        guard !files.isEmpty else { return false }

        Task { @MainActor in
            let conflicts = FileTransfer.conflicts(urls: files, to: target)
            guard !conflicts.isEmpty else {
                await performCopy(files: files, target: target, policy: .skip)
                return
            }
            activeDialog = .conflict(PendingDropConflict(
                files: files,
                target: target,
                presentation: FileConflictPresentation(conflicts: conflicts, totalCount: files.count)
            ))
        }
        return true
    }

    /// 用户在窗口内告警框里做出选择后继续复制。
    private func resolveConflict(_ pending: PendingDropConflict, policy: FileTransferConflictPolicy) {
        activeDialog = nil
        // 让告警框先退场，避免紧接着的结果提示被系统丢掉
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await performCopy(files: pending.files, target: pending.target, policy: policy)
        }
    }

    @MainActor
    private func performCopy(files: [URL], target: URL, policy: FileTransferConflictPolicy) async {
        let result = await FileTransfer.perform(
            urls: files,
            to: target,
            mode: .copy,
            conflictPolicy: policy
        )
        if !result.succeeded.isEmpty {
            pane.refresh()
        }
        guard !result.failures.isEmpty else { return }

        if files.count == 1, let failure = result.failures.first {
            activeDialog = .result(
                title: "复制失败",
                message: "「\(failure.name)」：\(failure.reason)"
            )
            return
        }

        let title = result.succeeded.isEmpty && result.skipped.isEmpty ? "操作失败" : "部分项目失败"
        var counts: [String] = []
        if !result.succeeded.isEmpty { counts.append("成功 \(result.succeeded.count) 项") }
        if !result.skipped.isEmpty { counts.append("跳过 \(result.skipped.count) 项") }
        counts.append("失败 \(result.failures.count) 项")

        let details = result.failures.prefix(6)
            .map { "\($0.name)：\($0.reason)" }
            .joined(separator: "\n")
        let more = result.failures.count > 6 ? "\n…" : ""
        activeDialog = .result(
            title: title,
            message: "\(counts.joined(separator: "，"))。\n\(details)\(more)"
        )
    }

    private func isAlreadyInDirectory(_ url: URL, directory: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
            == directory.standardizedFileURL.path(percentEncoded: false)
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
                    onRefresh: { pane.refresh() },
                    directory: pane.currentDirectory
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
