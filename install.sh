#!/bin/bash

set -e

echo "🚀 Установка Telegram-бота с напоминаниями и распознаванием голоса..."
echo ""

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
success "Структура создана"

# Запрос токена
echo ""
read -p "🔑 Введите токен Telegram-бота: " BOT_TOKEN
if [ -z "$BOT_TOKEN" ]; then error "Токен пуст!"; fi

cat > "$PROJECT_DIR/.env" << EOF
BOT_TOKEN=$BOT_TOKEN
DB_PATH=data/bot.db
WHISPER_MODEL_SIZE=small
LANGUAGE=ru
LOG_LEVEL=INFO
EOF
success ".env создан"

# requirements.txt
cat > "$APP_DIR/requirements.txt" << 'EOF'
aiogram>=3.0.0
apscheduler>=3.10.0
python-dotenv>=1.0.0
ffmpeg-python>=0.2.0
aiosqlite>=0.19.0
dateparser>=1.1.8
faster-whisper>=0.9.0
torch>=2.0.0 --index-url https://download.pytorch.org/whl/cpu
EOF
success "requirements.txt создан"

# main.py (тот же самый рабочий код)
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
from faster_whisper import WhisperModel

load_dotenv()

TOKEN = os.getenv("BOT_TOKEN")
DB_PATH = os.getenv("DB_PATH", "data/bot.db")
WHISPER_MODEL_SIZE = os.getenv("WHISPER_MODEL_SIZE", "small")
LANGUAGE = os.getenv("LANGUAGE", "ru")

bot = Bot(token=TOKEN)
dp = Dispatcher()
scheduler = AsyncIOScheduler()

# Инициализация Whisper
model_path = f"models/{WHISPER_MODEL_SIZE}"
if not Path(model_path).exists():
    print(f"📥 Загружаем модель Whisper {WHISPER_MODEL_SIZE}...")
    model = WhisperModel(WHISPER_MODEL_SIZE, device="cpu", compute_type="int8")
else:
    model = WhisperModel(model_path, device="cpu", compute_type="int8")

async def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""CREATE TABLE IF NOT EXISTS reminders (id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, text TEXT, remind_at REAL)""")
        await db.commit()

def parse_free_form_reminder(text: str):
    if not text or len(text.strip()) < 3: return None, None, "Коротко."
    matches = search_dates(text, languages=['ru', 'en'], settings={'PREFER_DATES_FROM': 'future'})
    if not matches: return None, None, None
    time_phrase, dt = matches[0]
    if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
    else: dt = dt.astimezone(timezone.utc)
    
    cleaned = re.sub(re.escape(time_phrase), '', text, count=1, flags=re.IGNORECASE)
    cleaned = re.sub(r'^(напомни|поставь|создай|позвони|сделай)\s*', '', cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip('.,;:!?- ')
    if not cleaned: cleaned = "Без текста"
    if dt <= datetime.now(timezone.utc): return None, None, f"Время {dt.strftime('%H:%M')} прошло."
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
        segments, _ = model.transcribe(wav_path, language=LANGUAGE, beam_size=5)
        recognized = " ".join([segment.text for segment in segments]).strip()
        if recognized: await create_reminder(message.chat.id, recognized, silent=True)
        else: await message.reply("🎤 Не распознал.")
    except Exception as e:
        await message.reply(f"❌ Ошибка: {str(e)}")
    finally:
        for p in (ogg_path, wav_path):
            if Path(p).exists(): Path(p).unlink()

@dp.message(F.text & ~F.command)
async def handle_text_reminder(message: types.Message):
    await create_reminder(message.chat.id, message.text)

@dp.message(Command("help"))
async def cmd_help(message: types.Message):
    await message.reply("Примеры:\n• завтра в 14:30 купить хлеб\n• через 2 часа позвонить")

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
    print("🤖 Бот запущен...")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
PYTHON_EOF
success "main.py создан"

# ========================
# ИСПРАВЛЕННЫЙ Dockerfile
# ========================
cat > "$PROJECT_DIR/Dockerfile" << 'DOCKERFILE_EOF'
FROM python:3.11-slim

WORKDIR /app

# Устанавливаем только необходимое, без рекомендаций, чтобы избежать конфликтов apt
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .
RUN mkdir -p models

CMD ["python", "main.py"]
DOCKERFILE_EOF
success "Dockerfile исправлен (добавлен --no-install-recommends)"

# docker-compose.yml
cat > "$PROJECT_DIR/docker-compose.yml" << 'COMPOSE_EOF'
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
          memory: 2G
COMPOSE_EOF
success "docker-compose.yml создан"

# .gitignore
cat > "$PROJECT_DIR/.gitignore" << 'GITIGNORE_EOF'
.env
app/data/
app/models/
__pycache__/
*.pyc
GITIGNORE_EOF

# Очистка старого образа и запуск
echo ""
echo "🧹 Очистка старых образов..."
docker rmi $(docker images -q reminder-telegram-bot 2>/dev/null) || true
$COMPOSE_CMD down || true

echo "🔨 Сборка и запуск..."
$COMPOSE_CMD up -d --build

if [ $? -eq 0 ]; then
    success "Бот успешно запущен!"
    echo "📋 Логи:"
    $COMPOSE_CMD logs -f
else
    error "Ошибка запуска. Проверьте вывод выше."
fi
