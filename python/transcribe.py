"""Lokale Spracherkennung für Audio- und Videodateien."""

import argparse
import json
import os
from pathlib import Path

os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")
ROOT = Path(__file__).resolve().parent


def timestamp(seconds: float, srt: bool = False) -> str:
    milliseconds = round(seconds * 1000)
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    secs, millis = divmod(remainder, 1000)
    if srt:
        return f"{hours:02}:{minutes:02}:{secs:02},{millis:03}"
    return f"{hours:02}:{minutes:02}:{secs:02}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path, default=ROOT / "input" / "Dimi1_Audio.mp3")
    parser.add_argument("--language", default="ru", help="Sprachcode, z. B. ru, de oder auto")
    parser.add_argument("--model", default="small", help="Whisper-Modell; Standard: small")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "output")
    parser.add_argument("--models-dir", type=Path, default=ROOT / "models")
    parser.add_argument("--max-seconds", type=float, help="Nur den Anfang verarbeiten, z. B. 30 Sekunden")
    args = parser.parse_args()
    if not args.input.is_file():
        parser.error(f"Datei nicht gefunden: {args.input}")
    if args.max_seconds is not None and args.max_seconds <= 0:
        parser.error("--max-seconds muss größer als 0 sein")

    from faster_whisper import WhisperModel
    from faster_whisper.audio import decode_audio

    args.output_dir.mkdir(parents=True, exist_ok=True)
    print(f"Lade Modell {args.model!r}. Beim ersten Start wird es heruntergeladen.", flush=True)
    model = WhisperModel(
        args.model,
        device="cpu",
        compute_type="int8",
        cpu_threads=min(8, os.cpu_count() or 4),
        download_root=str(args.models_dir),
    )
    audio = str(args.input.resolve())
    if args.max_seconds is not None:
        audio = decode_audio(audio, sampling_rate=16000)[: int(args.max_seconds * 16000)]
    segments, info = model.transcribe(
        audio,
        language=None if args.language == "auto" else args.language,
        beam_size=5,
        vad_filter=True,
    )
    print(f"Transkribiere: {args.input.name} (Sprache: {info.language})", flush=True)
    def output_file(extension: str) -> Path:
        return args.output_dir / f"{args.input.stem}.{extension}"

    rows = []
    # Diese Datei enthält auch bei einem Abbruch die bereits erkannten Abschnitte.
    with output_file("jsonl").open("w", encoding="utf-8") as journal:
        for segment in segments:
            row = {
                "start": segment.start,
                "end": segment.end,
                "text": segment.text.strip(),
                "avg_logprob": segment.avg_logprob,
                "no_speech_prob": segment.no_speech_prob,
            }
            rows.append(row)
            journal.write(json.dumps(row, ensure_ascii=False) + "\n")
            journal.flush()
            print(f"[{timestamp(segment.start)}] {row['text']}", flush=True)

    output_file("json").write_text(
        json.dumps({"source": str(args.input.resolve()), "language": info.language, "segments": rows},
                   ensure_ascii=False, indent=2), encoding="utf-8"
    )
    output_file("txt").write_text(
        "Automatisch erkanntes Transkript; Erkennungsfehler sind möglich.\n\n"
        + "\n".join(f"[{timestamp(r['start'])}] {r['text']}" for r in rows) + "\n",
        encoding="utf-8-sig",
    )
    output_file("srt").write_text(
        "\n\n".join(
            f"{i}\n{timestamp(r['start'], True)} --> {timestamp(r['end'], True)}\n{r['text']}"
            for i, r in enumerate(rows, 1)
        ) + "\n", encoding="utf-8-sig"
    )
    print(f"Fertig. {len(rows)} Abschnitte gespeichert in: {args.output_dir.resolve()}", flush=True)


if __name__ == "__main__":
    main()
