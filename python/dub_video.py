"""Create timestamp-aligned translated MP3 audio or a video with a translated track."""
import argparse
import asyncio
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import wave


SAMPLE_RATE = 24000


def event(message, **extra):
    print(json.dumps({"message": message, **extra}, ensure_ascii=False), flush=True)


def run_tool(arguments):
    result = subprocess.run(arguments, capture_output=True, encoding="utf-8", errors="replace")
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name}: {result.stderr[-4000:].strip()}")
    return result.stdout


def probe(path, ffprobe):
    return json.loads(run_tool([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))


def validate_segments(rows, duration):
    if not rows:
        raise ValueError("Keine übersetzten Sprachabschnitte vorhanden.")
    previous_start = -1
    starts = []
    for index, row in enumerate(rows):
        start, end = float(row["start"]), float(row["end"])
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start:
            raise ValueError("Ungültige Zeitstempel.")
        if start <= previous_start or start >= duration or end > duration + 0.25:
            raise ValueError("Zeitstempel passen nicht zur Länge oder Reihenfolge des Videos.")
        if not isinstance(row["text"], str) or not row["text"].strip():
            raise ValueError("Ein übersetzter Abschnitt ist leer.")
        starts.append(round(start * SAMPLE_RATE))
        previous_start = start
    return starts


async def synthesize_speech(text, voice, rate, output):
    import edge_tts
    await edge_tts.Communicate(text, voice, rate=f"{rate:+d}%").save(str(output))


class SpeechServiceError(RuntimeError):
    pass


async def synthesize_with_retry(text, voice, rate, output, *, synthesize=synthesize_speech,
                                notify=event, sleep=asyncio.sleep):
    """Keep retrying HTTP 403; bound consecutive other transient failures."""
    attempt = 0
    other_failures = 0
    while True:
        attempt += 1
        output.unlink(missing_ok=True)
        try:
            await synthesize(text, voice, rate, output)
            return
        except Exception as exc:
            output.unlink(missing_ok=True)
            status = getattr(exc, "status", None)
            import aiohttp
            transient = status in (403, 408, 429, 500, 502, 503, 504) or isinstance(
                exc, (aiohttp.ClientConnectionError, TimeoutError, ConnectionError))
            if not transient:
                if isinstance(exc, aiohttp.ClientError):
                    raise SpeechServiceError(
                        f"Microsofts Sprachdienst hat die Anfrage abgelehnt (HTTP {status or 'unbekannt'})."
                    ) from None
                raise
            reason = f"HTTP {status}" if status else "Verbindungsfehler"
            other_failures = 0 if status == 403 else other_failures + 1
            if other_failures >= 4:
                raise SpeechServiceError(
                    f"Microsofts Sprachdienst ist derzeit nicht erreichbar ({reason}). "
                    "Bitte später erneut exportieren. Bereits gespeicherte Sprachabschnitte "
                    "werden beim nächsten Versuch wiederverwendet."
                ) from None
            delays = (2, 5, 10)
            delay = delays[min(attempt - 1, len(delays) - 1)]
            notify(f"Sprachdienst: {reason}. Neuer Versuch {attempt + 1} in {delay} Sekunden …")
            await sleep(delay)


def valid_pcm(path):
    try:
        with wave.open(str(path), "rb") as audio:
            return (audio.getparams()[:3] == (1, 2, SAMPLE_RATE)
                    and audio.getnframes() > 0
                    and len(audio.readframes(audio.getnframes())) == audio.getnframes() * 2)
    except (OSError, EOFError, wave.Error):
        return False


def write_silence(target, frames):
    while frames > 0:
        count = min(frames, SAMPLE_RATE)
        target.writeframesraw(b"\0\0" * count)
        frames -= count


def pcm_frames(path):
    with wave.open(str(path), "rb") as source:
        return source.getnframes()


async def render_timeline(rows, duration, folder, voice, rate, ffmpeg, *, synthesize=synthesize_speech, notify=event,
                          cache_dir=None, sleep=asyncio.sleep):
    starts = validate_segments(rows, duration)
    timeline = folder / "timeline.wav"
    cursor = 0
    schedule = []
    if cache_dir is not None:
        cache_dir = Path(cache_dir)
        cache_dir.mkdir(parents=True, exist_ok=True)
    requested = False
    with wave.open(str(timeline), "wb") as target:
        target.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
        for index, (row, desired_start) in enumerate(zip(rows, starts), 1):
            notify(f"Vertone Abschnitt {index} von {len(rows)}", done=index - 1, total=len(rows))
            speech = folder / "speech.mp3"
            raw = folder / "raw.wav"
            key = hashlib.sha256(json.dumps(["pcm-v1", row["text"], voice, rate], ensure_ascii=False).encode("utf-8")).hexdigest()
            cached = cache_dir / f"{key}.wav" if cache_dir is not None else None
            if cached is not None and valid_pcm(cached):
                notify(f"Abschnitt {index} aus dem Sprachcache geladen.")
                shutil.copyfile(cached, raw)
            else:
                if requested:
                    await sleep(1)
                requested = True
                await synthesize_with_retry(row["text"], voice, rate, speech,
                    synthesize=synthesize, notify=notify, sleep=sleep)
                run_tool([ffmpeg, "-v", "error", "-y", "-i", str(speech), "-ar", str(SAMPLE_RATE),
                          "-ac", "1", "-c:a", "pcm_s16le", str(raw)])
                if not valid_pcm(raw):
                    raise ValueError("Der Sprachdienst hat eine ungültige Aufnahme geliefert.")
                if cached is not None:
                    # Publish only a complete clip; failed jobs retain earlier clips.
                    with tempfile.NamedTemporaryFile(dir=cache_dir, suffix=".tmp", delete=False) as pending:
                        pending_path = Path(pending.name)
                    try:
                        shutil.copyfile(raw, pending_path)
                        pending_path.replace(cached)
                    finally:
                        pending_path.unlink(missing_ok=True)
            actual_start = max(desired_start, cursor)
            write_silence(target, actual_start - cursor)
            with wave.open(str(raw), "rb") as source:
                count = source.getnframes()
                if count == 0:
                    raise ValueError("Der Sprachdienst hat eine leere Aufnahme geliefert.")
                while True:
                    data = source.readframes(SAMPLE_RATE)
                    if not data:
                        break
                    target.writeframesraw(data)
            cursor = actual_start + count
            schedule.append({**row, "actual_start": actual_start / SAMPLE_RATE,
                             "actual_end": cursor / SAMPLE_RATE})
            if actual_start > desired_start:
                notify(f"Abschnitt {index} startet nach dem vorherigen Abschnitt.")
        write_silence(target, round(duration * SAMPLE_RATE) - cursor)
    return timeline, schedule


async def create_plain_mp3(manifest, output, voice, rate, *, synthesize=synthesize_speech, notify=event, cache_dir=None, sleep=asyncio.sleep):
    text = manifest["text"]
    if not isinstance(text, str) or not text.strip():
        raise ValueError("Kein Text zum Vorlesen vorhanden.")
    output = Path(output).resolve()
    with tempfile.TemporaryDirectory(prefix="deepler_mp3_", dir=output.parent) as temp:
        speech = Path(temp) / "speech.mp3"
        notify("Erzeuge MP3 …")
        await synthesize_with_retry(text, voice, rate, speech,
            synthesize=synthesize, notify=notify, sleep=sleep)
        if not speech.is_file() or speech.stat().st_size == 0:
            raise ValueError("Der Sprachdienst hat keine Audiodaten geliefert.")
        shutil.copyfile(speech, output)
    notify("MP3 gespeichert.")


async def create_timed_mp3(manifest, output, voice, rate, *, synthesize=synthesize_speech, notify=event, cache_dir=None):
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise ValueError("Für MP3 mit Zeitstempeln müssen FFmpeg und FFprobe im PATH verfügbar sein.")
    source, output = Path(manifest["source"]).resolve(), Path(output).resolve()
    if source == output:
        raise ValueError("Die Originaldatei darf nicht überschrieben werden.")
    if not source.is_file():
        raise ValueError("Die Originaldatei wurde nicht gefunden.")
    metadata = probe(source, ffprobe)
    duration = float(metadata["format"].get("duration", 0))
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Die Länge der Originaldatei konnte nicht bestimmt werden.")
    with tempfile.TemporaryDirectory(prefix="deepler_mp3_", dir=output.parent) as temp:
        folder = Path(temp)
        timeline, schedule = await render_timeline(manifest["segments"], duration, folder,
            voice, rate, ffmpeg, synthesize=synthesize, notify=notify, cache_dir=cache_dir)
        notify("Speichere MP3 mit ursprünglichen Startzeiten …", done=len(schedule), total=len(schedule))
        result = folder / "timed.mp3"
        run_tool([ffmpeg, "-v", "error", "-y", "-i", str(timeline),
                  "-c:a", "libmp3lame", "-b:a", "192k", str(result)])
        shutil.copyfile(result, output)
    delayed = sum(row["actual_start"] > row["start"] + 1 / SAMPLE_RATE for row in schedule)
    notify("MP3 mit Zeitstempeln gespeichert.", delayed=delayed,
           duration=max(duration, schedule[-1]["actual_end"]))


async def create_dub(manifest, output, voice, rate, *, synthesize=synthesize_speech, notify=event, cache_dir=None, mix_original=False):
    language = manifest.get("language", "de").lower().split("-")[0]
    track_language, track_title = {
        "de": ("deu", "Deutsch"),
        "en": ("eng", "Englisch"),
        "it": ("ita", "Italienisch"),
        "es": ("spa", "Spanisch"),
    }[language]
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise ValueError("Für den Videoexport müssen FFmpeg und FFprobe im PATH verfügbar sein.")
    source = Path(manifest["source"]).resolve()
    output = Path(output).resolve()
    if source == output:
        raise ValueError("Das Originalvideo darf nicht überschrieben werden. Bitte einen neuen Dateinamen wählen.")
    if not source.is_file():
        raise ValueError("Das Originalvideo wurde nicht gefunden.")
    metadata = probe(source, ffprobe)
    videos = [stream for stream in metadata["streams"] if stream["codec_type"] == "video"]
    if not videos:
        raise ValueError("Die ausgewählte Datei enthält kein Video.")
    video = videos[0]
    duration = float(video.get("duration") or metadata["format"].get("duration", 0))
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Die Videolänge konnte nicht bestimmt werden.")
    validate_segments(manifest["segments"], duration)
    with tempfile.TemporaryDirectory(prefix="deepler_dub_", dir=output.parent) as temp:
        folder = Path(temp)
        timeline, schedule = await render_timeline(
            manifest["segments"], duration, folder, voice, rate, ffmpeg,
            synthesize=synthesize, notify=notify, cache_dir=cache_dir,
        )
        notify(f"Verbinde Video und Tonspur ({track_title}) …", done=len(manifest["segments"]), total=len(manifest["segments"]))
        result = folder / "dubbed.mp4"
        audio_duration = pcm_frames(timeline) / SAMPLE_RATE
        extension = max(0.0, audio_duration - duration)
        if extension <= 1 / SAMPLE_RATE:
            extension = 0.0  # Sample rounding alone must not trigger re-encoding.
        output_duration = duration + extension
        has_original_audio = any(stream["codec_type"] == "audio" for stream in metadata["streams"])
        base = [ffmpeg, "-v", "error", "-y", "-i", str(source), "-i", str(timeline)]
        audio_map = "1:a:0"
        if mix_original and has_original_audio:
            notify("Originalton wird mit 25 % Lautstärke unter die Übersetzung gemischt.")
            original_audio = next(stream for stream in metadata["streams"] if stream["codec_type"] == "audio")
            background_layout = ("pan=stereo|c0=c0|c1=c0" if original_audio.get("channels") == 1
                                 else "aformat=channel_layouts=stereo")
            base += ["-filter_complex",
                     f"[0:a:0]{background_layout},volume=0.25[background];"
                     "[1:a:0]pan=stereo|c0=c0|c1=c0[foreground];"
                     "[foreground][background]amix=inputs=2:duration=first:dropout_transition=0:normalize=0,"
                     "alimiter=limit=0.95:level=0:latency=1[mixed]"]
            audio_map = "[mixed]"
        base += ["-map", "0:v:0", "-map", audio_map, "-map", "0:a:0?",
                "-c:a", "aac", "-b:a", "192k", "-metadata:s:a:0", f"language={track_language}",
                "-metadata:s:a:0", f"title={track_title}",
                "-metadata:s:a:0", f"handler_name={track_title}", "-disposition:a:0", "default",
                "-t", f"{output_duration:.9f}", "-movflags", "+faststart"]
        if has_original_audio:
            base += ["-filter:a:1", "volume=0.25",
                     "-metadata:s:a:1", "title=Original (25 %)",
                     "-metadata:s:a:1", "handler_name=Original (25 %)",
                     "-disposition:a:1", "0"]
        if extension > 0:
            notify("Das letzte Bild bleibt bis zum Ende der Sprache stehen.")
            run_tool([*base, "-vf", f"tpad=stop_mode=clone:stop_duration={extension:.9f},pad=ceil(iw/2)*2:ceil(ih/2)*2",
                      "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                      "-pix_fmt", "yuv420p", str(result)])
        else:
            try:
                run_tool([*base, "-c:v", "copy", str(result)])
            except RuntimeError:
                # Formats such as WMV cannot always be copied into MP4.
                notify("Das Bildformat wird für MP4 konvertiert …")
                run_tool([*base, "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                          "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                          "-pix_fmt", "yuv420p", str(result)])
        shutil.copyfile(result, output)
    delayed = sum(row["actual_start"] > row["start"] + 1 / SAMPLE_RATE for row in schedule)
    notify(f"Video mit Tonspur ({track_title}) gespeichert.", delayed=delayed, duration=output_duration)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--voice", default="de-DE-KatjaNeural")
    parser.add_argument("--rate", type=int, default=0)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--audio-only", action="store_true")
    parser.add_argument("--plain-audio", action="store_true")
    parser.add_argument("--mix-original", action="store_true")
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        export = create_plain_mp3 if args.plain_audio else create_timed_mp3 if args.audio_only else create_dub
        options = {"cache_dir": args.cache_dir}
        if export is create_dub:
            options["mix_original"] = args.mix_original
        asyncio.run(export(manifest, args.output, args.voice, args.rate, **options))
    except Exception as exc:
        event(str(exc), error=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
