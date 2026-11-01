# guoapp 发行台账（Release Ledger）

记录每次发布的 build 号对应的**改动层 / 构建路径 / 摘要**，使版本号可追溯到"这次改了哪一层"，并据此选择正确的构建路径（防漏编 Go）。

类型标签：
- `[Go]`：改动了 `native/` 下的 Go 核心（provider / core）。**必须走 `build_zhen.ps1` 全流水线**重编 `.so/.dll`。
- `[Dart]`：仅 `lib/` 逻辑层改动（core_bridge / repository / models 等）。可走 `step2` 快线。
- `[UI]`：仅 `lib/` UI 层改动（ui / glass / fog / theme / player_controls / *screen / *menu 等）。可走 `step2` 快线。
- `[快线]`：仅配置 / 资源 / 脚本小修（无 native、无 lib）。可走 `step2` 快线。

本台账由 `C:\cmake-src\release_tracker.ps1` 在发版时自动追加（用法：发版前确保代码改动已在工作区，运行 `powershell -File release_tracker.ps1`，可选 `-DryRun` 预览、`-Type` 强制指定类型、`-Base <ref>` 指定 diff 基线）。历史发布记录详见 git tag。

<!-- entries below are appended by release_tracker.ps1 -->
