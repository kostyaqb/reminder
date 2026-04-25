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

# Создаём директорию для моделей (если будем хранить локально)
RUN mkdir -p models

CMD ["python", "main.py"]
