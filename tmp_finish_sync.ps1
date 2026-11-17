$ErrorActionPreference = 'Continue'
Set-Location 'c:\Users\Administrator\Desktop\新建文件夹 (2)\guoapp'
$env:PYTHONUTF8 = '1'
Write-Output '=== FINISH_TASK ==='
& python scripts/finish_task.py --message "remove seller QQ contact card, feedback via web area; redfruit DNS-pollution POST retry; updater dialog scrollable" 2>&1
Write-Output ('FINISH_EXIT=' + $LASTEXITCODE)
Write-Output '=== SYNC_SOURCE CHECK ==='
& python scripts/sync_source.py --check 2>&1
Write-Output ('SYNC_EXIT=' + $LASTEXITCODE)
Write-Output '=== DONE ==='
