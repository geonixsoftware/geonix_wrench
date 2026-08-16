import os
from dotenv import load_dotenv

load_dotenv()

DB_PATH = os.getenv("DB_PATH", "geonix_wrench.db")

# "ollama" | "anthropic" | "stub".
#
# `stub` is a DEV-ONLY offline extractor (see stub_extraction.py): no model, no
# network, keyword matching only. It exists so the app can be worked on when no
# provider is reachable. It produces guesses, not extractions — the server logs
# a warning on every startup while it is selected, and every job card it makes
# is flagged as machine-guessed. Never ship it.
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "ollama")

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.1:8b")

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
ANTHROPIC_MODEL = os.getenv("ANTHROPIC_MODEL", "claude-opus-5")

# `small` rather than `medium`. Measured on a 24s job-card recording, 4 requests
# at once on an 8-core box: medium/beam=3 took 62s per request, small/beam=1 took
# 16.5s — 3.7x the throughput. Transcripts were equivalent on the details a job
# card is built from (vehicle, parts, quantities, labour time): both produced
# "2019 Volkswagen Golf", "5W-30", "3mm", "2.5 hours".
#
# Caveat worth knowing: that was clean audio. `small` degrades faster than
# `medium` on noisy workshops and strong accents, so if extraction quality drops
# in the field, set WHISPER_MODEL_SIZE=medium (and expect the old latency back).
WHISPER_MODEL_SIZE = os.getenv("WHISPER_MODEL_SIZE", "small")
WHISPER_DEVICE = "cpu"
# int8 is much faster than float32 on CPU with only a small accuracy cost —
# needed to keep transcription within the client's upload timeout.
WHISPER_COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "int8")
# Auto language-detection runs on the first ~30s and is unreliable on short
# or noisy clips (low-confidence guesses cascade into garbled transcripts).
# Pin a language by default; set WHISPER_LANGUAGE=auto to re-enable detection.
_raw_whisper_language = os.getenv("WHISPER_LANGUAGE", "en")
WHISPER_LANGUAGE = None if _raw_whisper_language.lower() == "auto" else _raw_whisper_language

# How many recordings may be transcribed simultaneously.
#
# Transcription is CPU-bound and runs at roughly 1x real time on the medium
# model, so raising this does not make a single request faster — it only lets
# more of them share the same cores and finish later. Each concurrent slot also
# holds its own model instance (~1.5 GB for `medium`), so raise it only with
# both spare cores and spare RAM.
WHISPER_MAX_CONCURRENT = max(1, int(os.getenv("WHISPER_MAX_CONCURRENT", "4")))

# How many more recordings may wait for a slot before new uploads are rejected.
#
# Without a ceiling, a burst queues without bound: every client waits past its
# own upload timeout, gives up, and retries — so the server keeps transcribing
# recordings nobody is still waiting for. Shedding load early is what keeps the
# queue drainable.
WHISPER_MAX_QUEUED = max(0, int(os.getenv("WHISPER_MAX_QUEUED", "10")))

# Roughly how long one queued recording takes to clear, used for Retry-After.
# Measured ~16.5s for a 24s recording at 4-way concurrency; 20 leaves headroom.
WHISPER_SECONDS_PER_JOB = max(1, int(os.getenv("WHISPER_SECONDS_PER_JOB", "20")))

# CPU threads per model instance.
#
# CTranslate2 grabs every core by default, so N concurrent models each try to
# use the whole machine and spend their time fighting each other. Dividing the
# cores between the slots is what makes raising WHISPER_MAX_CONCURRENT actually
# increase throughput rather than just latency.
WHISPER_CPU_THREADS = max(
    1,
    int(
        os.getenv(
            "WHISPER_CPU_THREADS",
            str(max(1, (os.cpu_count() or 4) // WHISPER_MAX_CONCURRENT)),
        )
    ),
)

# Greedy decoding. Beam search multiplies decoder cost for accuracy that did not
# show up in job-card fields — on the benchmark recording beam=3 was 2x slower
# and, on `small`, very slightly worse ("notice" for "noticed", dropped "Used").
WHISPER_BEAM_SIZE = max(1, int(os.getenv("WHISPER_BEAM_SIZE", "1")))

ALLOWED_AUDIO_EXTENSIONS = {".m4a", ".wav", ".webm"}

# Audio was previously read into memory whole with no ceiling, so one request
# could exhaust the process. 25 MB is roughly 25 minutes of m4a at 128 kbps,
# far past any realistic job-card dictation.
MAX_AUDIO_SIZE_BYTES = int(os.getenv("MAX_AUDIO_SIZE_BYTES", str(25 * 1024 * 1024)))

# Read uploads in chunks so the cap can be enforced before the whole body is
# resident.
UPLOAD_CHUNK_BYTES = 1024 * 1024

# Caps on text that reaches the LLM prompt and the PDF renderer. Unbounded
# strings inflate model cost and can stall reportlab.
MAX_TRANSCRIPT_CHARS = int(os.getenv("MAX_TRANSCRIPT_CHARS", "20000"))
MAX_FIELD_CHARS = int(os.getenv("MAX_FIELD_CHARS", "2000"))
MAX_PARTS_PER_JOBCARD = int(os.getenv("MAX_PARTS_PER_JOBCARD", "100"))

# CORS. Wildcard plus credentials let any origin call the API and read the
# response; Starlette echoes the caller's Origin back in that combination.
# Set ALLOWED_ORIGINS to a comma-separated list in production.
_raw_origins = os.getenv("ALLOWED_ORIGINS", "").strip()
ALLOWED_ORIGINS = [o.strip() for o in _raw_origins.split(",") if o.strip()]

# Public /docs, /redoc and /openapi.json hand an attacker the whole route map.
# Off unless explicitly enabled.
ENABLE_API_DOCS = os.getenv("ENABLE_API_DOCS", "false").lower() == "true"

# Simple per-user request ceilings. Transcription runs Whisper and calls a paid
# model, so it gets its own tighter budget.
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
RATE_LIMIT_DEFAULT_PER_WINDOW = int(os.getenv("RATE_LIMIT_DEFAULT_PER_WINDOW", "120"))
RATE_LIMIT_AUDIO_PER_WINDOW = int(os.getenv("RATE_LIMIT_AUDIO_PER_WINDOW", "10"))

ALLOWED_LOGO_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
MAX_LOGO_SIZE_BYTES = 5 * 1024 * 1024
LOGO_STORAGE_DIR = os.getenv("LOGO_STORAGE_DIR", "storage/logos")
MAX_LOGO_DIMENSION_PX = 1000
DEFAULT_LOGO_PATH = os.path.join("assets", "default_logo.png")

FIREBASE_SERVICE_ACCOUNT_PATH = os.getenv("FIREBASE_SERVICE_ACCOUNT_PATH", "firebase-service-account.json")
HANDLE_MIN_LENGTH = 3
HANDLE_MAX_LENGTH = 30

SUPPORTED_CURRENCIES = {
    "USD": "$",
    "EUR": "€",
    "GBP": "£",
    "ZAR": "R",
    "AUD": "A$",
    "CAD": "C$",
}
DEFAULT_CURRENCY = "USD"
DEFAULT_LABOR_RATE = float(os.getenv("DEFAULT_LABOR_RATE", "85.0"))

# Stripe billing configuration. Prices are monthly recurring prices configured
# in the Stripe dashboard; the webhook secret is used to verify event signatures.
STRIPE_API_KEY = os.getenv("STRIPE_API_KEY")
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET")

INDIVIDUAL_PRICE_ID = os.getenv("INDIVIDUAL_PRICE_ID", "price_1U3FIdAsnEuiNQHH9y7WdAqI")
TEAM_PRICE_ID = os.getenv("TEAM_PRICE_ID", "price_1U3JqDAsnEuiNQHHLIXIjlV7")
TEAM_MIN_SEATS = int(os.getenv("TEAM_MIN_SEATS", "2"))

# Advertised prices, served to the app and the website so the figure is defined
# once instead of being retyped in each client.
#
# !! These are DISPLAY values only. Stripe charges whatever the price objects
# above are set to in the dashboard — changing a number here does not change
# what a customer pays. Keep the two in step, or a customer is quoted one amount
# and billed another. `python -m price_check` verifies they match.
INDIVIDUAL_PRICE_PER_MONTH = float(os.getenv("INDIVIDUAL_PRICE_PER_MONTH", "29"))
TEAM_PRICE_PER_SEAT = float(os.getenv("TEAM_PRICE_PER_SEAT", "25"))
BILLING_CURRENCY = os.getenv("BILLING_CURRENCY", "EUR")

# Stripe enables "Managed Payments" by default on new accounts, and it requires
# every product in a checkout line item to carry an eligible product tax code.
# Ours have none, so Stripe rejected every session with:
#   "Invalid line_items[0]: this product tax code is ineligible for Managed
#    Payments" -> our /api/billing/checkout-session returned 502.
# Opting out per session unblocks checkout without a dashboard change. To switch
# it on instead, set eligible tax codes on both products in the Stripe dashboard
# and then set STRIPE_MANAGED_PAYMENTS=true.
STRIPE_MANAGED_PAYMENTS = os.getenv("STRIPE_MANAGED_PAYMENTS", "false").lower() == "true"
