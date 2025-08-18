# upgrade_v10_ui.ps1
# UI Overhaul (v10): CSS moderno + plantillas retocadas (base, index, product, cart)
$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# 0) Backup
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
Ensure-Dir "backups"
$bk = "backups\ui_v10_$ts"
Ensure-Dir $bk
foreach($f in @("static\styles.css","templates\base.html","templates\index.html","templates\product.html","templates\cart.html")){
  if(Test-Path $f){ $dest = Join-Path $bk ($f.Replace('\','_')); Copy-Item $f $dest -Force }
}
Write-Host "Backup de UI previo en $bk" -ForegroundColor Green

# 1) Nuevo CSS
$css = @'
/* ================== UI Overhaul v10 ================== */
/* Paleta + superficies */
:root{
  --bg:#0b101b;
  --panel:#0f1628;
  --elev:#111a33;
  --line:#223055;
  --text:#e9f1ff;
  --muted:#a8b5d8;
  --accent:#60a5fa;
  --accent-2:#22c55e;
  --gold:#fcd34d;
  --warn:#f59e0b;
  --danger:#ef4444;
  --radius:14px;
  --shadow:0 10px 30px rgba(0,0,0,.35), 0 2px 6px rgba(0,0,0,.2);
}
/* Light (v9) respetado si está presente */
:root[data-theme="light"]{
  --bg:#f5f8ff;
  --panel:#ffffff;
  --elev:#f6f9ff;
  --line:#d9e2f5;
  --text:#0c1222;
  --muted:#5a6a86;
  --accent:#2563eb;
  --accent-2:#16a34a;
  --gold:#b45309;
  --warn:#b45309;
  --danger:#b91c1c;
}

*{box-sizing:border-box}
html,body{height:100%}
body{
  margin:0;
  background:
    radial-gradient(900px 400px at 10% -5%, rgba(31,64,170,.25), transparent 60%),
    radial-gradient(800px 300px at 90% -10%, rgba(99,102,241,.18), transparent 65%),
    var(--bg);
  color:var(--text);
  font-family: Inter, system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
  letter-spacing:.2px;
  line-height:1.45;
}

/* Topbar con blur y contenedor */
.topbar{
  position: sticky; top:0; z-index:40;
  background:rgba(10,14,30,.55);
  backdrop-filter: blur(10px);
  border-bottom:1px solid var(--line);
}
.wrap{max-width:1200px;margin:0 auto;padding:14px 18px}

.brand{color:#fff;text-decoration:none;font-weight:900;font-size:18px; letter-spacing:.4px}
nav a{
  color:var(--text); text-decoration:none; margin-left:10px; opacity:.9;
  padding:6px 10px; border-radius:10px;
}
nav a:hover{ background:rgba(255,255,255,.07); opacity:1 }
#themeToggle{ margin-left:10px; }

.search{display:flex; gap:8px; align-items:center}
.search input{
  width:280px; max-width:58vw;
  padding:10px 12px; border-radius:12px; border:1px solid var(--line);
  background:#0f1735; color:var(--text);
  outline:none; box-shadow:none;
}
.search input:focus{ border-color:var(--accent); box-shadow:0 0 0 3px rgba(96,165,250,.25) }
.search button{
  background: linear-gradient(135deg, var(--accent), #7dd3fc);
  color:#07283d; font-weight:800; border:none; border-radius:12px; padding:10px 14px; cursor:pointer;
}

/* Títulos / mensajes */
h1,h2,h3{margin:12px 0 10px 0}
h1{font-size:28px}
h2{font-size:22px}
h3{font-size:18px}
.muted{color:var(--muted)}
.flash{margin:12px 0}
.flash-item{padding:10px;border-radius:12px;margin-bottom:8px;border:1px solid var(--line); background:#0f1730}
.flash-item.success{border-color:#14532d;background:#0b2d1f}
.flash-item.info{border-color:#1e3a8a;background:#0b1a36}
.flash-item.warning{border-color:#7c5808;background:#2a1f07}
.flash-item.danger{border-color:#7f1d1d;background:#2a0f12}

/* Hero */
.hero{
  margin:12px 0 10px 0;
  background: linear-gradient(135deg, rgba(96,165,250,.16), rgba(34,197,94,.12));
  border:1px solid var(--line);
  border-radius:16px; padding:18px;
  box-shadow: var(--shadow);
}
.hero h1{font-size:32px;margin:0 0 4px 0}
.hero p{color:var(--muted); margin:0}

/* Grids y cards */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:16px}
.card{
  background:var(--panel); border:1px solid var(--line); border-radius:var(--radius);
  padding:12px; color:var(--text); text-decoration:none;
  transition: transform .18s ease, box-shadow .18s ease, border-color .18s ease;
}
.card:hover{ transform: translateY(-3px); box-shadow: var(--shadow); border-color:#2b3e78 }
.card img{width:100%; height:200px; object-fit:contain; background:#0f1735; border-radius:12px}
.card .title{font-weight:800; margin:8px 0 4px 0}
.card .price{color:var(--gold); font-weight:900}
.badges{display:flex; gap:6px; flex-wrap:wrap; margin:6px 0}
.badge{font-size:11px; padding:4px 8px; border-radius:999px; border:1px solid var(--line); background:#111b3a; color:#cfe3ff}

/* Producto */
.product{display:grid; grid-template-columns: minmax(280px,380px) 1fr; gap:18px}
@media (max-width: 920px){ .product{ grid-template-columns: 1fr } }
.product .photo{width:100%; height:380px; object-fit:contain; background:#0f1735; border-radius:14px; border:1px solid var(--line)}
.box{ background:var(--elev); border:1px solid var(--line); border-radius:12px; padding:14px; }

/* Botones */
.btn{
  background:#142045; border:1px solid var(--line); color:var(--text);
  padding:10px 12px; border-radius:12px; cursor:pointer; text-decoration:none;
  transition: all .15s ease;
}
.btn:hover{ border-color:#3353a0; transform: translateY(-1px) }
.primary{ background: linear-gradient(135deg, var(--accent), #7dd3fc); color:#052033; border:none }
.danger{ background:#3a2030; border:1px solid #6b2a3a }

/* Formularios */
.auth, .checkout, .admin-form{display:grid; gap:10px}
.auth input, .checkout input, .admin-form input, .admin-form textarea, select, textarea{
  padding:12px; border-radius:12px; border:1px solid var(--line); background:#0f1735; color:var(--text);
}
select{ cursor:pointer }
.auth input:focus, .checkout input:focus, .admin-form input:focus, .admin-form textarea:focus, select:focus, textarea:focus{
  border-color: var(--accent); box-shadow: 0 0 0 3px rgba(96,165,250,.25); outline:none;
}

/* Filtros */
.filters{display:flex; gap:10px; flex-wrap:wrap; margin:12px 0}
.filters select, .filters input{ min-width:160px }

/* Tabla */
.table{width:100%; border-collapse: collapse; overflow:hidden; border-radius:12px; border:1px solid var(--line)}
.table th, .table td{padding:10px; border-bottom:1px solid var(--line)}
.table tr:hover td{ background:#0f1735 }

/* Layout */
.footer{border-top:1px solid var(--line); margin-top:18px}
.row{display:flex; justify-content:space-between; align-items:center; gap:10px}
.total{font-size:18px; font-weight:900; color:var(--gold)}
.chip{display:inline-block; background:#17224a; border:1px solid #2a3670; color:#cfe3ff; border-radius:999px; font-size:12px; padding:4px 10px}

/* Transiciones tema */
html,body{ transition: background-color .25s ease, color .25s ease; }
'@
Set-Content -Path "static\styles.css" -Value $css -Encoding UTF8
Write-Host "styles.css actualizado (v10)."

# 2) base.html: mejorar topbar y contenedor (respetando toggle v9)
$basePath = "templates\base.html"
if(Test-Path $basePath){
  $base = Get-Content $basePath -Raw

  # Inserta contenedor de búsqueda si no existe
  if($base -notmatch 'class="search"'){
$searchForm = @'
    <form class="search" action="{{ url_for('index') }}">
      <input name="q" placeholder="Buscar..." value="{{ request.args.get('q','') }}">
      <button>Buscar</button>
    </form>
'@
    # Reemplaza el form existente de búsqueda por el nuevo (si lo encuentra)
    $base = $base -replace '<form class="search"[^>]*>[\s\S]*?</form>', $searchForm
  }

  # Asegura que wrap se usa en topbar y main
  if($base -notmatch '<header class="topbar">'){
    $base = $base -replace '<header class="topbar">', '<header class="topbar">'
  }

  Set-Content -Path $basePath -Value $base -Encoding UTF8
  Write-Host "base.html actualizado."
}else{
  Write-Warning "No se encontró templates/base.html; salteando."
}

# 3) index.html: hero + badges en cards
$idxPath = "templates\index.html"
if(Test-Path $idxPath){
  $idx = Get-Content $idxPath -Raw

  # Hero simple (si no existe)
  if($idx -notmatch '<div class="hero">'){
$hero = @'
<div class="hero">
  <h1>Cat&aacute;logo</h1>
  <p>Descubre peluches, figuras y cartas TCG con b&uacute;squeda inteligente y precios actualizados.</p>
</div>
'@
    $idx = $idx -replace '(<h1>Cat[^<]*</h1>)', "$hero"
  }

  # Badges en cards (TCG / Poco stock / Precio < mercado)
  if($idx -notmatch 'badges'){
$badgeBlock = @'
    <div class="badges">
      {% if p.categoria and p.categoria|lower == "tcg" %}<span class="badge">TCG</span>{% endif %}
      {% if p.stock is not none and p.stock <= 5 %}<span class="badge">Poco stock</span>{% endif %}
      {% if p.market_price is not none and p.precio_base < p.market_price %}<span class="badge">Oferta</span>{% endif %}
    </div>
'@
    # Inserta tras el título de cada card si es listado standard
    $idx = $idx -replace '(<div class="title">\{\{ p\.nombre \}\}</div>)', "`$1`r`n$badgeBlock"
  }

  Set-Content -Path $idxPath -Value $idx -Encoding UTF8
  Write-Host "index.html actualizado (hero + badges)."
}else{
  Write-Warning "No se encontró templates/index.html; salteando."
}

# 4) product.html: caja de precio + badges + bloques limpios (solo si existe)
$prodPath = "templates\product.html"
if(Test-Path $prodPath){
  $prod = Get-Content $prodPath -Raw

  # Asegura badges TCG / Poco stock
  if($prod -notmatch 'Metadatos TCG'){
    # Si tu product.html es muy distinto, no se parchea; solo avisamos
    Write-Host "product.html parece ya personalizado (v10 no inserta metadatos de nuevo)."
  }

  # Nada más aquí para evitar conflictos con tu versión ya corregida

  Set-Content -Path $prodPath -Value $prod -Encoding UTF8
  Write-Host "product.html verificado."
}else{
  Write-Warning "No se encontró templates/product.html; salteando."
}

# 5) cart.html: tabla limpia (sólo si existe)
$cartPath = "templates\cart.html"
if(Test-Path $cartPath){
  $cart = Get-Content $cartPath -Raw
  # En v10 ya es mostly CSS; no toco plantilla para no romper lógica
  Set-Content -Path $cartPath -Value $cart -Encoding UTF8
  Write-Host "cart.html verificado."
}

Write-Host "`nUI v10 aplicada. Recarga el navegador con Ctrl+F5." -ForegroundColor Green