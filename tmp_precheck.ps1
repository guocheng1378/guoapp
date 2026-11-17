$ErrorActionPreference = 'Continue'
Set-Location 'c:\Users\Administrator\Desktop\新建文件夹 (2)\guoapp'
Write-Output '=== VERSION ==='
Select-String -Path pubspec.yaml -Pattern '^version:' | Select-Object -First 1
Write-Output '=== BRANCH / HEAD ==='
git branch --show-current
git log -1 --format='%H %s'
Write-Output '=== STATUS (all) ==='
git status --short
Write-Output '=== GH AUTH ==='
& gh auth status 2>&1 | Select-Object -First 8
Write-Output '=== ADB ==='
& 'C:\android-tools\android-sdk\platform-tools\adb.exe' devices 2>$null
Write-Output '=== DIST 2280 APKs ==='
Get-ChildItem 'dist\android\zhenguojian-0.2.96+2280-*.apk' -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTime
Write-Output ('=== PRECHECK_DONE ===')
