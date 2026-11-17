import AppKit
import SwiftUI

// MARK: - 设置面板

/// 设置窗口内容：左栏分类导航、右栏详情，仿系统设置的左右分栏。
/// 新分类只需扩 Pane 枚举并补一个详情页。
struct SettingsView: View {
    @Bindable var appearance: AppearanceSettings
    let favorites: SidebarFavoritesSettings

    /// 设置分类；左栏行的图标与标题也在这里维护
    enum Pane: String, CaseIterable, Identifiable {
        case appearance
        case favorites
        case permissions
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: return "外观"
            case .favorites: return "收藏"
            case .permissions: return "权限"
            case .about: return "关于"
            }
        }

        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .favorites: return "star"
            case .permissions: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Pane = .appearance

    var body: some View {
        HStack(spacing: 0) {
            // 左栏：分类列表，「关于」固定在底部
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases.filter { $0 != .about }) { pane in
                    paneRow(pane)
                }
                Spacer(minLength: 0)
                Divider()
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                paneRow(.about)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(width: 168, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // 右栏：详情页
            Group {
                switch selection {
                case .appearance:
                    AppearancePane(appearance: appearance)
                case .favorites:
                    FavoritesPane(favorites: favorites)
                case .permissions:
                    PermissionsPane()
                case .about:
                    AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 400)
    }

    /// 左栏行：选中态与侧边栏快速访问一致（系统蓝底白字）
    private func paneRow(_ pane: Pane) -> some View {
        let isSelected = selection == pane
        return HStack(spacing: 8) {
            Image(systemName: pane.icon)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(width: 18)

            Text(pane.title)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : .primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = pane }
    }
}

// MARK: - 外观设置

/// 主题三选：跟随系统 / 浅色 / 深色
struct AppearancePane: View {
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        Form {
            Section {
                Picker("主题", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("外观")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 收藏设置

/// 选择侧栏「收藏」显示哪些位置；至少保留 1 项。
struct FavoritesPane: View {
    let favorites: SidebarFavoritesSettings
    @State private var showsMinimumAlert = false

    var body: some View {
        Form {
            Section {
                ForEach(favorites.allLocations) { location in
                    favoriteRow(location)
                }
            } header: {
                Text("显示在收藏")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("至少保留 \(SidebarFavoritesSettings.minimumCount) 项", isPresented: $showsMinimumAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("先勾选其他位置，再取消这一项。")
        }
    }

    /// 整行可点：复选框、图标、标题任意位置都能切换，不再只认小方块。
    private func favoriteRow(_ location: FavoriteLocation) -> some View {
        let isSelected = favorites.isSelected(location)
        return Button {
            toggle(location)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 18)

                Image(systemName: location.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(location.iconColor)
                    .frame(width: 20, height: 20)

                Text(location.title)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(location.title)
    }

    private func toggle(_ location: FavoriteLocation) {
        if favorites.isSelected(location) {
            guard favorites.selectedCount > SidebarFavoritesSettings.minimumCount else {
                showsMinimumAlert = true
                return
            }
            favorites.setSelected(false, for: location)
        } else {
            favorites.setSelected(true, for: location)
        }
    }
}

// MARK: - 关于

/// 关于页：应用信息、简介、作者联系方式和开源信息。
struct AboutPane: View {
    @State private var showsLicense = false

    private let githubURL = URL(string: "https://github.com/Leviathangk/Swifile")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .padding(.bottom, 12)

            Text("Swifile")
                .font(.system(size: 24, weight: .semibold))

            Text("版本 \(appVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text("macOS 双窗格文件管理器\n快速浏览、整理和搬运文件。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("GitHub")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Link("github.com/Leviathangk/Swifile", destination: githubURL)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text("许可证")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Button("PolyForm Noncommercial 1.0.0") {
                        showsLicense = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 26)
        .padding(.top, 56)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showsLicense) {
            LicenseSheet()
        }
    }
}

// MARK: - 许可证

/// 应用内许可证查看器，文本来自 app 包里的 LICENSE.txt。
private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "许可证文件缺失，请查看 GitHub 仓库中的 LICENSE。"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("PolyForm Noncommercial License 1.0.0")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let url = URL(string: "https://github.com/Leviathangk/Swifile/blob/main/LICENSE") {
                    Link("在 GitHub 打开", destination: url)
                        .font(.system(size: 11))
                }
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Text(licenseText)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .frame(width: 560, height: 380)
    }
}
