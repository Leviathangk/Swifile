# Swifile

macOS 双窗格文件管理器，SwiftUI + AppKit 混合实现。

## 功能特性

- **多窗格布局**：单窗格 / 双窗格 / 四窗格 / 一加二，各窗格独立导航
- **三种视图**：图标（宫格）、列表（支持行内展开目录）、分栏（Miller columns）
- **可编辑路径栏**：面包屑逐级点击跳转；点击路径右侧空白处或按 ⌘L 直接输入路径（支持 `~`、相对路径和带引号路径）
- **侧边栏**：收藏（设置里自选，至少 1 项）、硬盘、快速访问（拖入文件或文件夹即添加引用）、暂存区（拖入收集，多选后复制/移动到活动窗格，也可拖出）
- **搜索与排序**：即时过滤；按名称 / 大小 / 日期 / 类型排序，目录优先
- **右键菜单**：访达风格常用操作（打开、拷贝、移到废纸篓、添加到快速访问 / 暂存区、在终端打开）
- **主题**：跟随系统 / 浅色 / 深色（设置窗口切换）

## 环境要求

- macOS 14+
- Xcode 16+（或 Xcode Command Line Tools）
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（用于生成工程文件）

## 构建与运行

工程文件不入库，由 `project.yml` 生成：

```bash
brew install xcodegen
xcodegen generate
open Swifile.xcodeproj    # Xcode 内 Cmd+R 运行
```

不装 xcodegen 也可以直接编译出一个可执行文件：

```bash
swiftc -O -module-name Swifile -o Swifile $(find Swifile -name '*.swift')
```

## 目录结构

| 路径 | 内容 |
|---|---|
| `Swifile/App` | 应用入口与主窗口装配 |
| `Swifile/Models` | 状态与数据模型（窗格状态、快速访问、暂存区、外观） |
| `Swifile/Helpers` | 目录读取 / 缓存 / 图标 / 文件操作等基础能力 |
| `Swifile/Views` | 界面：工具栏、侧边栏、窗格（三种视图）、状态栏、设置 |
| `SwifileTests` | 单元测试（目录引擎） |
| `project.yml` | xcodegen 工程定义 |

## 架构要点

- 目录枚举在后台线程产出不可变快照（`DirectorySnapshot`），UI 只消费快照，读写分离
- 相同目录请求合并 + 快照缓存 + 目录监听失效（`DirectoryLoadCoordinator` / `DirectorySnapshotCache` / `DirectoryMonitor`）
- 列表视图用 NSTableView 桥接实现「按下即选中」（SwiftUI List/Table 的选中要等 mouseUp 才提交）
- 图标加载区分窗格优先级：非活动窗格只保留占位图，避免后台窗格抢占导航

## 性能自检

环境变量 `SWIFILE_PERF_BENCH=1` 启动应用即运行基准并自动退出，覆盖 4000 项冷加载、缓存命中、过滤排序、窗格冷加载、搜索、连续选择、四窗格切换等门禁：

```bash
SWIFILE_PERF_BENCH=1 ./Swifile
```

## 许可证

本项目采用 [PolyForm Noncommercial License 1.0.0](LICENSE)，仅允许非商业用途。

商业使用需要获得作者书面授权，具体说明见 [商业授权](COMMERCIAL_LICENSE.md)。

> 注意：这是 source-available 许可，不是 OSI 定义的开源许可证。源码公开不等于允许商业使用。
