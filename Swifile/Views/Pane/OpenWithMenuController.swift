import AppKit

// MARK: - 打开方式子菜单（AppKit）

/// 「打开方式」子菜单的数据源。
/// NSMenu 在视图创建时就已存在，但子菜单内容只在真正展开时重建：
/// 这样既能跟随当前选中的文件，也把 LaunchServices 查询推迟到需要的时刻。
@MainActor
final class OpenWithMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    /// 每次展开时重新取一次目标：用户可能在两次右键之间换了选中项
    private let urlsProvider: () -> [URL]

    /// 菜单项携带的打开目标
    private struct Payload {
        let fileURLs: [URL]
        let applicationURL: URL
    }

    init(urlsProvider: @escaping () -> [URL]) {
        self.urlsProvider = urlsProvider
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = urlsProvider()
        // 多选时用第一个文件的类型查应用，执行时作用于全部选中项（与访达一致）
        guard let url = urls.first else { return }

        let applications = ApplicationCatalog.applications(for: url)
        for application in applications {
            let item = NSMenuItem(
                title: application.name,
                action: #selector(openWithApplication(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = application.menuIcon
            item.representedObject = Payload(fileURLs: urls, applicationURL: application.url)
            menu.addItem(item)
        }
        if !applications.isEmpty {
            menu.addItem(.separator())
        }

        let other = NSMenuItem(
            title: FileMenuCommand.openWithOther.title,
            action: #selector(openWithOtherApplication(_:)),
            keyEquivalent: ""
        )
        other.target = self
        other.representedObject = urls
        menu.addItem(other)
    }

    @objc private func openWithApplication(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload else { return }
        FileActions.open(payload.fileURLs, withApplicationAt: payload.applicationURL)
    }

    @objc private func openWithOtherApplication(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        FileActions.openWith(urls)
    }
}
