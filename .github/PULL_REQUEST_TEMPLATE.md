## 改动说明

<!-- 一句话概括行为变化；修复的 issue 用 Fixes #编号 关联 -->

## 变更范围

<!-- 改了哪些模块：lib/ · native/core · native/sources · scripts · docs … -->

## 自查清单

- [ ] `flutter analyze` 无 error
- [ ] 相关测试已更新，默认变体 `flutter test` 通过
- [ ] 全源变体 `flutter test --dart-define=ALL_SOURCES=true` 通过（涉 Go 时另跑 `cd native && go test ./core/...`）
- [ ] 新功能附带测试；先修红，再提交
- [ ] 只包含本人改动，未裹挟他人在途修改
- [ ] 未提交构建产物、密钥、签名文件、个人配置
- [ ] 若改了 `pubspec.yaml`，`pubspec.lock` 已刷新并随代码一并提交

## AI 辅助说明

<!-- 明显由 AI 生成的批量改动请在此注明；纯人工可删除本节 -->
