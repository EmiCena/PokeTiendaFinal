# tidy_repo.ps1
$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(!(Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# Carpetas de destino
Ensure-Dir "scripts"
Ensure-Dir "scripts\migrations"
Ensure-Dir "scripts\maintenance"
Ensure-Dir "scripts\patches"

# Migrations (upgrade)
Get-ChildItem -File -Filter "upgrade_*.py" | Move-Item -Destination "scripts\migrations" -Force -ErrorAction SilentlyContinue

# Mantenimientos y seeds/imports/fixes
$maint = @(
  "fix_*.py",
  "seed*.py",
  "import_tcg_api.py",
  "fix_*",            # por si quedaron sin extensión por error
  "seed*",            # idem
  "import_tcg_api"    # idem
)
foreach($pat in $maint){
  Get-ChildItem -File -Filter $pat -ErrorAction SilentlyContinue |
    Move-Item -Destination "scripts\maintenance" -Force -ErrorAction SilentlyContinue
}

# Parches PowerShell
Get-ChildItem -File -Filter "patch*.ps1" -ErrorAction SilentlyContinue |
  Move-Item -Destination "scripts\patches" -Force -ErrorAction SilentlyContinue

Write-Host "Listo. Archivé scripts en /scripts. No se borró nada." -ForegroundColor Green
Write-Host "Raíz limpia: app.py, models.py, services/, ai/, templates/, static/, requirements.txt"