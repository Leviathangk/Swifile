import Foundation
import XCTest
@testable import Swifile

final class DirectoryEngineTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swifile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testReaderFiltersHiddenFilesAndTreatsPackagesAsFiles() throws {
        try Data().write(to: temporaryDirectory.appendingPathComponent("visible.txt"))
        try Data().write(to: temporaryDirectory.appendingPathComponent(".hidden.txt"))
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent("Sample.app", isDirectory: true),
            withIntermediateDirectories: false
        )

        let visible = try DirectoryReader.read(directory: temporaryDirectory, showHidden: false)
        XCTAssertEqual(Set(visible.items.map(\.name)), ["visible.txt", "Sample.app"])
        XCTAssertEqual(visible.items.first(where: { $0.name == "Sample.app" })?.isDirectory, false)

        let all = try DirectoryReader.read(directory: temporaryDirectory, showHidden: true)
        XCTAssertEqual(all.items.count, 3)
    }

    func testSnapshotCacheCanInvalidateBothVisibilityVariants() throws {
        let visible = DirectorySnapshot(
            directory: temporaryDirectory,
            items: [makeItem(name: "a.txt")],
            showHidden: false,
            loadedAt: Date()
        )
        let hidden = DirectorySnapshot(
            directory: temporaryDirectory,
            items: [makeItem(name: ".a.txt")],
            showHidden: true,
            loadedAt: Date()
        )
        let cache = DirectorySnapshotCache(maximumEntryCount: 4, maximumItemCount: 100)
        cache.insert(visible)
        cache.insert(hidden)

        XCTAssertNotNil(cache.value(for: temporaryDirectory, showHidden: false))
        XCTAssertNotNil(cache.value(for: temporaryDirectory, showHidden: true))

        cache.invalidate(temporaryDirectory)
        XCTAssertNil(cache.value(for: temporaryDirectory, showHidden: false))
        XCTAssertNil(cache.value(for: temporaryDirectory, showHidden: true))
    }

    func testPipelineFiltersCaseInsensitivelyAndKeepsFoldersFirst() {
        let items = [
            makeItem(name: "beta.TXT"),
            makeItem(name: "Alpha", isDirectory: true),
            makeItem(name: "alpha.txt")
        ]

        let result = FileContentPipeline.process(
            items: items,
            query: "ALPHA",
            sortField: .name,
            sortOrder: .descending
        )

        XCTAssertEqual(result.files.map(\.name), ["Alpha", "alpha.txt"])
    }

    func testTenThousandItemPipelineStaysBelowLatencyBudget() {
        let items = (0..<10_000).map { index in
            makeItem(name: String(format: "item-%05d.txt", index), size: Int64(index))
        }

        let start = CFAbsoluteTimeGetCurrent()
        let result = FileContentPipeline.process(
            items: items,
            query: "item-01",
            sortField: .size,
            sortOrder: .descending
        )
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1_000

        XCTAssertEqual(result.files.count, 1_000)
        XCTAssertLessThan(milliseconds, 150, "万级条目过滤排序超过交互时延预算")
    }

    @MainActor
    func testPanePublishesCachedDirectoryWithoutWaitingForAnotherRunLoopTurn() async throws {
        let itemURL = temporaryDirectory.appendingPathComponent("instant.txt")
        try Data().write(to: itemURL)
        let snapshot = try DirectoryReader.read(directory: temporaryDirectory, showHidden: false)
        DirectorySnapshotCache.shared.insert(snapshot)

        let pane = PaneState(directory: temporaryDirectory)
        pane.ensureLoaded()

        XCTAssertTrue(pane.hasLoadedOnce)
        XCTAssertFalse(pane.isLoading)
        XCTAssertEqual(pane.filteredFiles.map(\.name), ["instant.txt"])
    }

    private func makeItem(
        name: String,
        isDirectory: Bool = false,
        size: Int64 = 0
    ) -> FileItem {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: isDirectory)
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            size: isDirectory ? nil : size,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(size)),
            isHidden: name.hasPrefix("."),
            formattedSize: isDirectory ? "--" : "\(size) 字节",
            formattedDate: "2026-01-01 00:00",
            fileType: isDirectory ? "文件夹" : "纯文本"
        )
    }
}
