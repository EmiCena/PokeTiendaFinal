# ai/search_service.py
import json, hashlib, time
from sqlalchemy import text
from models import db, PokemonProducto
from ai.embedding_service import get_embedding
from ai.vector_utils import cosine

def _doc_for_product(p: PokemonProducto) -> str:
    parts = [
        p.nombre or "",
        p.descripcion or "",
        f"Tipo: {p.tipo or ''}",
        f"Categoría: {p.categoria or ''}",
    ]
    for k in ("expansion","rarity","language","condition","card_number"):
        v = getattr(p,k,None)
        if v: parts.append(f"{k}: {v}")
    return "\n".join(parts)

def _fingerprint(text: str) -> str:
    return hashlib.sha1(text.encode("utf-8")).hexdigest()

def upsert_product_embedding(p: PokemonProducto) -> None:
    doc = _doc_for_product(p)
    fp = _fingerprint(doc)
    row = db.session.execute(text("SELECT fingerprint FROM product_embeddings WHERE product_id=:pid"),
                             {"pid": p.id}).fetchone()
    if row and row[0] == fp:
        return
    vec, model = get_embedding(doc)
    db.session.execute(text("""
        INSERT INTO product_embeddings (product_id, model, vector, fingerprint, updated_at)
        VALUES (:pid, :m, :v, :f, :ts)
        ON CONFLICT(product_id) DO UPDATE SET
          model=excluded.model, vector=excluded.vector, fingerprint=excluded.fingerprint, updated_at=excluded.updated_at
    """), {"pid": p.id, "m": model, "v": json.dumps(vec), "f": fp, "ts": time.strftime("%Y-%m-%d %H:%M:%S")})
    db.session.commit()

def semantic_search(query: str, k: int = 12, filters: dict | None = None):
    """Retorna lista de (producto, score) ordenada."""
    if not query.strip():
        return []
    # Embedding de la consulta
    qv, _ = get_embedding(query)
    # Cargar todas las vectors
    rows = db.session.execute(text("SELECT product_id, vector FROM product_embeddings")).fetchall()
    if not rows:
        # Si no hay índice, crea embeddings básicos on-the-fly (fallback mínimo)
        for p in PokemonProducto.query.all():
            upsert_product_embedding(p)
        rows = db.session.execute(text("SELECT product_id, vector FROM product_embeddings")).fetchall()

    scored = []
    for pid, vj in rows:
        try:
            vec = json.loads(vj)
        except Exception:
            continue
        score = cosine(qv, vec)
        scored.append((pid, score))
    scored.sort(key=lambda x: x[1], reverse=True)

    # filtrar por filtros de catálogo si vienen (cat/tipo/etc.)
    result = []
    for pid, score in scored[: max(k*3, k)]:
        p = PokemonProducto.query.get(pid)
        if not p: continue
        if filters:
            if "cat" in filters and filters["cat"] and (p.categoria or "").lower() != filters["cat"].lower():
                continue
            if "tipo" in filters and filters["tipo"] and (p.tipo or "").lower() != filters["tipo"].lower():
                continue
        result.append((p, score))
        if len(result) >= k: break
    return result