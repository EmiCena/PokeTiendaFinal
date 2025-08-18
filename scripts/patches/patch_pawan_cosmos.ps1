# patch_pawan_cosmos.ps1
# Parches para usar Pawan (CosmosRP Instructed) como backend de chat compatible con OpenAI.
# - Reescribe ai/rag_assistant.py con OPENAI_CHAT_BASE_URL
# - Reescribe ai/embedding_service.py con OPENAI_EMBED_BASE_URL (fallback local si no hay embeddings)
# - Inyecta /ai/health en app.py (dentro de create_app)
# Requiere: app.py existente en la raíz del proyecto.

$ErrorActionPreference = "Stop"

function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

# 0) Chequeos
if(-not (Test-Path "app.py")){ Write-Error "No encuentro app.py en el directorio actual."; exit 1 }
Ensure-Dir "ai"

# 1) ai/embedding_service.py (con base separada para embeddings)
$embedding_py = @'
# ai/embedding_service.py
import os, re, json, hashlib, math, requests

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
# Base específica para embeddings (si no hay, usa OPENAI_BASE_URL; si tampoco, OpenAI)
OPENAI_EMBED_BASE_URL = os.getenv("OPENAI_EMBED_BASE_URL", os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
EMBEDDING_MODEL = os.getenv("OPENAI_EMBED_MODEL", "text-embedding-3-small")

WORD_RE = re.compile(r"[A-Za-zÁÉÍÓÚÜÑáéíóúüñ0-9]+")

def _tokenize(text: str):
    return WORD_RE.findall(text.lower())

def _hash_embedding(text: str, dim: int = 256) -> list[float]:
    """Fallback ligero por hashing de tokens (sin dependencias)."""
    vec = [0.0]*dim
    for tok in _tokenize(text):
        h = hashlib.md5(tok.encode("utf-8")).digest()
        idx = int.from_bytes(h[:4], "little") % dim
        vec[idx] += 1.0
    # L2 normalize
    norm = math.sqrt(sum(v*v for v in vec)) or 1.0
    return [v/norm for v in vec]

def get_embedding(text: str) -> tuple[list[float], str]:
    """Devuelve (vector, modelo). Usa OpenAI-compat si hay base+key; si falla, hashing."""
    if OPENAI_API_KEY and OPENAI_EMBED_BASE_URL:
        try:
            url = f"{OPENAI_EMBED_BASE_URL}/embeddings"
            headers = {"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"}
            payload = {"model": EMBEDDING_MODEL, "input": text[:6000]}
            r = requests.post(url, headers=headers, data=json.dumps(payload), timeout=20)
            r.raise_for_status()
            emb = r.json()["data"][0]["embedding"]
            return emb, EMBEDDING_MODEL
        except Exception:
            pass
    return _hash_embedding(text), f"hash-{256}"
'@
Set-Content -Path "ai/embedding_service.py" -Value $embedding_py -Encoding UTF8

# 2) ai/rag_assistant.py (con base separada para chat)
$assistant_py = @'
# ai/rag_assistant.py
import os, json, requests
from ai.search_service import semantic_search

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
# Base específica para chat (si no está, usa OPENAI_BASE_URL; si tampoco, OpenAI)
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
    hits = semantic_search(question, k=k, filters=None)
    ctx_lines = []
    for p, sc in hits:
        ctx_lines.append(f"- {p.nombre} | Tipo: {p.tipo} | Precio base: {p.precio_base:.2f}\\n  {p.descripcion or ''}")
    context = "\\n".join(ctx_lines) or "Sin datos."

    if OPENAI_API_KEY and OPENAI_CHAT_BASE_URL:
        try:
            msg = [
                {"role":"system", "content": SYS_PROMPT},
                {"role":"user", "content": f"Pregunta: {question}\\n\\nContexto:\\n{context}\\n\\nResponde:"}
            ]
            txt = openai_chat(msg)
            return txt, hits
        except Exception:
            pass
    intro = "No tengo IA externa habilitada; aquí tienes productos relacionados:\\n"
    bullets = "\\n".join([f"- {p.nombre} (tipo {p.tipo}, $ {p.precio_base:.2f})" for p, _ in hits])
    return intro + bullets, hits
'@
Set-Content -Path "ai/rag_assistant.py" -Value $assistant_py -Encoding UTF8

# 3) app.py: inyectar /ai/health dentro de create_app() (antes de 'return app')
$app = Get-Content -Raw "app.py"

if ($app -notmatch '\@app.getKATEX_INLINE_OPEN"/ai/health"KATEX_INLINE_CLOSE') {
  $snippet = @'
    @app.get("/ai/health")
    def ai_health():
        import os, json, requests
        base = os.getenv("OPENAI_CHAT_BASE_URL", os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
        model = os.getenv("OPENAI_CHAT_MODEL", "gpt-4o-mini")
        key = os.getenv("OPENAI_API_KEY")
        try:
            if not key:
                return jsonify({"ok": False, "error": "OPENAI_API_KEY no seteada", "base": base, "model": model}), 400
            r = requests.post(
                f"{base}/chat/completions",
                headers={"Authorization": f"Bearer {key}", "Content-Type":"application/json"},
                data=json.dumps({"model": model, "messages":[{"role":"user","content":"ping"}], "max_tokens": 4}),
                timeout=10
            )
            ok = 200 <= r.status_code < 300
            return jsonify({"ok": ok, "status": r.status_code, "base": base, "model": model, "raw": (r.text[:200] if not ok else "ok")}), (200 if ok else 502)
        except Exception as e:
            return jsonify({"ok": False, "error": str(e), "base": base, "model": model}), 502

'@
  $regex = [regex]'(\n\s*return app\s*\n)'
  $app   = $regex.Replace($app, ($snippet + '$1'), 1)
  Set-Content -Path "app.py" -Value $app -Encoding UTF8
  Write-Host "Ruta /ai/health inyectada en app.py"
} else {
  Write-Host "Ya existe /ai/health en app.py (no se modifica)."
}

Write-Host "Patch Pawan aplicado." -ForegroundColor Green
Write-Host ""
Write-Host "Siguientes pasos:" -ForegroundColor Cyan
Write-Host '1) Seteá variables (PowerShell):'
Write-Host '   $env:OPENAI_CHAT_BASE_URL = "https://api.pawan.krd/cosmosrp-it/v1"'
Write-Host '   $env:OPENAI_API_KEY      = "pk-xxxxxxxxxxxxxxxxxxxx"'
Write-Host '   $env:OPENAI_CHAT_MODEL   = "CosmosRP-V3.5" (si da error, probá "cosmosrp-v3.5")'
Write-Host '   # (Embeddings no los provee Pawan; tu app usa fallback local automáticamente)'
Write-Host ""
Write-Host "2) Levantá la app:  python app.py"
Write-Host "3) Salud IA: http://localhost:5000/ai/health"
Write-Host "4) Asistente: http://localhost:5000/ai/ask"
Write-Host "5) Búsqueda IA: http://localhost:5000/ai/search?q=charizard%20vmax%20fuego"