# upgrade_v9.ps1
# v9: (C) tarea diaria de precios de mercado + (D) Dark/Light + SEO + favicon + dedupe TCG
$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p | Out-Null } }

# 0) Chequeos
if(-not (Test-Path "app.py")){ Write-Error "Ejecuta este script en la raiz del proyecto (donde esta app.py)."; exit 1 }
Ensure-Dir "scripts"; Ensure-Dir "scripts\maintenance"; Ensure-Dir "scripts\migrations"; Ensure-Dir "logs"; Ensure-Dir "static"

$proj = (Get-Location).Path
$pythonVenv = Join-Path $proj ".venv\Scripts\python.exe"
if(-not (Test-Path $pythonVenv)){ $pythonVenv = "python" }

# 1) Escribir script de DE-DUPE TCG por tcg_card_id
$dedupe = @'
# scripts/maintenance/dedupe_tcg_by_id.py
import re, argparse
from app import create_app
from models import db, PokemonProducto, OrderItem
from sqlalchemy import text

RE_IMG = re.compile(r"images\.pokemontcg\.io/([a-z0-9]+)/(\d+)(?:_|\.|/)", re.I)

def guess_card_id_from_image(url: str):
    if not url: return None
    m = RE_IMG.search(url)
    if not m: return None
    return f"{m.group(1).lower()}-{m.group(2)}"

def backfill_missing_ids():
    rows = db.session.query(PokemonProducto).filter(
        PokemonProducto.categoria=="tcg",
        (PokemonProducto.tcg_card_id.is_(None)) | (PokemonProducto.tcg_card_id=="")
    ).all()
    changed = 0
    for p in rows:
        cid = guess_card_id_from_image(p.image_url or "")
        if cid:
            p.tcg_card_id = cid
            changed += 1
    if changed: db.session.commit()
    return changed

def pick_keeper(items):
    items = sorted(items, key=lambda x: (0 if (x.market_price is None) else 1, x.id, x.stock or 0), reverse=True)
    return items[0]

def dedupe(dry_run=False):
    rows = db.session.query(PokemonProducto).filter(
        PokemonProducto.categoria=="tcg",
        PokemonProducto.tcg_card_id.isnot(None),
        PokemonProducto.tcg_card_id != ""
    ).all()
    groups = {}
    for p in rows: groups.setdefault(p.tcg_card_id, []).append(p)
    to_delete = []; n_groups = 0
    for cid, items in groups.items():
        if len(items) <= 1: continue
        n_groups += 1
        keep = pick_keeper(items)
        losers = [x for x in items if x.id != keep.id]
        keep.stock = (keep.stock or 0) + sum((x.stock or 0) for x in losers)
        loser_ids = [x.id for x in losers]
        if loser_ids:
            (db.session.query(OrderItem)
               .filter(OrderItem.product_id.in_(loser_ids))
               .update({OrderItem.product_id: keep.id}, synchronize_session=False))
        to_delete.extend(loser_ids)
    if not dry_run and to_delete:
        (db.session.query(PokemonProducto)
           .filter(PokemonProducto.id.in_(to_delete))
           .delete(synchronize_session=False))
        db.session.commit()
    return n_groups, len(to_delete)

def ensure_unique_index():
    try:
        db.session.execute(text(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_product_tcg_id_unique "
            "ON productos(tcg_card_id) WHERE tcg_card_id IS NOT NULL AND tcg_card_id <> ''"
        ))
        db.session.commit()
    except Exception as e:
        print("Indice unico:", e)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    app = create_app()
    with app.app_context():
        print("Backfill ids...")
        ch = backfill_missing_ids()
        print("  ids completados:", ch)
        print("Dedupe...")
        g, d = dedupe(dry_run=args.dry_run)
        print("  grupos:", g, "eliminados:", d if not args.dry_run else f"(sim) {d}")
        print("Indice unico...")
        ensure_unique_index()
        print("OK")
if __name__ == "__main__": main()
'@
Set-Content -Path "scripts\maintenance\dedupe_tcg_by_id.py" -Value $dedupe -Encoding UTF8

# 1b) Backup de DB
if(Test-Path "store.db"){
  Ensure-Dir "backups"
  $bk = Join-Path "backups" ("store_" + (Get-Date -f "yyyyMMdd_HHmmss") + ".db")
  Copy-Item "store.db" $bk -Force
  Write-Host "Backup creado:" $bk
}

# 1c) Ejecutar de-dupe como módulo (PowerShell-friendly)
if(-not (Test-Path "scripts\__init__.py")) { New-Item -ItemType File scripts\__init__.py -Force | Out-Null }
if(-not (Test-Path "scripts\maintenance\__init__.py")) { New-Item -ItemType File scripts\maintenance\__init__.py -Force | Out-Null }
& $pythonVenv -m scripts.maintenance.dedupe_tcg_by_id

# 2) Runner PS1 para refrescar precios de mercado + Tarea programada diaria 05:00
$runner = @'
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
'@
Set-Content -Path "scripts\maintenance\run_daily_update.ps1" -Value $runner -Encoding UTF8

# 2b) Crear/actualizar tarea programada (necesita permisos)
$taskName = "PokeShop-MarketUpdate"
$psExe = (Get-Command powershell).Source
$taskScript = Join-Path $proj "scripts\maintenance\run_daily_update.ps1"
# Borrar si existe
try { schtasks /Delete /TN $taskName /F | Out-Null } catch {}
# Crear diaria 05:00
$taskCmd = """$psExe"" -NoProfile -ExecutionPolicy Bypass -File ""$taskScript"""
schtasks /Create /SC DAILY /ST 05:00 /TN $taskName /TR $taskCmd /F | Out-Null
Write-Host "Tarea programada creada: $taskName (diaria 05:00)"

# 3) Dark/Light + SEO + favicon

# 3a) favicon.svg
$fav = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
 <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#7dd3fc"/><stop offset="1" stop-color="#60a5fa"/></linearGradient></defs>
 <circle cx="32" cy="32" r="30" fill="#0b0f1a" stroke="url(#g)" stroke-width="4"/>
 <circle cx="32" cy="32" r="10" fill="#fff" stroke="#7dd3fc" stroke-width="3"/>
 <rect x="4" y="28" width="56" height="8" fill="#172554"/>
</svg>
'@
Set-Content -Path "static\favicon.svg" -Value $fav -Encoding UTF8

# 3b) base.html: meta OG/Twitter + favicon + toggle
$basePath = "templates\base.html"
if(Test-Path $basePath){
  $base = Get-Content $basePath -Raw

  if($base -notmatch "og:title"){
    $headInject = @'
  <!-- v9 SEO -->
  <meta name="description" content="PokeShop: peluches, figuras y cartas TCG con b&uacute;squeda inteligente.">
  <meta property="og:type" content="website">
  <meta property="og:title" content="PokeShop">
  <meta property="og:description" content="PokeShop: peluches, figuras y cartas TCG con b&uacute;squeda inteligente.">
  <meta property="og:url" content="/">
  <meta property="og:image" content="{{ url_for('static', filename='favicon.svg') }}">
  <meta name="twitter:card" content="summary">
  <link rel="icon" href="{{ url_for('static', filename='favicon.svg') }}" type="image/svg+xml">
'@
    $base = $base -replace '(<head>\s*)', "`$1`r`n$headInject"
  }

  if($base -notmatch "themeToggle"){
    $base = $base -replace '(</nav>)', ' <button id="themeToggle" class="btn" type="button" title="Cambiar tema">🌙</button>$1'
  }

  if($base -notmatch "data-theme"){
$toggleScript = @'
<script>
(function(){
  const root = document.documentElement;
  const key='theme';
  function apply(t){ root.setAttribute('data-theme', t); try{localStorage.setItem(key,t);}catch(e){} }
  const pref = (function(){
    try{ return localStorage.getItem(key); }catch(e){ return null; }
  })() || (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
  apply(pref);
  const btn = document.getElementById('themeToggle');
  if(btn){
    btn.textContent = (pref==="light") ? "☀️" : "🌙";
    btn.addEventListener('click', function(){
      const t = root.getAttribute('data-theme')==="light" ? "dark" : "light";
      apply(t);
      btn.textContent = (t==="light") ? "☀️" : "🌙";
    });
  }
})();
</script>
'@
    $base = $base -replace '(</body>)', "$toggleScript`r`n$1"
  }

  Set-Content -Path $basePath -Value $base -Encoding UTF8
  Write-Host "base.html parcheado (SEO + toggle + favicon)."
}else{
  Write-Warning "No se encontro templates/base.html; salteando parche UI."
}

# 3c) styles.css: tema claro
$cssPath = "static\styles.css"
$lightCss = @'
/* v9 light theme */
:root[data-theme="light"]{
  --bg:#f4f7ff;
  --panel:#ffffff;
  --elev:#f8fbff;
  --line:#d7e0f5;
  --text:#0b1220;
  --muted:#475569;
  --accent:#2563eb;
  --accent-2:#16a34a;
  --warn:#b45309;
  --danger:#b91c1c;
}
html,body{ transition: background-color .25s ease, color .25s ease; }
'@
if(Test-Path $cssPath){
  Add-Content -Path $cssPath -Value $lightCss -Encoding UTF8
  Write-Host "styles.css actualizado con tema claro."
}else{
  Write-Warning "No se encontro static/styles.css; salteando parche CSS."
}

Write-Host ""
Write-Host "v9 aplicada:" -ForegroundColor Green
Write-Host " - Dedupe TCG ejecutado + indice unico por tcg_card_id"
Write-Host " - Runner diario: scripts/maintenance/run_daily_update.ps1"
Write-Host " - Tarea programada: PokeShop-MarketUpdate (05:00)"
Write-Host " - UI: toggle Dark/Light + SEO + favicon"
Write-Host ""
Write-Host "Chequear tarea: schtasks /Query /TN PokeShop-MarketUpdate"
Write-Host "Forzar update ahora: powershell -NoProfile -ExecutionPolicy Bypass -File `"$taskScript`""
Write-Host "Reinicia la app: python app.py y refresca el navegador (Ctrl+F5)."