import os
from dotenv import load_dotenv

load_dotenv()

DB_PATH = os.getenv("DB_PATH", "geonix_wrench.db")

LLM_PROVIDER = os.getenv("LLM_PROVIDER", "ollama")  # "ollama" or "anthropic"

OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.1:8b")

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
ANTHROPIC_MODEL = os.getenv("ANTHROPIC_MODEL", "claude-opus-5")

WHISPER_MODEL_SIZE = os.getenv("WHISPER_MODEL_SIZE", "medium")
WHISPER_DEVICE = "cpu"
# int8 is much faster than float32 on CPU with only a small accuracy cost —
# needed to keep transcription within the client's upload timeout.
WHISPER_COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "int8")
# Auto language-detection runs on the first ~30s and is unreliable on short
# or noisy clips (low-confidence guesses cascade into garbled transcripts).
# Pin a language by default; set WHISPER_LANGUAGE=auto to re-enable detection.
_raw_whisper_language = os.getenv("WHISPER_LANGUAGE", "en")
WHISPER_LANGUAGE = None if _raw_whisper_language.lower() == "auto" else _raw_whisper_language

ALLOWED_AUDIO_EXTENSIONS = {".m4a", ".wav", ".webm"}

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
