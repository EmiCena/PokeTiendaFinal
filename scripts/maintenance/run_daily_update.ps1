# scripts/maintenance/run_daily_update.ps1
param([int]$Limit=300)
$ErrorActionPreference = "Stop"
$proj = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$python = Join-Path $proj ".venv\Scripts\python.exe"
if(-not (Test-Path $python)){ $python = "python" }
$logDir = Join-Path $proj "logs"; if(-not (Test-Path $logDir)){ New-Item -ItemType Directory $logDir | Out-Null }
$log = Join-Path $logDir ("market_update_" + (Get-Date -f "yyyyMMdd") + ".log")
Push-Location $proj
try{
  "=== $(Get-Date -f "yyyy-MM-dd HH:mm:ss") START ===" | Out-File -FilePath $log -Append -Encoding utf8
  & $python -m scripts.maintenance.update_market_prices --limit $Limit 2>&1 | Tee-Object -FilePath $log -Append
  "=== $(Get-Date -f "yyyy-MM-dd HH:mm:ss") END ===`r`n" | Out-File -FilePath $log -Append -Encoding utf8
}catch{
  "ERROR: $($_.Exception.Message)" | Out-File -FilePath $log -Append -Encoding utf8
}finally{
  Pop-Location
}
