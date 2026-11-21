import Foundation

// MARK: - 窗格内的文件操作

/// 右键菜单、快捷键、拖放共用的「动作 + 结果反馈」组合。
///
/// 这些操作都要先改文件系统、再刷新目录、再把结果告诉界面（选中新项 / 进入改名 / 报错）。
/// 集中在这里，三种视图与快捷键才会走同一条路径，不会各写一份、反馈各不相同。
@MainActor
enum PaneOperations {
    // MARK: - 新建文件夹

    /// 在当前目录新建文件夹，刷新后选中它并直接进入改名（访达同款体验）。
    static func createFolder(in pane: PaneState, directory: URL) {
        FileActions.createFolder(in: directory) { created in
            // 选中与改名请求都先挂上，再让目录刷新把它们一并在同一帧落地。
            // 视图侧会等目标行真正出现才执行，因此不需要在这里轮询等待——
            // 轮询会额外多出一拍，表现为「先选中整行、再跳到编辑」的两段式。
            pane.selectWhenAvailable([created])
            pane.requestRename(url: created, initialName: created.lastPathComponent)
            pane.refresh()
        }
    }

    // MARK: - 粘贴

    /// 粘贴剪贴板里的文件：带剪切标记时移动，否则复制。
    static func paste(into pane: PaneState, directory: URL) {
        guard let contents = FileClipboard.read() else { return }
        let mode: FileTransferMode = contents.isCut ? .move : .copy
        transfer(urls: contents.urls, to: directory, mode: mode, in: pane)
    }

    /// 外部拖入：一律复制；本来就在目标目录里的项直接忽略（与访达一致）。
    static func copyDropped(_ urls: [URL], into pane: PaneState) {
        let directory = pane.currentDirectory
        let targetPath = directory.standardizedFileURL.path(percentEncoded: false)
        let files = urls.filter { url in
            url.isFileURL
                && url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
                != targetPath
        }
        guard !files.isEmpty else { return }
        transfer(urls: files, to: directory, mode: .copy, in: pane)
    }

    // MARK: - 制作副本

    /// 制作副本：复制到各自所在目录，命名与访达一致，完成后选中新条目。
    static func duplicate(_ files: [FileItem], in pane: PaneState) {
        guard !files.isEmpty else { return }
        Task { @MainActor in
            let result = await FileTransfer.duplicate(urls: files.map(\.url))
            if !result.failures.isEmpty {
                let details = result.failures.prefix(6)
                    .map { "\($0.name)：\($0.reason)" }
                    .joined(separator: "\n")
                let more = result.failures.count > 6 ? "\n…" : ""
                pane.dialogs.showResult(
                    title: result.created.isEmpty ? "制作副本失败" : "部分项目无法制作副本",
                    message: "\(details)\(more)"
                )
            }
            if !result.created.isEmpty {
                pane.refresh()
                pane.selectWhenAvailable(result.created)
            }
        }
    }

    // MARK: - 重命名

    /// 提交一次改名。成功则刷新并选中新名字，失败则提示原因。
    static func rename(_ url: URL, to name: String, in pane: PaneState) {
        do {
            let renamed = try FileActions.rename(url, to: name)
            if renamed.path(percentEncoded: false) != url.standardizedFileURL.path(percentEncoded: false) {
                pane.selectWhenAvailable([renamed])
            }
            pane.refresh()
        } catch {
            pane.dialogs.showResult(title: "重命名失败", message: error.localizedDescription)
            // 行内输入框里可能还留着失败的名字，刷新一次让列表回到真实状态
            pane.refresh()
        }
    }

    // MARK: - 搬运实现

    private static func transfer(
        urls: [URL],
        to directory: URL,
        mode: FileTransferMode,
        in pane: PaneState
    ) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            let conflicts = FileTransfer.conflicts(urls: urls, to: directory)
            guard !conflicts.isEmpty else {
                await perform(urls: urls, to: directory, mode: mode, policy: .skip, in: pane)
                return
            }

            let presentation = FileConflictPresentation(conflicts: conflicts, totalCount: urls.count)
            pane.dialogs.showConflict(
                PaneDialogs.ConflictPrompt(presentation: presentation) { policy in
                    pane.dialogs.dismiss()
                    // 让告警框先退场，避免紧接着的结果提示被系统丢掉
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        await perform(urls: urls, to: directory, mode: mode, policy: policy, in: pane)
                    }
                }
            )
        }
    }

    private static func perform(
        urls: [URL],
        to directory: URL,
        mode: FileTransferMode,
        policy: FileTransferConflictPolicy,
        in pane: PaneState
    ) async {
        let result = await FileTransfer.perform(
            urls: urls,
            to: directory,
            mode: mode,
            conflictPolicy: policy
        )

        // 剪切粘贴只生效一次：否则再按一次 ⌘V 会把同一批文件再移动一遍。
        // 有失败项时保留剪贴板，方便用户处理后重试。
        if mode == .move, !result.succeeded.isEmpty, result.failures.isEmpty {
            FileClipboard.clear()
        }

        if !result.placed.isEmpty {
            pane.refresh()
            pane.selectWhenAvailable(result.placed)
        }
        pane.dialogs.showTransferFailures(result, verb: mode.verb, itemCount: urls.count)
    }
}
