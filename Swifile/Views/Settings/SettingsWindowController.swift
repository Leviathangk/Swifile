import AppKit
import SwiftUI

// MARK: - 独立设置窗口

/// 设置窗口的持有者：复用同一个窗口，关闭后保留实例以便再次打开。
@MainActor
final class SettingsWindowPresenter {
    private var controller: SettingsWindowController?

    func show(
        appearance: AppearanceSettings,
        defaultApps: DefaultAppsSettings,
        favorites: SidebarFavoritesSettings
    ) {
        let controller = self.controller
            ?? SettingsWindowController(
                appearance: appearance,
                defaultApps: defaultApps,
                favorites: favorites
            )
        self.controller = controller
        controller.show()
    }
}

/// 独立设置窗口：在 orderFront 之前算好相对主窗口的位置。
/// 这样窗口第一帧就是最终位置，不会先出现在旧位置再瞬移。
@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        appearance: AppearanceSettings,
        defaultApps: DefaultAppsSettings,
        favorites: SidebarFavoritesSettings
    ) {
        let hosting = NSHostingController(
            rootView: SettingsView(
                appearance: appearance,
                defaultApps: defaultApps,
                favorites: favorites
            )
        )
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // 关掉位置记忆与状态恢复，位置完全由 show() 在显示前计算
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.setContentSize(NSSize(width: 640, height: 400))
        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        positionBeforeShow()
        showWindow(nil)
    }

    /// 关键顺序：先定位，再让窗口可见。这样第一帧就是最终位置。
    private func positionBeforeShow() {
        guard let window else { return }

        let main = NSApp.keyWindow.flatMap { $0 !== window ? $0 : nil }
            ?? NSApp.mainWindow.flatMap { $0 !== window ? $0 : nil }
            ?? NSApp.windows.first { $0.isVisible && $0 !== window && $0.frame.width > 300 }

        guard let main else {
            window.center()
            return
        }

        let size = window.frame.size
        var origin = CGPoint(
            x: main.frame.midX - size.width / 2,
            y: main.frame.midY - size.height / 2
        )
        if let screen = main.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        window.setFrameOrigin(origin)
    }
}
