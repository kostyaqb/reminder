#!/bin/bash
set -e
echo "🚀 Установка Ultra-Lite Telegram Bot..."

# Цвета
GREEN='\033[0;32m'
NC='\033[0m'
success() { echo -e "${GREEN}✅ $1${NC}"; }

# Проверка Docker
if ! command -v docker &> /dev/null; then echo "Docker not found"; exit 1; fi
COMPOSE_CMD="docker compose"
command -v docker-compose &> /dev/null && COMPOSE_CMD="docker-compose"

mkdir -p app/data app/models

# Запрос токена
read -p "🔑 Token: " BOT_TOKEN
cat > .env << EOF
BOT_TOKEN=$BOT_TOKEN
DB_PATH=data/bot.db
MODEL_NAME=tiny-int8
LANGUAGE=ru
EOF
success ".env created"

# requirements.txt (ТОЛЬКО ЛЕГКИЕ ПАКЕТЫ, БЕЗ TORCH И FASTER-WHISPER)
cat > app/requirements.txt << 'EOF'
aiogram>=3.0.0
apscheduler>=3.10.0
python-dotenv>=1.0.0
ffmpeg-python>=0.2.0
aiosqlite>=0.19.0
dateparser>=1.1.8
ctranslate2>=4.0.0
tokenizers>=0.15.0
numpy<2.0.0
EOF
success "requirements.txt created (NO TORCH)"

# main.py (Адаптирован под ctranslate2 напрямую)
cat > app/main.py << 'PYTHON_EOF'
import os
import re
import time
import asyncio
from datetime import datetime, timezone
from pathlib import Path
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv
import ffmpeg
import aiosqlite
from dateparser import search_dates
import ctranslate2
import tokenizers

load_dotenv()

TOKEN = os.getenv("BOT_TOKEN")
DB_PATH = os.getenv("DB_PATH", "data/bot.db")
MODEL_NAME = os.getenv("MODEL_NAME", "tiny-int8")
LANGUAGE = os.getenv("LANGUAGE", "ru")

bot = Bot(token=TOKEN)
dp = Dispatcher()
scheduler = AsyncIOScheduler()

# Загрузка модели Whisper через CTranslate2 (напрямую, без обертки faster-whisper)
# Мы используем репозиторий huggingface для скачивания конвертированной модели
def load_model():
    model_path = f"models/{MODEL_NAME}"
    if not Path(model_path).exists():
        print(f"📥 Downloading model {MODEL_NAME}... (this may take a minute)")
        # Используем huggingface_hub для скачивания готовой CTranslate2 модели
        from huggingface_hub import snapshot_download
        # tiny-int8 модель от Systran
        repo_id = f"Systran/faster-whisper-{MODEL_NAME.replace('-int8', '')}"
        # Внимание: стандартная загрузка faster-whisper моделей требует конвертации. 
        # Для ultra-lite мы будем использовать встроенный механизм faster-whisper, 
        # но установим его ВРУЧНУЮ без torch, если возможно, или используем простой трюк.
        
        # ТРЮК: Установим faster-whisper НО заблокируем torch через pip config или просто надеясь, 
        # что ctranslate2 хватит. 
        # НА САМОМ ДЕЛЕ: Проще всего использовать faster-whisper, но установить его ТАК:
        # pip install faster-whisper --no-deps && pip install ctranslate2 tokenizers numpy
        # Но в requirements выше мы уже убрали faster-whisper.
        
        # ДАВАЙТЕ СДЕЛАЕМ ПРОЩЕ: Вернем faster-whisper, но ЗАПРЕТИМ ему ставить torch.
        raise Exception("Use the updated install script logic below")

# ПЕРЕПИСАННАЯ ЛОГИКА ЗАГРУЗКИ ДЛЯ ULTRA LITE:
# Мы будем использовать faster-whisper, но установим его особым образом в Dockerfile.
# А здесь код останется почти таким же, как был, но импорты будут работать, 
# если в системе есть только ctranslate2.

# Однако, проще всего для пользователя - использовать стандартный faster-whisper, 
# но собрать образ так, чтобы он НЕ качал torch.

print("⚠️ Switching to robust lite mode...")

# Если мы здесь, значит мы вернемся к faster-whisper, но ограничим зависимости.
# Для этого я обновлю Dockerfile ниже.
PYTHON_EOF

# ПРАВИЛЬНЫЙ main.py для работы с ограниченным окружением
cat > app/main.py << 'PYTHON_EOF'
import os
import re
import time
import asyncio
from datetime import datetime, timezone
from pathlib import Path
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from dotenv import load_dotenv
import ffmpeg
import aiosqlite
from dateparser import search_dates

# Пробуем импортировать faster_whisper. Если его нет, будет ошибка, но мы поставим его особым образом.
try:
    from faster_whisper import WhisperModel
except ImportError:
    raise RuntimeError("faster-whisper not installed. Check Dockerfile.")

load_dotenv()

TOKEN = os.getenv("BOT_TOKEN")
DB_PATH = os.getenv("DB_PATH", "data/bot.db")
MODEL_NAME = os.getenv("MODEL_NAME", "tiny-int8")
LANGUAGE = os.getenv("LANGUAGE", "ru")

bot = Bot(token=TOKEN)
dp = Dispatcher()
scheduler = AsyncIOScheduler()

print(f"📦 Loading model: {MODEL_NAME}")
model = WhisperModel(MODEL_NAME, device="cpu", compute_type="int8")

async def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""CREATE TABLE IF NOT EXISTS reminders (id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, text TEXT, remind_at REAL)""")
        await db.commit()

def parse_free_form_reminder(text: str):
    if not text or len(text.strip()) < 3: return None, None, "Short."
    matches = search_dates(text, languages=['ru', 'en'], settings={'PREFER_DATES_FROM': 'future'})
    if not matches: return None, None, None
    time_phrase, dt = matches[0]
    if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
    else: dt = dt.astimezone(timezone.utc)
    
    cleaned = re.sub(re.escape(time_phrase), '', text, count=1, flags=re.IGNORECASE)
    cleaned = re.sub(r'^(напомни|поставь|создай|позвони|сделай)\s*', '', cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip('.,;:!?- ')
    if not cleaned: cleaned = "No text"
    if dt <= datetime.now(timezone.utc): return None, None, f"Time {dt.strftime('%H:%M')} passed."
    return dt, cleaned, None

async def create_reminder(chat_id: int, text: str, silent: bool = False):
    dt, task, error = parse_free_form_reminder(text)
    if error:
        if not silent: await bot.send_message(chat_id, error)
        return False
    if not dt: return False
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("INSERT INTO reminders (chat_id, text, remind_at) VALUES (?, ?, ?)", (chat_id, task, dt.timestamp()))
        await db.commit()
    await bot.send_message(chat_id, f"✅ Reminder: {dt.strftime('%d.%m %H:%M')}\n📝 {task}")
    return True

@dp.message(F.voice)
async def handle_voice(message: types.Message):
    voice = await message.bot.get_file(message.voice.file_id)
    ogg_path = f"/tmp/voice_{message.voice.file_id}.ogg"
    wav_path = ogg_path.replace(".ogg", ".wav")
    await message.bot.download_file(voice.file_path, ogg_path)
    try:
        ffmpeg.input(ogg_path).output(wav_path, format="wav", acodec="pcm_s16le", ar=16000, ac=1).run(overwrite_output=True, quiet=True)
        segments, _ = model.transcribe(wav_path, language=LANGUAGE, beam_size=1)
        recognized = " ".join([segment.text for segment in segments]).strip()
        if recognized: await create_reminder(message.chat.id, recognized, silent=True)
        else: await message.reply("🎤 Not recognized.")
    except Exception as e:
        await message.reply(f"❌ Error: {str(e)}")
    finally:
        for p in (ogg_path, wav_path):
            if Path(p).exists(): Path(p).unlink()

@dp.message(F.text & ~F.command)
async def handle_text_reminder(message: types.Message):
    await create_reminder(message.chat.id, message.text)

@dp.message(Command("help"))
async def cmd_help(message: types.Message):
    await message.reply("Examples:\n• tomorrow at 2pm buy milk\n• call mom in 1 hour")

async def check_reminders():
    now_ts = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute("SELECT id, chat_id, text FROM reminders WHERE remind_at <= ?", (now_ts,)) as cur:
            rows = await cur.fetchall()
            for _, chat_id, text in rows:
                await bot.send_message(chat_id, f"⏰ {text}")
            await db.execute("DELETE FROM reminders WHERE remind_at <= ?", (now_ts,))
            await db.commit()

async def main():
    await init_db()
    scheduler.add_job(check_reminders, "interval", seconds=10)
    scheduler.start()
    print("🤖 Bot started...")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
PYTHON_EOF
success "main.py created"

# Dockerfile (ХИТРОСТЬ: ставим faster-whisper БЕЗ зависимостей, потом доустанавливаем только нужное)
cat > Dockerfile << 'DOCKERFILE_EOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt .

# ХИТРОСТЬ:
# 1. Ставим faster-whisper с флагом --no-deps (не ставить зависимости)
# 2. Ставим вручную только легкие зависимости (ctranslate2, tokenizers, numpy)
# 3. Torch НЕ ставится!
RUN pip install --no-cache-dir --no-deps faster-whisper && \
    pip install --no-cache-dir ctranslate2 tokenizers numpy av pydantic aiohttp aiogram apscheduler python-dotenv ffmpeg-python aiosqlite dateparser

COPY app/ .
RUN mkdir -p models

CMD ["python", "main.py"]
DOCKERFILE_EOF
success "Dockerfile created (TRICK: no torch)"

cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'
services:
  telegram-bot:
    build: .
    container_name: reminder_bot
    env_file: .env
    volumes:
      - ./app//app/data
      - ./app/models:/app/models
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 1G
COMPOSE_EOF
success "docker-compose.yml created"

cat > .gitignore << 'GITIGNORE_EOF'
.env
app/data/
app/models/
__pycache__/
*.pyc
GITIGNORE_EOF

echo ""
echo "🔨 Building..."
$COMPOSE_CMD up -d --build

if [ $? -eq 0 ]; then
    success "DONE! Check logs:"
    $COMPOSE_CMD logs -f
else
    echo "Error building."
fi
