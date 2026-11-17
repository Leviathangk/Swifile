import SwiftUI

// MARK: - 应用入口
@main
struct SwifileApp: App {
    @State private var appState = AppStateManager()
    /// 外观设置：启动时从 UserDefaults 读取并应用（影响所有窗口，含 AppKit 视图）
    @State private var appearance = AppearanceSettings()
    /// 设置窗口持有者：复用同一个窗口，重新打开时重新定位
    @State private var settingsPresenter = SettingsWindowPresenter()

    var body: some Scene {
        WindowGroup {
            ContentView(
                appState: appState,
                onOpenSettings: {
                    settingsPresenter.show(
                        appearance: appearance,
                        favorites: appState.favorites
                    )
                }
            )
            .background(WindowMinimumSize(size: NSSize(width: 1000, height: 600)))
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            // 独立设置窗口：⌘, 与工具栏齿轮共用同一个 presenter
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    settingsPresenter.show(
                        appearance: appearance,
                        favorites: appState.favorites
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // 地址栏快捷入口：⌘L 让活动窗格进入路径编辑
            CommandMenu("前往") {
                Button("输入路径…") {
                    appState.paneFocus.activePane.requestPathEditing()
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}
