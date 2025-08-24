# patch_market_prices_v2.ps1
param(
  [string]$Set = "",
  [int]$Limit = 0,
  [double]$Sleep = 0.25,
  [switch]$PatchTemplates,
  [switch]$Commit,
  [switch]$Push,
  [string]$Branch = "feat/market-prices"
)

$ErrorActionPreference = "Stop"
function step($m){ Write-Host "== $m ==" -ForegroundColor Cyan }
function ok($m){ Write-Host $m -ForegroundColor Green }
function warn($m){ Write-Host $m -ForegroundColor Yellow }
function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# 0) Python/venv
step "Detectando Python"
$PY = ".\.venv\Scripts\python.exe"
if(-not (Test-Path $PY)){
  try { & py --version | Out-Null; $PY = "py" } catch {
    try { & python --version | Out-Null; $PY = "python" } catch { throw "No se encontró Python ni venv." }
  }
}
ok "Python: $PY"

# 1) Mojibake fix
step "Corrigiendo mojibake (UTF-8) en templates y static"
function Reencode($path) {
  if(-not (Test-Path $path)) { return }
  $files = Get-ChildItem -Path $path -Recurse -Include *.html,*.htm,*.js,*.css -File
  foreach($f in $files){
    try{
      $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
      $txt1252 = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
      if($txt1252 -match 'Ã'){
        [System.IO.File]::WriteAllText($f.FullName, $txt1252, [System.Text.Encoding]::UTF8)
        Write-Host "Re-encoded -> $($f.FullName)" -ForegroundColor Green
      }
    } catch { Write-Warning "Skip $($f.FullName): $_" }
  }
}
Reencode "templates"
Reencode "static"
ok "Mojibake: OK (haz Ctrl+F5 en el navegador)"

# 2) Archivos de servicio/migración/mantenimiento
step "Creando/actualizando servicio y migraciones"
Ensure-Dir "services"; Ensure-Dir "scripts\maintenance"; Ensure-Dir "scripts\migrations"

# 2a) services/market_price_service.py
$svc = @'
import os, time, requests
from datetime import datetime
from typing import Optional, Tuple
from models import db, PokemonProducto

class MarketPriceService:
    BASE = "https://api.pokemontcg.io/v2"
    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key or os.getenv("POKEMONTCG_API_KEY", "")
    def _headers(self):
        h = {"Accept": "application/json"}
        if self.api_key: h["X-Api-Key"] = self.api_key
        return h
    def _fetch_card_json(self, set_code: str, number: int) -> Optional[dict]:
        for cid in (f"{set_code.upper()}-{number}", f"{set_code.lower()}-{number}"):
            r = requests.get(f"{self.BASE}/cards/{cid}", headers=self._headers(), timeout=15)
            if r.status_code == 200: return r.json().get("data")
        q = f"set.id:{set_code.lower()} number:{number}"
        r = requests.get(f"{self.BASE}/cards", headers=self._headers(), params={"q": q}, timeout=15)
        if r.status_code == 200:
            arr = r.json().get("data") or []
            return arr[0] if arr else None
        return None
    def _extract_market(self, card: dict) -> Tuple[Optional[float], Optional[str], Optional[str]]:
        if not card: return (None, None, None)
        tp = (card.get("tcgplayer") or {}).get("prices") or {}
        for k in ("holofoil", "reverseHolofoil", "normal"):
            pr = tp.get(k) or {}
            v = pr.get("market") or pr.get("mid") or pr.get("low")
            if v: return float(v), "USD", "tcgplayer"
        cm = (card.get("cardmarket") or {}).get("prices") or {}
        v = cm.get("trendPrice") or cm.get("averageSellPrice") or cm.get("avg1") or cm.get("avg7")
        if v: return float(v), "EUR", "cardmarket"
        return (None, None, None)
    @staticmethod
    def _parse_tcg_id(tcg_card_id: str):
        try:
            sc, n = tcg_card_id.split("-", 1)
            return sc.lower(), int(n.lstrip("0") or "0")
        except Exception:
            return (None, None)
    def update_prices(self, set_code: Optional[str] = None, sleep: float = 0.25, limit: Optional[int] = None) -> int:
        q = PokemonProducto.query.filter(
            PokemonProducto.categoria=="tcg",
            PokemonProducto.tcg_card_id.isnot(None),
            PokemonProducto.tcg_card_id!=""
        ).order_by(PokemonProducto.id.asc())
        updated = 0; count = 0
        for p in q:
            if limit and count >= limit: break
            count += 1
            sc, num = self._parse_tcg_id(p.tcg_card_id)
            if not sc or num is None: continue
            if set_code and sc.lower() != set_code.lower(): continue
            try:
                card = self._fetch_card_json(sc, num)
                price, curr, src = self._extract_market(card)
                if price:
                    p.market_price = round(float(price), 2)
                    p.market_currency = curr
                    p.market_source = src
                    p.market_updated_at = datetime.utcnow()
                    db.session.add(p); updated += 1
                if sleep: time.sleep(sleep)
            except Exception:
                continue
        if updated: db.session.commit()
        return updated
'@
Set-Content "services\market_price_service.py" $svc -Encoding UTF8
ok "services/market_price_service.py"

# 2b) migración v14
$mig = @'
import os
from sqlalchemy import text
from models import db
try:
    from app import create_app
except Exception:
    create_app = None
flask_app = None
if create_app:
    try: flask_app = create_app()
    except Exception: flask_app = None
if flask_app is None:
    from flask import Flask
    proj = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    db_file = os.path.join(proj, "store.db")
    flask_app = Flask(__name__)
    flask_app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_file}"
    flask_app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
    db.init_app(flask_app)
with flask_app.app_context():
    cols = [r[1] for r in db.session.execute(text("PRAGMA table_info(productos)")).fetchall()]
    def addcol(name, decl):
        if name not in cols:
            db.session.execute(text(f"ALTER TABLE productos ADD COLUMN {name} {decl}"))
    addcol("market_price","REAL")
    addcol("market_currency","VARCHAR(8)")
    addcol("market_source","VARCHAR(32)")
    addcol("market_updated_at","TEXT")
    db.session.commit()
    print("v14: columnas de mercado listas en productos")
'@
Set-Content "scripts\migrations\upgrade_v14_market.py" $mig -Encoding UTF8
ok "scripts/migrations/upgrade_v14_market.py"

# 2c) updater
$maint = @'
import os, argparse
from models import db
try:
    from app import create_app
except Exception:
    create_app = None
from services.market_price_service import MarketPriceService
def main(set_code: str, limit: int, sleep: float):
    app = None
    if create_app:
        try: app = create_app()
        except Exception: app = None
    if app is None:
        from flask import Flask
        proj = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        db_file = os.path.join(proj, "store.db")
        app = Flask(__name__)
        app.config["SQLALCHEMY_DATABASE_URI"] = f"sqlite:///{db_file}"
        app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
        db.init_app(app)
    with app.app_context():
        if not os.getenv("POKEMONTCG_API_KEY"):
            print("WARN: POKEMONTCG_API_KEY no seteada.")
        svc = MarketPriceService()
        n = svc.update_prices(set_code=set_code or None, limit=(limit or None), sleep=sleep)
        print(f"Actualizadas {n} cartas{(' del set '+set_code) if set_code else ''}.")
if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", dest="set_code", default=None)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--sleep", type=float, default=0.25)
    args = ap.parse_args()
    main(args.set_code, args.limit if args.limit>0 else 0, args.sleep)
'@
Set-Content "scripts\maintenance\update_market_prices.py" $maint -Encoding UTF8
ok "scripts/maintenance/update_market_prices.py"

# 3) Instalar deps (sin >/nul)
step "Instalando requests (y actualizando pip)"
& $PY -m pip install -U pip | Out-Null
& $PY -m pip install requests | Out-Null
ok "pip/requests OK"

# 4) Migración
step "Ejecutando migración v14"
& $PY -m scripts.migrations.upgrade_v14_market
ok "Migración aplicada"

# 5) Actualizar precios (invocación robusta)
step "Actualizando precios desde pokemontcg.io"
$updateArgs = @("-m","scripts.maintenance.update_market_prices")
if($Set){ $updateArgs += @("--set",$Set) }
if($Limit -gt 0){ $updateArgs += @("--limit",$Limit) }
$updateArgs += @("--sleep",$Sleep)
& $PY @updateArgs
ok "Actualización completada"

# 6) Parche opcional de plantillas
if($PatchTemplates){
  step "Parcheando plantillas para mostrar precio de mercado"
  if(Test-Path "templates\product.html"){
    $p = Get-Content "templates\product.html" -Raw
    if($p -notmatch "market_price"){
$snip = @'
{% if p.market_price %}
  <div class="text-sm opacity-70">
    Precio de mercado: <b>{{ p.market_price }}</b> {{ p.market_currency or '' }}
    <span class="badge badge-outline">{{ p.market_source or 'market' }}</span>
    {% if p.market_updated_at %}<span class="opacity-60">({{ p.market_updated_at }})</span>{% endif %}
  </div>
{% endif %}
'@
      $p = $p + "`r`n" + $snip
      Set-Content "templates\product.html" $p -Encoding UTF8
      ok "product.html actualizado"
    } else { warn "product.html ya mostraba mercado (ok)" }
  }
  if(Test-Path "templates\index.html"){
    $i = Get-Content "templates\index.html" -Raw
    if($i -notmatch "Mercado:"){
$ins = @'
{% if p.market_price %}
  <div class="text-xs opacity-70 mt-1">Mercado: {{ p.market_price }} {{ p.market_currency }}</div>
{% endif %}
'@
      $i = $i + "`r`n" + $ins
      Set-Content "templates\index.html" $i -Encoding UTF8
      ok "index.html actualizado"
    } else { warn "index.html ya mostraba mercado (ok)" }
  }
}

# 7) Commit/push opcionales
if($Commit){
  try { git --version | Out-Null } catch { Write-Warning "Git no está en PATH. Saltando commit."; exit }
  function SwitchOrCreate($br){
    $cur = ""; try { $cur = (git branch --show-current 2>$null) } catch {}
    if([string]::IsNullOrWhiteSpace($cur)){
      try { git switch -c $br } catch { git checkout -b $br }
    } elseif($cur -ne $br){
      $exists = $false; try { git show-ref --verify --quiet ("refs/heads/" + $br); $exists = $true } catch {}
      if($exists){ try { git switch $br } catch { git checkout $br } }
      else       { try { git switch -c $br } catch { git checkout -b $br } }
    }
  }
  SwitchOrCreate $Branch
  git add services\market_price_service.py scripts\maintenance\update_market_prices.py scripts\migrations\upgrade_v14_market.py
  if($PatchTemplates){ git add templates\product.html templates\index.html }
  git commit -m "fix(i18n): UTF-8 templates; feat(market): servicio + migración v14 + updater"
  if($Push){ git push -u origin HEAD } else { warn "Commit creado en $(git branch --show-current). Usa -Push para subir." }
}

ok "Listo. Si aún ves acentos rotos, haz Ctrl+F5. Para precios, verifica un producto TCG con tcg_card_id."
if(-not $env:POKEMONTCG_API_KEY){
  warn "POKEMONTCG_API_KEY no está seteada. Configúrala: `$env:POKEMONTCG_API_KEY='TU_KEY'"
}