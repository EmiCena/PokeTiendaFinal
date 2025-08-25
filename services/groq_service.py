import os
from groq import Groq

GROQ_API_KEY = os.getenv("GROQ_API_KEY")
GROQ_MODEL = os.getenv("GROQ_MODEL", "llama-3.1-8b-instant")

def _client():
    if not GROQ_API_KEY:
        return None
    return Groq(api_key=GROQ_API_KEY)

def groq_chat(messages, model=None, temperature=0.3, max_tokens=512, stream=False, **kwargs):
    client = _client()
    if not client:
        raise RuntimeError("GROQ_API_KEY no seteada")
    mdl = model or GROQ_MODEL

    if stream:
        out = ""
        for chunk in client.chat.completions.create(
            model=mdl, messages=messages,
            temperature=temperature, max_tokens=max_tokens, stream=True, **kwargs
        ):
            delta = chunk.choices[0].delta.content or ""
            out += delta
        return out

    resp = client.chat.completions.create(
        model=mdl, messages=messages,
        temperature=temperature, max_tokens=max_tokens, **kwargs
    )
    return (resp.choices[0].message.content or "").strip()