import AppKit
import SwiftUI

// MARK: - 预览快捷键
/// 空格 = 访达习惯：呼出/关闭应用内悬浮预览（FloatingPreviewOverlay，一套组件）；
/// Esc = 关闭。搜索框等文本编辑中的空格照常输入（field editor 是 NSTextView，不拦截）。
/// 注意：预览面板是应用内组件，不是 QLPreviewPanel 独立窗口。
struct PreviewHotkeys: NSViewRepresentable {
    let paneFocus: PaneFocus
    let preview: PreviewState

    func makeNSView(context: Context) -> PreviewHotkeyView {
        let view = PreviewHotkeyView()
        view.configure(paneFocus: paneFocus, preview: preview)
        return view
    }

    func updateNSView(_ nsView: PreviewHotkeyView, context: Context) {
        nsView.configure(paneFocus: paneFocus, preview: preview)
    }
}

@MainActor
final class PreviewHotkeyView: NSView {
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

    /// 返回 nil 表示吃掉事件
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let paneFocus, let preview,
              !event.isARepeat,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.shift)
        else { return event }

        // 文本编辑中的按键照常输入
        if window?.firstResponder is NSTextView { return event }

        // 空格：开关悬浮预览
        if event.keyCode == 49 {
            // 已打开 → 关闭
            if preview.item != nil {
                preview.item = nil
                return nil
            }
            // 按显示顺序取第一个选中的文件；分栏视图的选择不在 filteredFiles 里时
            // 用 URL 现场构造（详情字段由 FileItem.make 统一读取）
            let pane = paneFocus.activePane
            let file = pane.filteredFiles.first(where: { pane.selectionStore.urls.contains($0.url) })
                ?? pane.selectionStore.urls.first.map { FileItem.make(url: $0) }
            guard let file else { return event }
            preview.item = file
            return nil
        }

        // Esc：关闭已打开的预览
        if event.keyCode == 53, preview.item != nil {
            preview.item = nil
            return nil
        }

        return event
    }
}
