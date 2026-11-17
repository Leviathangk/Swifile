import SwiftUI
import AppKit

// MARK: - 头部宿主容器
/// 将动态面包屑放进独立的 AppKit 容器，避免与文件表格共同参与 SwiftUI 尺寸协商。
struct PaneHeaderHost: NSViewRepresentable {
    let pane: PaneState
    let activity: PaneActivity
    let onActivate: () -> Void

    func makeNSView(context: Context) -> PaneHeaderContainer {
        PaneHeaderContainer(pane: pane, activity: activity, onActivate: onActivate)
    }

    func updateNSView(_ nsView: PaneHeaderContainer, context: Context) {
        nsView.updateIfNeeded(pane: pane, activity: activity, onActivate: onActivate)
    }
}

/// 为固定高度头部提供稳定的宿主视图身份。
/// 只在目录或窗格身份变化时重建 SwiftUI 树；焦点切换由 activity 内部驱动，不经过这里。
final class PaneHeaderContainer: NSView {
    private let hostingView: NSHostingView<PaneHeaderView>
    private var currentPane: PaneState?
    private var currentActivity: PaneActivity?

    init(pane: PaneState, activity: PaneActivity, onActivate: @escaping () -> Void) {
        hostingView = NSHostingView(
            rootView: PaneHeaderView(pane: pane, activity: activity, onActivate: onActivate)
        )
        super.init(frame: .zero)
        currentPane = pane
        currentActivity = activity
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func updateIfNeeded(pane: PaneState, activity: PaneActivity, onActivate: @escaping () -> Void) {
        // 焦点切换只改变 activity 的内部状态，引用不变时保持现有 SwiftUI 树
        guard currentPane !== pane || currentActivity !== activity else { return }
        currentPane = pane
        currentActivity = activity
        hostingView.rootView = PaneHeaderView(pane: pane, activity: activity, onActivate: onActivate)
    }
}

// MARK: - 窗格头部视图
/// 每个窗格顶部的导航头：显示当前文件夹名、面包屑路径和操作按钮
struct PaneHeaderView: View {
    let pane: PaneState
    let activity: PaneActivity
    let onActivate: () -> Void

    @State private var isEditingPath = false
    @State private var pathDraft = ""
    @State private var pathErrorMessage: String?
    @State private var pathClickMonitor: Any?
    @FocusState private var pathFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            // 后退/前进按钮
            navigationButtons
                .padding(.trailing, 2)

            if isEditingPath {
                pathEditor
            } else {
                // 面包屑铺在整条路径栏的透明点击层上：点空白处进入编辑，点面包屑仍逐级跳转
                ZStack(alignment: .leading) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { beginPathEditing() }
                        .help("点击输入路径")

                    breadcrumbs
                }
            }

            // 右侧操作按钮（加号 + 更多）
            actionButtons
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .overlay(
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { onActivate() }
        )
        .onChange(of: pane.pathEditRequestToken) { _, _ in
            guard activity.isActive, !isEditingPath else { return }
            beginPathEditing()
        }
        .onChange(of: pane.currentDirectory) { _, _ in
            if isEditingPath { cancelPathEditing() }
        }
        .onChange(of: pathFieldFocused) { _, isFocused in
            // 点到文件列表等外部区域时退出编辑；报错弹窗抢走焦点时保持输入态
            guard isEditingPath, !isFocused, pathErrorMessage == nil else { return }
            cancelPathEditing()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if isEditingPath { cancelPathEditing() }
        }
        .onAppear {
            installPathClickMonitor()
        }
        .onDisappear {
            removePathClickMonitor()
        }
        .alert("无法打开路径", isPresented: pathErrorBinding) {
            Button("好", role: .cancel) {
                // 关掉提示后回到输入框并全选，方便直接改路径
                DispatchQueue.main.async {
                    pathFieldFocused = true
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
        } message: {
            Text(pathErrorMessage ?? "")
        }
    }

    // MARK: - 导航按钮

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button(action: { pane.goBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(pane.canGoBack ? Color.secondary : Color.secondary.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!pane.canGoBack)
            
            Button(action: { pane.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(pane.canGoForward ? Color.secondary : Color.secondary.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!pane.canGoForward)
        }
    }

    // MARK: - 地址栏编辑

    /// 原生输入框；回车跳转，Esc 退出，进入时全选当前路径。
    private var pathEditor: some View {
        TextField("输入路径，回车跳转", text: $pathDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .focused($pathFieldFocused)
            .onSubmit { commitPath() }
            .onExitCommand { cancelPathEditing() }
            .onAppear {
                pathFieldFocused = true
                DispatchQueue.main.async {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            // 原生 plain 输入框会随宽度拉伸；圆角背景只负责给出可编辑区域的视觉边界
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.82),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        pathFieldFocused
                            ? Color.accentColor.opacity(0.8)
                            : Color(nsColor: .separatorColor),
                        lineWidth: pathFieldFocused ? 1 : 0.5
                    )
            )
    }

    private var pathErrorBinding: Binding<Bool> {
        Binding(
            get: { pathErrorMessage != nil },
            set: { isPresented in
                if !isPresented { pathErrorMessage = nil }
            }
        )
    }

    private func beginPathEditing() {
        onActivate()
        pathDraft = pane.currentDirectory.path(percentEncoded: false)
        pathErrorMessage = nil
        isEditingPath = true
    }

    private func commitPath() {
        if let error = pane.navigate(toUserPath: pathDraft) {
            pathErrorMessage = error.localizedDescription
            pathFieldFocused = true
            return
        }
        isEditingPath = false
        pathFieldFocused = false
    }

    private func cancelPathEditing() {
        isEditingPath = false
        pathFieldFocused = false
        pathDraft = ""
        pathErrorMessage = nil
    }

    // MARK: - 点击外部退出

    /// 常驻窗口级点击监听，仅在编辑态生效：文件列表、工具栏、侧栏、其它窗口等位置
    /// 点一下都退出，且只丢弃输入不导航；点输入框内部仍保留编辑态。
    private func installPathClickMonitor() {
        removePathClickMonitor()
        pathClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if shouldEndPathEditing(for: event) {
                    cancelPathEditing()
                }
            }
            return event
        }
    }

    private func removePathClickMonitor() {
        if let pathClickMonitor {
            NSEvent.removeMonitor(pathClickMonitor)
            self.pathClickMonitor = nil
        }
    }

    private func shouldEndPathEditing(for event: NSEvent) -> Bool {
        // 报错弹窗期间不退出，等用户关掉提示继续改
        guard isEditingPath, pathErrorMessage == nil else { return false }

        guard let eventWindow = event.window,
              let keyWindow = NSApp.keyWindow,
              eventWindow === keyWindow,
              let editor = keyWindow.firstResponder as? NSTextView,
              let editorWindow = editor.window,
              eventWindow === editorWindow else {
            return true
        }

        let field: NSView = (editor.delegate as? NSTextField) ?? editor
        let fieldFrame = field.convert(field.bounds, to: nil)
        return !fieldFrame.insetBy(dx: -8, dy: -4).contains(event.locationInWindow)
    }

    // MARK: - Xcode 风格面包屑视图

    private var breadcrumbs: some View {
        let components = pane.currentDirectory.pathComponents
        var items: [(id: Int, name: String, url: URL)] = []
        var url = URL(fileURLWithPath: "/")
        var id = 0
        for component in components {
            if component == "/" { continue }
            url = url.appendingPathComponent(component)
            items.append((id: id, name: component, url: url))
            id += 1
        }
        
        return ViewThatFits(in: .horizontal) {
            breadcrumbsRow(items: items, prefixCount: items.count, suffixCount: 0)
            if items.count > 4 {
                breadcrumbsRow(items: items, prefixCount: 1, suffixCount: 3)
            }
            if items.count > 3 {
                breadcrumbsRow(items: items, prefixCount: 1, suffixCount: 2)
            }
            if items.count > 2 {
                breadcrumbsRow(items: items, prefixCount: 1, suffixCount: 1)
            }
            if items.count > 1 {
                breadcrumbsRow(items: items, prefixCount: 0, suffixCount: 1)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func breadcrumbsRow(items: [(id: Int, name: String, url: URL)], prefixCount: Int, suffixCount: Int) -> some View {
        HStack(spacing: 4) {
            if prefixCount == items.count {
                ForEach(items, id: \.id) { item in
                    if item.id > 0 { chevron }
                    breadcrumbButton(for: item, isLast: item.id == items.count - 1)
                }
            } else {
                let prefixItems = Array(items[0..<prefixCount])
                let suffixItems = Array(items[(items.count - suffixCount)...])
                let hiddenItems = Array(items[prefixCount..<(items.count - suffixCount)])
                
                ForEach(prefixItems, id: \.id) { item in
                    if item.id > 0 { chevron }
                    breadcrumbButton(for: item, isLast: false)
                }
                
                if !hiddenItems.isEmpty {
                    if prefixCount > 0 { chevron }

                    Menu {
                        ForEach(hiddenItems, id: \.id) { item in
                            Button(getDisplayName(for: item.name)) {
                                pane.navigate(to: item.url)
                            }
                        }
                    } label: {
                        Text("...")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .cornerRadius(4)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                
                ForEach(suffixItems, id: \.id) { item in
                    chevron
                    breadcrumbButton(for: item, isLast: item.id == items.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func breadcrumbButton(for item: (id: Int, name: String, url: URL), isLast: Bool) -> some View {
        Button(action: {
            pane.navigate(to: item.url)
        }) {
            HStack(spacing: 3) {
                Image(systemName: "folder.fill")
                    .foregroundColor(Color.accentColor.opacity(0.8))
                    .font(.system(size: 11))

                BreadcrumbTitle(activity: activity, text: getDisplayName(for: item.name), isLast: isLast)
            }
        }
        .buttonStyle(.plain)
        .layoutPriority(isLast ? 1 : 0)
    }

    /// 只订阅窗格活动状态的标题层：焦点切换仅重算这里，不牵连整个头部。
    private struct BreadcrumbTitle: View {
        let activity: PaneActivity
        let text: String
        let isLast: Bool

        var body: some View {
            Text(text)
                .foregroundColor(activity.isActive ? (isLast ? .primary : .secondary) : .secondary)
                .font(.system(size: 11.5, weight: isLast ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .foregroundColor(Color.gray.opacity(0.5))
            .font(.system(size: 9, weight: .bold))
    }

    private func getDisplayName(for name: String) -> String {
        let maxLength = 30
        if name.count > maxLength {
            return name.prefix(12) + "..." + name.suffix(12)
        }
        return name
    }

    // MARK: - 右侧按钮区域

    @ViewBuilder
    private var actionButtons: some View {
        // 更多操作（使用 Menu，固定尺寸防止重叠）
        Menu {
            Button("在 Finder 中打开") {
                NSWorkspace.shared.open(pane.currentDirectory)
            }
            Button("在终端中打开") {
                openInTerminal()
            }
            Divider()
            Button("拷贝路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    pane.currentDirectory.path(percentEncoded: false),
                    forType: .string
                )
            }
            Divider()
            Button("刷新") {
                pane.refresh()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 操作

    private func openInTerminal() {
        let path = pane.currentDirectory.path(percentEncoded: false)
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"cd \\\"\(path)\\\"\""
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}
