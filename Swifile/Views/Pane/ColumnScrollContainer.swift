import SwiftUI
import AppKit

// MARK: - 分栏原生滚动容器
/// 用 AppKit 的 NSScrollView 托管 SwiftUI 内容，替代 SwiftUI ScrollView。
///
/// 原因：SwiftUI 的 ScrollView 在 macOS 26 上不生成系统的 scroll pocket，
/// `NSScroller` 对象存在也画不出来，表现为横向滚动条「出现一下就消失」。
/// 原生 NSScrollView 配合占位式滚动条（legacy）才是访达列视图的做法：
/// 底部常驻一条滚动条、内容位置恒定，不会因为滚动条出现而整列跳动。
struct ColumnScrollContainer<Content: View>: NSViewRepresentable {
    /// 内容总宽度（列宽总和 + 预览列）
    let contentWidth: CGFloat
    /// 变化时滚动到最右端（新增列 / 预览列出现）
    let scrollToken: Int
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ColumnScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        // 常驻底栏：滚动条始终可见、可拖，且内容布局恒定不跳动
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .none

        let host = NSHostingView(rootView: content())
        host.frame = NSRect(x: 0, y: 0, width: max(contentWidth, 1), height: 1)
        scrollView.documentView = host
        scrollView.hostedView = host
        scrollView.contentWidth = contentWidth

        context.coordinator.host = host
        context.coordinator.lastToken = scrollToken
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let host = context.coordinator.host else { return }
        host.rootView = content()

        if let columnScroll = scrollView as? ColumnScrollView {
            columnScroll.contentWidth = contentWidth
            columnScroll.needsLayout = true
        }

        // 新增列/预览列出现：滚到最右，保持与访达一致的浏览位置
        guard context.coordinator.lastToken != scrollToken else { return }
        context.coordinator.lastToken = scrollToken
        DispatchQueue.main.async {
            let visibleWidth = scrollView.contentView.bounds.width
            let maxX = max(max(contentWidth, visibleWidth) - visibleWidth, 0)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: maxX, y: 0))
            } completionHandler: {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    final class Coordinator {
        weak var host: NSHostingView<Content>?
        var lastToken = 0
    }
}

// MARK: - 自维护内容尺寸的滚动视图
/// SwiftUI 首次布局时 clip 还是零尺寸，之后不一定再回调 updateNSView；
/// 尺寸交由滚动视图自己在 layout() 里维护，避免宿主高度被定死在 1pt。
final class ColumnScrollView: NSScrollView {
    var contentWidth: CGFloat = 0
    weak var hostedView: NSView?

    override func layout() {
        super.layout()
        guard let hostedView else { return }
        let clip = contentView.bounds.size
        // 宿主宽度必须等于内容实际宽度：比内容宽的话 SwiftUI 会把 HStack 居中，
        // 左侧出现空白；比可视区窄时由滚动视图负责左对齐即可。
        let width = max(contentWidth, 1)
        let height = max(clip.height, 1)
        if hostedView.frame.width != width || hostedView.frame.height != height || hostedView.frame.origin != .zero {
            hostedView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        // 占位式横向滚动条默认右侧会空出一段（系统给竖向滚动条预留的角），
        // 本容器没有竖向滚动条，让滚动条铺满整宽，避免左右不对称
        if let sc = horizontalScroller, sc.frame.width < bounds.width - 0.5 {
            sc.frame = NSRect(x: 0, y: sc.frame.origin.y, width: bounds.width, height: sc.frame.height)
        }
    }
}
