# start_project.ps1
# Prepara entorno, corre migraciones y levanta la app.
# Uso ejemplos:
#   .\start_project.ps1
#   .\start_project.ps1 -AdminEmail "admin@local" -AdminPassword "TuPass123" -SeedDemo
#   .\start_project.ps1 -Port 5001 -OpenBrowser

param(
  [string]$AdminEmail = "",
  [string]$AdminPassword = "",
  [switch]$SeedDemo,
  [switch]$OpenBrowser,
  [int]$Port = 5000
)

$ErrorActionPreference = "Stop"

function step($msg){ Write-Host "== $msg ==" -ForegroundColor Cyan }
function ok($msg){ Write-Host $msg -ForegroundColor Green }
function warn($msg){ Write-Host $msg -ForegroundColor Yellow }

# 0) Verifica Python
step "Verificando Python"
try { & py --version | Out-Null; $pyLauncher = "py" }
catch {
  try { & python --version | Out-Null; $pyLauncher = "python" }
  catch { throw "No se encontró Python. Instálalo y reintenta." }
}
ok "Python OK"

# 1) Crea venv si falta
step "Creando/validando entorno virtual (.venv)"
if(-not (Test-Path ".venv\Scripts\python.exe")){
  & $pyLauncher -m venv .venv
  ok "Entorno virtual creado"
} else { ok "Entorno virtual existente" }

# 2) Python del venv
$PY = Join-Path $PWD ".venv\Scripts\python.exe"
if(-not (Test-Path $PY)){ throw "No se encontró $PY" }

# 3) Instala deps
step "Instalando dependencias"
& $PY -m pip install -U pip setuptools wheel
if(Test-Path "requirements.txt"){
  & $PY -m pip install -r requirements.txt
} else {
  warn "No hay requirements.txt; instalando mínimos"
  & $PY -m pip install Flask Flask-Login Flask-WTF Flask-SQLAlchemy SQLAlchemy email-validator requests
}
ok "Dependencias listas"

# 4) Asegura carpetas
if(-not (Test-Path "uploads")){ New-Item -ItemType Directory -Force -Path "uploads" | Out-Null }
if(-not (Test-Path "logs")){ New-Item -ItemType Directory -Force -Path "logs" | Out-Null }

# 5) Migraciones (si existen)
step "Ejecutando migraciones"
if(Test-Path "scripts\migrations\upgrade_v12.py"){
  & $PY -m scripts.migrations.upgrade_v12
} else { warn "upgrade_v12.py no encontrado (ok si ya corriste antes)" }
if(Test-Path "scripts\migrations\upgrade_v13_set_image.py"){
  & $PY -m scripts.migrations.upgrade_v13_set_image
} else { warn "upgrade_v13_set_image.py no encontrado (ok si ya corriste antes)" }
ok "Migraciones aplicadas"

# 6) Crear admin (opcional)
if($AdminEmail -and $AdminPassword){
  step "Creando/actualizando admin"
  if(Test-Path "scripts\utils\make_admin.py"){
    & $PY -m scripts.utils.make_admin --email $AdminEmail --password $AdminPassword
    ok "Admin listo: $AdminEmail"
  } else {
    warn "scripts/utils/make_admin.py no existe. Omite creación de admin."
  }
}

# 7) Seed demo (opcional)
if($SeedDemo){
  step "Sembrando datos demo"
  if(Test-Path "scripts\utils\seed_demo.py"){
    & $PY -m scripts.utils.seed_demo
    ok "Seed demo completado"
  } else {
    warn "scripts/utils/seed_demo.py no existe. Omite seed."
  }
}

# 8) Levantar la app
step "Levantando la app"
$env:PORT = $Port  # tu app puede ignorarlo si no usa PORT; no pasa nada
if($OpenBrowser){ Start-Process "http://localhost:$Port" | Out-Null }
& $PY app.py