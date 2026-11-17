import AppKit
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

    /// 回到读过的目录时先显示缓存首帧，但必须在后台重读一次：
    /// 目录在别处新增的文件不能因为缓存命中而长期缺失。
    @MainActor
    func testReturningToCachedDirectoryRevalidatesExternalChanges() async throws {
        let first = temporaryDirectory.appendingPathComponent("A", isDirectory: true)
        let second = temporaryDirectory.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        try Data().write(to: first.appendingPathComponent("a1.txt"))
        try Data().write(to: second.appendingPathComponent("b1.txt"))

        // 先放入只含 a1 的旧快照，模拟从这个目录离开后外部新增了 a2。
        let stale = try DirectoryReader.read(directory: first, showHidden: false)
        DirectorySnapshotCache.shared.insert(stale)

        let pane = PaneState(directory: second)
        pane.ensureLoaded()
        try await waitUntil { pane.filteredFiles.map(\.name) == ["b1.txt"] }

        try Data().write(to: first.appendingPathComponent("a2.txt"))
        pane.navigate(to: first)
        try await waitUntil {
            Set(pane.filteredFiles.map(\.name)) == ["a1.txt", "a2.txt"]
        }
    }

    /// QuickLook 返回非方形位图时，NSImage 的逻辑尺寸必须保持比例，否则三个视图都会拉伸。
    func testThumbnailImageKeepsAspectRatio() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 400,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try XCTUnwrap(context.makeImage())

        let image = IconService.thumbnailImage(from: cgImage, maxPointSize: 64)

        XCTAssertEqual(image.size.width, 64, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 16, accuracy: 0.01)
    }

    /// 删除后 FSEvents 还会补普通事件；400ms 内同路径重建不能被提前退父。
    @MainActor
    func testDeletedDirectoryRecreatedWithinWindowStaysInPlace() async throws {
        let directory = temporaryDirectory.appendingPathComponent("recreated", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: directory.appendingPathComponent("old.txt"))

        let pane = PaneState(directory: directory)
        pane.ensureLoaded()
        try await waitUntil { pane.filteredFiles.map(\.name) == ["old.txt"] }

        try FileManager.default.removeItem(at: directory)
        try await Task.sleep(nanoseconds: 400_000_000)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: directory.appendingPathComponent("new.txt"))

        try await waitUntil {
            pane.currentDirectory.standardizedFileURL.path == directory.standardizedFileURL.path
                && pane.filteredFiles.map(\.name) == ["new.txt"]
        }
    }

    func testIconCacheKeySeparatesSameMtimeDifferentSize() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let small = IconService.makeKey(
            path: "/tmp/a.png",
            size: 64,
            version: date,
            fileSize: 100
        )
        let large = IconService.makeKey(
            path: "/tmp/a.png",
            size: 64,
            version: date,
            fileSize: 200
        )

        XCTAssertNotEqual(small, large)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待超时", file: file, line: line)
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
            creationDate: nil,
            isHidden: name.hasPrefix("."),
            formattedSize: isDirectory ? "--" : "\(size) 字节",
            formattedDate: "2026-01-01 00:00",
            fileType: isDirectory ? "文件夹" : "纯文本"
        )
    }
}
