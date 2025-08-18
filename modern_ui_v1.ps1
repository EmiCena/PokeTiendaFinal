# modern_ui_v1.ps1
$ErrorActionPreference = "Stop"
$css = @'
/* styles.css — Modern UI v1 (dark, glass, soft shadows) */
:root{
  --bg:#0b0f1a;
  --panel:#101628;
  --elev:#121a33;
  --line:#1c2a52;
  --text:#e9eeff;
  --muted:#a9b6db;
  --accent:#7dd3fc;           /* cyan */
  --accent-2:#22c55e;         /* green */
  --warn:#f59e0b;
  --danger:#f43f5e;
  --ring:#60a5fa;
  --radius:14px;
  --shadow:0 10px 30px rgba(0,0,0,.35), 0 2px 6px rgba(0,0,0,.2);
}
*{box-sizing:border-box}
html,body{height:100%}
body{
  margin:0;
  background: radial-gradient(1200px 600px at 20% -10%, #0f1430 0%, #0b0f1a 60%);
  color:var(--text);
  font-family: Inter, system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
  letter-spacing:.2px;
}

/* Topbar con blur */
.topbar{
  position:sticky; top:0; z-index:50;
  background:rgba(13,20,40,.6);
  backdrop-filter: blur(10px);
  border-bottom:1px solid var(--line);
}
.wrap{max-width:1200px;margin:0 auto;padding:14px 18px}

.brand{color:#fff;text-decoration:none;font-weight:900;font-size:18px; letter-spacing:.4px}
nav a{
  color:var(--text); text-decoration:none; margin-left:12px; opacity:.9;
  padding:6px 10px; border-radius:10px;
}
nav a:hover{ background:rgba(255,255,255,.05); opacity:1 }

.search{display:flex; gap:8px; align-items:center}
.search input{
  width:240px; max-width:52vw;
  padding:10px 12px; border-radius:12px; border:1px solid var(--line);
  background:#0f1735; color:var(--text);
  outline:none; box-shadow:none;
}
.search input:focus{ border-color:var(--ring); box-shadow:0 0 0 3px rgba(96,165,250,.25) }
.search button{
  background: linear-gradient(135deg, var(--accent), #60a5fa);
  color:#08243a; font-weight:800; border:none; border-radius:12px; padding:10px 14px; cursor:pointer;
}

/* Titulos y secciones */
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

/* Grid y cards */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:16px}
.card{
  background:var(--panel); border:1px solid var(--line); border-radius:var(--radius);
  padding:12px; color:var(--text); text-decoration:none;
  transition: transform .18s ease, box-shadow .18s ease, border-color .18s ease;
}
.card:hover{ transform: translateY(-3px); box-shadow: var(--shadow); border-color:#2b3e78 }
.card img{width:100%; height:200px; object-fit:contain; background:#0f1735; border-radius:12px}
.card .title{font-weight:800; margin:8px 0 4px 0}
.card .price{color:#fcd34d; font-weight:900}

/* Producto */
.product{display:grid; grid-template-columns: minmax(280px,360px) 1fr; gap:18px}
@media (max-width: 900px){ .product{ grid-template-columns: 1fr } }
.product .photo{width:100%; height:360px; object-fit:contain; background:#0f1735; border-radius:14px; border:1px solid var(--line)}
.box{
  background:var(--elev); border:1px solid var(--line); border-radius:12px; padding:14px;
}

/* Botones */
.btn{
  background:#142045; border:1px solid var(--line); color:var(--text);
  padding:10px 12px; border-radius:12px; cursor:pointer; text-decoration:none;
  transition: all .15s ease;
}
.btn:hover{ border-color:#3353a0; transform: translateY(-1px) }
.primary{ background: linear-gradient(135deg, var(--accent), #60a5fa); color:#052033; border:none }
.danger{ background:#3a2030; border:1px solid #6b2a3a }

/* Formularios */
.auth, .checkout, .admin-form{display:grid; gap:10px}
.auth input, .checkout input, .admin-form input, .admin-form textarea, select, textarea{
  padding:12px; border-radius:12px; border:1px solid var(--line); background:#0f1735; color:var(--text);
}
select{ cursor:pointer }
.auth input:focus, .checkout input:focus, .admin-form input:focus, .admin-form textarea:focus, select:focus, textarea:focus{
  border-color: var(--ring); box-shadow: 0 0 0 3px rgba(96,165,250,.25); outline:none;
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
.total{font-size:18px; font-weight:900; color:#fcd34d}

/* Chips */
.chip{display:inline-block; background:#17224a; border:1px solid #2a3670; color:#cfe3ff; border-radius:999px; font-size:12px; padding:4px 10px}

/* Hero opcional (si lo agregas en index) */
.hero{
  background: radial-gradient(800px 300px at 10% -10%, #132055 0%, transparent 60%);
  border:1px solid var(--line); border-radius:16px; padding:18px; margin:12px 0;
}
.hero h1{ font-size:32px; margin:0 0 6px 0 }
.hero p{ color:var(--muted); margin:0 }
'@
Set-Content -Path "static\styles.css" -Value $css -Encoding UTF8

Write-Host "UI moderna aplicada (styles.css actualizado)." -ForegroundColor Green
Write-Host "Refresca el navegador con Ctrl+F5."