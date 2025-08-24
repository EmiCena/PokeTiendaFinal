# patch_ui_daisy.ps1
param(
  [switch]$Commit,
  [switch]$Push,
  [string]$Branch = "feat/ui-daisy"
)

$ErrorActionPreference = "Stop"
function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Backup($path,$destDir){
  if(Test-Path $path){
    Ensure-Dir $destDir
    Copy-Item $path (Join-Path $destDir ([IO.Path]::GetFileName($path))) -Force
  }
}

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = "backups\ui_$ts"
Ensure-Dir "templates"

Write-Host "== Backup de plantillas a $backupDir ==" -ForegroundColor Cyan
Backup "templates\base.html" $backupDir
Backup "templates\index.html" $backupDir
Backup "templates\product.html" $backupDir
Backup "templates\packs.html" $backupDir

# 1) base.html (Tailwind + DaisyUI por CDN, navbar moderna, toasts, toggle tema)
$base = @'
<!doctype html>
<html lang="es" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{% block title %}PokeTienda{% endblock %}</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = { theme: { extend: { colors: { brand:{DEFAULT:"#60a5fa","2":"#7dd3fc"}, accent:"#22c55e" } } } }
  </script>
  <link href="https://cdn.jsdelivr.net/npm/daisyui@4.12.10/dist/full.min.css" rel="stylesheet" />
  <script src="https://code.iconify.design/iconify-icon/2.1.0/iconify-icon.min.js"></script>
  {% block head %}{% endblock %}
</head>
<body class="min-h-screen bg-base-200 text-base-content">
  <header class="sticky top-0 z-50 backdrop-blur bg-base-100/70 border-b border-base-300">
    <div class="navbar container mx-auto px-4">
      <div class="flex-1">
        <a href="{{ url_for('index') }}" class="btn btn-ghost normal-case text-xl font-extrabold">
          <span class="w-6 h-6 rounded-md bg-gradient-to-br from-brand to-brand-2 grid place-items-center mr-2">★</span>
          PokeTienda
        </a>
      </div>
      <div class="flex-none gap-2">
        <ul class="menu menu-horizontal px-1">
          <li><a href="{{ url_for('index') }}">Catálogo</a></li>
          {% if 'packs_bp' in current_app.blueprints %}
            <li><a href="{{ url_for('packs_bp.packs_home') }}">Packs</a></li>
            <li><a href="{{ url_for('packs_bp.collection') }}">Colección</a></li>
          {% endif %}
          <li><a href="{{ url_for('ai_search') }}">AI Búsqueda</a></li>
          <li><a href="{{ url_for('ai_ask') }}">AI Asistente</a></li>
        </ul>

        <button id="themeToggle" class="btn btn-ghost btn-square" title="Cambiar tema">
          <iconify-icon icon="line-md:sunny-outline-to-moon-alt-loop-transition"></iconify-icon>
        </button>

        {% if current_user.is_authenticated %}
          <div class="dropdown dropdown-end">
            <label tabindex="0" class="btn btn-ghost avatar placeholder">
              <div class="bg-neutral text-neutral-content w-8 rounded-full">
                <span>{{ (current_user.email or 'U')[:1]|upper }}</span>
              </div>
            </label>
            <ul tabindex="0" class="menu menu-sm dropdown-content mt-3 z-[1] p-2 shadow bg-base-100 rounded-box w-52">
              <li><a href="{{ url_for('profile') }}">Perfil</a></li>
              <li><a href="{{ url_for('orders_list') }}">Mis pedidos</a></li>
              <li><a href="{{ url_for('cart_view') }}">Carrito</a></li>
              {% if getattr(current_user,'is_admin',False) %}
                <li><a href="{{ url_for('admin_products') }}">Admin productos</a></li>
                {% if 'packs_bp' in current_app.blueprints %}
                <li><a href="{{ url_for('packs_bp.admin_packs') }}">Admin packs</a></li>
                {% endif %}
              {% endif %}
              <li><a href="{{ url_for('logout') }}">Salir</a></li>
            </ul>
          </div>
        {% else %}
          <a class="btn btn-outline" href="{{ url_for('login') }}">Entrar</a>
          <a class="btn btn-primary" href="{{ url_for('register') }}">Registro</a>
        {% endif %}
      </div>
    </div>
  </header>

  <main class="container mx-auto px-4 py-4">
    {% block content %}{% endblock %}
  </main>

  <footer class="container mx-auto px-4 py-6 border-t border-base-300 text-sm text-base-content/70">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div>© PokeTienda</div>
      <nav class="flex gap-3">
        <a class="link link-hover" href="{{ url_for('index') }}">Inicio</a>
        <a class="link link-hover" href="{{ url_for('ai_health') }}">Estado IA</a>
      </nav>
    </div>
  </footer>

  <div class="toast toast-end">
    {% with msgs = get_flashed_messages(with_categories=True) %}
      {% if msgs %}
        {% for cat, msg in msgs %}
          <div class="alert {{ 'alert-success' if cat=='success' else 'alert-info' if cat=='info' else 'alert-warning' if cat=='warning' else 'alert-error' }}">
            <span>{{ msg }}</span>
          </div>
        {% endfor %}
      {% endif %}
    {% endwith %}
  </div>

  <script>
    (() => {
      const root = document.documentElement;
      const saved = localStorage.getItem("theme");
      if (saved) root.setAttribute("data-theme", saved);
      const btn = document.getElementById("themeToggle");
      btn && btn.addEventListener("click", () => {
        const cur = root.getAttribute("data-theme") || "dark";
        const next = cur === "dark" ? "light" : "dark";
        root.setAttribute("data-theme", next);
        localStorage.setItem("theme", next);
      });
      setTimeout(() => {
        document.querySelectorAll('.toast .alert').forEach(el=>{
          el.classList.add('opacity-0','transition','duration-300');
          setTimeout(()=>el.remove(),300);
        })
      }, 3500);
    })();
  </script>
  {% block scripts %}{% endblock %}
</body>
</html>
'@
Set-Content "templates\base.html" $base -Encoding UTF8
Write-Host "templates/base.html actualizado." -ForegroundColor Green

# 2) index.html (hero + filtros + cards + paginación con DaisyUI)
$index = @'
{% extends "base.html" %}
{% block title %}Catálogo · PokeTienda{% endblock %}
{% block content %}

<section class="hero bg-gradient-to-br from-base-200 to-base-100 border border-base-300 rounded-2xl p-6 mb-6">
  <div class="flex flex-wrap items-center justify-between gap-4">
    <div>
      <div class="badge badge-outline">Catálogo</div>
      <h1 class="text-2xl font-extrabold mt-2">Descubre peluches, figuras y cartas TCG</h1>
      <p class="opacity-70">Con precios dinámicos, packs con animación y búsqueda inteligente.</p>
    </div>
    <div class="flex gap-2">
      {% if 'packs_bp' in current_app.blueprints %}
        <a class="btn btn-primary" href="{{ url_for('packs_bp.packs_home') }}"><iconify-icon icon="mdi:cards-outline"></iconify-icon> Abrir packs</a>
      {% endif %}
      <a class="btn btn-outline" href="{{ url_for('ai_search') }}"><iconify-icon icon="mdi:magnify"></iconify-icon> AI Búsqueda</a>
    </div>
  </div>
</section>

<form method="get" class="flex flex-wrap items-end gap-2 mb-4">
  <div>
    <label class="label"><span class="label-text">Tipo</span></label>
    <select name="tipo" class="select select-bordered">
      <option value="">(todos)</option>
      <option value="cartas" {{ 'selected' if tipo=='cartas' else '' }}>Cartas</option>
      <option value="peluche" {{ 'selected' if tipo=='peluche' else '' }}>Peluche</option>
      <option value="figura" {{ 'selected' if tipo=='figura' else '' }}>Figura</option>
    </select>
  </div>
  <div>
    <label class="label"><span class="label-text">Categoría</span></label>
    <select name="cat" class="select select-bordered">
      <option value="">(todas)</option>
      <option value="tcg" {{ 'selected' if cat=='tcg' else '' }}>TCG</option>
      <option value="general" {{ 'selected' if cat=='general' else '' }}>General</option>
    </select>
  </div>
  <div>
    <label class="label"><span class="label-text">Orden</span></label>
    <select name="sort" class="select select-bordered">
      <option value="new" {{ 'selected' if sort=='new' else '' }}>Novedades</option>
      <option value="price_asc" {{ 'selected' if sort=='price_asc' else '' }}>Precio ↑</option>
      <option value="price_desc" {{ 'selected' if sort=='price_desc' else '' }}>Precio ↓</option>
    </select>
  </div>
  <div class="grow">
    <label class="label"><span class="label-text">Buscar</span></label>
    <input name="q" value="{{ q }}" placeholder="Pikachu, sv1-001, peluche..." class="input input-bordered w-full">
  </div>
  <button class="btn btn-primary"><iconify-icon icon="mdi:tune-variant"></iconify-icon> Aplicar</button>
</form>

{% if products|length == 0 %}
  <div class="alert alert-info">
    <iconify-icon icon="mdi:information"></iconify-icon>
    <span>No hay productos.</span>
  </div>
{% else %}
  <div class="grid gap-4 grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4">
    {% for p in products %}
      <div class="card bg-base-100 shadow-sm border border-base-300">
        <figure class="aspect-[4/3] bg-base-200">
          {% if p.image_url %}<img src="{{ p.image_url }}" alt="{{ p.nombre }}" class="object-cover w-full h-full">
          {% else %}<div class="skeleton w-full h-full"></div>{% endif %}
        </figure>
        <div class="card-body p-4">
          <h2 class="card-title text-base">{{ p.nombre }}</h2>
          <p class="opacity-70 text-sm">{{ p.tipo }} · {{ p.categoria }}</p>
          <div class="flex flex-wrap gap-2 my-1">
            {% if p.rarity %}<div class="badge badge-outline">{{ p.rarity }}</div>{% endif %}
            {% if p.expansion %}<div class="badge badge-outline">{{ p.expansion }}</div>{% endif %}
          </div>
          <div class="card-actions justify-between items-center mt-2">
            <div class="font-extrabold">${{ "%.2f"|format(p.precio_base) }}</div>
            <a class="btn btn-sm" href="{{ url_for('product_detail', pid=p.id) }}">Ver</a>
          </div>
          <form class="mt-2" method="post" action="{{ url_for('cart_add', pid=p.id) }}">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <input type="hidden" name="qty" value="1">
            <button class="btn btn-primary btn-block btn-sm"><iconify-icon icon="mdi:cart"></iconify-icon> Añadir</button>
          </form>
        </div>
      </div>
    {% endfor %}
  </div>

  {% if pag and (pag.pages or 0) > 1 %}
  <div class="join mt-6 justify-center flex">
    {% if pag.has_prev %}
      <a class="join-item btn" href="{{ url_for('index', q=q, tipo=tipo, cat=cat, sort=sort, page=pag.prev_num) }}">«</a>
    {% else %}<button class="join-item btn" disabled>«</button>{% endif %}
    <button class="join-item btn">Página {{ pag.page }} / {{ pag.pages }}</button>
    {% if pag.has_next %}
      <a class="join-item btn" href="{{ url_for('index', q=q, tipo=tipo, cat=cat, sort=sort, page=pag.next_num) }}">»</a>
    {% else %}<button class="join-item btn" disabled>»</button>{% endif %}
  </div>
  {% endif %}
{% endif %}
{% endblock %}
'@
Set-Content "templates\index.html" $index -Encoding UTF8
Write-Host "templates/index.html actualizado." -ForegroundColor Green

# 3) product.html (detalle moderno con CTA, reviews y AI)
$product = @'
{% extends "base.html" %}
{% block title %}{{ p.nombre }} · PokeTienda{% endblock %}
{% block content %}
<div class="grid md:grid-cols-2 gap-6">
  <div class="card bg-base-100 border border-base-300">
    <figure class="aspect-[4/3] bg-base-200">
      {% if p.image_url %}<img src="{{ p.image_url }}" alt="{{ p.nombre }}" class="object-contain w-full h-full">{% endif %}
    </figure>
  </div>
  <div class="space-y-3">
    <div class="badge badge-outline">Producto</div>
    <h1 class="text-2xl font-extrabold">{{ p.nombre }}</h1>
    <p class="opacity-70">{{ p.tipo }} · {{ p.categoria }}</p>
    <div class="flex flex-wrap gap-2">
      {% if p.rarity %}<div class="badge badge-outline">{{ p.rarity }}</div>{% endif %}
      {% if p.expansion %}<div class="badge badge-outline">{{ p.expansion }}</div>{% endif %}
      {% if p.language %}<div class="badge badge-outline">{{ p.language }}</div>{% endif %}
      {% if p.condition %}<div class="badge badge-outline">{{ p.condition }}</div>{% endif %}
    </div>
    <div class="text-3xl font-extrabold">${{ "%.2f"|format(precio) }}</div>
    <div class="flex gap-2">
      <form method="post" action="{{ url_for('cart_add', pid=p.id) }}">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <input type="hidden" name="qty" value="1">
        <button class="btn btn-primary"><iconify-icon icon="mdi:cart"></iconify-icon> Añadir al carrito</button>
      </form>
      {% if current_user.is_authenticated %}
        {% if in_wishlist %}
          <form method="post" action="{{ url_for('wishlist_remove', pid=p.id) }}"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><button class="btn">Quitar de favoritos</button></form>
        {% else %}
          <form method="post" action="{{ url_for('wishlist_add', pid=p.id) }}"><input type="hidden" name="csrf_token" value="{{ csrf_token() }}"><button class="btn btn-outline">Añadir a favoritos</button></form>
        {% endif %}
      {% endif %}
    </div>
    {% if razones and razones|length>0 %}
      <div class="alert alert-info mt-2"><span>Precio dinámico: {{ razones|join(', ') }}</span></div>
    {% endif %}
    <div class="prose max-w-none mt-3"><p>{{ p.descripcion }}</p></div>

    <details class="collapse collapse-arrow border border-base-300 rounded-box">
      <summary class="collapse-title text-base font-medium">Pregúntale a la IA sobre este producto</summary>
      <div class="collapse-content">
        <form method="post" action="{{ url_for('ai_ask_product', pid=p.id) }}" class="flex gap-2 mt-2">
          <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
          <input class="input input-bordered w-full" name="q" placeholder="¿Es edición limitada?">
          <button class="btn btn-primary">Preguntar</button>
        </form>
        {% if ai_q %}
          <div class="mt-3">
            <div class="badge badge-outline">Pregunta</div>
            <p class="mt-1">{{ ai_q }}</p>
            <div class="badge badge-outline mt-2">Respuesta</div>
            <p class="mt-1">{{ ai_answer }}</p>
          </div>
        {% endif %}
      </div>
    </details>
  </div>
</div>

{% if recs and recs|length>0 %}
<h3 class="text-xl font-bold mt-6 mb-2">También te puede interesar</h3>
<div class="grid gap-4 grid-cols-1 sm:grid-cols-2 md:grid-cols-4">
  {% for r in recs %}
  <div class="card bg-base-100 border border-base-300">
    <figure class="aspect-[4/3] bg-base-200">{% if r.image_url %}<img src="{{ r.image_url }}" alt="{{ r.nombre }}" class="object-cover w-full h-full">{% endif %}</figure>
    <div class="card-body p-4">
      <div class="card-title text-base">{{ r.nombre }}</div>
      <div class="opacity-70 text-sm">{{ r.tipo }} · {{ r.categoria }}</div>
      <div class="flex justify-between items-center mt-2">
        <div class="font-extrabold">${{ "%.2f"|format(r.precio_base) }}</div>
        <a class="btn btn-sm" href="{{ url_for('product_detail', pid=r.id) }}">Ver</a>
      </div>
    </div>
  </div>
  {% endfor %}
</div>
{% endif %}

<h3 class="text-xl font-bold mt-6 mb-2">Reseñas</h3>
<div class="grid md:grid-cols-2 gap-4">
  <div>
    {% if reviews and reviews|length>0 %}
      <ul class="space-y-2">
        {% for rv in reviews %}
        <li class="card bg-base-100 border border-base-300 p-3">
          <div class="font-bold">★ {{ rv.rating }}/5</div>
          <div class="opacity-70 text-sm">{{ rv.created_at }}</div>
          <p class="mt-1">{{ rv.comment }}</p>
        </li>
        {% endfor %}
      </ul>
    {% else %}
      <div class="alert alert-info">Sé el primero en reseñar este producto.</div>
    {% endif %}
  </div>
  <div>
    {% if current_user.is_authenticated %}
      <form method="post" action="{{ url_for('post_review', pid=p.id) }}" class="card bg-base-100 border border-base-300 p-4 space-y-2">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <label class="form-control w-full">
          <div class="label"><span class="label-text">Puntuación</span></div>
          <select name="rating" class="select select-bordered">
            {% for i in range(1,6) %}
              <option value="{{ i }}">{{ i }}</option>
            {% endfor %}
          </select>
        </label>
        <label class="form-control">
          <div class="label"><span class="label-text">Comentario</span></div>
          <textarea name="comment" class="textarea textarea-bordered" rows="3"></textarea>
        </label>
        <button class="btn btn-primary">Enviar</button>
      </form>
    {% else %}
      <div class="alert alert-info">Inicia sesión para dejar una reseña.</div>
    {% endif %}
  </div>
</div>
{% endblock %}
'@
Set-Content "templates\product.html" $product -Encoding UTF8
Write-Host "templates/product.html actualizado." -ForegroundColor Green

# 4) packs.html (lista de sets y sobre abierto con DaisyUI; mantiene animación existente si tienes packs.css/js)
$packs = @'
{% extends "base.html" %}
{% block title %}Packs · PokeTienda{% endblock %}
{% block head %}
<link rel="stylesheet" href="{{ url_for('static', filename='packs.css') }}">
{% endblock %}
{% block content %}
<h1 class="text-2xl font-extrabold mb-3">Packs</h1>

{% if opened_set %}
  <div class="mb-3">
    <div class="grid gap-4 grid-cols-1 sm:grid-cols-2 md:grid-cols-5 lg:grid-cols-5">
      {% for c in cards %}
      <div class="card bg-base-100 border border-base-300" style="transition-delay: {{ (loop.index0 * 80)|int }}ms;">
        <div class="card3d">
          <div class="face front"></div>
          <div class="face back">
            <img src="{{ c.image_url or url_for('static', filename='no-card.png') }}" alt="{{ c.name }}">
            <div class="meta">{{ c.name }}</div>
            <div class="muted">{{ c.tcg_card_id }} · {{ c.rarity or '-' }}</div>
            {% if c.duplicate %}<div class="dup">Duplicado ★</div>{% endif %}
          </div>
        </div>
      </div>
      {% endfor %}
    </div>
    {% if dup_points and dup_points>0 %}
      <div class="alert alert-info mt-3"><span>Puntos estrella obtenidos: <b>{{ dup_points }}</b></span></div>
    {% endif %}
    <div class="mt-4 flex gap-2">
      <a class="btn" href="{{ url_for('packs_bp.packs_home') }}">Volver</a>
      {% if current_user.is_authenticated and current_user.is_admin %}
      <form method="post" action="{{ url_for('packs_bp.packs_open') }}" class="open-pack-form">
        <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
        <input type="hidden" name="set" value="{{ opened_set }}">
        <button class="btn btn-primary">Abrir otro</button>
      </form>
      {% endif %}
    </div>
  </div>

  {% if current_user.is_authenticated and current_user.is_admin %}
  <div class="hidden" id="preopen">
     <div class="packbox pulse"><div class="shine"></div><div class="label">Abriendo sobre...</div></div>
  </div>
  {% endif %}

{% else %}
  <p class="opacity-70 mb-3">Abre 1 pack diario por set. También puedes usar tus bonus tokens acumulados por compras.</p>
  {% if sets|length == 0 %}
    <div class="alert alert-info">No hay sets disponibles.</div>
  {% else %}
  <div class="grid gap-4 grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4">
    {% for s in sets %}
    <div class="card bg-base-100 border border-base-300">
      <figure class="aspect-[4/3] bg-base-200">
        {% if s.image %}<img src="{{ s.image }}" alt="{{ s.set_name }}" class="object-cover w-full h-full">{% endif %}
      </figure>
      <div class="card-body p-4">
        <div class="card-title text-base">{{ s.set_name }}</div>
        <div class="opacity-70">{{ s.set_code|upper }}</div>
        <div class="flex gap-2 my-1">
          {% if s.daily %}<div class="badge badge-success badge-outline">Diario disponible</div>
          {% else %}<div class="badge">Usado hoy</div>{% endif %}
          <div class="badge">Bonus: {{ s.bonus }}</div>
        </div>
        <form method="post" action="{{ url_for('packs_bp.packs_open') }}" class="open-pack-form">
          <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
          <input type="hidden" name="set" value="{{ s.set_code }}">
          <button class="btn btn-primary" {% if not s.daily and s.bonus==0 %}disabled{% endif %}>Abrir pack</button>
        </form>
      </div>
    </div>
    {% endfor %}
  </div>

  <div class="hidden" id="preopen">
     <div class="packbox pulse"><div class="shine"></div><div class="label">Abriendo sobre...</div></div>
  </div>
  {% endif %}
{% endif %}
{% endblock %}
{% block scripts %}
<script defer src="{{ url_for('static', filename='packs.js') }}"></script>
<script>
  // Añade la clase reveal para animar al cargar resultado
  document.addEventListener("DOMContentLoaded", ()=>{
    const stage = document.querySelector(".grid");
    if(stage){ setTimeout(()=> document.body.classList.add("reveal"), 50); }
  });
</script>
{% endblock %}
'@
Set-Content "templates\packs.html" $packs -Encoding UTF8
Write-Host "templates/packs.html actualizado." -ForegroundColor Green

# 5) Git commit opcional
if($Commit){
  try { git --version | Out-Null } catch { Write-Warning "Git no está disponible en PATH. Saltando commit."; exit }
  $cur = (git branch --show-current 2>$null)
  if([string]::IsNullOrWhiteSpace($cur)){ try { git switch -c $Branch } catch { git checkout -b $Branch } }
  elseif($cur -ne $Branch){ try { git switch $Branch } catch { git checkout -b $Branch } }
  git add templates\base.html templates\index.html templates\product.html templates\packs.html
  git commit -m "feat(ui): Tailwind + DaisyUI theme; moderniza base/index/product/packs"
  if($Push){
    git push -u origin $Branch
  } else {
    Write-Host "Commit creado en rama $Branch. Usa -Push para subir." -ForegroundColor Yellow
  }
}
Write-Host "Listo. UI actualizada. Revisa la app y el PR si creaste rama." -ForegroundColor Green