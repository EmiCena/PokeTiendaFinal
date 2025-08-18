# ai/vector_utils.py
import math
def cosine(a: list[float], b: list[float]) -> float:
    s = 0.0; na = 0.0; nb = 0.0
    la = len(a); lb = len(b)
    for i in range(min(la, lb)):
        va = a[i]; vb = b[i]
        s += va*vb; na += va*va; nb += vb*vb
    den = math.sqrt(na) * math.sqrt(nb)
    return s/den if den else 0.0