"""分文件实测测试红名单（CI 门禁与本地共用同一判据）。

每个测试文件按变体单独跑 `flutter test`，逐行输出
`RESULT|<变体>|<文件>|<退出码>`，最后汇总红名单。

用法：
  python scripts/test_matrix.py                          # 全量双变体
  python scripts/test_matrix.py --only widget_test.dart  # 单文件复测
  python scripts/test_matrix.py --variant all            # 只跑全源变体

退出码：红名单为空 0；非空 1（门禁语义，CI 直接以此阻断）。
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = {'default': [], 'all': ['ALL_SOURCES=true']}


def flutter_command() -> str:
    if shutil.which('flutter'):
        return 'flutter'
    for candidate in (Path('C:/flutter/bin/flutter.bat'),):
        if candidate.is_file():
            return str(candidate)
    raise SystemExit('找不到 flutter 命令：PATH 与常见安装位置均未命中')


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description='分文件实测测试红名单')
    parser.add_argument('--only', help='只跑指定测试文件名')
    parser.add_argument(
        '--variant', choices=[*VARIANTS, 'both'], default='both',
        help='变体选择：default / all / both（默认 both）',
    )
    options = parser.parse_args()

    files = sorted((ROOT / 'test').glob('*_test.dart'))
    if options.only:
        files = [path for path in files if path.name == options.only]
        if not files:
            parser.error('找不到测试文件：' + options.only)
    wanted = (
        VARIANTS.items() if options.variant == 'both'
        else [(options.variant, VARIANTS[options.variant])]
    )

    failing: list[tuple[str, str, str]] = []
    for path in files:
        for name, defines in wanted:
            command = [
                flutter_command(), 'test', path.as_posix(),
                '--no-pub', '--reporter', 'compact',
                '--dart-define=DISABLE_REMOTE_IMAGES=true',
                *(f'--dart-define={define}' for define in defines),
            ]
            completed = subprocess.run(
                command, cwd=ROOT, capture_output=True,
                text=True, encoding='utf-8', errors='replace',
            )
            print(f'RESULT|{name}|{path.name}|{completed.returncode}', flush=True)
            if completed.returncode != 0:
                failing.append((name, path.name, completed.stdout[-4000:]))
    for _, _, tail in failing:
        print(tail, file=sys.stderr)

    if failing:
        print('红名单（CI 阻断）：')
        for name, filename, _ in failing:
            print(f'  - {filename} ({name})')
        return 1
    print('红名单为空：全部测试通过。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
