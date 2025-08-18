# backoffice.ps1
# Crea un Django Admin (djsite/) usando store.db sin tocar Flask.
$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# 0) Chequeos
if(-not (Test-Path "app.py")){ Write-Error "Ejecuta este script en la raiz del proyecto (donde esta app.py)."; exit 1 }
$proj = (Get-Location).Path
$py = Join-Path $proj ".venv\Scripts\python.exe"
if(-not (Test-Path $py)){ $py = "python" }

# 1) Instalar Django
Write-Host "Instalando Django..." -ForegroundColor Cyan
& $py -m pip install "Django>=5,<6" | Out-Null

# 2) Crear proyecto djsite si no existe
if(-not (Test-Path "djsite")){
  Write-Host "Creando proyecto Django (djsite)..." -ForegroundColor Cyan
  & $py -m django startproject djsite | Out-Null
} else { Write-Host "djsite/ ya existe (ok)." }

# 3) Crear app backoffice si no existe
Push-Location djsite
if(-not (Test-Path "backoffice")){
  Write-Host "Creando app backoffice..." -ForegroundColor Cyan
  & $py manage.py startapp backoffice | Out-Null
} else { Write-Host "backoffice/ ya existe (ok)." }

# 4) Escribir settings.py completo apuntando a store.db (raiz)
$settings = @'
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = "dev-change-me"
DEBUG = True
ALLOWED_HOSTS = ["127.0.0.1", "localhost"]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "backoffice",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "djsite.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "djsite.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR.parent / "store.db",
    }
}

LANGUAGE_CODE = "es-es"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
DEFAULT_AUTO_FIELD = "django.db.models.AutoField"
'@
# backup si ya existía
if(Test-Path "djsite\settings.py"){ Copy-Item "djsite\settings.py" ("settings.backup_" + (Get-Date -f "yyyyMMdd_HHmmss") + ".py") }
Set-Content "djsite\settings.py" $settings -Encoding UTF8
Write-Host "settings.py escrito." -ForegroundColor Green

# 5) urls.py con admin
$urls = @'
from django.contrib import admin
from django.urls import path

urlpatterns = [
    path("admin/", admin.site.urls),
]

admin.site.site_header = "PokeShop Admin"
admin.site.site_title = "PokeShop Admin"
admin.site.index_title = "Panel de control"
'@
Set-Content "djsite\urls.py" $urls -Encoding UTF8
Write-Host "urls.py escrito." -ForegroundColor Green

# 6) Generar modelos (inspectdb) para todas las tablas y forzar managed=False
Write-Host "Generando modelos (inspectdb)..." -ForegroundColor Cyan
$inspect = & $py manage.py inspectdb
Set-Content "backoffice\models.py" $inspect -Encoding UTF8
# Fuerza managed=False
$modelsTxt = Get-Content "backoffice\models.py" -Raw
$modelsTxt = $modelsTxt -replace "managed\s*=\s*True", "managed = False"
Set-Content "backoffice\models.py" $modelsTxt -Encoding UTF8
Write-Host "Modelos generados (managed=False)." -ForegroundColor Green

# 7) Registrar todos los modelos del app en Admin
$adminAuto = @'
from django.contrib import admin
from django.apps import apps
from django.contrib.admin.sites import AlreadyRegistered

app = apps.get_app_config("backoffice")
for model in app.get_models():
    try:
        admin.site.register(model)
    except AlreadyRegistered:
        pass
'@
Set-Content "backoffice\admin.py" $adminAuto -Encoding UTF8
Write-Host "admin.py (auto-registro) creado." -ForegroundColor Green

# 8) Migraciones propias de Django y superusuario
Write-Host "Aplicando migraciones de Django..." -ForegroundColor Cyan
& $py manage.py migrate

Write-Host "Creando superusuario (admin@poke.com / admin123) si no existe..." -ForegroundColor Cyan
$env:DJANGO_SUPERUSER_USERNAME = "admin"
$env:DJANGO_SUPERUSER_EMAIL    = "admin@poke.com"
$env:DJANGO_SUPERUSER_PASSWORD = "admin123"
try{ & $py manage.py createsuperuser --noinput | Out-Null } catch { Write-Host "Posiblemente ya exista (ok)." }
Remove-Item Env:DJANGO_SUPERUSER_USERNAME -ErrorAction SilentlyContinue
Remove-Item Env:DJANGO_SUPERUSER_EMAIL -ErrorAction SilentlyContinue
Remove-Item Env:DJANGO_SUPERUSER_PASSWORD -ErrorAction SilentlyContinue

Pop-Location

Write-Host ""
Write-Host "Django Admin listo." -ForegroundColor Green
Write-Host "Inicia:  cd djsite ; python manage.py runserver 8001" -ForegroundColor Cyan
Write-Host "Admin:   http://127.0.0.1:8001/admin  (admin@poke.com / admin123)" -ForegroundColor Cyan
Write-Host "Nota: Django usa store.db y no altera tus tablas Flask (managed=False)." -ForegroundColor DarkGray