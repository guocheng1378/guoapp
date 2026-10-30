# 贡献指南

感谢关注真果鉴（zhenguojian）。本文面向想参与开发的贡献者；使用类问题请先查阅 [docs/FAQ.md](docs/FAQ.md)。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `lib/` | Flutter UI，手机 / TV / 桌面三端共用一套界面 |
| `native/core/` | Go 核心，编译为 c-shared 库：站源 provider、播放解析、下载、直播、榜单 |
| `native/sources/` | maccms 协议族站源实现（多个源共用一个协议包） |
| `test/` | Flutter 测试（Go 测试位于 `native/core/` 内） |
| `scripts/` | 构建、打包、测试矩阵脚本 |
| `docs/` | 架构与接口文档（编号架构文档、DEVELOPMENT、SOURCE-GUIDE、FAQ 等） |

## 开发环境

- Flutter 3.47.4（与 CI 一致）
- Go 1.27
- JDK 17 + Android SDK（platform 35/36、build-tools 36、NDK 28.2，用于核心交叉编译）
- Visual Studio 2022 Build Tools（Windows 桌面端）

## 双变体体系（重要）

项目有两套发布变体，包名相同、互相覆盖：

- **默认变体（红果鉴）**：单站源 `hongguo`，`ALL_SOURCES=false`
- **全源变体（真果鉴）**：全部站源，`ALL_SOURCES=true`

**铁律：Dart 侧 `--dart-define=ALL_SOURCES` 与 Go 核心编译戳（`scripts/build_native.py --all-sources`）必须同变体。** 两者不一致时应用会弹出「应用与原生核心的站源版本不一致」拦截页。构建、测试命令必须成对携带变体参数。

## 本地开发

```bash
flutter pub get
flutter analyze
flutter test                                    # 默认变体
flutter test --dart-define=ALL_SOURCES=true     # 全源变体
```

- 测试按「文件 × 变体」矩阵组织：`python scripts/test_matrix.py`（CI 门禁同一判据，退出码非 0 即有红）。
- 代码内用 `lib/app_build.dart` 的编译期常量 `allSourcesEnabled` 做变体分支。
- 新功能必须附带测试；先修红，再提交。
- 修改 `pubspec.yaml` 的版本号或依赖后，先 `flutter pub get` 刷新 `pubspec.lock` 再构建，锁文件随代码一并提交。

## Go 核心

```bash
cd native
go test ./core/...
```

- Go module 根是 `native/`，不是仓库根。
- 给 `provider.Drama` 增加需要到达 Dart 层的字段时，必须同步修改 `native/core/app_runtime.go` 中的 `nativeDrama` 结构与 `nativeNormalize` 透传，缺一处字段就会在序列化层被静默丢弃。
- 改动 Go 源码后重新打包必须重编 c-shared 库（`scripts/build_native.py`）；仅改 Dart 可复用旧核心库。

## 构建与打包

```bash
# Android（全源变体）
python scripts/build_native.py --platform android --all-sources
flutter build apk --release --split-per-abi --no-pub --dart-define=ALL_SOURCES=true
python scripts/package_release.py --platform android --all-sources

# Windows
python scripts/build_native.py --platform windows --all-sources
flutter build windows --release --no-pub --dart-define=ALL_SOURCES=true
python scripts/package_release.py --platform windows --all-sources
```

已知坑（Windows）：

- 项目路径含非 ASCII 字符时 Dart AOT（gen_snapshot）会失败，需经纯 ASCII 路径（如 junction）构建。
- `build_native.py` 需要 `PYTHONUTF8=1`。
- 打包后请核对产物内 flutter_assets 条目数与核心库是否为本次编译产物，增量构建偶发伪增量。

## 提交规范

- 只提交你本人改动的文件；多人或多会话共用工作区时，不要裹挟他人在途修改。
- commit message 一句话说明行为变化，中英文皆可。
- 不要提交构建产物、密钥、签名文件、个人配置与下载内容。

## 站源接入

新增站源走「登记 Spec → 实现 provider → 核心注册 → 测试 → 变体适配」流程，详见 [docs/SOURCE-GUIDE.md](docs/SOURCE-GUIDE.md)。

## AI 协作政策

允许使用 AI 辅助开发，但：

- AI 生成的改动必须经人类逐行复核后才能提交；
- 提交者对提交内容负全责；
- 明显由 AI 生成的批量改动，请在 PR 描述中注明。

## 许可证

本项目以 [GPL-3.0](LICENSE) 发布。提交代码即表示同意以同一许可证授权你的贡献。引入第三方代码前先确认许可证兼容性：GPL 系项目（Kazumi、FongMi/TV 等）可直接参考实现；MIT / Apache 项目需保留原始版权与许可声明。

## 文档地图

- `docs/README.md`：docs 目录导航（完整文档地图）
- `docs/` 编号架构文档（01–05）：分层、播放链路、下载、直播、CI/CD
- `docs/DEVELOPMENT.md`：开发环境与流程
- `docs/SOURCE-GUIDE.md`：站源接入指南
- `docs/duanju-platform-apis.md`：平台接口速查
- `docs/FAQ.md`：用户常见问题
- `CHANGELOG.md`：面向用户的版本变化摘要
