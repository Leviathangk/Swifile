import Foundation
import Observation

// MARK: - 窗格内告警框

/// 窗格级的告警框状态：冲突询问和结果提示共用同一个展示位。
///
/// 挂在 PaneState 上而不是某个视图里：拖放、粘贴、制作副本、行内改名
/// 这些动作分布在三种视图和快捷键里，但用户看到的应当是这个窗格的同一个弹窗，
/// 不会出现「两个 alert 抢同一个窗格」，也不会「在图标视图里操作却弹在列表视图」。
@MainActor
@Observable
final class PaneDialogs {
    /// 等待用户决定覆盖还是跳过的搬运请求。
    struct ConflictPrompt {
        let presentation: FileConflictPresentation
        /// 用户做出选择后继续；调用方负责把执行结果再送回这里展示
        let resolve: (FileTransferConflictPolicy) -> Void
    }

    enum Content {
        case conflict(ConflictPrompt)
        case result(title: String, message: String)

        var title: String {
            switch self {
            case .conflict(let prompt): return prompt.presentation.title
            case .result(let title, _): return title
            }
        }

        var message: String {
            switch self {
            case .conflict(let prompt): return prompt.presentation.message
            case .result(_, let message): return message
            }
        }
    }

    var content: Content?

    var isPresented: Bool { content != nil }

    func showConflict(_ prompt: ConflictPrompt) {
        content = .conflict(prompt)
    }

    func showResult(title: String, message: String) {
        content = .result(title: title, message: message)
    }

    func dismiss() {
        content = nil
    }

    /// 展示一次搬运的结果：只有失败项需要打扰用户，
    /// 成功与跳过已经由目录刷新和行内变化给出反馈。
    func showTransferFailures(
        _ result: FileTransferResult,
        verb: String,
        itemCount: Int
    ) {
        guard !result.failures.isEmpty else { return }

        if itemCount == 1, let failure = result.failures.first {
            showResult(
                title: "\(verb)失败",
                message: "「\(failure.name)」：\(failure.reason)"
            )
            return
        }

        let title = result.succeeded.isEmpty && result.skipped.isEmpty ? "操作失败" : "部分项目失败"
        var counts: [String] = []
        if !result.succeeded.isEmpty { counts.append("成功 \(result.succeeded.count) 项") }
        if !result.skipped.isEmpty { counts.append("跳过 \(result.skipped.count) 项") }
        counts.append("失败 \(result.failures.count) 项")

        let details = result.failures.prefix(6)
            .map { "\($0.name)：\($0.reason)" }
            .joined(separator: "\n")
        let more = result.failures.count > 6 ? "\n…" : ""
        showResult(
            title: title,
            message: "\(counts.joined(separator: "，"))。\n\(details)\(more)"
        )
    }
}
