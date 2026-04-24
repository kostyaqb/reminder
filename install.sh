#!/bin/bash
set -e

echo "🤖 Reminder Bot Installer"
echo "========================="

# Проверка Docker
if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
    echo "❌ Ошибка: Docker или Docker Compose не установлены."
    echo "🔗 Инструкция: https://docs.docker.com/get-docker/"
    exit 1
fi

# Ввод токена
read -p "📝 Введите TELEGRAM BOT TOKEN (от @BotFather): " BOT_TOKEN
if [[ -z "$BOT_TOKEN" ]]; then
    echo "❌ Токен не может быть пустым."
    exit 1
fi

# Создание .env
echo "BOT_TOKEN=$BOT_TOKEN" > .env
chmod 600 .env
echo "✅ Файл .env создан"

# Загрузка модели, если отсутствует
if [ ! -d "models/vosk-model-small-ru-0.22" ]; then
    echo "📦 Загрузка модели распознавания речи (~40 МБ)..."
    mkdir -p models
    wget -q https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip -O models/model.zip
    unzip -q models/model.zip -d models/
    rm -f models/model.zip
    echo "✅ Модель загружена"
fi

# Сборка и запуск
echo "🐳 Сборка и запуск контейнера..."
docker compose up -d --build

echo ""
echo "✅ Готово! Бот запущен."
echo "📋 Логи: docker compose logs -f"
echo "🛑 Остановка: docker compose down"
