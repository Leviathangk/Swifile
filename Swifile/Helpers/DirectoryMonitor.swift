import Foundation
import Darwin

/// 使用 vnode 事件监听当前目录，仅在外部内容变化时触发一次合并刷新。
@MainActor
final class DirectoryMonitor {
    private let queue = DispatchQueue(label: "com.swifile.directory-monitor", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var refreshTask: Task<Void, Never>?
    private var changeHandler: (() -> Void)?
    private(set) var watchedPath: String?

    func watch(_ url: URL, onChange: @escaping () -> Void) {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        if watchedPath == path, source != nil {
            changeHandler = onChange
            return
        }

        stop()
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        watchedPath = path
        changeHandler = onChange
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        newSource.setCancelHandler {
            close(descriptor)
        }
        source = newSource
        newSource.resume()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        source?.cancel()
        source = nil
        changeHandler = nil
        watchedPath = nil
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.changeHandler?()
        }
    }

    deinit {
        refreshTask?.cancel()
        source?.cancel()
    }
}
