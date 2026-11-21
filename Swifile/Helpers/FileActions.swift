import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 重命名错误

/// 重命名失败的原因，文案直接展示在窗格内的告警框里。
enum FileRenameError: LocalizedError {
    case emptyName
    case invalidName
    case nameExists(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "名称不能为空。"
        case .invalidName:
            return "名称不能是「.」「..」，也不能包含「/」或「:」。"
        case .nameExists(let name):
            return "当前文件夹里已经有「\(name)」。"
        }
    }
}

/// 重命名时默认选中的范围：去掉扩展名只选中主名，与访达一致。
/// 目录与隐藏文件（.gitignore 这类）选中全部。
enum FileNameRange {
    static func baseName(of name: String, isDirectory: Bool) -> NSRange {
        let full = name as NSString
        guard !isDirectory else { return NSRange(location: 0, length: full.length) }
        let dot = full.range(of: ".", options: .backwards)
        guard dot.location != NSNotFound, dot.location > 0 else {
            return NSRange(location: 0, length: full.length)
        }
        return NSRange(location: 0, length: dot.location)
    }
}

// MARK: - 文件操作动作

/// 文件操作的共享实现。
/// 列表视图的自定义菜单（NSMenu）与其它视图的 SwiftUI 右键菜单都调用这里，
/// 避免同一套动作在多处各写一份、行为逐渐分叉。
@MainActor
enum FileActions {
    /// 打开：目录进入下一层，文件交给「默认应用」设置或系统默认应用
    static func open(_ files: [FileItem], openDirectory: (FileItem) -> Void) {
        for file in files {
            if file.isDirectory {
                openDirectory(file)
            } else {
                openFile(at: file.url)
            }
        }
    }

    /// 打开单个文件：优先使用「默认应用」里该类型的设置，否则交给系统默认应用
    static func openFile(at url: URL) {
        if let application = DefaultAppsSettings.shared.resolvedApplication(for: url) {
            open([url], withApplicationAt: application.url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 用指定应用打开一组文件或文件夹（「打开方式」列表里的每一项）
    static func open(_ urls: [URL], withApplicationAt applicationURL: URL) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// 用其他应用打开：弹出应用选择面板（「打开方式」里的「其他…」）
    static func openWith(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = "选择应用"
        panel.prompt = "打开"
        if panel.runModal() == .OK, let appURL = panel.url {
            open(urls, withApplicationAt: appURL)
        }
    }

    static func revealInFinder(_ files: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(files.map(\.url))
    }

    /// 在终端中打开：目录直接进入，文件则进入它所在的目录。
    /// 走设置里的默认终端，不依赖 AppleScript，避免"自动化"权限被拒时整条动作静默失败。
    static func openInTerminal(_ file: FileItem) {
        let dir = file.isDirectory ? file.url : file.url.deletingLastPathComponent()
        openInTerminal(at: dir)
    }

    /// 在终端中打开指定目录（空白区域右键用）。
    /// 使用设置里的默认终端；应用被移除时由设置模型回退到系统终端。
    static func openInTerminal(at directory: URL) {
        TerminalLauncher.open(
            directory: directory,
            using: DefaultAppsSettings.shared.resolvedTerminalApplication()
        )
    }

    /// 在 Finder 中显示某个目录本身（空白区域右键用）
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 拷贝单个路径（空白区域右键用）
    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path(percentEncoded: false), forType: .string)
    }

    // MARK: - 新建文件夹

    /// 在当前目录下新建文件夹，重名时自动加序号。
    /// 创建完成后把新目录交给调用方：视图据此刷新、选中并直接进入行内重命名，
    /// 与访达「新建文件夹后光标落在名字上」的体验一致。
    static func createFolder(in directory: URL, onCreated: @escaping (URL) -> Void) {
        Task {
            let manager = FileManager.default
            var name = "未命名文件夹"
            var target = directory.appendingPathComponent(name, isDirectory: true)
            var index = 2
            while manager.fileExists(atPath: target.path(percentEncoded: false)) {
                name = "未命名文件夹 \(index)"
                target = directory.appendingPathComponent(name, isDirectory: true)
                index += 1
            }
            do {
                try manager.createDirectory(at: target, withIntermediateDirectories: false)
                await FileSystemHelper.invalidateCache(for: directory)
                await MainActor.run { onCreated(target) }
            } catch {
                NSLog("Failed to create folder at \(target.path(percentEncoded: false)): \(error)")
            }
        }
    }

    // MARK: - 重命名

    /// 重命名一个文件或文件夹，返回改名后的 URL。
    /// 与访达一致：不允许空名、路径分隔符；重名直接报错（不自动加序号）。
    /// 只改大小写时走「临时名 → 目标名」两步，避免在大小写不敏感的卷上被判定为重名。
    static func rename(_ url: URL, to rawName: String) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FileRenameError.emptyName }
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw FileRenameError.invalidName
        }

        let manager = FileManager.default
        let source = url.standardizedFileURL
        let directory = source.deletingLastPathComponent()
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let destination = directory
            .appendingPathComponent(name, isDirectory: isDirectory)
            .standardizedFileURL

        let sourcePath = source.path(percentEncoded: false)
        let destinationPath = destination.path(percentEncoded: false)
        guard sourcePath != destinationPath else { return source }

        if manager.fileExists(atPath: destinationPath) {
            let caseOnly = sourcePath.compare(destinationPath, options: .caseInsensitive) == .orderedSame
            guard caseOnly else { throw FileRenameError.nameExists(name) }

            let temp = directory.appendingPathComponent(".swifile-rename-\(UUID().uuidString)")
            try manager.moveItem(at: source, to: temp)
            do {
                try manager.moveItem(at: temp, to: destination)
            } catch {
                try? manager.moveItem(at: temp, to: source)
                throw error
            }
        } else {
            try manager.moveItem(at: source, to: destination)
        }

        return destination
    }

    // MARK: - 拷贝 / 剪切

    /// 拷贝到剪贴板（⌘C）。写入标准 file URL，可以直接粘到访达。
    static func copy(_ files: [FileItem]) {
        FileClipboard.write(files.map(\.url), asCut: false)
    }

    /// 剪切到剪贴板（⌘X）：带自定义标记，粘贴时走移动语义。
    static func cut(_ files: [FileItem]) {
        FileClipboard.write(files.map(\.url), asCut: true)
    }

    static func copyPaths(_ files: [FileItem]) {
        let paths = files.map { $0.url.path(percentEncoded: false) }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths, forType: .string)
    }

    static func addToStaging(_ files: [FileItem], staging: StagingState) {
        staging.stageItems(files)
    }

    /// 添加到快速访问：扁平引用列表，重复路径由数据层自动跳过
    static func addToQuickAccess(_ files: [FileItem], manager: QuickAccessManager) {
        manager.add(urls: files.map(\.url))
    }

    /// 移到废纸篓，完成后回调（通常用于刷新所在目录）
    static func moveToTrash(_ files: [FileItem], onComplete: @escaping () -> Void) {
        let urls = files.map(\.url)
        Task {
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    NSLog("Failed to trash \(url.path): \(error)")
                }
            }
            if let dir = urls.first?.deletingLastPathComponent() {
                await FileSystemHelper.invalidateCache(for: dir)
            }
            await MainActor.run { onComplete() }
        }
    }
}

// MARK: - 菜单命令

/// 右键菜单里的一条命令。
/// 标题与图标只在这里定义一次：SwiftUI 菜单（列视图、图标视图、列表视图外的场景）
/// 和列表视图的 AppKit 菜单都从这里渲染，避免两边各写一份、日后逐渐走样。
enum FileMenuCommand: String {
    case open
    case openWith
    case openWithOther
    case quickLook
    case revealInFinder
    case openInTerminal
    case copy
    case cut
    case paste
    case copyPath
    case duplicate
    case rename
    case addToQuickAccess
    case addToStaging
    case moveToTrash
    case newFolder
    case copyDirectoryPath
    case refresh

    var title: String {
        switch self {
        case .open: return "打开"
        case .openWith: return "打开方式"
        case .openWithOther: return "其他…"
        case .quickLook: return "快速预览"
        case .revealInFinder: return "在 Finder 中显示"
        case .openInTerminal: return "在终端中打开"
        case .copy: return "拷贝"
        case .cut: return "剪切"
        case .paste: return "粘贴"
        case .copyPath, .copyDirectoryPath: return "拷贝路径"
        case .duplicate: return "制作副本"
        case .rename: return "重命名"
        case .addToQuickAccess: return "添加到快速访问"
        case .addToStaging: return "添加到暂存区"
        case .moveToTrash: return "移到废纸篓"
        case .newFolder: return "新建文件夹"
        case .refresh: return "刷新"
        }
    }

    /// SF Symbol 名；「打开」「打开方式」在系统菜单里本来就没有图标
    var symbol: String? {
        switch self {
        case .open, .openWith, .openWithOther: return nil
        case .quickLook: return "eye"
        case .revealInFinder: return "magnifyingglass"
        case .openInTerminal: return "terminal"
        case .copy: return "doc.on.doc"
        case .cut: return "scissors"
        case .paste: return "doc.on.clipboard"
        case .copyPath, .copyDirectoryPath: return "link"
        case .duplicate: return "plus.square.on.square"
        case .rename: return "pencil"
        case .addToQuickAccess: return "pin"
        case .addToStaging: return "tray.and.arrow.down"
        case .moveToTrash: return "trash"
        case .newFolder: return "folder.badge.plus"
        case .refresh: return "arrow.clockwise"
        }
    }

    var isDestructive: Bool { self == .moveToTrash }

    /// AppKit 菜单项图标：与 SwiftUI 侧读同一个 SF Symbol 名。
    /// 统一到 16pt 见方，菜单行高才不会因图标尺寸不同而跳动。
    var menuImage: NSImage? {
        guard let symbol,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - 文件右键菜单

/// 文件右键菜单：列视图与图标视图共用，动作全部走 FileActions / PaneOperations。
/// 列表视图因为宿主是 NSTableView，仍用 AppKit 菜单，但同样按 FileMenuCommand 渲染。
struct FileContextMenu: View {
    let pane: PaneState
    let files: [FileItem]
    let staging: StagingState
    let preview: PreviewState
    let quickAccess: QuickAccessManager

    /// 右击单个文件夹时，粘贴的目标就是这个文件夹；否则不显示这一项
    private var pasteTarget: URL? {
        guard files.count == 1, let first = files.first, first.isDirectory else { return nil }
        return first.url
    }

    var body: some View {
        FileMenuButton(command: .open) {
            FileActions.open(files) { pane.navigate(to: $0.url) }
        }
        if !files.isEmpty {
            OpenWithMenu(urls: files.map(\.url))
        }
        FileMenuButton(command: .quickLook) {
            if let first = files.first {
                preview.item = first
            }
        }

        Divider()

        FileMenuButton(command: .revealInFinder) {
            FileActions.revealInFinder(files)
        }
        FileMenuButton(command: .openInTerminal) {
            guard let first = files.first else { return }
            FileActions.openInTerminal(first)
        }

        Divider()

        FileMenuButton(command: .copy) {
            FileActions.copy(files)
        }
        FileMenuButton(command: .cut) {
            FileActions.cut(files)
        }
        if let pasteTarget {
            FileMenuButton(command: .paste) {
                PaneOperations.paste(into: pane, directory: pasteTarget)
            }
            .disabled(!FileClipboard.hasFiles)
        }
        FileMenuButton(command: .copyPath) {
            FileActions.copyPaths(files)
        }

        Divider()

        if files.count == 1, let first = files.first {
            FileMenuButton(command: .rename) {
                pane.requestRename(url: first.url, initialName: first.name)
            }
        }
        FileMenuButton(command: .duplicate) {
            PaneOperations.duplicate(files, in: pane)
        }

        Divider()

        FileMenuButton(command: .addToQuickAccess) {
            FileActions.addToQuickAccess(files, manager: quickAccess)
        }
        FileMenuButton(command: .addToStaging) {
            FileActions.addToStaging(files, staging: staging)
        }

        Divider()

        FileMenuButton(command: .moveToTrash) {
            FileActions.moveToTrash(files) { pane.refresh() }
        }
    }
}

// MARK: - 目录右键菜单

/// 空白区域右键菜单：作用于当前显示的目录本身。
/// 列表视图用等价的 AppKit 菜单，动作同样走 FileActions / PaneOperations。
struct DirectoryContextMenu: View {
    let pane: PaneState
    let directory: URL

    var body: some View {
        FileMenuButton(command: .newFolder) {
            PaneOperations.createFolder(in: pane, directory: directory)
        }
        FileMenuButton(command: .paste) {
            PaneOperations.paste(into: pane, directory: directory)
        }
        .disabled(!FileClipboard.hasFiles)

        Divider()

        FileMenuButton(command: .revealInFinder) {
            FileActions.reveal(directory)
        }
        FileMenuButton(command: .openInTerminal) {
            FileActions.openInTerminal(at: directory)
        }
        OpenWithMenu(urls: [directory])

        Divider()

        FileMenuButton(command: .copyDirectoryPath) {
            FileActions.copyPath(directory)
        }

        Divider()

        FileMenuButton(command: .refresh) {
            pane.refresh()
        }
    }
}

// MARK: - 菜单项渲染

/// 菜单项标题：图标与文字都取自 FileMenuCommand
struct FileMenuLabel: View {
    let command: FileMenuCommand

    var body: some View {
        if let symbol = command.symbol {
            Label(command.title, systemImage: symbol)
        } else {
            Text(command.title)
        }
    }
}

/// 一般菜单项：动作由调用方给出
struct FileMenuButton: View {
    let command: FileMenuCommand
    let action: () -> Void

    var body: some View {
        Button(role: command.isDestructive ? .destructive : nil, action: action) {
            FileMenuLabel(command: command)
        }
    }
}

/// 「打开方式」子菜单：列视图、图标视图共用。
/// 应用列表按第一个选中项的类型查询（多选时与访达一致），执行时作用于全部选中项。
/// 查询发生在子菜单构建时，首次约 20ms，之后按类型走 30 秒缓存。
struct OpenWithMenu: View {
    let urls: [URL]

    var body: some View {
        Menu {
            let applications = urls.first.map { ApplicationCatalog.applications(for: $0) } ?? []
            ForEach(applications) { application in
                Button {
                    FileActions.open(urls, withApplicationAt: application.url)
                } label: {
                    Label {
                        Text(application.name)
                    } icon: {
                        Image(nsImage: application.menuIcon)
                    }
                }
            }
            if !applications.isEmpty {
                Divider()
            }
            Button(FileMenuCommand.openWithOther.title) {
                FileActions.openWith(urls)
            }
        } label: {
            FileMenuLabel(command: .openWith)
        }
    }
}
