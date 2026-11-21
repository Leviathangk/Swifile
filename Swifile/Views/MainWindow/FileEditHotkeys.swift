import AppKit
import SwiftUI

// MARK: - 文件操作快捷键

/// 文件区的键盘快捷键：⌘C / ⌘X / ⌘V / ⌘D / ⌘⌫ / ⌘A / ⌘O / Return。
///
/// 不用 SwiftUI 的 CommandMenu 绑定这些键：`⌘C`、`⌘V` 一旦进主菜单，
/// 搜索框和地址栏里的文本编辑也会被抢走，复制粘贴就全废了。
/// 这里用本地事件监听，只在「第一响应者不是文本输入」时接管，
/// 文本框里仍然走系统默认行为。
struct FileEditHotkeys: NSViewRepresentable {
    let paneFocus: PaneFocus
    let preview: PreviewState

    func makeNSView(context: Context) -> FileEditHotkeyView {
        let view = FileEditHotkeyView()
        view.configure(paneFocus: paneFocus, preview: preview)
        return view
    }

    func updateNSView(_ nsView: FileEditHotkeyView, context: Context) {
        nsView.configure(paneFocus: paneFocus, preview: preview)
    }
}

@MainActor
final class FileEditHotkeyView: NSView {
    private var paneFocus: PaneFocus?
    private var preview: PreviewState?
    private var keyMonitor: Any?

    func configure(paneFocus: PaneFocus, preview: PreviewState) {
        self.paneFocus = paneFocus
        self.preview = preview
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitor()
        } else {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handleKeyDown(event)
            }
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let paneFocus,
              !event.isARepeat,
              event.window != nil,
              event.window?.attachedSheet == nil else { return event }

        // 文本编辑中的按键照常输入（搜索框、路径栏、行内改名框）
        if window?.firstResponder is NSTextView { return event }

        let pane = paneFocus.activePane
        let selected = selectedItems(in: pane)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = flags == .command

        if commandOnly {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                guard !selected.isEmpty else { return event }
                FileActions.copy(selected)
                return nil
            case "x":
                guard !selected.isEmpty else { return event }
                FileActions.cut(selected)
                return nil
            case "v":
                // 剪贴板里没有文件时不吞按键，让 ⌘V 保持系统语义
                guard FileClipboard.hasFiles else { return event }
                paste(into: pane, selected: selected)
                return nil
            case "d":
                guard !selected.isEmpty else { return event }
                PaneOperations.duplicate(selected, in: pane)
                return nil
            case "a":
                let all = pane.filteredFiles.map(\.url)
                guard !all.isEmpty else { return event }
                pane.selectionStore.set(Set(all))
                return nil
            case "o":
                guard let first = selected.first else { return event }
                FileActions.open([first]) { pane.navigate(to: $0.url) }
                return nil
            default:
                break
            }

            if event.keyCode == 51 || event.keyCode == 117 {
                guard !selected.isEmpty else { return event }
                FileActions.moveToTrash(selected) { pane.refresh() }
                return nil
            }
        }

        // Return：对单个选中项进入改名（访达同款），无选中时不拦截
        if event.keyCode == 36, flags.isEmpty, selected.count == 1, let file = selected.first {
            pane.requestRename(url: file.url, initialName: file.name)
            return nil
        }

        return event
    }

    /// 粘贴目标：选中单个文件夹就粘进去，否则粘到当前目录。
    private func paste(into pane: PaneState, selected: [FileItem]) {
        let target: URL
        if selected.count == 1, let folder = selected.first, folder.isDirectory {
            target = folder.url
        } else {
            target = pane.currentDirectory
        }
        PaneOperations.paste(into: pane, directory: target)
    }

    /// 按显示顺序取选中项；分栏视图的选择可能不在 filteredFiles 里，用 URL 现场构造。
    private func selectedItems(in pane: PaneState) -> [FileItem] {
        let urls = pane.selectionStore.urls
        guard !urls.isEmpty else { return [] }
        let displayed = pane.filteredFiles.filter { urls.contains($0.url) }
        let shown = Set(displayed.map(\.url))
        let missing = urls.subtracting(shown).sorted { $0.path < $1.path }
        return displayed + missing.map { FileItem.make(url: $0) }
    }
}
