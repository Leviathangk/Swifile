import SwiftUI
import AppKit

// MARK: - 主窗口尺寸限制
/// 在原生窗口承载视图上限制最小尺寸，避免根视图的最小宽度参与侧栏安全区动画。
struct WindowMinimumSize: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> WindowMinimumSizeView {
        let view = WindowMinimumSizeView()
        view.minimumSize = size
        return view
    }

    func updateNSView(_ nsView: WindowMinimumSizeView, context: Context) {
        nsView.minimumSize = size
    }
}

final class WindowMinimumSizeView: NSView {
    var minimumSize: NSSize = .zero {
        didSet {
            guard minimumSize != oldValue else { return }
            widthConstraint?.constant = minimumSize.width
            updateMinimumHeight()
        }
    }

    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        widthConstraint?.isActive = false
        heightConstraint?.isActive = false
        widthConstraint = nil
        heightConstraint = nil

        guard let window else { return }
        // SwiftUI 挂载内容时，外层窗口承载视图仍在装配，等本轮完成后再加约束。
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  let contentView = window.contentView else { return }
            self.installConstraints(on: contentView)
        }
    }

    private func installConstraints(on contentView: NSView) {
        let width = contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.width)
        let height = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumSize.height)
        widthConstraint = width
        heightConstraint = height
        NSLayoutConstraint.activate([width, height])
        updateMinimumHeight()
    }

    override func layout() {
        super.layout()
        updateMinimumHeight()
    }

    /// 保留工具栏下方的内容高度；标题栏占位由窗口实时提供，不写死系统尺寸。
    private func updateMinimumHeight() {
        guard let window, let contentView = window.contentView else { return }
        let titlebarHeight = max(0, contentView.bounds.height - window.contentLayoutRect.height)
        let height = minimumSize.height + titlebarHeight
        if heightConstraint?.constant != height {
            heightConstraint?.constant = height
        }
    }
}
