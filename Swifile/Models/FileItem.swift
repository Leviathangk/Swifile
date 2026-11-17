import Foundation

// MARK: - 排序键

/// 目录优先的排序键：目录排在同名的文件之前（访达的行为）。
struct DirectoryFirst<Value: Comparable>: Comparable {
    let isDirectory: Bool
    let value: Value

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.value < rhs.value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isDirectory == rhs.isDirectory && lhs.value == rhs.value
    }
}

/// 按访达的语言规则比较的字符串：file2 排在 file10 之前，忽略大小写与宽度差异。
struct LocalizedString: Comparable {
    let raw: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.raw.localizedStandardCompare(rhs.raw) == .orderedAscending
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.raw.localizedStandardCompare(rhs.raw) == .orderedSame
    }
}

// MARK: - 文件条目

/// 文件系统条目的不可变快照。
///
/// 展示字符串在目录读取阶段一次性生成，滚动列表时不再访问文件系统或执行格式化。
struct FileItem: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let nameLowercased: String
    let url: URL
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let creationDate: Date?
    let isHidden: Bool
    let formattedSize: String
    let formattedDate: String
    let fileType: String
    let fileExtension: String
    /// 展示层级：0 为顶层，展开的子项逐级递增，仅用于列表缩进
    let depth: Int

    // MARK: - 表头排序键

    /// 列表视图表头排序用。Table 的表头排序只认 KeyPathComparator，
    /// 没法接自定义比较器，所以把「目录优先」和访达的字符串比较规则编码进键里。

    var nameSortKey: DirectoryFirst<LocalizedString> {
        DirectoryFirst(isDirectory: isDirectory, value: LocalizedString(raw: name))
    }

    var dateSortKey: DirectoryFirst<Date> {
        DirectoryFirst(isDirectory: isDirectory, value: modificationDate ?? .distantPast)
    }

    var sizeSortKey: DirectoryFirst<Int64> {
        DirectoryFirst(isDirectory: isDirectory, value: size ?? 0)
    }

    var typeSortKey: DirectoryFirst<LocalizedString> {
        DirectoryFirst(isDirectory: isDirectory, value: LocalizedString(raw: fileType))
    }

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64?,
        modificationDate: Date?,
        creationDate: Date?,
        isHidden: Bool,
        formattedSize: String,
        formattedDate: String,
        fileType: String,
        depth: Int = 0
    ) {
        let normalizedURL = url.standardizedFileURL
        self.id = normalizedURL
        self.name = name
        self.nameLowercased = name.lowercased()
        self.url = normalizedURL
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.isHidden = isHidden
        self.formattedSize = formattedSize
        self.formattedDate = formattedDate
        self.fileType = fileType
        self.fileExtension = normalizedURL.pathExtension.lowercased()
        self.depth = depth
    }

    /// 生成指定层级的副本，用于展开后的子项缩进
    func atDepth(_ depth: Int) -> FileItem {
        guard depth != self.depth else { return self }
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            size: size,
            modificationDate: modificationDate,
            creationDate: creationDate,
            isHidden: isHidden,
            formattedSize: formattedSize,
            formattedDate: formattedDate,
            fileType: fileType,
            depth: depth
        )
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

// MARK: - 由 URL 构造条目

extension FileItem {
    /// 目录枚举与拖放落点共用的资源键集合
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey
    ]

    /// 批量场景复用的格式化器：目录枚举按次创建、逐条复用
    static func makeSizeFormatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    /// 日期格式化器工厂（dateFormat 与列表列显示口径一致）
    static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    /// 由已取到的资源值构造条目：目录枚举与拖放落点走同一套字段口径，
    /// 避免两处对 isDirectory / fileType / 尺寸的判断各写一遍。
    init(
        url: URL,
        values: URLResourceValues,
        sizeFormatter: ByteCountFormatter,
        dateFormatter: DateFormatter
    ) {
        let normalized = url.standardizedFileURL
        let name = normalized.lastPathComponent
        let isPackage = values.isPackage ?? false
        let isDirectory = (values.isDirectory ?? false) && !isPackage
        let rawSize = isDirectory ? nil : values.fileSize.map(Int64.init)
        let date = values.contentModificationDate
        let fileType: String
        if isDirectory {
            fileType = "文件夹"
        } else if isPackage && normalized.pathExtension.lowercased() == "app" {
            fileType = "应用程序"
        } else {
            fileType = FileIconHelper.localizedType(extension: normalized.pathExtension.lowercased())
        }

        self.init(
            url: normalized,
            name: name,
            isDirectory: isDirectory,
            size: rawSize,
            modificationDate: date,
            creationDate: values.creationDate,
            isHidden: values.isHidden ?? name.hasPrefix("."),
            formattedSize: rawSize.map(sizeFormatter.string(fromByteCount:)) ?? "--",
            formattedDate: date.map(dateFormatter.string(from:)) ?? "--",
            fileType: fileType
        )
    }

    /// 由任意 URL 构造条目（拖放落点这类只拿到 URL 的场景）。
    /// 属性读取失败时退化为「只有名字」的条目，不抛错、不阻断拖放。
    static func make(url: URL) -> FileItem {
        let values = (try? url.resourceValues(forKeys: resourceKeys)) ?? URLResourceValues()
        return FileItem(
            url: url,
            values: values,
            sizeFormatter: makeSizeFormatter(),
            dateFormatter: makeDateFormatter()
        )
    }
}

// MARK: - 排序与布局

enum SortField: String, CaseIterable, Sendable {
    case name
    case size
    case date
    case type
}

enum SortOrder: String, CaseIterable, Sendable {
    case ascending
    case descending

    var toggled: SortOrder {
        self == .ascending ? .descending : .ascending
    }
}

enum ViewMode: String, CaseIterable, Sendable {
    case icon
    case list
    case column
}

enum LayoutMode: String, CaseIterable, Sendable {
    case single
    case dual
    case quad
    case onePlusTwo

    var paneCount: Int {
        switch self {
        case .single: 1
        case .dual: 2
        case .quad: 4
        case .onePlusTwo: 3
        }
    }
}

// MARK: - 数据快照

/// 一次目录读取的完整结果，可在线程间安全传递。
struct DirectorySnapshot: Sendable {
    let directory: URL
    let items: [FileItem]
    let showHidden: Bool
    let loadedAt: Date

    static func empty(directory: URL, showHidden: Bool) -> DirectorySnapshot {
        DirectorySnapshot(
            directory: directory,
            items: [],
            showHidden: showHidden,
            loadedAt: .distantPast
        )
    }
}

/// 过滤和排序后的列表结果。
struct ContentSnapshot: Sendable {
    let files: [FileItem]
    let query: String
    let totalCount: Int
}
