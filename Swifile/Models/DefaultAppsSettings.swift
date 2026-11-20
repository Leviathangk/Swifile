import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - 默认应用设置

/// 默认应用设置的唯一真值来源。
/// 目前只有「默认终端」一项；后续新增按文件类型指定默认应用时继续加在这里。
@MainActor
@Observable
final class DefaultAppsSettings {
    static let shared = DefaultAppsSettings()

    private static let terminalKey = "defaultTerminalBundleID"
    private static let typeDefaultsKey = "defaultApplicationBundleIDs"

    /// 默认终端的 bundle ID，修改即落盘。
    /// 应用被卸载后不会立刻清空配置，由 resolve/validate 检查后回退系统终端。
    var terminalBundleID: String {
        didSet {
            guard terminalBundleID != oldValue else { return }
            UserDefaults.standard.set(terminalBundleID, forKey: Self.terminalKey)
        }
    }

    /// 按类别保存的默认应用（category.rawValue -> bundleID）；没有条目表示跟随系统
    private var typeDefaults: [String: String] {
        didSet {
            guard typeDefaults != oldValue else { return }
            UserDefaults.standard.set(typeDefaults, forKey: Self.typeDefaultsKey)
        }
    }

    init() {
        // 启动时只读取，不写回：终端装在外置卷、卷未挂载时应用会暂时找不到，
        // 直接回退会永久覆盖用户配置。真正使用终端或打开设置页时再回退并写回。
        terminalBundleID = UserDefaults.standard.string(forKey: Self.terminalKey)
            ?? ApplicationCatalog.systemTerminalBundleID
        typeDefaults = UserDefaults.standard.dictionary(forKey: Self.typeDefaultsKey)
            as? [String: String] ?? [:]
    }

    /// 实际执行「在终端中打开」时使用的应用。
    /// 配置项失效（应用被移除）时回退到系统终端，并把回退结果写回设置。
    func resolvedTerminalApplication() -> OpenableApplication {
        if let application = ApplicationCatalog.application(withBundleID: terminalBundleID) {
            return application
        }
        terminalBundleID = ApplicationCatalog.systemTerminalBundleID
        if let terminal = ApplicationCatalog.application(withBundleID: ApplicationCatalog.systemTerminalBundleID) {
            return terminal
        }
        // 系统终端也找不到属于系统异常，仍给出可执行的兜底地址
        return OpenableApplication(
            url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            bundleID: ApplicationCatalog.systemTerminalBundleID,
            name: "终端"
        )
    }

    /// 设置面板的候选项：已安装终端 + 当前选择（兼容不在已知清单里的自定义应用）
    var terminalOptions: [OpenableApplication] {
        var applications = ApplicationCatalog.installedTerminals()
        if let current = ApplicationCatalog.application(withBundleID: terminalBundleID),
           !applications.contains(where: { $0.id == current.id }) {
            applications.append(current)
        }
        return applications
    }

    /// 设置面板出现时再校验一次：应用可能在 Swifile 运行期间被卸载
    func validateTerminalSelection() {
        guard ApplicationCatalog.application(withBundleID: terminalBundleID) == nil else { return }
        terminalBundleID = ApplicationCatalog.systemTerminalBundleID
    }

    /// 用户从文件面板选择了自定义应用（面板只允许选 .app）
    func selectTerminal(at url: URL) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        terminalBundleID = bundleID
    }

    // MARK: 按文件类型

    /// 某类别当前配置的 bundle ID；空字符串表示跟随系统
    func applicationBundleID(for category: DefaultAppCategory) -> String {
        typeDefaults[category.rawValue] ?? ""
    }

    func setApplicationBundleID(_ bundleID: String, for category: DefaultAppCategory) {
        if bundleID.isEmpty {
            typeDefaults.removeValue(forKey: category.rawValue)
        } else {
            typeDefaults[category.rawValue] = bundleID
        }
    }

    /// 某类别当前配置且仍安装的应用；未配置或已失效返回 nil
    func application(for category: DefaultAppCategory) -> OpenableApplication? {
        guard let bundleID = typeDefaults[category.rawValue] else { return nil }
        return ApplicationCatalog.application(withBundleID: bundleID)
    }

    /// 设置页候选项：系统推荐应用 + 当前自定义应用（即使不在推荐列表里）
    func applicationOptions(for category: DefaultAppCategory) -> [OpenableApplication] {
        var applications = ApplicationCatalog.applications(for: category)
        if let current = application(for: category),
           !applications.contains(where: { $0.id == current.id }) {
            applications.append(current)
        }
        return applications
    }

    /// 打开文件时实际使用的应用：按文件类型匹配类别配置。
    /// 配置的应用已卸载时清掉这条配置，回退到系统默认应用。
    func resolvedApplication(for url: URL) -> OpenableApplication? {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else {
            return nil
        }
        for category in DefaultAppCategory.allCases where type.conforms(to: category.contentType) {
            guard let bundleID = typeDefaults[category.rawValue] else { continue }
            if let application = ApplicationCatalog.application(withBundleID: bundleID) {
                return application
            }
            typeDefaults.removeValue(forKey: category.rawValue)
        }
        return nil
    }

    /// 设置页出现时清理已卸载应用留下的配置
    func validateTypeSelections() {
        for category in DefaultAppCategory.allCases {
            guard let bundleID = typeDefaults[category.rawValue] else { continue }
            if ApplicationCatalog.application(withBundleID: bundleID) == nil {
                typeDefaults.removeValue(forKey: category.rawValue)
            }
        }
    }

    /// 为某个类别选择系统推荐列表之外的应用
    func selectApplication(at url: URL, for category: DefaultAppCategory) {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        setApplicationBundleID(bundleID, for: category)
    }
}
