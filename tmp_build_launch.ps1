$ErrorActionPreference = 'Continue'
$log = 'c:\Users\Administrator\Desktop\新建文件夹 (2)\guoapp\tmp_build_2281.log'
if (Test-Path $log) { Remove-Item $log -Force }
$ps = @'
$ErrorActionPreference = 'Continue'
$env:PATH = 'C:\flutter\bin;C:\go\bin;' + $env:PATH
$env:PYTHONUTF8 = '1'
Set-Location 'c:\Users\Administrator\Desktop\新建文件夹 (2)\guoapp'
Write-Output ('FLUTTER=' + (Get-Command flutter -ErrorAction SilentlyContinue).Source)
& python scripts/build_android.py --cn-mirrors --all-sources 2>&1
Write-Output ('=== BUILD_EXIT=' + $LASTEXITCODE + ' ===')
'@
$scriptPath = 'c:\Users\Administrator\Desktop\新建文件夹 (2)\guoapp\tmp_build_body.ps1'
[System.IO.File]::WriteAllText($scriptPath, $ps, (New-Object System.Text.UTF8Encoding($false)))
$p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
Write-Output ('BUILD_PID=' + $p.Id)
Write-Output 'LAUNCH_DONE'
