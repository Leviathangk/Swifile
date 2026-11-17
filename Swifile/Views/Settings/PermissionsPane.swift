import SwiftUI

// MARK: - 权限设置

/// 权限面板：只管完全磁盘访问一项。
/// 授权动作在系统设置里完成，这里负责触发申请、状态展示与自动核对。
struct PermissionsPane: View {
    /// 完全磁盘访问的探测结果
    @State private var fullDiskAccess = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(fullDiskAccess ? Color(nsColor: .systemGreen) : Color(nsColor: .systemGray))
                        .frame(width: 8, height: 8)
                    Text(fullDiskAccess ? "已授予" : "未授予")
                    Spacer()
                    if fullDiskAccess {
                        Button("打开系统设置") {
                            SystemPermissionChecker.openFullDiskAccessSettings()
                        }
                    } else {
                        Button("在访达中显示") {
                            SystemPermissionChecker.revealAppInFinder()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)

                        Button("申请权限") {
                            SystemPermissionChecker.requestFullDiskAccess()
                        }
                    }
                }
            } header: {
                Text("完全磁盘访问权限")
            } footer: {
                Text("授权后桌面、文档、下载等就不再弹窗。列表里没看到 Swifile？点「在访达中显示」，把应用拖进列表。")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        // 授权在系统设置里完成，面板开着时每 2 秒自动核对一次状态
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refresh()
            }
        }
    }

    private func refresh() {
        fullDiskAccess = SystemPermissionChecker.hasFullDiskAccess()
    }
}
