# Swifile 项目说明（给 AI 协作者）

原生 macOS 文件管理器：SwiftUI + AppKit，多窗格、三种视图、暂存区、快速访问。
许可证是 PolyForm Noncommercial 1.0.0（个人/非商业免费，商用需授权）。

## 目录约定

| 路径 | 说明 |
|---|---|
| `Swifile/` | 应用源码（App / Helpers / Models / Views / Resources） |
| `SwifileTests/` | XCTest |
| `project.yml` | XcodeGen 工程定义，`.xcodeproj` 不入库 |
| `build/` | 全部构建产物，已 gitignore |
| `scripts/` | 本地开发脚本，**暂不入库**（见下） |
| `docs/` `demo/` | 本地资料，已 gitignore |

## 关键约束

- **本机 `xcodebuild` 不可用**：Xcode 的 `IDESimulatorFoundation` 插件符号缺失
  （`Symbol not found: DVTDownloads...`）。构建/测试一律走 `xcrun swiftc` 或 `scripts/`。
- 部署目标 macOS 14.0，只出 arm64，`SWIFT_VERSION 5.9`，`SWIFT_STRICT_CONCURRENCY complete`。
- Bundle ID `com.swifile.app`。
- `scripts/` 里有 `dev.sh` / `test.sh`，**用户明确要求暂不入库**，改动它们时不要 `git add`。

## 编译

改完代码先做类型检查（最快，几秒）：

```bash
xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-macos14.0 \
  -module-name Swifile $(find Swifile -name '*.swift')
```

跑单测：

```bash
./scripts/test.sh     # 手工构建 XCTest bundle，绕开 xcodebuild
```

本地跑起来看效果：

```bash
./scripts/dev.sh              # 构建 build/dev/Swifile.app 并启动
./scripts/dev.sh --build-only # 只构建
./scripts/dev.sh --debug      # -Onone -g，可断点
```

日志：`build/dev/Swifile.log` / `build/dev/Swifile.err`。

> `swiftc` 只做语法与类型检查，**不验证运行时行为**。涉及焦点、编辑器、动画这类
> 看不见摸不着的交互，必须实际跑起来验证，不要凭代码推断就交差。

## 发布

按顺序做，别跳步。

### 1. 升版本号

三处必须同步：

| 文件 | 位置 |
|---|---|
| `Swifile/Info.plist` | `CFBundleShortVersionString`（如 `1.3.0`）、`CFBundleVersion`（build 号，递增） |
| `README.md` | 「下载与安装」里的 `当前版本：...` |
| `CHANGELOG.md` | 新增 `## <版本>` 章节 |

`CHANGELOG.md` 的写法：先一句话说这次更新解决什么问题，再按功能分小节列条目。
发布时把该章节内容复制一份作为 GitHub Release 正文。

### 2. 提交

提交信息照仓库既有风格：中文、第一行说**为什么改**，空行后列改了什么。
发布提交单独一条，形如 `发布 1.3.0：<一句话概括>`。

### 3. 打包 DMG

```bash
REL=build/release
APP="$REL/Swifile.app"
rm -rf "$REL" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 二进制
xcrun swiftc -O -j 6 -swift-version 5 -target arm64-apple-macos14.0 \
  -module-name Swifile -o "$APP/Contents/MacOS/Swifile" \
  $(find Swifile -name '*.swift' -type f | sort)

# Info.plist 里是 Xcode 变量，发布包要展开成真实值
PLIST="$APP/Contents/Info.plist"
cp Swifile/Info.plist "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion zh-Hans' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Swifile' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.swifile.app' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Swifile' "$PLIST"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :LSApplicationCategoryType string public.app-category.utilities' "$PLIST" >/dev/null 2>&1 || true

# 图标从 assets 现生成，不依赖 build/manual 模板
ICONSET="$REL/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
cp Swifile/Resources/Assets.xcassets/AppIcon.appiconset/*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# 签名 + 校验
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# DMG
STAGE="$REL/dmg-staging"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Swifile" -srcfolder "$STAGE" -ov -format UDZO \
  build/Swifile-<版本>.dmg
shasum -a 256 build/Swifile-<版本>.dmg > build/Swifile-<版本>.dmg.sha256
```

### 4. 验证 DMG

挂载后核对版本与签名，再安装：

```bash
hdiutil attach build/Swifile-<版本>.dmg -nobrowse -readonly
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Volumes/Swifile/Swifile.app/Contents/Info.plist
codesign --verify --deep --strict /Volumes/Swifile/Swifile.app
```

### 5. 安装到本机

```bash
pkill -f '/Applications/Swifile.app/Contents/MacOS/Swifile' || true
rm -rf /Applications/Swifile.app
cp -R /Volumes/Swifile/Swifile.app /Applications/
hdiutil detach /Volumes/Swifile
open -n /Applications/Swifile.app
```

替换后系统权限（桌面/文稿/下载）需要重新授权一次，属正常现象。

### 6. 推送与发布

```bash
git push origin main

gh release create v<版本> \
  --title "Swifile <版本>" \
  --notes-file <正文文件> \
  build/Swifile-<版本>.dmg \
  build/Swifile-<版本>.dmg.sha256
```

标签命名沿用 `v1.2.0` 这种形式。Release 正文结构照上一版：
更新内容分节 → `## 下载` 列出两个附件 → 末尾保留 Gatekeeper 说明
（当前是 ad-hoc 本地签名，未做 Developer ID 公证）。

## 已知陷阱

| 现象 | 原因 / 做法 |
|---|---|
| `xcodebuild` 直接报插件加载失败 | 本机 Xcode 坏了，用 `swiftc` 或 `scripts/` |
| 改了 UI 交互就交付 | 不行。必须实际验证。做法：写一个临时探针程序，用真实视图（如 `FileTableView` + `PaneState`）建窗口，`NSApp.run()` 跑事件循环，再打印几何数值 / 出图 / 打印菜单项。`swiftc` 把 `Swifile/*.swift`（排除 `SwifileApp.swift`）和探针一起编译即可 |
| 新增右键菜单项只加了一处 | 顺序与分组统一在 `FileMenuLayout`（`FileActions.swift`），四处在读它 |
| 新建文件夹后改名被打断 | 改名框是挂在 `clipView` 上的浮层，不要挂回 `tableView` |
| 改名的文字位置有 1pt 跳动 | 输入框左边缘取 `labelRect.minX - 4`，这个 4 是 `NSTextFieldCell` 的文字内缩，量出来的 |
