import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 默认应用设置

/// 「其他…」的哨兵值：Picker 选中它时弹应用面板，不改写实际配置
private enum OtherApplicationTag {
    static let value = "__swifile.other-application__"
}

/// 默认应用：终端 + 常用文件类型。
/// 后续继续扩展时只要加 Section 或 DefaultAppCategory 即可。
struct DefaultAppsPane: View {
    @Bindable var defaults: DefaultAppsSettings

    var body: some View {
        Form {
            Section {
                DefaultApplicationPickerRow(
                    title: "在终端中打开时使用",
                    options: defaults.terminalOptions,
                    currentBundleID: defaults.terminalBundleID,
                    includesFollowSystemOption: false,
                    onSelect: { defaults.terminalBundleID = $0 },
                    onChooseOther: chooseOtherTerminal
                )
            } header: {
                Text("终端")
            } footer: {
                Text("未选择时使用系统「终端」。所选应用被移除后，会自动回退到系统终端。")
            }

            Section {
                ForEach(DefaultAppCategory.allCases) { category in
                    DefaultApplicationPickerRow(
                        title: category.title,
                        options: defaults.applicationOptions(for: category),
                        currentBundleID: defaults.applicationBundleID(for: category),
                        includesFollowSystemOption: true,
                        onSelect: { defaults.setApplicationBundleID($0, for: category) },
                        onChooseOther: { chooseOtherApplication(for: category) }
                    )
                }
            } header: {
                Text("按文件类型")
            } footer: {
                Text("仅影响 Swifile 内的打开操作，不修改系统默认应用。")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 应用可能在 Swifile 运行期间被卸载
            defaults.validateTerminalSelection()
            defaults.validateTypeSelections()
        }
    }

    private func chooseOtherTerminal() {
        guard let url = pickApplication(title: "选择终端应用") else { return }
        defaults.selectTerminal(at: url)
    }

    private func chooseOtherApplication(for category: DefaultAppCategory) {
        guard let url = pickApplication(title: "选择\(category.title)应用") else { return }
        defaults.selectApplication(at: url, for: category)
    }

    /// 弹出应用选择面板；取消返回 nil
    private func pickApplication(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = title
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - 默认应用选择行

/// 一行默认应用选择器：跟随系统 + 系统推荐应用 + 其他…。
/// Picker 的显示值用本地状态镜像：面板取消时配置值没变、SwiftUI 不会重绘，
/// 只靠绑定读配置会让下拉停在「其他…」。
private struct DefaultApplicationPickerRow: View {
    let title: String
    let options: [OpenableApplication]
    let currentBundleID: String
    let includesFollowSystemOption: Bool
    let onSelect: (String) -> Void
    let onChooseOther: () -> Void

    @State private var selection = ""

    var body: some View {
        Picker(title, selection: $selection) {
            if includesFollowSystemOption {
                Text("跟随系统").tag("")
            }
            ForEach(options) { application in
                Text(application.name)
                    .tag(application.bundleID ?? application.url.path(percentEncoded: false))
            }
            Text("其他…").tag(OtherApplicationTag.value)
        }
        .onAppear {
            selection = currentBundleID
        }
        .onChange(of: selection) { _, newValue in
            guard newValue != currentBundleID else { return }
            if newValue == OtherApplicationTag.value {
                onChooseOther()
                // 无论面板确认还是取消，都把显示同步回真实配置
                selection = currentBundleID
            } else {
                onSelect(newValue)
            }
        }
        .onChange(of: currentBundleID) { _, newValue in
            selection = newValue
        }
    }
}
