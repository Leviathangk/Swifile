import AppKit
import SwiftUI

// MARK: - 行内改名输入框

/// SwiftUI 视图（图标、分栏）里的行内改名输入框。
///
/// 用 AppKit 的 NSTextField 而不是 SwiftUI TextField：需要「进入即全选主名」
/// 和「回车提交 / Esc 取消」这两条精确行为，SwiftUI 的 TextField 拿不到选区控制。
/// 外观上刻意保留系统输入框的立体边框与焦点环：改名时用户得一眼看出
/// 可输入范围和光标在哪，纯文字上加一层描边在深色模式下几乎看不清。
struct InlineRenameField: NSViewRepresentable {
    let initialName: String
    let isDirectory: Bool
    var fontSize: CGFloat = 12
    /// 单行 List 行高较矮，输入框需要比宫格更紧凑
    var height: CGFloat = 20
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> InlineRenameEditor {
        InlineRenameEditor(
            name: initialName,
            selectRange: FileNameRange.baseName(of: initialName, isDirectory: isDirectory),
            fontSize: fontSize,
            height: height
        )
    }

    func updateNSView(_ nsView: InlineRenameEditor, context: Context) {
        nsView.onCommit = onCommit
        nsView.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: InlineRenameEditor, coordinator: ()) {
        nsView.stop()
    }
}

/// 承载改名输入框的容器：第一次进入窗口时抢焦点并选中主名。
@MainActor
final class InlineRenameEditor: NSView, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let field = NSTextField()
    private let selectRange: NSRange
    private var hasStarted = false
    /// 改名期间的窗口级点击监听：点别处即提交（访达的行为）
    private var clickMonitor: Any?
    /// 防止 controlTextDidEndEditing 与点击监听重复收尾
    private var isFinishing = false

    init(name: String, selectRange: NSRange, fontSize: CGFloat, height: CGFloat) {
        self.selectRange = selectRange
        super.init(frame: .zero)

        field.stringValue = name
        field.font = .systemFont(ofSize: fontSize)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        // 默认焦点环：深色模式下唯一能看清「输入范围」的提示
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.target = self
        field.action = #selector(commitAction)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: height)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: field.intrinsicContentSize.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !hasStarted, window != nil else { return }
        hasStarted = true
        installClickMonitor()
        // 焦点要等这一帧布局结束、视图真正挂在窗口上才抢得到
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
            guard let editor = self.field.currentEditor() as? NSTextView else { return }
            let length = (self.field.stringValue as NSString).length
            let clamped = NSRange(
                location: min(self.selectRange.location, length),
                length: min(self.selectRange.length, max(0, length - self.selectRange.location))
            )
            editor.selectedRange = clamped
        }
    }

    /// 视图被移除时收尾，避免监听泄漏
    func stop() {
        removeClickMonitor()
    }

    // MARK: - 点别处提交

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleClickOutside(event)
            }
            return event
        }
    }

    private func removeClickMonitor() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private func handleClickOutside(_ event: NSEvent) {
        guard !isFinishing, let window = field.window, event.window === window else { return }
        let point = field.convert(event.locationInWindow, from: nil)
        guard !field.bounds.contains(point) else { return }
        finish(commit: true)
    }

    // MARK: - 提交 / 取消

    @objc private func commitAction() {
        finish(commit: true)
    }

    private func finish(commit: Bool) {
        guard !isFinishing else { return }
        isFinishing = true
        let value = field.stringValue
        removeClickMonitor()
        field.delegate = nil
        field.target = nil
        field.action = nil
        // 先交还焦点，外部视图随后可能整个被移除
        if field.currentEditor() != nil {
            field.window?.makeFirstResponder(nil)
        }
        if commit {
            onCommit?(value)
        } else {
            onCancel?()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Esc 取消；回车、点别处、切窗口都按提交处理，与访达一致
        let movement = (notification.userInfo?["NSTextMovement"] as? Int)
            .flatMap(NSTextMovement.init(rawValue:))
        finish(commit: movement != .cancel)
    }
}
