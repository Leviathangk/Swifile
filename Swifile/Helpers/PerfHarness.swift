import AppKit
import Foundation

/// 仅供性能门禁使用的视图求值计数器。
enum PerfCounters {
    nonisolated(unsafe) static var paneChromeEvals: UInt64 = 0
    nonisolated(unsafe) static var paneBodyEvals: UInt64 = 0
    nonisolated(unsafe) static var paneBodyEvalsByPane: [UUID: UInt64] = [:]
    nonisolated(unsafe) static var statusLabelEvals: UInt64 = 0
    nonisolated(unsafe) static var iconCellEvals: UInt64 = 0

    static func reset() {
        paneChromeEvals = 0
        paneBodyEvals = 0
        paneBodyEvalsByPane.removeAll(keepingCapacity: true)
        statusLabelEvals = 0
        iconCellEvals = 0
    }

    static func recordPaneBodyEvaluation(for paneId: UUID) {
        paneBodyEvals &+= 1
        paneBodyEvalsByPane[paneId, default: 0] &+= 1
    }

    static func paneBodyEvaluationCount(for paneId: UUID) -> UInt64 {
        paneBodyEvalsByPane[paneId] ?? 0
    }
}

private struct PerformanceReport: Codable, Sendable {
    let coldLoadMilliseconds: Double
    let cacheHitMilliseconds: Double
    let filterSortMilliseconds: Double
    let paneColdLoadMilliseconds: Double
    let paneSearchMilliseconds: Double
    let selectionMilliseconds: Double
    let multiPaneNavigationMilliseconds: Double
    let multiPaneOtherBodyEvaluations: UInt64
    let itemCount: Int
    let passed: Bool
}

private struct MultiPaneFixture: Sendable {
    let root: URL
    let directories: [URL]
}

/// 设置 `SWIFILE_PERF_BENCH=1` 时运行独立目录引擎基准并自动结束应用。
enum PerfHarness {
    static let isEnabled = ProcessInfo.processInfo.environment["SWIFILE_PERF_BENCH"] == "1"

    @MainActor
    static func runIfNeeded(appState: AppStateManager) {
        guard isEnabled else { return }
        Task {
            let report = await runBenchmark(appState: appState)
            print(
                "[性能] 冷加载 \(format(report.coldLoadMilliseconds)) ms，" +
                "缓存命中 \(format(report.cacheHitMilliseconds)) ms，" +
                "过滤排序 \(format(report.filterSortMilliseconds)) ms，" +
                "窗格冷加载 \(format(report.paneColdLoadMilliseconds)) ms，" +
                "窗格搜索 \(format(report.paneSearchMilliseconds)) ms，" +
                "选择 x200 \(format(report.selectionMilliseconds)) ms，" +
                "四窗格切换 \(format(report.multiPaneNavigationMilliseconds)) ms，" +
                "旁窗格求值 \(report.multiPaneOtherBodyEvaluations)，" +
                "结果 \(report.passed ? "通过" : "失败")"
            )
            write(report)
            NSApplication.shared.terminate(nil)
        }
    }

    @MainActor
    private static func runBenchmark(appState: AppStateManager) async -> PerformanceReport {
        let root = await Task.detached(priority: .utility) { createFixture() }.value
        defer { try? FileManager.default.removeItem(at: root) }

        await FileSystemHelper.removeAllCachedSnapshots()

        let coldStart = CFAbsoluteTimeGetCurrent()
        let cold = try? await FileSystemHelper.loadSnapshot(
            at: root,
            showHidden: false,
            useCache: true
        )
        let coldMilliseconds = elapsedMilliseconds(since: coldStart)

        let cacheStart = CFAbsoluteTimeGetCurrent()
        let cached = try? await FileSystemHelper.loadSnapshot(
            at: root,
            showHidden: false,
            useCache: true
        )
        let cacheMilliseconds = elapsedMilliseconds(since: cacheStart)

        let filterStart = CFAbsoluteTimeGetCurrent()
        let content = FileContentPipeline.process(
            items: cached?.items ?? [],
            query: "item-01",
            sortField: .date,
            sortOrder: .descending
        )
        let filterMilliseconds = elapsedMilliseconds(since: filterStart)

        await FileSystemHelper.removeAllCachedSnapshots()
        let pane = appState.paneFocus.activePane
        let paneLoadStart = CFAbsoluteTimeGetCurrent()
        pane.navigate(to: root)
        let paneLoaded = await waitUntil(timeoutMilliseconds: 2_000) {
            pane.hasLoadedOnce && !pane.isLoading && pane.totalItemCount == 4_000
        }
        let paneLoadMilliseconds = elapsedMilliseconds(since: paneLoadStart)

        let generationBeforeSearch = pane.fileGeneration
        let searchStart = CFAbsoluteTimeGetCurrent()
        pane.searchQuery = "item-01"
        let searchFinished = await waitUntil(timeoutMilliseconds: 500) {
            pane.fileGeneration > generationBeforeSearch && pane.totalItemCount == 100
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let searchMilliseconds = elapsedMilliseconds(since: searchStart)

        let selectionStart = CFAbsoluteTimeGetCurrent()
        if pane.filteredFiles.count >= 2 {
            for index in 0..<200 {
                pane.selectionStore.replace(with: pane.filteredFiles[index % 2].url)
            }
        }
        let selectionMilliseconds = elapsedMilliseconds(since: selectionStart)

        let multiPaneFixture = await Task.detached(priority: .utility) {
            createMultiPaneFixture()
        }.value
        defer { try? FileManager.default.removeItem(at: multiPaneFixture.root) }

        appState.setLayout(.quad)
        let panes = appState.panes
        for (pane, directory) in zip(panes, multiPaneFixture.directories) {
            pane.navigate(to: directory)
        }
        let allPanesLoaded = await waitUntil(timeoutMilliseconds: 2_000) {
            panes.count == 4 && panes.allSatisfy {
                $0.hasLoadedOnce && !$0.isLoading && $0.totalItemCount == 600
            }
        }
        // 让初始四窗格的观察通知和首帧图标任务先稳定，再测单窗格导航。
        try? await Task.sleep(nanoseconds: 50_000_000)
        PerfCounters.reset()
        let otherPaneGenerations = panes.dropFirst().map(\.fileGeneration)
        let multiPaneStart = CFAbsoluteTimeGetCurrent()
        panes[0].navigate(to: multiPaneFixture.directories[4])
        let targetPaneLoaded = await waitUntil(timeoutMilliseconds: 2_000) {
            panes[0].hasLoadedOnce && !panes[0].isLoading && panes[0].totalItemCount == 600
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let multiPaneNavigationMilliseconds = elapsedMilliseconds(since: multiPaneStart)
        let otherPaneBodyEvaluations = panes.dropFirst().reduce(UInt64(0)) {
            $0 + PerfCounters.paneBodyEvaluationCount(for: $1.id)
        }
        let otherPanesStable = zip(panes.dropFirst(), otherPaneGenerations).allSatisfy {
            $0.0.fileGeneration == $0.1
        }
        let multiPanePassed = allPanesLoaded && targetPaneLoaded && otherPanesStable &&
            multiPaneNavigationMilliseconds < 900 && otherPaneBodyEvaluations <= 2

        let count = cold?.items.count ?? 0
        return PerformanceReport(
            coldLoadMilliseconds: coldMilliseconds,
            cacheHitMilliseconds: cacheMilliseconds,
            filterSortMilliseconds: filterMilliseconds,
            paneColdLoadMilliseconds: paneLoadMilliseconds,
            paneSearchMilliseconds: searchMilliseconds,
            selectionMilliseconds: selectionMilliseconds,
            multiPaneNavigationMilliseconds: multiPaneNavigationMilliseconds,
            multiPaneOtherBodyEvaluations: otherPaneBodyEvaluations,
            itemCount: count,
            passed: count == 4_000 &&
                coldMilliseconds < 900 &&
                cacheMilliseconds < 20 &&
                filterMilliseconds < 100 &&
                paneLoaded && paneLoadMilliseconds < 900 &&
                searchFinished && searchMilliseconds < 500 &&
                selectionMilliseconds < 20 &&
                multiPanePassed &&
                !content.files.isEmpty
        )
    }

    @MainActor
    private static func waitUntil(
        timeoutMilliseconds: Double,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutMilliseconds / 1_000
        while CFAbsoluteTimeGetCurrent() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private static func createFixture() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifile-benchmark-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<4_000 {
            let name = String(format: "item-%04d.txt", index)
            FileManager.default.createFile(
                atPath: root.appendingPathComponent(name).path(percentEncoded: false),
                contents: Data()
            )
        }
        return root
    }

    private static func createMultiPaneFixture() -> MultiPaneFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifile-multipane-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var directories: [URL] = []
        directories.reserveCapacity(5)
        for directoryIndex in 0..<5 {
            let directory = root.appendingPathComponent("pane-\(directoryIndex)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directories.append(directory)
            for itemIndex in 0..<600 {
                let name = String(format: "item-%04d.txt", itemIndex)
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(name).path(percentEncoded: false),
                    contents: Data()
                )
            }
        }
        return MultiPaneFixture(root: root, directories: directories)
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func write(_ report: PerformanceReport) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifile-perf-report.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
