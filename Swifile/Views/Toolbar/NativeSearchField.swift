import AppKit
import SwiftUI

// MARK: - 原生搜索框

/// 系统搜索框（NSSearchField）桥接。
/// 放大镜、清除按钮、焦点环、深浅色配色都由系统绘制，不再手工拼圆角与图标。
/// SwiftUI 侧没有等价控件：TextField 不带搜索语义，`.searchable` 要求视图处在
/// 导航容器里，而主窗口是自定义分栏结构，所以这里直接用 AppKit 的原生控件。
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "搜索"
    /// 焦点进入/离开搜索框：内容区的选中色要跟着在弱化与强调之间切换
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 12)
        field.onFocusChange = onFocusChange
        field.installClickMonitor()
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        (nsView as? SearchField)?.onFocusChange = onFocusChange
        // 只在值确实不同时才回写（切换窗格、外部清空），否则会打断正在输入的内容
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSSearchField, coordinator: Coordinator) {
        (nsView as? SearchField)?.removeClickMonitor()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        /// 输入即过滤：搜索框没有「开始搜索」这一步，字符一变就更新查询
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// 系统搜索框本体。
/// 覆写 viewDidMoveToWindow 只为让出初始焦点：AppKit 会把窗口里第一个可聚焦控件
/// 设为初始响应者，搜索框会因此抢走本该属于文件列表的键盘导航，用户按方向键时
/// 光标却在搜索框里移动。只让一次，之后用户主动点进来不受影响。
final class SearchField: NSSearchField {
    /// 焦点进入/离开
    var onFocusChange: ((Bool) -> Void)?
    private var didReleaseInitialFocus = false
    /// 常驻的窗口级点击监听：点击落在搜索框以外时交出焦点，去掉残留的焦点环
    private var clickMonitor: Any?
    deinit {
        removeClickMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didReleaseInitialFocus, window != nil else { return }
        didReleaseInitialFocus = true
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder === self.currentEditor() {
                window.makeFirstResponder(nil)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    /// 点搜索框以外的地方就交出焦点。
    /// 是否聚焦用 `firstResponder === currentEditor()` 判断（编辑态的真实响应者），
    /// 不依赖 become/resign 回调的时机；点击表格行时 NSTableView 会自己接管响应者，
    /// 点空白、侧边栏、工具栏等位置则没有接管者，不干预的话焦点环会一直留着。
    func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window,
                      event.window === window,
                      window.firstResponder === self.currentEditor() else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }
}
