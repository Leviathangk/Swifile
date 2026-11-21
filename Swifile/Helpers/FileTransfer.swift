import Foundation

// MARK: - 批量文件搬运

/// 复制或移动。
enum FileTransferMode: Sendable {
    case copy
    case move

    var verb: String {
        switch self {
        case .copy: return "复制"
        case .move: return "移动"
        }
    }
}

/// 目标位置已有同名项时，用户的选择。
enum FileTransferConflictPolicy: Sendable {
    case skip
    case overwrite
}

/// 一个同名冲突：源文件与它将要落到的目标路径。
struct FileTransferConflict: Sendable, Identifiable {
    let source: URL
    let destination: URL

    var id: URL { source }
    var name: String { source.lastPathComponent }
}

/// 单个失败项：文件名 + 给用户看的原因。
struct FileTransferFailure: Sendable {
    let name: String
    let reason: String
}

/// 操作结果。succeeded/skipped 保存源 URL，便于调用方从暂存区精确移除；
/// placed 保存最终落地的路径（同目录粘贴时与源不同名），便于在窗格里选中新项。
struct FileTransferResult: Sendable {
    let succeeded: [URL]
    let skipped: [URL]
    let failures: [FileTransferFailure]
    let placed: [URL]
}

/// 制作副本的结果：新条目路径 + 失败项。
struct FileDuplicateResult: Sendable {
    let created: [URL]
    let failures: [FileTransferFailure]
}

/// 同名冲突提示的标题、正文和按钮标题，供窗口内的 SwiftUI 告警框复用。
struct FileConflictPresentation: Sendable {
    let title: String
    let message: String
    let skipButtonTitle: String
    let overwriteButtonTitle: String

    init(conflicts: [FileTransferConflict], totalCount: Int) {
        if conflicts.count == 1, let conflict = conflicts.first {
            title = "「\(conflict.name)」已存在"
            message = "目标位置已有同名项。要覆盖还是跳过？"
            skipButtonTitle = "跳过"
            overwriteButtonTitle = "覆盖"
        } else {
            let names = conflicts.prefix(5).map { "「\($0.name)」" }.joined(separator: "、")
            let more = conflicts.count > 5 ? " 等 \(conflicts.count) 项" : ""
            let rest = totalCount > conflicts.count ? "其余 \(totalCount - conflicts.count) 项会照常处理。" : ""
            title = "发现 \(conflicts.count) 个同名项"
            message = "\(names)\(more)在目标位置已存在。覆盖会替换原项目，跳过则保留原项目。\(rest)"
            skipButtonTitle = "全部跳过"
            overwriteButtonTitle = "全部覆盖"
        }
    }
}

/// 文件搬运的统一入口。
enum FileTransfer {
    /// 预检同名冲突。检查在调用线程同步完成，仅做 fileExists，足够快。
    static func conflicts(urls: [URL], to directory: URL) -> [FileTransferConflict] {
        let manager = FileManager.default
        let targetDirectory = directory.standardizedFileURL

        return urls.compactMap { source in
            let sourceURL = source.standardizedFileURL
            let destination = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            guard !samePath(sourceURL, destination),
                  manager.fileExists(atPath: destination.path(percentEncoded: false)) else {
                return nil
            }
            return FileTransferConflict(source: sourceURL, destination: destination)
        }
    }

    static func perform(
        urls: [URL],
        to directory: URL,
        mode: FileTransferMode,
        conflictPolicy: FileTransferConflictPolicy
    ) async -> FileTransferResult {
        await Task.detached(priority: .userInitiated) {
            run(urls: urls, directory: directory, mode: mode, conflictPolicy: conflictPolicy)
        }.value
    }

    /// 制作副本：每项复制到它自己所在的目录，命名与访达一致（「xxx 的副本」）。
    static func duplicate(urls: [URL]) async -> FileDuplicateResult {
        await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            var created: [URL] = []
            var failures: [FileTransferFailure] = []

            for url in urls {
                let source = url.standardizedFileURL
                let directory = source.deletingLastPathComponent()
                let destination = uniqueCopyDestination(for: source, in: directory)
                do {
                    try manager.copyItem(at: source, to: destination)
                    created.append(destination)
                } catch {
                    failures.append(FileTransferFailure(
                        name: source.lastPathComponent,
                        reason: error.localizedDescription
                    ))
                }
            }

            return FileDuplicateResult(created: created, failures: failures)
        }.value
    }

    private static func run(
        urls: [URL],
        directory: URL,
        mode: FileTransferMode,
        conflictPolicy: FileTransferConflictPolicy
    ) -> FileTransferResult {
        let manager = FileManager.default
        let targetDirectory = directory.standardizedFileURL
        var succeeded: [URL] = []
        var skipped: [URL] = []
        var failures: [FileTransferFailure] = []
        var placed: [URL] = []

        for source in urls {
            let sourceURL = source.standardizedFileURL
            var destination = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)

            if samePath(sourceURL, destination) {
                // 同一目录里粘贴等同于「复制一份」：与访达一样自动换个名字，
                // 而不是当作失败。移动没有这个语义，保持原样报错。
                guard mode == .copy else {
                    failures.append(FileTransferFailure(
                        name: sourceURL.lastPathComponent,
                        reason: "已经在目标目录中"
                    ))
                    continue
                }
                destination = uniqueCopyDestination(for: sourceURL, in: targetDirectory)
            } else if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                switch conflictPolicy {
                case .skip:
                    skipped.append(sourceURL)
                    continue
                case .overwrite:
                    do {
                        try manager.removeItem(at: destination)
                    } catch {
                        failures.append(FileTransferFailure(
                            name: sourceURL.lastPathComponent,
                            reason: "无法覆盖：\(error.localizedDescription)"
                        ))
                        continue
                    }
                }
            }

            do {
                switch mode {
                case .copy:
                    try manager.copyItem(at: sourceURL, to: destination)
                case .move:
                    try manager.moveItem(at: sourceURL, to: destination)
                }
                succeeded.append(sourceURL)
                placed.append(destination)
            } catch {
                failures.append(FileTransferFailure(
                    name: sourceURL.lastPathComponent,
                    reason: error.localizedDescription
                ))
            }
        }

        return FileTransferResult(
            succeeded: succeeded,
            skipped: skipped,
            failures: failures,
            placed: placed
        )
    }

    /// 生成「xxx 的副本」「xxx 的副本 2」这类不冲突的目标路径。
    /// 目录不拆扩展名，应用包（.app）按文件方式处理，与访达一致。
    private static func uniqueCopyDestination(for source: URL, in directory: URL) -> URL {
        let manager = FileManager.default
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values?.isDirectory ?? false
        let splitExtension = !isDirectory || source.pathExtension.lowercased() == "app"

        let rawName = source.lastPathComponent
        let ext = splitExtension ? source.pathExtension : ""
        let stem = ext.isEmpty ? rawName : (rawName as NSString).deletingPathExtension

        var index = 0
        while true {
            let suffix = index == 0 ? " 的副本" : " 的副本 \(index + 1)"
            let name = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name, isDirectory: isDirectory)
            if !manager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
            index += 1
        }
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path(percentEncoded: false) == rhs.standardizedFileURL.path(percentEncoded: false)
    }
}
