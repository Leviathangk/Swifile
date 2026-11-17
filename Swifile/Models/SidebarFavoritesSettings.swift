import Foundation
import Observation
import SwiftUI

// MARK: - 收藏位置

/// 侧栏「收藏」可选的系统目录；标题、图标尽量与访达的个人收藏一致。
enum FavoriteLocation: String, CaseIterable, Identifiable, Sendable {
    case applications
    case downloads
    case desktop
    case documents
    case home
    case movies
    case music
    case pictures
    case publicFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applications: return "应用程序"
        case .downloads: return "下载"
        case .desktop: return "桌面"
        case .documents: return "文稿"
        case .home: return "个人文件夹"
        case .movies: return "影片"
        case .music: return "音乐"
        case .pictures: return "图片"
        case .publicFolder: return "公共"
        }
    }

    var icon: String {
        switch self {
        case .applications: return "app"
        case .downloads: return "arrow.down.circle"
        case .desktop: return "display"
        case .documents: return "doc"
        case .home: return "house"
        case .movies: return "film"
        case .music: return "music.note"
        case .pictures: return "photo"
        case .publicFolder: return "person.2"
        }
    }

    var iconColor: Color {
        switch self {
        case .applications: return .indigo
        case .downloads: return .green
        case .desktop: return .cyan
        case .documents: return .blue
        case .home: return .orange
        case .movies: return .purple
        case .music: return .pink
        case .pictures: return .teal
        case .publicFolder: return .gray
        }
    }

    var url: URL {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        switch self {
        case .applications:
            return manager.urls(for: .applicationDirectory, in: .localDomainMask).first
                ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .downloads:
            return manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Downloads", isDirectory: true)
        case .desktop:
            return manager.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Desktop", isDirectory: true)
        case .documents:
            return manager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Documents", isDirectory: true)
        case .home:
            return home
        case .movies:
            return manager.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Movies", isDirectory: true)
        case .music:
            return manager.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Music", isDirectory: true)
        case .pictures:
            return manager.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Pictures", isDirectory: true)
        case .publicFolder:
            return home.appendingPathComponent("Public", isDirectory: true)
        }
    }
}

// MARK: - 收藏设置

/// 控制侧栏「收藏」显示哪些系统目录，至少保留 1 项。
/// 选择顺序就是侧栏显示顺序，保存在 UserDefaults。
@MainActor
@Observable
final class SidebarFavoritesSettings {
    static let minimumCount = 1

    private static let selectedKey = "sidebarFavoriteIDs"
    private static let defaultIDs: [String] = [
        FavoriteLocation.desktop.id,
        FavoriteLocation.downloads.id,
        FavoriteLocation.home.id
    ]

    private(set) var selectedIDs: [String]

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.selectedKey) ?? []
        let validIDs = Set(FavoriteLocation.allCases.map(\.id))
        var seen = Set<String>()
        let uniqueSelection = stored.filter {
            validIDs.contains($0) && seen.insert($0).inserted
        }
        // 旧数据或异常数据为空时回到默认三项，保证侧栏始终可用
        selectedIDs = uniqueSelection.count >= Self.minimumCount
            ? uniqueSelection
            : Self.defaultIDs
    }

    /// 设置页里的全部可选项。
    var allLocations: [FavoriteLocation] {
        FavoriteLocation.allCases
    }

    /// 侧栏实际显示的位置，顺序与选择顺序一致。
    var selectedLocations: [FavoriteLocation] {
        let lookup = Dictionary(uniqueKeysWithValues: FavoriteLocation.allCases.map { ($0.id, $0) })
        return selectedIDs.compactMap { lookup[$0] }
    }

    var selectedCount: Int {
        selectedLocations.count
    }

    func isSelected(_ location: FavoriteLocation) -> Bool {
        selectedIDs.contains(location.id)
    }

    func setSelected(_ selected: Bool, for location: FavoriteLocation) {
        if selected {
            guard !selectedIDs.contains(location.id) else { return }
            selectedIDs.append(location.id)
        } else {
            guard selectedCount > Self.minimumCount else { return }
            selectedIDs.removeAll { $0 == location.id }
        }
        UserDefaults.standard.set(selectedIDs, forKey: Self.selectedKey)
    }
}
