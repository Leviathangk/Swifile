import Observation

/// 单个窗格的活动状态，与文件列表内容独立观察。
@MainActor
@Observable
final class PaneActivity {
    private(set) var isActive: Bool

    /// 内容区是否持有键盘焦点。
    /// 失去键盘焦点时选中要画成灰色：否则点搜索框后「列表选中」与「搜索框焦点环」
    /// 会同时是高亮，看不出到底谁在响应。由表格的第一响应者变化和搜索框的聚焦
    /// 显式驱动，不靠响应者反推——列视图与图标视图是纯 SwiftUI，不接管第一响应者。
    private(set) var hasKeyboardFocus: Bool

    init(isActive: Bool = false, hasKeyboardFocus: Bool = true) {
        self.isActive = isActive
        self.hasKeyboardFocus = hasKeyboardFocus
    }

    func setActive(_ value: Bool) {
        guard value != isActive else { return }
        isActive = value
    }

    func setKeyboardFocus(_ value: Bool) {
        guard value != hasKeyboardFocus else { return }
        hasKeyboardFocus = value
    }
}
