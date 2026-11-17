import SwiftUI

// MARK: - 多窗格网格容器
/// 根据全局布局模式（1x1, 1x2, 2x2, 1+2），动态排布多个 PaneView
struct PaneGridContainer: View {
    let panes: [PaneState]
    let layoutMode: LayoutMode
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState
    let onActivate: (PaneState) -> Void

    var body: some View {
        Group {
            switch layoutMode {
            case .single:
                singleLayout
            case .dual:
                dualLayout
            case .quad:
                quadLayout
            case .onePlusTwo:
                onePlusTwoLayout
            }
        }
    }

    // MARK: - 单窗格

    private var singleLayout: some View {
        paneView(at: 0)
    }

    // MARK: - 双窗格（左右对半）

    private var dualLayout: some View {
        HStack(spacing: 0) {
            paneView(at: 0)
            Divider()
            paneView(at: 1)
        }
    }

    // MARK: - 2×2 网格

    private var quadLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                paneView(at: 0)
                Divider()
                paneView(at: 1)
            }
            Divider()
            HStack(spacing: 0) {
                paneView(at: 2)
                Divider()
                paneView(at: 3)
            }
        }
    }

    // MARK: - 1+2 布局（左大 + 右上下）

    private var onePlusTwoLayout: some View {
        HStack(spacing: 0) {
            paneView(at: 0)
            Divider()
            VStack(spacing: 0) {
                paneView(at: 1)
                Divider()
                paneView(at: 2)
            }
        }
    }

    // MARK: - 辅助方法

    @ViewBuilder
    private func paneView(at index: Int) -> some View {
        if index < panes.count {
            let pane = panes[index]
            PaneWrapper(
                pane: pane,
                quickAccess: quickAccess,
                staging: staging,
                preview: preview,
                showsActiveBorder: layoutMode != .single,
                onActivate: onActivate
            )
            // 保持每个窗格的 AppKit 视图树身份稳定，避免布局变化时复用到其它窗格。
            .id(pane.id)
        } else {
            // 安全后备：如果窗格不够，显示占位
            Color(nsColor: .controlBackgroundColor)
        }
    }
}

// MARK: - 窗格包装器
/// 每个包装器只订阅自己的 PaneActivity。
/// 焦点切换时，只有旧窗格和新窗格的包装器收到 Observation 通知。
private struct PaneWrapper: View {
    let pane: PaneState
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState
    /// 只有多窗格才需要指出「哪个是活动的」；单窗格画这圈线纯属噪音
    let showsActiveBorder: Bool
    let onActivate: (PaneState) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PaneHeaderHost(
                pane: pane,
                activity: pane.activity,
                onActivate: { onActivate(pane) }
            )
            .frame(height: 28)

            PaneContentHost(
                pane: pane,
                onActivate: { onActivate(pane) },
                quickAccess: quickAccess,
                staging: staging,
                preview: preview
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(PaneActiveBorder(activity: pane.activity, isEnabled: showsActiveBorder))
    }
}

/// 蓝色活动边框独立订阅焦点状态，焦点变更不会进入文件内容的视图树。
private struct PaneActiveBorder: View {
    let activity: PaneActivity
    let isEnabled: Bool

    var body: some View {
        let isActive = isEnabled && activity.isActive
        // strokeBorder 是内描边：2pt 完整落在窗格内。
        // 用居中描边的 stroke 时，贴着窗口边缘/相邻窗格的那条边有一半画在边界外被裁掉，
        // 最右侧的线看起来只有 1pt（变细）。
        RoundedRectangle(cornerRadius: 0)
            .strokeBorder(
                isActive ? Color.accentColor.opacity(0.5) : Color.clear,
                lineWidth: isActive ? 2 : 0
            )
            .allowsHitTesting(false)
    }
}

/// 将目录头部变化与内容区域的 SwiftUI 差分隔离。
/// `currentDirectory` 只影响头部；内容区域自行订阅目录内容状态。
private struct PaneContentHost: View {
    let pane: PaneState
    let onActivate: () -> Void
    let quickAccess: QuickAccessManager
    let staging: StagingState
    let preview: PreviewState

    var body: some View {
        PaneView(
            pane: pane,
            onActivate: onActivate,
            quickAccess: quickAccess,
            staging: staging,
            preview: preview
        )
    }
}
