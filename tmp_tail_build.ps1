$ErrorActionPreference = 'Continue'
$log = 'c:\Users\Administrator\Desktop\新建文件夹 (2)\guoapp\tmp_build_2281.log'
$err = "$log.err"
$proc = Get-Process -Id 3820 -ErrorAction SilentlyContinue
Write-Output ('PROC_ALIVE=' + [bool]$proc)
Write-Output '=== STDOUT TAIL ==='
if (Test-Path $log) { Get-Content $log -Tail 30 -Encoding UTF8 }
Write-Output '=== STDERR TAIL ==='
if (Test-Path $err) { Get-Content $err -Tail 15 -Encoding UTF8 }
Write-Output '=== DONE ==='
