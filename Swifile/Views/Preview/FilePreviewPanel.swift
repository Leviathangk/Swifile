import SwiftUI
import Quartz

// MARK: - 文件预览组件
/// 访达预览列同款排版：预览图带圆角投影居中，下面是文件名、类型 · 大小、
/// 「信息」小节（创建时间 / 修改时间）。分栏视图的预览列与空格呼出的悬浮
/// 预览共用这一套组件。图片走自家缩略渲染避免 QLPreviewView 的整块白底，
/// 其余类型交给系统 QLPreviewView 渲染。

/// 系统预览视图桥接：QLPreviewView 不需要任何接管协议，赋 URL 即渲染
private struct InlinePreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        // 新 SDK 上该构造是可失败的，失败时退回空视图（信息区仍可用）
        guard let view = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let qlView = nsView as? QLPreviewView else { return }
        // 只在变化时赋值：同一文件的重复赋值会让预览重新加载闪一下
        if (qlView.previewItem as? NSURL) != (url as NSURL) {
            qlView.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? QLPreviewView)?.previewItem = nil
    }
}

struct FilePreviewPanel: View {
    let file: FileItem

    /// 预览图解码上限：预览列宽度的 6 倍左右，足够清晰且省内存
    private static let thumbMaxPixel: CGFloat = 1400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 预览区：占满剩余高度
            Group {
                if file.isDirectory {
                    folderPreview
                } else if FileIconHelper.category(for: file.url, isDirectory: false) == .image {
                    ImageThumbView(url: file.url, maxPixel: Self.thumbMaxPixel)
                } else {
                    InlinePreviewView(url: file.url)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 14)

            // 信息区
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)

                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("信息")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                infoRow("创建时间", formattedCreationDate)
                infoRow("修改时间", file.formattedDate)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var metaLine: String {
        if file.isDirectory { return file.fileType }
        return "\(file.fileType) · \(file.formattedSize)"
    }

    private var formattedCreationDate: String {
        guard let date = file.creationDate else { return "--" }
        return FileItem.makeDateFormatter().string(from: date)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// 目录：大图标 + 无预览
    private var folderPreview: some View {
        Image(nsImage: IconService.placeholder(isDirectory: true, size: 96))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 图片缩略渲染
/// 用 CGImageSource 解码受限尺寸的缩略图（访达预览同款观感：圆角 + 投影），
/// 解码失败（如 SVG）时回退到系统 QLPreviewView。
private struct ImageThumbView: View {
    let url: URL
    let maxPixel: CGFloat

    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            } else if loadFailed {
                InlinePreviewView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { await loadThumb() }
    }

    private func loadThumb() async {
        image = nil
        loadFailed = false
        let target = url
        let maxPixel = maxPixel
        let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(target as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        guard !Task.isCancelled else { return }
        if let decoded {
            image = decoded
        } else {
            loadFailed = true
        }
    }
}

// MARK: - 悬浮预览
/// 空格呼出的应用内悬浮层：玻璃卡片浮在内容区上，点外部或 Esc/空格关闭。
struct FloatingPreviewOverlay: View {
    let file: FileItem
    let onClose: () -> Void

    var body: some View {
        // 透明捕获层：点卡片以外任意位置关闭
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            .overlay {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("预览")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("关闭预览")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    FilePreviewPanel(file: file)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 560, height: 500)
                .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 22, y: 6)
            }
    }
}
