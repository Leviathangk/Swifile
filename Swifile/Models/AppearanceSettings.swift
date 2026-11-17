import AppKit
import Observation

// MARK: - 外观设置

/// 应用主题：跟随系统 / 浅色 / 深色
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// 设置面板中的显示名称
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 对应的 AppKit 外观；nil 表示跟随系统
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 外观设置的唯一真值来源：读写 UserDefaults 并立即应用到所有窗口。
/// 直接改 `NSApplication.appearance` 而不是 SwiftUI 的 preferredColorScheme：
/// 本应用是 SwiftUI + AppKit 混合，列表表格的斑马纹与选中色由 AppKit 绘制，
/// preferredColorScheme 只影响 SwiftUI 视图，覆盖不到它们。
@MainActor
@Observable
final class AppearanceSettings {
    private static let storageKey = "appearanceMode"

    var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            apply()
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
        mode = stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        apply()
    }

    /// 应用到 NSApp：nil 恢复跟随系统，影响所有窗口（含 AppKit 视图）
    private func apply() {
        NSApplication.shared.appearance = mode.nsAppearance
    }
}
