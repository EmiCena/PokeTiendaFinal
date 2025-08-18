# prepare_for_github.ps1
# Prepara repo: .gitignore + README, limpia __pycache__, primer commit y push.
# Uso:
#   .\prepare_for_github.ps1 -RepoUrl "https://github.com/Usuario/Repo.git" -Strategy rebase
#   .\prepare_for_github.ps1 -RepoUrl "https://github.com/Usuario/Repo.git" -Strategy force

param(
  [Parameter(Mandatory = $true)]
  [string]$RepoUrl,
  [ValidateSet('rebase','force')]
  [string]$Strategy = 'rebase',
  [string]$Branch = 'main'
)

$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

Write-Host "== Preparando repo para GitHub ==" -ForegroundColor Cyan

# 0) Checks
try { git --version | Out-Null } catch { throw "Git no está instalado o no está en PATH." }

# 1) .gitignore (si no existe, lo creamos)
$gitignoreContent = @"
# Python
__pycache__/
*.py[cod]
*$py.class

# Distribución
build/
dist/
*.egg-info/

# Entorno
.venv/
venv/
env/
ENV/
.env
.env.*

# SQLite / datos locales
instance/
*.sqlite
*.db
store.db
store.backup*.db

# Logs / backups
logs/
*.log
backups/
backup_*/

# Uploads (mantén marcador .gitkeep)
uploads/*
!uploads/.gitkeep

# Editor / SO
.DS_Store
Thumbs.db
.vscode/
.idea/
"@

if(-not (Test-Path ".gitignore")){
  Set-Content ".gitignore" $gitignoreContent -Encoding UTF8
  Write-Host "Creado .gitignore" -ForegroundColor Green
} else {
  Write-Host ".gitignore ya existe (ok)" -ForegroundColor Yellow
}

# 2) README.md básico (si no existe)
if(-not (Test-Path "README.md")){
  $readme = @"
# PokeTienda (Flask)

## Setup
- Python 3.10+
- Crear/activar entorno y deps:
  python -m venv .venv
  .\.venv\Scripts\Activate.ps1
  pip install -U pip
  pip install -r requirements.txt

## Correr
py app.py

## Migraciones packs
py -m scripts.migrations.upgrade_v12
py -m scripts.migrations.upgrade_v13_set_image

## Admin
py -m scripts.utils.make_admin --email "admin@local" --password "TuPass123"

Notas:
- La DB local (store.db) y uploads/ están ignorados por git.
"@
  Set-Content "README.md" $readme -Encoding UTF8
  Write-Host "Creado README.md" -ForegroundColor Green
} else {
  Write-Host "README.md ya existe (ok)" -ForegroundColor Yellow
}

# 3) Placeholder uploads
Ensure-Dir "uploads"
if(-not (Test-Path "uploads\.gitkeep")){ New-Item -ItemType File "uploads\.gitkeep" | Out-Null }

# 4) Limpieza de cachés
Write-Host "Limpiando __pycache__ y .pyc..." -ForegroundColor Cyan
Get-ChildItem -Recurse -Force -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Force -Include *.pyc,*.pyo -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# 5) Inicializa git si hace falta
if(-not (Test-Path ".git")){
  git init | Out-Null
  Write-Host "git init" -ForegroundColor Green
}

# 6) Rama principal
git branch -M $Branch | Out-Null

# 7) Remote origin
$existingRemote = ""
try { $existingRemote = (git config --get remote.origin.url) } catch {}

if([string]::IsNullOrWhiteSpace($existingRemote)){
  git remote add origin $RepoUrl
  Write-Host "Agregado remote origin: $RepoUrl" -ForegroundColor Green
} elseif ($existingRemote -ne $RepoUrl) {
  git remote set-url origin $RepoUrl
  Write-Host "Actualizado remote origin: $RepoUrl" -ForegroundColor Green
} else {
  Write-Host "Remote origin ya apunta a $RepoUrl (ok)" -ForegroundColor Yellow
}

# 8) Add + commit si hay cambios
$porcelain = (git status --porcelain)
if(-not [string]::IsNullOrWhiteSpace($porcelain)){
  git add .
  git commit -m "chore: initial repo setup (.gitignore, README, cleanup)"
  Write-Host "Commit inicial realizado" -ForegroundColor Green
} else {
  Write-Host "Sin cambios para commitear (ok)" -ForegroundColor Yellow
}

# 9) Determina si remoto tiene commits
$hasRemoteCommits = $false
try {
  $ls = (git ls-remote --heads origin $Branch)
  if(-not [string]::IsNullOrWhiteSpace($ls)){ $hasRemoteCommits = $true }
} catch { $hasRemoteCommits = $false }

# 10) Push según estrategia
if(-not $hasRemoteCommits){
  Write-Host "Remoto vacío: push inicial" -ForegroundColor Cyan
  git push -u origin $Branch
  Write-Host "Listo: push inicial completado" -ForegroundColor Green
} else {
  if($Strategy -eq 'rebase'){
    Write-Host "Remoto tiene commits → integrando (rebase)..." -ForegroundColor Cyan
    git fetch origin
    # Intenta rebase; si falla por historiales no relacionados, intenta pull con allow-unrelated-histories
    $rebaseOk = $true
    try {
      git pull --rebase origin $Branch
    } catch {
      $rebaseOk = $false
    }
    if(-not $rebaseOk){
      Write-Host "Rebase falló, intentando merge con historiales no relacionados..." -ForegroundColor Yellow
      git pull origin $Branch --allow-unrelated-histories
    }
    # Commit adicional si quedaron merges
    $porcelain2 = (git status --porcelain)
    if(-not [string]::IsNullOrWhiteSpace($porcelain2)){ git add .; git commit -m "chore: merge remote main" }
    git push -u origin $Branch
    Write-Host "Listo: push con rebase/merge completado" -ForegroundColor Green
  } else {
    Write-Host "Estrategia: sobrescribir remoto (force-with-lease)" -ForegroundColor Yellow
    git push -u origin $Branch --force-with-lease
    Write-Host "Listo: push forzado completado" -ForegroundColor Green
  }
}

Write-Host "`nTodo OK. Revisa tu repo en: $RepoUrl" -ForegroundColor Cyan