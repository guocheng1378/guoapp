package all

// 已迁移为 bundled JS 模块的站源，其内置 Go 实现已物理删除，由 JS 模块按同 id
// 接管（fanguo / heguo / maoguo / xingguo / yaguo / yunzhui / maccmsweb）。
// 仅保留仍由 Go 提供实现的 maccmsapi（视频类源）。
import (
	_ "duanjuapp/native/sources/maccmsapi"
)
