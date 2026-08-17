# Geonix Wrench API.
#
# Two stages so the compiler toolchain needed to build wheels never reaches the
# running image. faster-whisper, pillow and lxml all pull in native code.
FROM python:3.13-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.13-slim

# ffmpeg is what faster-whisper shells out to for anything that is not already
# 16kHz mono WAV — which is every recording the app sends. Without it every
# upload fails at the decode step.
# libgomp1 is required by ctranslate2, the runtime under faster-whisper.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /install /usr/local

WORKDIR /app
COPY . .

# Never run as root, and never let the image own the data directory: it is a
# mounted volume, and the mount has to be writable by this uid.
RUN useradd --create-home --uid 10001 wrench \
    && mkdir -p /data/logos \
    && chown -R wrench:wrench /data
USER wrench

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DB_PATH=/data/geonix_wrench.db \
    LOGO_STORAGE_DIR=/data/logos \
    HF_HOME=/data/models

# Whisper downloads its weights on first use. Pointing the cache at the volume
# means that happens once, not on every container restart.
VOLUME ["/data"]
EXPOSE 8000

# start-period is generous because the startup hook downloads and loads the
# Whisper model before serving — first boot on a fresh volume is minutes, not
# seconds, and a tighter window would kill the container mid-download forever.
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"

# One worker on purpose. Each would hold its own copy of the Whisper model, so
# scaling by workers multiplies memory rather than throughput; the app already
# runs transcription in a bounded thread pool off the event loop.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
