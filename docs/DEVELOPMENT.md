# 开发指南

面向参与开发的贡献者：环境准备、双变体体系、常用命令与流程速查。架构与实现细节见 [docs 导航](README.md)。

> 旧版开发手册（停留在 v0.2.87 时代）已归档至 [archive/DEVELOPMENT-v0.2.87-snapshot.md](archive/DEVELOPMENT-v0.2.87-snapshot.md)，仅供考古，勿作为当前依据。

## 环境要求

| 组件 | 要求 |
|---|---|
| Flutter | 3.47+（含 Dart） |
| Go | 1.27+ |
| JDK | 17 |
| Android | SDK（API 35+）+ NDK |
| Windows 桌面 | Visual Studio 2022 Build Tools（含 C++ 工作负载） |

> 提示：项目路径含中文或空格时，Flutter AOT（Android）构建可能失败，建议将仓库检出到纯 ASCII 路径。

## 双变体体系

| 变体 | 构建条件 | 站源范围 |
|---|---|---|
| 真果鉴 | `--dart-define=ALL_SOURCES=true` | 25 源（全量） |
| 红果鉴 | 不传该参数 | 默认单源（红果） |

两个变体共用同一包名、互相覆盖安装；**测试与 CI 均按双变体运行**，改动需在两个变体下同时验证。

## 常用命令

```bash
# 安装依赖
flutter pub get

# 构建 Android（真果鉴 = 全源变体；三个 ABI 分包）
flutter build apk --release --split-per-abi --dart-define=ALL_SOURCES=true

# 构建 Windows
flutter build windows --dart-define=ALL_SOURCES=true

# 一键打包（校验产物、按 {名称-版本-ABI} 命名）
python scripts/package_release.py --platform android --all-sources

# Go 核心：编译检查与测试（在 native 目录）
go build ./core
go test ./core/...

# Flutter 测试（双变体）
flutter test
flutter test --dart-define=ALL_SOURCES=true

# 双变体全量门禁（与 CI 同判据）
python scripts/test_matrix.py
```

> Go 原生核心需先行编译并打进应用；Android / Windows 交叉编译细节见 [05_项目运行与构建.md](05_项目运行与构建.md)。

## 开发流程

1. 阅读 [CONTRIBUTING.md](../CONTRIBUTING.md)（提交规范、AI 协作约定、测试要求）；
2. 涉及站源逻辑先看 [SOURCE-GUIDE.md](SOURCE-GUIDE.md)（Provider 契约与五步接入）；
3. 提交前完成双变体测试与 `flutter analyze`（0 error 基线）；
4. 面向用户的版本变化同步更新根目录 [CHANGELOG.md](../CHANGELOG.md)。
