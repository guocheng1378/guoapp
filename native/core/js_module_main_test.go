package core

import (
	"os"
	"testing"
)

// TestMain 关掉测试期的内置模块装配。
//
// 内置模块接管内置采集站（同一个 id 由 JS 模块提供），会改写全局 provider
// 注册表；既有用例验证的是内置 Go 实现的行为，测试期不装配内置模块，
// 避免全局状态互相污染。内置模块自身的行为由 js_module_bundled_test.go
// 直接调用函数验证。
func TestMain(m *testing.M) {
	jsModuleBundledEnabled = false
	// 安装包不再内嵌模块（bundled/ 只留在仓库里），但测试仍要验证各模块的
	// 清单与脚本，这里把内置模块文件系统指回源码目录。
	bundledJSModulesFS = os.DirFS("bundled")
	os.Exit(m.Run())
}
