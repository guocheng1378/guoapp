#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验「红果源对齐上游」改动是否进入 libduanju_core.so。

用法:
    python scripts/check_so.py <apk 或 libduanju_core.so> [...]
    python scripts/check_so.py --dart <apk>      # 顺带查 libapp.so 里的 feed 字符串

说明:
    用纯 ASCII 关键字，避开 PowerShell/GBK 中文编码坑。
    退出码: 0=全部命中; 1=有缺失; 2=没有找到 libduanju_core.so。

对照用法:
    对上一版(未含本次改动)的 .so 跑一次，应当全部 MISSING，可验证脚本与数据有效。
"""

import sys
import zipfile

# 本次改动独有、且只可能出现在新代码里的字符串(全部 ASCII)。
CORE_NEEDLES = [
    b"hongguo-helper",                          # 主/辅双设备请求 lane
    b"helperDeviceId",                          # 双设备持久化字段(JSON tag)
    b"/reading/bookapi/bookmall/tab/v1/",       # feed 推荐入口
    b"/reading/bookapi/new_category/landing/v/",  # 题材标签接口
    b"tag:cate_",                               # 题材分类前缀/正则
]

# Dart 侧(feed chip)关键字，AOT 字符串编码不固定，两种编码都试。
DART_NEEDLES = ["home_feed", "find_drama"]


def scan_core(label, data):
    print("%s  %d bytes" % (label, len(data)))
    found = {}
    for needle in CORE_NEEDLES:
        hit = data.find(needle) >= 0
        found[needle] = hit
        print("    %-40s %s" % (needle.decode(), "FOUND" if hit else "MISSING"))
    return found


def scan_dart(label, data):
    print("%s  (Dart)  %d bytes" % (label, len(data)))
    for text in DART_NEEDLES:
        hit = data.find(text.encode("utf-8")) >= 0 or data.find(text.encode("utf-16-le")) >= 0
        print("    %-40s %s" % (text, "FOUND" if hit else "MISSING"))


def main(argv):
    dart = False
    targets = []
    for arg in argv:
        if arg == "--dart":
            dart = True
        else:
            targets.append(arg)
    if not targets:
        print(__doc__)
        return 2

    overall = {needle: False for needle in CORE_NEEDLES}
    core_files = 0
    dart_files = 0

    for target in targets:
        try:
            if target.lower().endswith(".apk"):
                zip_file = zipfile.ZipFile(target)
                for name in zip_file.namelist():
                    if name.endswith("libduanju_core.so"):
                        core_files += 1
                        for key, val in scan_core(name, zip_file.read(name)).items():
                            overall[key] = overall[key] or val
                    elif dart and name.endswith("libapp.so"):
                        dart_files += 1
                        scan_dart(name, zip_file.read(name))
            else:
                data = open(target, "rb").read()
                core_files += 1
                for key, val in scan_core(target, data).items():
                    overall[key] = overall[key] or val
        except OSError as error:
            print("ERROR: %s (%s)" % (target, error))

    if core_files == 0:
        print("no libduanju_core.so found")
        return 2

    missing = [needle.decode() for needle, ok in overall.items() if not ok]
    if missing:
        print("\nFAIL: missing %s" % ", ".join(missing))
        return 1

    print("\nOK: 全部关键字命中 (core files=%d%s)" % (
        core_files, ", dart files=%d" % dart_files if dart else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
