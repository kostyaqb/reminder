FROM python:3.11-slim

WORKDIR /app

# ffmpeg + библиотеки для Vosk
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libatlas3-base libgomp1 && \
    rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

CMD ["python", "main.py"]
