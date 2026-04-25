#!/bin/bash

set -e

echo "🚀 Установка Telegram-бота (Ultra-Lite версия)..."
echo ""

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

error() { echo -e "${RED}❌ $1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}✅ $1${NC}"; }

# Проверка Docker
if ! command -v docker &> /dev/null; then error "Docker не установлен."; fi
if command -v docker-compose &> /dev/null; then COMPOSE_CMD="docker-compose"; 
elif docker compose version &> /dev/null 2>&1; then COMPOSE_CMD="docker compose"; 
else error "docker-compose не найден."; fi

# Создание структуры
PROJECT_DIR="$(pwd)"
APP_DIR="$PROJECT_DIR/app"
mkdir -p "$APP_DIR/data" "$APP_DIR/models"
success "Структура папок создана"

# Запрос токена
echo ""
read -p "🔑 Введите токен Telegram-бота (получите у @BotFather): " BOT_TOKEN
if [ -z "$BOT_TOKEN" ]; then error "Токен не может быть пустым!"; fi

cat > "$PROJECT_DIR/.env" << EOF
BOT_TOKEN=$BOT_TOKEN
DB_PATH=data/bot.db
MODEL_NAME=tiny-int8
LANGUAGE=ru
LOG_LEVEL=INFO
EOF
success "Файл .env создан"

# requirements.txt (БЕЗ TORCH, только легковесные библиотеки)
cat > "$APP_DIR/requirements.txt" << 'EOF'
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
success "Файл requirements.txt создан"

# main.py
cat > "$APP_DIR/main.py" << 'PYTHON_EOF'
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
    if not text or len(text.strip()) < 3: return None, None, "Слишком коротко."
    matches = search_dates(text, languages=['ru', 'en'], settings={'PREFER_DATES_FROM': 'future'})
    if not matches: return None, None, None
    time_phrase, dt = matches[0]
    if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
    else: dt = dt.astimezone(timezone.utc)
    
    cleaned = re.sub(re.escape(time_phrase), '', text, count=1, flags=re.IGNORECASE)
    cleaned = re.sub(r'^(напомни|поставь|создай|позвони|сделай)\s*', '', cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip('.,;:!?- ')
    if not cleaned: cleaned = "Без текста"
    if dt <= datetime.now(timezone.utc): return None, None, f"Время {dt.strftime('%H:%M')} уже прошло."
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
    await bot.send_message(chat_id, f"✅ Напомню {dt.strftime('%d.%m в %H:%M')}:\n📝 {task}")
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
        else: await message.reply("🎤 Не удалось распознать речь.")
    except Exception as e:
        await message.reply(f"❌ Ошибка обработки: {str(e)}")
    finally:
        for p in (ogg_path, wav_path):
            if Path(p).exists(): Path(p).unlink()

@dp.message(F.text & ~F.command)
async def handle_text_reminder(message: types.Message):
    await create_reminder(message.chat.id, message.text)

@dp.message(Command("help"))
async def cmd_help(message: types.Message):
    await message.reply("Примеры:\n• завтра в 14:30 купить хлеб\n• через 2 часа позвонить маме")

async def check_reminders():
    now_ts = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute("SELECT id, chat_id, text FROM reminders WHERE remind_at <= ?", (now_ts,)) as cur:
            rows = await cur.fetchall()
            for _, chat_id, text in rows:
                await bot.send_message(chat_id, f"⏰ Напоминание: {text}")
            await db.execute("DELETE FROM reminders WHERE remind_at <= ?", (now_ts,))
            await db.commit()

async def main():
    await init_db()
    scheduler.add_job(check_reminders, "interval", seconds=10)
    scheduler.start()
    print("🤖 Бот запущен...")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
PYTHON_EOF
success "Файл main.py создан"

# Dockerfile (ХИТРОСТЬ: ставим faster-whisper БЕЗ зависимостей, потом доустанавливаем только нужное)
cat > "$PROJECT_DIR/Dockerfile" << 'DOCKERFILE_EOF'
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
# 1. Ставим faster-whisper с флагом --no-deps (не ставить зависимости, т.е. без torch)
# 2. Ставим вручную только легкие зависимости (ctranslate2, tokenizers, numpy)
RUN pip install --no-cache-dir --no-deps faster-whisper && \
    pip install --no-cache-dir ctranslate2 tokenizers numpy av pydantic aiohttp aiogram apscheduler python-dotenv ffmpeg-python aiosqlite dateparser

COPY app/ .
RUN mkdir -p models

CMD ["python", "main.py"]
DOCKERFILE_EOF
success "Файл Dockerfile создан (без Torch)"

# docker-compose.yml (ИСПРАВЛЕННЫЙ: используем именованные тома)
cat > "$PROJECT_DIR/docker-compose.yml" << 'COMPOSE_EOF'
services:
  telegram-bot:
    build: .
    container_name: reminder_bot
    env_file: .env
    volumes:
      - bot-/app/data
      - bot-models:/app/models
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 1G

volumes:
  bot-
  bot-models:
COMPOSE_EOF
success "Файл docker-compose.yml создан (используются именованные тома)"

# .gitignore
cat > "$PROJECT_DIR/.gitignore" << 'GITIGNORE_EOF'
.env
app/data/
app/models/
__pycache__/
*.pyc
*.pyo
.dockerignore
GITIGNORE_EOF
success "Файл .gitignore создан"

# Очистка старого
echo ""
echo "🧹 Очистка старых контейнеров..."
$COMPOSE_CMD down || true

# Сборка и запуск
echo "🔨 Сборка и запуск (это может занять 2-3 минуты)..."
$COMPOSE_CMD up -d --build

if [ $? -eq 0 ]; then
    success "Бот успешно запущен!"
    echo ""
    echo "📋 Логи бота (нажмите Ctrl+C для выхода):"
    $COMPOSE_CMD logs -f
else
    error "Ошибка запуска. Проверьте вывод выше."
fi
