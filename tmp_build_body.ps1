$ErrorActionPreference = 'Continue'
$env:PATH = 'C:\flutter\bin;C:\go\bin;' + $env:PATH
$env:PYTHONUTF8 = '1'
Set-Location 'c:\Users\Administrator\Desktop\新建文件夹 (2)\guoapp'
Write-Output ('FLUTTER=' + (Get-Command flutter -ErrorAction SilentlyContinue).Source)
& python scripts/build_android.py --cn-mirrors --all-sources 2>&1
Write-Output ('=== BUILD_EXIT=' + $LASTEXITCODE + ' ===')