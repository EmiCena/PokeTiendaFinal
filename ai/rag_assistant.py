# ai/rag_assistant.py
import os, json, requests
from ai.search_service import semantic_search
from ai.cache_service import get_cache, set_cache, make_key

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_CHAT_BASE_URL = os.getenv("OPENAI_CHAT_BASE_URL", os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
CHAT_MODEL = os.getenv("OPENAI_CHAT_MODEL", "gpt-4o-mini")

SYS_PROMPT = (
 "Eres un asistente de una tienda PokÃ©mon. Responde de forma breve y clara, "
 "en espaÃ±ol neutro, usando la informaciÃ³n de 'contexto' que te doy. "
 "Si no estÃ¡s seguro, dilo y sugiere productos relacionados."
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
    intro = "No tengo IA externa habilitada; aquÃ­ tienes productos relacionados:\n"
    bullets = "\n".join([f"- {p.nombre} (tipo {p.tipo}, $ {p.precio_base:.2f})" for p, _ in hits])
    txt = intro + bullets
    set_cache(cache_key, json.dumps({"answer": txt, "hit_ids": hit_ids}))
    return txt, hits
