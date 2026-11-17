import CoreServices
import Darwin
import Foundation

/// 基于 FSEvents 的目录监听。
///
/// 对齐访达的行为：
/// - 文件级事件能发现当前目录及展开子目录里的新增、删除、改名和内容变化；
/// - WatchRoot 能发现当前目录被改名、删除或同路径替换；
/// - FSEvents 自带合并延迟，持续写入时按固定间隔交付，不会像尾去抖那样无限顺延。
final class DirectoryMonitor: @unchecked Sendable {
    struct Event: Sendable {
        /// 事件所属的监听根路径。主线程处理前要拿它和当前目录比对，
        /// 避免上一个目录延迟投递的根事件把刚导航到的新目录带跑。
        let root: String
        /// 事件路径，已经尽量还原成调用方传入的路径形式。
        let paths: Set<String>
        /// FSEvents 要求递归重扫（事件被内核或用户丢弃）。
        let mustScanSubDirs: Bool
        /// 根目录移动后的新路径。
        let rootMovedTo: String?
        /// 根目录已经不存在。
        let rootMissing: Bool
        /// 同一路径被替换成了新的目录。
        let rootReplaced: Bool
    }

    enum DirectoryStatus: Sendable {
        case directory
        case missing
        case denied
        case other
    }

    private let queue = DispatchQueue(label: "com.swifile.directory-monitor", qos: .utility)
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?
    private var rootFD: Int32 = -1
    /// FSEvents 返回的真实路径（无尾斜杠）
    private var rootPath: String?
    /// 调用方传入的路径形式，用来把事件路径映射回视图侧
    private var originalRootPath: String?
    private var rootDevice: dev_t = 0
    private var rootInode: ino_t = 0
    private var handler: (@Sendable (Event) -> Void)?

    /// 当前监听的原始路径；没有监听时为 nil。
    var watchedPath: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return originalRootPath
    }

    /// 启动监听。`since` 应该取读取目录快照之前的事件 ID，
    /// 这样读取期间发生的变化会作为历史事件补回来。
    func watch(
        _ url: URL,
        since eventID: UInt64? = nil,
        onChange: @escaping @Sendable (Event) -> Void
    ) {
        let original = Self.canonicalPath(url)
        let resolved = Self.realPath(Self.canonicalPath(url))
        queue.sync {
            if stream != nil, rootPath == resolved {
                setOriginalRootPath(original)
                self.handler = onChange
                return
            }

            stopInternal()
            setOriginalRootPath(original)
            self.handler = onChange
            startInternal(path: resolved, since: eventID ?? FSEventsGetCurrentEventId())
        }
    }

    func stop() {
        queue.sync {
            stopInternal()
        }
    }

    deinit {
        // PaneState 正常退出前会 stop；这里兜底释放 FSEvents 和根目录 fd，
        // 避免测试或布局重建时留下回调持有已销毁对象。
        stopInternal()
    }

    private func startInternal(path: String, since: UInt64) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            setOriginalRootPath(nil)
            return
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            setOriginalRootPath(nil)
            return
        }

        rootFD = descriptor
        rootDevice = info.st_dev
        rootInode = info.st_ino
        rootPath = path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)

        guard let newStream = FSEventStreamCreate(
            nil,
            directoryMonitorCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(since),
            0.4,
            flags
        ) else {
            close(descriptor)
            rootFD = -1
            rootPath = nil
            setOriginalRootPath(nil)
            return
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            close(descriptor)
            rootFD = -1
            rootPath = nil
            setOriginalRootPath(nil)
            return
        }
        stream = newStream
    }

    private func stopInternal() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        if rootFD >= 0 {
            close(rootFD)
            rootFD = -1
        }
        rootPath = nil
        rootDevice = 0
        rootInode = 0
        handler = nil
        setOriginalRootPath(nil)
    }

    private func setOriginalRootPath(_ path: String?) {
        stateLock.lock()
        originalRootPath = path
        stateLock.unlock()
    }

    /// FSEvents 回调在私有队列上执行；收到的是 C 指针，先复制成 Swift 值再交给主线程。
    fileprivate func receive(
        count: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let rawPaths = (array as? [String]) ?? []
        var paths: Set<String> = []
        var mustScanSubDirs = false
        var rootChanged = false

        for index in 0..<count {
            let flags = eventFlags[index]
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                continue
            }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                mustScanSubDirs = true
            }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                mustScanSubDirs = true
            }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                rootChanged = true
            }
            if index < rawPaths.count {
                paths.insert(displayPath(forResolved: rawPaths[index]))
            }
        }

        guard let handler else { return }
        let eventRoot = watchedPath ?? ""
        if rootChanged {
            handleRootChange(handler: handler, root: eventRoot, paths: paths)
            return
        }
        guard mustScanSubDirs || !paths.isEmpty else { return }
        handler(Event(
            root: eventRoot,
            paths: paths,
            mustScanSubDirs: mustScanSubDirs,
            rootMovedTo: nil,
            rootMissing: false,
            rootReplaced: false
        ))
    }

    private func handleRootChange(
        handler: @escaping @Sendable (Event) -> Void,
        root: String,
        paths: Set<String>
    ) {
        var currentPath: String?
        if rootFD >= 0 {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if fcntl(rootFD, F_GETPATH, &buffer) == 0 {
                currentPath = Self.canonicalPath(String(cString: buffer))
            }
        }

        guard let oldPath = rootPath else { return }
        if let currentPath, currentPath != oldPath,
           Self.status(ofPath: currentPath) == .directory {
            handler(Event(
                root: root,
                paths: paths,
                mustScanSubDirs: true,
                rootMovedTo: displayMovedPath(currentPath),
                rootMissing: false,
                rootReplaced: false
            ))
            return
        }

        let oldStatus = Self.status(ofPath: oldPath)
        guard oldStatus != .missing else {
            handler(Event(
                root: root,
                paths: paths,
                mustScanSubDirs: true,
                rootMovedTo: nil,
                rootMissing: true,
                rootReplaced: false
            ))
            return
        }

        // 无权限时 fileExists 也会返回 false；不能把它误判成删除退父目录。
        // 让 PaneState 重新读一次，由真实的读取错误展示权限页。
        if oldStatus == .denied {
            handler(Event(
                root: root,
                paths: paths,
                mustScanSubDirs: true,
                rootMovedTo: nil,
                rootMissing: false,
                rootReplaced: true
            ))
            return
        }

        var info = stat()
        let replaced: Bool
        if stat(oldPath, &info) == 0 {
            replaced = info.st_dev != rootDevice || info.st_ino != rootInode
        } else {
            replaced = true
        }
        handler(Event(
            root: root,
            paths: paths,
            mustScanSubDirs: true,
            rootMovedTo: nil,
            rootMissing: false,
            // 同路径也要重启监听：旧 stream/fd 还盯着被替换掉的 inode。
            rootReplaced: replaced || currentPath == oldPath
        ))
    }

    /// 用 stat 区分“不存在”和“存在但无权限”。
    /// FileManager.fileExists 在 TCC/POSIX 拒绝时统一返回 false，会把权限问题误判成目录删除。
    static func status(of url: URL) -> DirectoryStatus {
        status(ofPath: canonicalPath(url))
    }

    static func status(ofPath path: String) -> DirectoryStatus {
        var info = stat()
        var failure: Int32 = 0
        let result = canonicalPath(path).withCString {
            let code = stat($0, &info)
            if code != 0 { failure = errno }
            return code
        }
        if result == 0 {
            return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .other
        }
        switch failure {
        case ENOENT, ENOTDIR:
            return .missing
        case EACCES, EPERM:
            return .denied
        default:
            return .other
        }
    }

    /// 把 FSEvents 的真实路径映射回调用方传入的路径形式。
    /// 例如 `/tmp/foo` 的 FSEvents 事件实际是 `/private/tmp/foo/...`。
    private func displayPath(forResolved path: String) -> String {
        let canonical = Self.canonicalPath(path)
        guard let resolvedRoot = rootPath, let originalRoot = originalRootPath else {
            return canonical
        }
        if canonical == resolvedRoot { return originalRoot }
        guard canonical.hasPrefix(resolvedRoot + "/") else { return canonical }
        return originalRoot + canonical.dropFirst(resolvedRoot.count)
    }

    /// 根目录被改名时，FSEvents 给的是解析后的新路径。
    /// 如果改名只发生在同一父目录内，把新名字套回调用方原来的父路径，
    /// 避免 `/tmp/foo` 浏览中途变成 `/private/tmp/foo`。
    private func displayMovedPath(_ resolvedNew: String) -> String {
        let canonical = Self.canonicalPath(resolvedNew)
        guard let resolvedRoot = rootPath, let originalRoot = originalRootPath else {
            return canonical
        }
        let newParent = URL(fileURLWithPath: canonical).deletingLastPathComponent().path
        let oldParent = URL(fileURLWithPath: resolvedRoot).deletingLastPathComponent().path
        guard newParent == oldParent else { return canonical }

        let originalParent = URL(fileURLWithPath: originalRoot).deletingLastPathComponent()
        // 原路径的父目录必须真的对应解析后的父目录，才能把新名字套回去。
        // 如果根自身是符号链接（/Users/me/link -> /Volumes/X/target），
        // 直接套原父目录会拼出一个不存在的路径，甚至跳到同名错误目录。
        guard Self.realPath(Self.canonicalPath(originalParent)) == oldParent else {
            return canonical
        }
        let name = URL(fileURLWithPath: canonical).lastPathComponent
        return Self.canonicalPath(
            originalParent.appendingPathComponent(name, isDirectory: true)
        )
    }

    static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.precomposedStringWithCanonicalMapping
    }

    static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Foundation 的 resolvingSymlinksInPath 不会展开 `/tmp` 这类根级符号链接，
    /// FSEvents 返回的却是 `/private/tmp`。这里统一用 realpath 对齐两边。
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { realpath($0, &buffer) }
        guard result != nil else { return path }
        return String(cString: buffer)
    }

    private static func canonicalPath(_ path: String) -> String {
        var value = path
        if value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value.precomposedStringWithCanonicalMapping
    }
}

private let directoryMonitorCallback: FSEventStreamCallback = {
    _, info, count, eventPaths, eventFlags, _ in
    guard let info else { return }
    let monitor = Unmanaged<DirectoryMonitor>
        .fromOpaque(info)
        .takeUnretainedValue()
    monitor.receive(
        count: count,
        eventPaths: eventPaths,
        eventFlags: eventFlags
    )
}
