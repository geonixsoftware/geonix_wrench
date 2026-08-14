from functools import lru_cache

from faster_whisper import WhisperModel

from config import (
    WHISPER_COMPUTE_TYPE,
    WHISPER_DEVICE,
    WHISPER_LANGUAGE,
    WHISPER_MODEL_SIZE,
)

# Biases Whisper's decoding toward auto-repair vocabulary it otherwise mishears
# (e.g. "Volkswagen Golf" -> "Svabun"), since it has no domain fine-tuning.
VOCABULARY_PROMPT = (
    "Auto repair shop job notes. Vehicle makes: Volkswagen, Toyota, Honda, Ford, "
    "Chevrolet, Nissan, BMW, Mercedes-Benz, Audi, Hyundai, Kia, Mazda, Subaru, "
    "Jeep, Ram, GMC, Chrysler, Dodge, Volvo, Land Rover, Porsche, Tesla. Models: "
    "Golf, Civic, Corolla, Camry, Accord, Fusion, F-150, Silverado. Oil viscosity "
    "grades: 0W-20, 5W-20, 5W-30, 5W-40, 10W-30, 10W-40, full synthetic, "
    "conventional, high mileage. Quantities in liters or quarts."
)


@lru_cache(maxsize=1)
def _get_model() -> WhisperModel:
    return WhisperModel(
        WHISPER_MODEL_SIZE,
        device=WHISPER_DEVICE,
        compute_type=WHISPER_COMPUTE_TYPE,
    )


def preload_model() -> None:
    # Downloading/loading the model can take far longer than a request's
    # timeout budget, so this is called once at server startup instead of
    # letting the first upload request pay that cost.
    _get_model()


def transcribe_audio(file_path: str) -> str:
    model = _get_model()
    segments, _info = model.transcribe(
        file_path,
        # A larger beam eats CPU time fast on the medium model; 3 keeps
        # accuracy close to 5 without pushing requests toward the client
        # upload timeout.
        beam_size=3,
        vad_filter=True,
        initial_prompt=VOCABULARY_PROMPT,
        language=WHISPER_LANGUAGE,
        condition_on_previous_text=False,
    )
    return " ".join(segment.text.strip() for segment in segments).strip()
