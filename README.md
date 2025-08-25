PokeTienda — Tienda Pokémon + Chat IA (Groq)
Tienda web hecha con Flask para explorar cartas y productos, abrir packs, gestionar carrito y lista de deseos, y chatear con un asistente IA que sugiere cartas relacionadas.

Incluye una base de datos SQLite (store.db) lista para usar.

Catálogo con filtros y buscador
Detalle de producto con reseñas
Carrito, checkout (simulado) y wishlist
Packs (sobres) con apertura aleatoria
Chat IA (Groq) que responde y sugiere cartas clicables
Búsqueda semántica (si está configurado el servicio correspondiente)
Nota: El generador de “mazos meta” está desactivado por simplicidad y límites de modelo. El chat IA se enfoca en responder y sugerir cartas.

Requisitos
Python 3.10 o superior (recomendado 3.11)
Git
(Opcional) Clave de API de Groq para activar el chat IA: https://console.groq.com/
Instalación rápida (Windows)
Clonar y entrar al proyecto
PowerShell

git clone https://github.com/TU_USUARIO/TU_REPO.git
cd TU_REPO
Crear y activar entorno virtual
PowerShell

python -m venv .venv
.\.venv\Scripts\Activate.ps1
Instalar dependencias
PowerShell

pip install -r requirements.txt
Si no tienes requirements.txt, instala lo básico:

PowerShell

pip install Flask Flask-Login Flask-WTF SQLAlchemy email-validator groq python-dotenv
(Opcional) Configurar IA Groq
PowerShell

$env:GROQ_API_KEY="tu_api_key_de_groq"
# opcional
$env:GROQ_MODEL="llama-3.1-8b-instant"
Ejecutar
PowerShell

python app.py
Abre http://127.0.0.1:5000
Instalación rápida (macOS / Linux)
Bash

git clone https://github.com/TU_USUARIO/TU_REPO.git
cd TU_REPO

python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt
# o, si no hay requirements:
pip install Flask Flask-Login Flask-WTF SQLAlchemy email-validator groq python-dotenv

# (opcional) IA Groq
export GROQ_API_KEY="tu_api_key_de_groq"
export GROQ_MODEL="llama-3.1-8b-instant"

python app.py
# Abre http://127.0.0.1:5000
Base de datos
Este repo incluye store.db en la raíz, lista para usar.
Si eliminas store.db, la app creará tablas vacías automáticamente al iniciar (db.create_all()).
Si quieres “resetear” todo, borra store.db y vuelve a ejecutar.
Importante: store.db es útil para demo y pruebas. Evita subir datos sensibles reales.

Funcionalidades
Home (/) con catálogo, filtros por categoría/expansión/rareza, paginación y destacados.
Detalle de producto (/product/<id>) con reseñas y relacionados.
Carrito (/cart), añadir/eliminar/actualizar, checkout que descuenta stock.
Wishlist (/wishlist) para usuarios logueados.
Packs (/packs/): abrir sobres aleatorios (si el blueprint está presente).
Chat IA (/ai/chat): conversa y recibe sugerencias de cartas clicables.
Búsqueda IA (/ai/search): resultados semánticos (si el servicio está activo).
Salud IA (/ai/groq/health): comprueba si Groq responde.
Autenticación y roles
Registro (/register), login (/login) y logout (/logout).
Rutas protegidas: wishlist, checkout, etc.
Admin de productos (/admin/products) requiere usuario con is_admin=True.
Cómo crear un admin rápidamente:

Python

# PowerShell
$env:FLASK_APP="app:create_app"
flask shell
En el shell:

Python

from models import db, User
u = User.query.filter_by(email="tu@correo.com").first()
u.is_admin = True
db.session.commit()
exit()
IA con Groq
El chat IA usa el endpoint /ai/chat (sugerencias y respuestas generales).
Salud IA: /ai/groq/health → debe devolver {"ok": true, ...} si GROQ_API_KEY está configurada.
Variables de entorno:

GROQ_API_KEY: tu clave de Groq
GROQ_MODEL (opcional): llama-3.1-8b-instant (por defecto) o llama-3.1-70b-versatile
Si no defines GROQ_API_KEY, el chat mostrará mensajes sin IA pero seguirá sugiriendo cartas.

Estructura del proyecto (resumen)
app.py — App Flask, rutas principales y configuración
models.py — Modelos SQLAlchemy
packs_bp.py — Blueprint de packs (si está presente)
templates/ — HTML con Jinja (base.html, index, product, ai_chat, etc.)
static/ — CSS/JS (packs.css, packs.js, etc.)
services/
groq_service.py — Wrapper del SDK de Groq
(otros servicios opcionales)
store.db — Base de datos SQLite incluida
uploads/ — Carpeta para imágenes subidas (se crea sola)
Endpoints principales
Catálogo: /
Producto: /product/<id>
Login / Register / Logout: /login / /register / /logout
Carrito y checkout: /cart / /checkout
Wishlist: /wishlist
Packs: /packs/
Chat IA: /ai/chat
Búsqueda IA: /ai/search
Salud Groq: /ai/groq/health
Variables de entorno útiles
SECRET_KEY — recomendada en producción (si no, usa “dev-secret” por defecto)
GROQ_API_KEY — activa el chat IA Groq
GROQ_MODEL — modelo de Groq (opcional)
Puedes usar un .env (con python-dotenv) si lo prefieres:

text

SECRET_KEY=dev-secret
GROQ_API_KEY=tu_key
GROQ_MODEL=llama-3.1-8b-instant
Solución de problemas (FAQ)
No abre la app / error de import:

Activa el entorno virtual correcto y reinstala dependencias.
Ejecuta siempre desde la carpeta raíz del proyecto.
BuildError en plantillas (url_for hacia ‘register’, ‘packs_bp.algo’):

Asegúrate de que la ruta exista. En plantillas puedes proteger con:
text

{% if has_endpoint('packs_bp.collection') %} ... {% endif %}
Para packs: el blueprint packs_bp.py debe definir “packs_bp = Blueprint(...)” antes de los decoradores @packs_bp.route.
“Import services.groq_service could not be resolved”:

Crea la carpeta services con init.py vacío y groq_service.py dentro.
/ai/groq/health devuelve ok:false:

Configura GROQ_API_KEY en el mismo terminal donde ejecutas “python app.py”.
Cambios sin commitear al hacer git rebase/push:

Haz commit (git add -A; git commit -m "WIP") o usa git stash push -u; luego rebase/push.
La DB cambia siempre y ensucia el repo:

Una vez comiteada, puedes “ignorar” cambios locales:
text

git update-index --skip-worktree store.db
Para volver a trackear:
text

git update-index --no-skip-worktree store.db
Contribuir
Crea una rama desde main:
text

git switch -c feat/tu-feature
Commit y push:
text

git add -A
git commit -m "feat: tu-feature"
git push -u origin feat/tu-feature
Abre un Pull Request.
Consejos:

No subas API keys ni contraseñas.
Si incluyes store.db, procura que pese menos de 100 MB. Si no, usa Git LFS.
Licencia
Elige la licencia que prefieras (por ejemplo MIT). Si no defines una, por defecto el proyecto no tiene licencia pública.

—
