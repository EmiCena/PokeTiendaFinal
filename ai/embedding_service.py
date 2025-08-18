# ai/embedding_service.py
import os, re, json, hashlib, math, requests

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
# Base especÃ­fica para embeddings (si no hay, usa OPENAI_BASE_URL; si tampoco, OpenAI)
OPENAI_EMBED_BASE_URL = os.getenv("OPENAI_EMBED_BASE_URL", os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"))
EMBEDDING_MODEL = os.getenv("OPENAI_EMBED_MODEL", "text-embedding-3-small")

WORD_RE = re.compile(r"[A-Za-zÃÃ‰ÃÃ“ÃšÃœÃ‘Ã¡Ã©Ã­Ã³ÃºÃ¼Ã±0-9]+")

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
