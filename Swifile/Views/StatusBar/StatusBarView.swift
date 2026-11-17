import SwiftUI

// MARK: - 底部状态栏
/// 文件计数来自 pane.totalItemCount；选中数来自独立 SelectionStore.count。
/// 单击选择只刷新本视图的选中文案，不触发内容列表重建。
struct StatusBarView: View {
    let paneFocus: PaneFocus
    let diskUsed: Int64
    let diskTotal: Int64

    private var diskFreeFormatted: String {
        let free = diskTotal - diskUsed
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    private var diskTotalFormatted: String {
        ByteCountFormatter.string(fromByteCount: diskTotal, countStyle: .file)
    }

    private var diskUsageRatio: Double {
        guard diskTotal > 0 else { return 0 }
        return Double(diskUsed) / Double(diskTotal)
    }

    var body: some View {
        // 拆成子视图，让选中文案的观察范围尽量小。
        // 用 ZStack 让容量条永远水平居中：双 Spacer 布局会随左右文案的
        // 宽度差产生偏移（左侧「11 项」比右侧可用容量短，条就被挤偏）。
        ZStack {
            HStack {
                StatusSelectionLabel(paneFocus: paneFocus)
                    .frame(maxWidth: 420, alignment: .leading)

                Spacer()

                Text("可用 \(diskFreeFormatted) / \(diskTotalFormatted)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(alignment: .trailing)
            }

            // 磁盘占用：官方线性进度条，轨道与填充由系统绘制
            ProgressView(value: min(max(diskUsageRatio, 0), 1))
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(width: 180)
                .help("已用 \(Int(diskUsageRatio * 100))%")
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1),
            alignment: .top
        )
    }
}

// MARK: - 仅订阅 activePane 的 total + selectionStore
private struct StatusSelectionLabel: View {
    let paneFocus: PaneFocus

    var body: some View {
        let _ = { if PerfHarness.isEnabled { PerfCounters.statusLabelEvals &+= 1 } }()
        let pane = paneFocus.activePane
        let total = pane.totalItemCount
        let selection = pane.selectionStore
        let selected = selection.count

        // 单选显示文件详情（名称 · 大小 · 修改日期）；多选只报数量
        let detail = selected == 1
            ? pane.filteredFiles.first(where: { selection.urls.contains($0.url) }).map {
                "\($0.name)  \($0.isDirectory ? $0.fileType : $0.formattedSize)  \($0.formattedDate)"
            }
            : nil

        return Group {
            if let detail {
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(selected > 0 ? "已选择 \(selected) 项，共 \(total) 项" : "\(total) 项")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: 420, alignment: .leading)
    }
}
