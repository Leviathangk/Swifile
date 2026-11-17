import SwiftUI
import AppKit

// MARK: - 告警框状态

/// 等待用户决定覆盖/跳过的搬运请求。
private struct PendingTransferConflict {
    let items: [FileItem]
    let target: URL
    let mode: FileTransferMode
    let presentation: FileConflictPresentation
}

/// 暂存区同一时间只展示一个窗口内告警框：冲突询问或结果提示。
private enum StagingDialog {
    case conflict(PendingTransferConflict)
    case result(title: String, message: String)

    var message: String {
        switch self {
        case .conflict(let pending): return pending.presentation.message
        case .result(_, let message): return message
        }
    }
}

// MARK: - 暂存区视图

/// 侧边栏底部的跨目录中转站：
/// 拖入收集、拖出到 Finder/其他应用/窗格、多选批量复制或移动、双击打开和右键操作。
struct StagingAreaView: View {
    let staging: StagingState
    let paneFocus: PaneFocus
    let preview: PreviewState
    /// 搬运完成后刷新所有窗格（移动会同时改变源目录和目标目录）
    let onRefreshPanes: () -> Void

    /// List 的多选值。FileItem.id 是标准化 URL，可直接作为选择值。
    @State private var selectedIDs: Set<FileItem.ID> = []
    /// 拖入高亮：整个暂存区（标题行 + 列表区 + 操作栏）都是落点
    @State private var isDragTarget = false
    @State private var isTransferring = false
    @State private var statusText: String?
    @State private var activeDialog: StagingDialog?

    private let rowHeight: CGFloat = 26
    /// 最多显示 6 行，再多就滚动；整块高度由标题 + 列表 + 操作栏封顶。
    private let maxListHeight: CGFloat = 6 * 26 + 2

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            // 全部移出后保留操作栏几秒，让「已移动 N 项」的反馈可见，再自动收起
            if !staging.items.isEmpty || isTransferring || statusText != nil {
                actionBar
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(isDragTarget ? Color.accentColor : Color(nsColor: .separatorColor))
        )
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isDragTarget
                        ? Color.accentColor.opacity(0.08)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.3)
                )
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        // 整个暂存区都是落点：内容区或访达拖来的文件都进暂存；
        // 空态提示就写着「拖拽文件到此处」，落点必须覆盖整块显示范围
        .dropDestination(for: URL.self) { urls, _ in
            stage(urls)
            return true
        } isTargeted: { isDragTarget = $0 }
        .onChange(of: staging.items) { _, items in
            // 条目被移除（含移动成功自动移除）后，把选择集合同步收紧。
            selectedIDs.formIntersection(Set(items.map(\.id)))
        }
        // 冲突询问与结果提示统一走系统告警框，并挂在当前窗口内。
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
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 6) {
            Text("暂存区")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if !staging.items.isEmpty {
                Text("\(staging.items.count) 项")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Button("清除") {
                    selectedIDs.removeAll()
                    statusText = nil
                    staging.clear()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .separatorColor).opacity(0.3))
    }

    // MARK: - 列表与空状态

    @ViewBuilder
    private var content: some View {
        if staging.items.isEmpty {
            Text("拖拽文件到此处")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else {
            // 用 List 承载：滚动、键盘导航、多选（⌘/Shift）、分隔线交给系统。
            List(selection: $selectedIDs) {
                ForEach(staging.items) { item in
                    StagingRow(
                        item: item,
                        isSelected: selectedIDs.contains(item.id),
                        onRemove: { remove([item]) }
                    )
                    .tag(item.id)
                    .contextMenu {
                        stagingContextMenu(items: actionItems(for: item))
                    }
                    // 双击打开：同时保留 List 的单击选中语义
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded { open(item) }
                    )
                    // 拖出到 Finder、其他应用或另一个窗格的目录
                    .onDrag { NSItemProvider(object: item.url as NSURL) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, rowHeight)
            // 高度贴合内容，最多 6 行；超过后列表内部滚动，不再把侧边栏撑开
            .frame(height: min(CGFloat(staging.items.count) * rowHeight + 2, maxListHeight))
        }
    }

    // MARK: - 批量操作栏

    private var actionBar: some View {
        HStack(spacing: 6) {
            Button {
                transfer(selectedItems, mode: .copy)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty || isTransferring)
            .help(copyHelp)
            .accessibilityLabel("复制到活动窗格")

            Button {
                transfer(selectedItems, mode: .move)
            } label: {
                Label("移动", systemImage: "arrow.right.square")
            }
            .buttonStyle(.plain)
            .disabled(selectedIDs.isEmpty || isTransferring)
            .help(moveHelp)
            .accessibilityLabel("移动到活动窗格")

            Spacer()

            if isTransferring {
                ProgressView()
                    .controlSize(.mini)
            } else if let statusText {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if !selectedIDs.isEmpty {
                Text("已选 \(selectedIDs.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Button("全选") {
                    selectedIDs = Set(staging.items.map(\.id))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("全选暂存项")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .separatorColor).opacity(0.12))
    }

    // MARK: - 计算与动作

    private var selectedItems: [FileItem] {
        staging.items.filter { selectedIDs.contains($0.id) }
    }

    /// 右键作用域：右键点中的条目在多选内就作用于整批，否则只作用于该条。
    private func actionItems(for item: FileItem) -> [FileItem] {
        selectedIDs.contains(item.id) ? selectedItems : [item]
    }

    private var copyHelp: String {
        "复制到活动窗格：\(paneFocus.activePane.currentDirectory.path(percentEncoded: false))"
    }

    private var moveHelp: String {
        "移动到活动窗格：\(paneFocus.activePane.currentDirectory.path(percentEncoded: false))"
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

    @ViewBuilder
    private func stagingContextMenu(items: [FileItem]) -> some View {
        Button("打开") { open(items) }
        Button("快速预览") {
            if let first = items.first {
                preview.item = first
            }
        }
        Button("在 Finder 中显示") { FileActions.revealInFinder(items) }
        Button("拷贝路径") { FileActions.copyPaths(items) }

        Divider()

        Button("复制到活动窗格") { transfer(items, mode: .copy) }
        Button("移动到活动窗格") { transfer(items, mode: .move) }

        Divider()

        Button("移除", role: .destructive) { remove(items) }
    }

    /// 打开：目录交给活动窗格导航，文件交给系统默认应用。
    private func open(_ item: FileItem) {
        if item.isDirectory {
            paneFocus.activePane.navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// 批量打开：文件全部交给系统，目录只导航到第一个，避免连续跳目录。
    private func open(_ items: [FileItem]) {
        for item in items where !item.isDirectory {
            NSWorkspace.shared.open(item.url)
        }
        if let directory = items.first(where: \.isDirectory) {
            paneFocus.activePane.navigate(to: directory.url)
        }
    }

    private func remove(_ items: [FileItem]) {
        let ids = Set(items.map(\.id))
        guard !ids.isEmpty else { return }
        selectedIDs.subtract(ids)
        staging.removeItems(withIDs: ids)
    }

    /// 复制/移动到活动窗格；发现同名项时先询问覆盖还是跳过。
    private func transfer(_ items: [FileItem], mode: FileTransferMode) {
        guard !items.isEmpty, !isTransferring else { return }

        let target = paneFocus.activePane.currentDirectory
        let conflicts = FileTransfer.conflicts(urls: items.map(\.url), to: target)

        guard !conflicts.isEmpty else {
            performTransfer(items: items, target: target, mode: mode, policy: .skip)
            return
        }

        activeDialog = .conflict(PendingTransferConflict(
            items: items,
            target: target,
            mode: mode,
            presentation: FileConflictPresentation(conflicts: conflicts, totalCount: items.count)
        ))
    }

    /// 用户在窗口内告警框里做出选择后继续搬运。
    private func resolveConflict(
        _ pending: PendingTransferConflict,
        policy: FileTransferConflictPolicy
    ) {
        activeDialog = nil
        // 让告警框先退场，避免紧接着的结果提示被系统丢掉
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            performTransfer(
                items: pending.items,
                target: pending.target,
                mode: pending.mode,
                policy: policy
            )
        }
    }

    private func performTransfer(
        items: [FileItem],
        target: URL,
        mode: FileTransferMode,
        policy: FileTransferConflictPolicy
    ) {
        let urls = items.map(\.url)
        isTransferring = true
        statusText = nil

        Task { @MainActor in
            let result = await FileTransfer.perform(
                urls: urls,
                to: target,
                mode: mode,
                conflictPolicy: policy
            )
            isTransferring = false

            if mode == .move, !result.succeeded.isEmpty {
                let moved = Set(result.succeeded)
                selectedIDs.subtract(moved)
                staging.removeItems(withIDs: moved)
            }

            if !result.succeeded.isEmpty {
                onRefreshPanes()
            }
            report(result, mode: mode, itemCount: items.count)
        }
    }

    private func report(_ result: FileTransferResult, mode: FileTransferMode, itemCount: Int) {
        let isSingle = itemCount == 1

        var summary: [String] = []
        if !result.succeeded.isEmpty {
            summary.append(isSingle ? "已\(mode.verb)" : "已\(mode.verb) \(result.succeeded.count) 项")
        }
        if !result.skipped.isEmpty {
            summary.append(isSingle ? "已跳过" : "跳过 \(result.skipped.count) 项")
        }
        if !summary.isEmpty {
            setStatus(summary.joined(separator: "，"))
        }

        guard !result.failures.isEmpty else { return }

        if isSingle, let failure = result.failures.first {
            activeDialog = .result(
                title: "\(mode.verb)失败",
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

    private func setStatus(_ text: String) {
        statusText = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusText == text {
                statusText = nil
            }
        }
    }

    /// 暂存拖入的文件（重复路径由 StagingState 去重）
    private func stage(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL).map { FileItem.make(url: $0) }
        guard !files.isEmpty else { return }
        staging.stageItems(files)
    }
}

// MARK: - 暂存条目行

private struct StagingRow: View {
    let item: FileItem
    let isSelected: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            let category = FileIconHelper.category(for: item.url, isDirectory: item.isDirectory)
            Image(systemName: category.sfSymbolName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                .frame(width: 14, height: 14)

            Text(item.name)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("从暂存区移除")
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowSeparator(.visible)
        .contentShape(Rectangle())
        .help("双击打开；可拖到 Finder、其他应用或另一个窗格")
    }
}
