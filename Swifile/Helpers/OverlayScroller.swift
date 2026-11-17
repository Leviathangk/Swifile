import SwiftUI
import AppKit

// MARK: - 浮动滚动条修复
/// SwiftUI 的 ScrollView 使用系统 NSScrollView；占位式滚动条会吃掉布局空间，
/// 把内容整体顶上去。宫格等纵向滚动场景改用浮动式（overlay）滚动条，
/// 浮在内容之上、不占空间。用法：挂在滚动内容（ScrollView 内部）上。
struct OverlayScrollerFixer: NSViewRepresentable {
    /// 要显式打开的滚动条轴向（SwiftUI 通常已配好，这里兜底）
    var axis: Axis = .vertical
    /// true：滚动条常驻显示；false：按系统偏好自动淡出
    var alwaysVisible = false

    func makeNSView(context: Context) -> OverlayScrollerFinder {
        let finder = OverlayScrollerFinder()
        finder.axis = axis
        finder.alwaysVisible = alwaysVisible
        return finder
    }

    func updateNSView(_ nsView: OverlayScrollerFinder, context: Context) {
        nsView.axis = axis
        nsView.alwaysVisible = alwaysVisible
        nsView.applyWhenMounted()
    }
}

final class OverlayScrollerFinder: NSView {
    var axis: Axis = .vertical
    var alwaysVisible = false

    private weak var target: NSScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var clipBoundsObserver: NSObjectProtocol?
    private var heartbeat: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWhenMounted()
        if window != nil {
            startHeartbeat()
        } else {
            heartbeat?.invalidate()
            heartbeat = nil
        }
    }

    deinit {
        heartbeat?.invalidate()
        observations.removeAll()
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.window != nil else { return }
            guard let scrollView = self.enclosingScrollView() else { return }
            self.attach(to: scrollView)
            self.enforce(on: scrollView)
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
    }

    func applyWhenMounted() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            guard let scrollView = self.enclosingScrollView() else { return }
            self.attach(to: scrollView)
            self.enforce(on: scrollView)
        }
    }

    private func enclosingScrollView() -> NSScrollView? {
        var current: NSView? = superview
        while let view = current {
            if let scrollView = view as? NSScrollView { return scrollView }
            current = view.superview
        }
        return nil
    }

    private func attach(to scrollView: NSScrollView) {
        guard target !== scrollView else { return }
        target = scrollView
        observations.removeAll()
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }

        observations = [
            scrollView.observe(\.autohidesScrollers, options: [.new]) { [weak self, weak scrollView] _, _ in
                guard let self, let scrollView else { return }
                self.enforce(on: scrollView)
            },
            scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self, weak scrollView] _, _ in
                guard let self, let scrollView else { return }
                self.enforce(on: scrollView)
            }
        ]

        scrollView.contentView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            guard let self, let scrollView else { return }
            self.enforce(on: scrollView)
        }
    }

    private func enforce(on scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        switch axis {
        case .vertical where !scrollView.hasVerticalScroller:
            scrollView.hasVerticalScroller = true
        case .horizontal where !scrollView.hasHorizontalScroller:
            scrollView.hasHorizontalScroller = true
        default:
            break
        }
        if alwaysVisible {
            if scrollView.autohidesScrollers {
                scrollView.autohidesScrollers = false
            }
            let scroller = axis == .horizontal
                ? scrollView.horizontalScroller
                : scrollView.verticalScroller
            if let scroller {
                if scroller.isHidden { scroller.isHidden = false }
                if scroller.alphaValue < 1 { scroller.alphaValue = 1 }
            }
        }
    }
}
