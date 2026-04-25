#!/bin/bash

set -e

echo "🚀 Установка Telegram-бота с напоминаниями и распознаванием голоса..."
echo ""

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для вывода ошибок
error() {
    echo -e "${RED}❌ $1${NC}" >&2
    exit 1
}

# Функция для вывода успеха
success() {
    echo -e "${GREEN}✅ $1${NC}"
}

# Функция для вывода предупреждений
warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Проверка наличия Docker
if ! command -v docker &> /dev/null; then
    error "Docker не установлен. Установите Docker и попробуйте снова."
fi

# Проверка наличия docker-compose или docker compose plugin
if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    error "docker-compose не найден. Установите docker-compose или обновите Docker."
fi

echo "📦 Проверка зависимостей... OK"

# Создание структуры проекта
PROJECT_DIR="$(pwd)"
APP_DIR="$PROJECT_DIR/app"
DATA_DIR="$APP_DIR/data"
MODELS_DIR="$APP_DIR/models"

mkdir -p "$APP_DIR" "$DATA_DIR" "$MODELS_DIR"

success "Структура проекта создана"

# ========================
# 1. Создаём .env с запросом токена
# ========================
echo ""
read -p "🔑 Введите токен вашего Telegram-бота (получите у @BotFather): " BOT_TOKEN

if [ -z "$BOT_TOKEN" ]; then
    error "Токен не может быть пустым!"
fi

cat > "$PROJECT_DIR/.env" << EOF
BOT_TOKEN=$BOT_TOKEN
DB_PATH=data/bot.db
WHISPER_MODEL_SIZE=small
LANGUAGE=ru
LOG_LEVEL=INFO
EOF

success "Файл .env создан"

# ========================
# 2. Создаём requirements.txt
# ========================
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

success "Файл requirements.txt создан"

# ========================
# 3. Создаём main.py
# ========================
cat > "$APP_DIR/main.py" << 'PYTHON_EOF'
import os
import re
import json
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
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")

bot = Bot(token=TOKEN)
dp = Dispatcher()
scheduler = AsyncIOScheduler()

# 🎙️ Инициализация Whisper
model_path = f"models/{WHISPER_MODEL_SIZE}"
if not Path(model_path).exists():
    print(f"📥 Загружаем модель Whisper {WHISPER_MODEL_SIZE}...")
    model = WhisperModel(WHISPER_MODEL_SIZE, device="cpu", compute_type="int8")
else:
    print(f"📦 Используем локальную модель: {model_path}")
    model = WhisperModel(model_path, device="cpu", compute_type="int8")

# 🗃️ БД
async def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS reminders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id INTEGER,
                text TEXT,
                remind_at REAL
            )
        """)
        await db.commit()

# 🧠 Парсер свободной формы
def parse_free_form_reminder(text: str):
    if not text or len(text.strip()) < 3:
        return None, None, "Текст слишком короткий."

    matches = search_dates(
        text,
        languages=['ru', 'en'],
        settings={'PREFER_DATES_FROM': 'future', 'STRICT_PARSING': False}
    )
    if not matches:
        return None, None, None  # Тихий пропуск

    time_phrase, dt = matches[0]

    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = dt.astimezone(timezone.utc)

    cleaned = re.sub(re.escape(time_phrase), '', text, count=1, flags=re.IGNORECASE)
    cleaned = re.sub(r'^(напомни|поставь напоминание|создай напоминание|позвони|сделай|напомни пожалуйста)\s*', '', cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip('.,;:!?- ')

    if not cleaned:
        cleaned = "Без текста"

    if dt <= datetime.now(timezone.utc):
        return None, None, f"⚠️ Время {dt.strftime('%d.%m в %H:%M')} уже прошло."

    return dt, cleaned, None

async def create_reminder(chat_id: int, text: str, silent: bool = False):
    dt, task, error = parse_free_form_reminder(text)
    
    if error:
        if not silent:
            await bot.send_message(chat_id, error)
        return False
    if not dt:
        return False  # Не нашли время → игнорируем

    remind_timestamp = dt.timestamp()
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "INSERT INTO reminders (chat_id, text, remind_at) VALUES (?, ?, ?)",
            (chat_id, task, remind_timestamp)
        )
        await db.commit()

    human_time = dt.strftime("%d.%m в %H:%M")
    await bot.send_message(chat_id, f"✅ Напомню {human_time}:\n📝 {task}")
    return True

# 🎤 Обработка голосовых через Whisper
@dp.message(F.voice)
async def handle_voice(message: types.Message):
    voice = await message.bot.get_file(message.voice.file_id)
    ogg_path = f"/tmp/voice_{message.voice.file_id}.ogg"
    wav_path = ogg_path.replace(".ogg", ".wav")
    
    await message.bot.download_file(voice.file_path, ogg_path)
    
    try:
        (
            ffmpeg.input(ogg_path)
            .output(wav_path, format="wav", acodec="pcm_s16le", ar=16000, ac=1)
            .run(overwrite_output=True, quiet=True)
        )

        segments, _ = model.transcribe(wav_path, language=LANGUAGE, beam_size=5)
        recognized = " ".join([segment.text for segment in segments]).strip()

        if recognized:
            await create_reminder(message.chat.id, recognized, silent=True)
        else:
            await message.reply("🎤 Не удалось распознать речь. Попробуйте ещё раз или напишите текстом.")

    except Exception as e:
        await message.reply(f"❌ Ошибка обработки голоса: {str(e)}")
    finally:
        for p in (ogg_path, wav_path):
            if Path(p).exists():
                Path(p).unlink()

# 💬 Текстовые сообщения (свободная форма)
@dp.message(F.text & ~F.command)
async def handle_text_reminder(message: types.Message):
    await create_reminder(message.chat.id, message.text)

# 🆘 Справка
@dp.message(Command("help"))
async def cmd_help(message: types.Message):
    await message.reply(
        "📝 *Как ставить напоминания:*\n"
        "Просто напишите или отправьте голосом:\n"
        "• `напомни завтра в 14:30 купить молоко`\n"
        "• `через 2 часа позвонить маме`\n"
        "• `5 мая в 10:00 встреча`\n"
        "Бот сам найдёт время и текст задачи."
    )

# ⏰ Проверка напоминаний
async def check_reminders():
    now_ts = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute("SELECT id, chat_id, text FROM reminders WHERE remind_at <= ?", (now_ts,)) as cur:
            rows = await cur.fetchall()
            for row_id, chat_id, text in rows:
                await bot.send_message(chat_id, f"⏰ *Напоминание:*\n{text}", parse_mode="Markdown")
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

# ========================
# 4. Создаём Dockerfile
# ========================
cat > "$PROJECT_DIR/Dockerfile" << 'DOCKERFILE_EOF'
FROM python:3.11-slim

WORKDIR /app

# Установка системных зависимостей
RUN apt-get update && \
    apt-get install -y ffmpeg curl && \
    rm -rf /var/lib/apt/lists/*

# Копируем зависимости
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копируем код
COPY app/ .

# Создаём директорию для моделей
RUN mkdir -p models

CMD ["python", "main.py"]
DOCKERFILE_EOF

success "Файл Dockerfile создан"

# ========================
# 5. Создаём docker-compose.yml
# ========================
cat > "$PROJECT_DIR/docker-compose.yml" << 'COMPOSE_EOF'
version: '3.8'

services:
  telegram-bot:
    build: .
    container_name: reminder_bot
    env_file: .env
    volumes:
      - ./app/data:/app/data
      - ./app/models:/app/models
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 2G
COMPOSE_EOF

success "Файл docker-compose.yml создан"

# ========================
# 6. Создаём .gitignore
# ========================
cat > "$PROJECT_DIR/.gitignore" << 'GITIGNORE_EOF'
.env
app/data/
app/models/
__pycache__/
*.pyc
*.pyo
.DS_Store
.gitignore
GITIGNORE_EOF

success "Файл .gitignore создан"

# ========================
# 7. Сборка и запуск
# ========================
echo ""
echo "🔨 Сборка Docker-образа..."
$COMPOSE_CMD up -d --build

if [ $? -ne 0 ]; then
    error "Ошибка при сборке образа. Проверьте логи выше."
fi

success "Образ успешно собран"

echo ""
echo "🚀 Запуск бота..."
sleep 3

# Проверяем, запущен ли контейнер
if [ "$($COMPOSE_CMD ps -q telegram-bot 2>/dev/null)" ]; then
    success "Бот успешно запущен!"
    echo ""
    echo "📋 Логи бота (нажмите Ctrl+C для выхода):"
    $COMPOSE_CMD logs -f
else
    error "Контейнер не запустился. Проверьте логи:"
    $COMPOSE_CMD logs
fi
