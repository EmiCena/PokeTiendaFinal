# patch_ai_v7_plus.ps1
# Añade cache para el asistente y "Pregúntale a la IA" en la ficha de producto.
# Idempotente: puedes correrlo varias veces.

$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# Chequeos
if(-not (Test-Path "app.py")){ Write-Error "No encuentro app.py en la carpeta actual."; exit 1 }
Ensure-Dir "ai"
Ensure-Dir "templates"

# 1) ai/cache_service.py
$cache_py = @'
# ai/cache_service.py
import json, time, hashlib
from sqlalchemy import text
from models import db

def _now():
    return time.strftime("%Y-%m-%d %H:%M:%S")

def get_cache(cache_key: str) -> str | None:
    row = db.session.execute(text("SELECT value FROM ai_cache WHERE cache_key=:k"), {"k": cache_key}).fetchone()
    return row[0] if row else None

def set_cache(cache_key: str, value: str) -> None:
    db.session.execute(
        text("""
        INSERT INTO ai_cache(cache_key, value, updated_at)
        VALUES (:k, :v, :ts)
        ON CONFLICT(cache_key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
        """),
        {"k": cache_key, "v": value, "ts": _now()}
    )
    db.session.commit()

def make_key(namespace: str, model: str, text: str) -> str:
    h = hashlib.sha1(text.encode("utf-8")).hexdigest()
    return f"{namespace}:{model}:{h}"
'@
Set-Content -Path "ai/cache_service.py" -Value $cache_py -Encoding UTF8
Write-Host "Escrito ai/cache_service.py"

# 2) ai/rag_assistant.py (con cache)
$assistant_py = @'
# ai/rag_assistant.py
import os, json, requests
from ai.search_service import semantic_search
from ai.cache_service import get_cache, set_cache, make_key

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_CHAT_BASE_URL = os.getenv("OPENAI_CHAT_BASE_URL", os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
CHAT_MODEL = os.getenv("OPENAI_CHAT_MODEL", "gpt-4o-mini")

SYS_PROMPT = (
 "Eres un asistente de una tienda Pokémon. Responde de forma breve y clara, "
 "en español neutro, usando la información de 'contexto' que te doy. "
 "Si no estás seguro, dilo y sugiere productos relacionados."
)

def openai_chat(messages: list[dict]) -> str:
    url = f"{OPENAI_CHAT_BASE_URL}/chat/completions"
    headers = {"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"}
    payload = {"model": CHAT_MODEL, "messages": messages, "temperature": 0.2}
    r = requests.post(url, headers=headers, data=json.dumps(payload), timeout=30)
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"].strip()

def answer_question(question: str, k: int = 5):
    # cache por pregunta + modelo
    cache_key = make_key("qa", os.getenv("OPENAI_CHAT_MODEL", "chat-model"), (question or "").strip())
    cached = get_cache(cache_key)
    if cached:
        try:
            obj = json.loads(cached)
            # reconstruimos hits desde ids
            from models import PokemonProducto
            hits = []
            for pid in obj.get("hit_ids", []):
                p = PokemonProducto.query.get(pid)
                if p: hits.append((p, 0.0))
            return obj.get("answer",""), hits
        except Exception:
            pass

    # recuperar productos relevantes para armar contexto
    hits = semantic_search(question, k=k, filters=None)
    ctx_lines, hit_ids = [], []
    for p, sc in hits:
        hit_ids.append(p.id)
        ctx_lines.append(f"- {p.nombre} | Tipo: {p.tipo} | Precio base: {p.precio_base:.2f}\n  {p.descripcion or ''}")
    context = "\n".join(ctx_lines) or "Sin datos."

    if OPENAI_API_KEY and OPENAI_CHAT_BASE_URL:
        try:
            msg = [
                {"role":"system", "content": SYS_PROMPT},
                {"role":"user", "content": f"Pregunta: {question}\n\nContexto:\n{context}\n\nResponde:"}
            ]
            txt = openai_chat(msg)
            set_cache(cache_key, json.dumps({"answer": txt, "hit_ids": hit_ids}))
            return txt, hits
        except Exception:
            pass

    # Fallback local si no hay IA externa
    intro = "No tengo IA externa habilitada; aquí tienes productos relacionados:\n"
    bullets = "\n".join([f"- {p.nombre} (tipo {p.tipo}, $ {p.precio_base:.2f})" for p, _ in hits])
    txt = intro + bullets
    set_cache(cache_key, json.dumps({"answer": txt, "hit_ids": hit_ids}))
    return txt, hits
'@
Set-Content -Path "ai/rag_assistant.py" -Value $assistant_py -Encoding UTF8
Write-Host "Actualizado ai/rag_assistant.py (con cache)"

# 3) app.py: inyectar ruta /ai/ask_product/<pid> si no existe
$app = Get-Content -Raw "app.py"
if ($app -notmatch '\@app\.routeKATEX_INLINE_OPEN"/ai/ask_product/<int:pid>"') {
  $snippet = @'
    @app.route("/ai/ask_product/<int:pid>", methods=["POST"])
    def ai_ask_product(pid: int):
        from services.precio_dinamico_service import PrecioDinamicoService
        from models import PokemonProducto, Review
        from ai.rag_assistant import OPENAI_API_KEY, OPENAI_CHAT_BASE_URL, openai_chat
        p = PokemonProducto.query.get_or_404(pid)
        q = (request.form.get("q") or "").strip()
        ai_answer = None
        if q:
            context = f"""Producto: {p.nombre}
Tipo: {p.tipo} | Categoría: {p.categoria}
Precio base: {p.precio_base:.2f}
Descripción: {p.descripcion or ''}"""
            msg = [
                {"role":"system","content":"Eres un asistente de una tienda Pokémon. Responde breve y claro."},
                {"role":"user","content": f"Pregunta: {q}\n\nContexto del producto:\n{context}\n\nResponde:"}
            ]
            try:
                if OPENAI_API_KEY and OPENAI_CHAT_BASE_URL:
                    ai_answer = openai_chat(msg)
                else:
                    ai_answer = "IA externa no disponible. Revisa la descripción y especificaciones del producto."
            except Exception as e:
                ai_answer = f"Error IA: {e}"
        precio, razones, feats = PrecioDinamicoService().calcular_precio(
            p, current_user if current_user.is_authenticated else None
        )
        reviews = Review.query.filter_by(product_id=p.id).order_by(Review.created_at.desc()).all()
        return render_template("product.html", p=p, precio=precio, razones=razones, feats=feats,
                               reviews=reviews, avg_rating=None, my_review=None,
                               purchasers=set(), in_wishlist=False,
                               ai_q=q, ai_answer=ai_answer)

'@
  $regex = [regex]'(\n\s*return app\s*\n)'
  $app   = $regex.Replace($app, ($snippet + '$1'), 1)
  Set-Content -Path "app.py" -Value $app -Encoding UTF8
  Write-Host "Ruta /ai/ask_product insertada en app.py"
} else {
  Write-Host "Ruta /ai/ask_product ya existe (no se modifica)."
}

# 4) templates/product.html: insertar form IA si no existe
if(Test-Path "templates\product.html"){
  $prod = Get-Content "templates\product.html" -Raw
  if($prod -notmatch "ai_ask_product"){
    $form = @'
<div class="box" style="margin:10px 0">
  <form method="post" action="{{ url_for('ai_ask_product', pid=p.id) }}" class="auth">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    <label>Preg&uacute;ntale a la IA sobre este producto
      <textarea name="q" rows="2" placeholder="Ej: diferencias, usos, comparaci&oacute;n">{{ ai_q or '' }}</textarea>
    </label>
    <button class="btn">Preguntar</button>
  </form>
  {% if ai_answer %}
    <div class="muted" style="margin-top:6px"><b>Respuesta IA:</b> {{ ai_answer }}</div>
  {% endif %}
</div>
'@
    # intenta insertar antes del bloque de Reseñas si existe
    if($prod -match "<h3>Reseñas"){
      $prod = $prod -replace "<h3>Reseñas","$form`r`n<h3>Reseñas"
    } else {
      $prod = $prod + "`r`n" + $form
    }
    Set-Content "templates\product.html" $prod -Encoding UTF8
    Write-Host "Formulario IA insertado en templates/product.html"
  } else {
    Write-Host "El formulario IA ya existe en templates/product.html (no se modifica)."
  }
} else {
  Write-Host "Aviso: templates/product.html no existe; no se pudo insertar formulario." -ForegroundColor Yellow
}

Write-Host "Patch IA v7+ aplicado." -ForegroundColor Green
Write-Host ""
Write-Host "Siguientes pasos:" -ForegroundColor Cyan
Write-Host "1) Asegura la tabla ai_cache (si no corriste la v7):  python upgrade_v7.py"
Write-Host "2) Opcional: reindexa embeddings (fallback local):   python ai/build_embeddings.py"
Write-Host "3) Levantá la app:                                   python app.py"
Write-Host "4) Probá en una ficha el formulario IA y /ai/ask"