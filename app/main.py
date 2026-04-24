import os, asyncio, json, logging, subprocess, time
from pathlib import Path
from dotenv import load_dotenv
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from apscheduler.schedulers.asyncio import AsyncIOScheduler
import aiosqlite
import vosk

load_dotenv()
BOT_TOKEN = os.getenv("BOT_TOKEN")
if not BOT_TOKEN:
    raise ValueError("BOT_TOKEN не найден в .env файле")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
scheduler = AsyncIOScheduler()

# Пути внутри контейнера
BASE_DIR = Path(__file__).parent.resolve()
DATA_DIR = BASE_DIR / "data"
MODELS_DIR = BASE_DIR / "models"
DB_PATH = DATA_DIR / "bot.db"
MODEL_PATH = MODELS_DIR / "vosk-model-small-ru-0.22"

DATA_DIR.mkdir(exist_ok=True)

if not MODEL_PATH.exists():
    raise FileNotFoundError(f"Модель Vosk не найдена в {MODEL_PATH}. Запустите install.sh")

model = vosk.Model(str(MODEL_PATH))
recognizer = vosk.KaldiRecognizer(model, 16000)

# --- База данных ---
async def init_db():
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

# --- Хендлеры ---
@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    await message.answer(
        "👋 Привет! Я бот-напоминалка.\n"
        "📝 Команды:\n"
        "• `/remind 10m Купить хлеб` — напомнить через 10 минут\n"
        "🎤 Отправьте голосовое сообщение, и я распознаю текст."
    )

@dp.message(Command("remind"))
async def cmd_remind(message: types.Message):
    parts = message.text.split(maxsplit=2)
    if len(parts) < 3:
        return await message.answer("❌ Формат: `/remind <время> <текст>`\nПример: `/remind 15m Позвонить маме`")
    _, time_str, text = parts
    try:
        minutes = int(time_str.replace("m", "").replace("м", ""))
        if minutes <= 0: raise ValueError
    except ValueError:
        return await message.answer("❌ Укажите время в минутах (например, 10m)")

    remind_at = time.time() + minutes * 60
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("INSERT INTO reminders (chat_id, text, remind_at) VALUES (?, ?, ?)",
                         (message.chat.id, text, remind_at))
        await db.commit()
    await message.answer(f"✅ Напомню через {minutes} мин.")

@dp.message(F.voice)
async def handle_voice(message: types.Message):
    file_info = await bot.get_file(message.voice.file_id)
    ogg_path = DATA_DIR / f"voice_{message.voice.file_id}.ogg"
    wav_path = DATA_DIR / f"voice_{message.voice.file_id}.wav"

    try:
        await bot.download_file(file_info.file_path, ogg_path)
        subprocess.run([
            "ffmpeg", "-y", "-i", str(ogg_path),
            "-ar", "16000", "-ac", "1", "-acodec", "pcm_s16le",
            str(wav_path)
        ], check=True, capture_output=True)

        with open(wav_path, "rb") as f:
            while True:
                data = f.read(4000)
                if not data: break
                if recognizer.AcceptWaveform(data):
                    result = json.loads(recognizer.Result())
                    text = result.get("text", "").strip()
                    break
            else:
                text = ""

        await message.answer(f"🎤 Распознано: {text or '[не удалось распознать]'}")
    except Exception as e:
        logger.error(f"Voice processing error: {e}")
        await message.answer("❌ Ошибка при обработке голосового сообщения.")
    finally:
        for p in (ogg_path, wav_path):
            if p.exists(): p.unlink()

# --- Планировщик ---
async def check_reminders():
    now = time.time()
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute("SELECT id, chat_id, text FROM reminders WHERE remind_at <= ?", (now,)) as cur:
            rows = await cur.fetchall()
            for _, chat_id, text in rows:
                try:
                    await bot.send_message(chat_id, f"⏰ Напоминание: {text}")
                except Exception as e:
                    logger.error(f"Failed to send reminder to {chat_id}: {e}")
            await db.execute("DELETE FROM reminders WHERE remind_at <= ?", (now,))
            await db.commit()

async def main():
    await init_db()
    scheduler.add_job(check_reminders, "interval", seconds=5)
    scheduler.start()
    await dp.start_polling(bot)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        scheduler.shutdown()
        logger.info("Bot stopped.")
