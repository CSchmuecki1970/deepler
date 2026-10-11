import asyncio
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from unittest.mock import AsyncMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
import dub_video as dub


FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")


def row(start, end, text):
    return {"start": start, "end": end, "text": text}


def synth_factory(durations, calls):
    async def synthesize(text, voice, rate, output):
        calls.append((text, voice, rate))
        # A reproducible square wave makes unmodified sample lengths and
        # content directly testable. FFmpeg detects WAV by its header.
        frames = round(durations[text] * dub.SAMPLE_RATE)
        data = b"".join(struct.pack('<h', 6000 if i % 48 < 24 else -6000) for i in range(frames))
        with wave.open(str(output), 'wb') as target:
            target.setparams((1, 2, dub.SAMPLE_RATE, 0, 'NONE', 'not compressed'))
            target.writeframes(data)
    return synthesize


class ValidationTests(unittest.TestCase):
    def test_rejects_bad_or_out_of_order_timestamps(self):
        for rows in [[], [row(-1, 1, 'a')], [row(0, float('nan'), 'a')],
                     [row(1, 2, 'a'), row(1, 3, 'b')], [row(0, 1, '')]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                dub.validate_segments(rows, 4)


class RetryTests(unittest.TestCase):
    def test_retries_403_without_reusing_partial_audio(self):
        class Forbidden(Exception):
            status = 403
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'speech.mp3'
            attempts = []
            async def synthesize(text, voice, rate, path):
                self.assertFalse(path.exists())
                attempts.append(rate)
                path.write_bytes(b'partial' if len(attempts) < 3 else b'complete')
                if len(attempts) < 3:
                    raise Forbidden('wss://secret-url')
            sleep = AsyncMock()
            asyncio.run(dub.synthesize_with_retry('Hallo', 'voice', -10, output,
                synthesize=synthesize, sleep=sleep, notify=lambda *a, **k: None))
            self.assertEqual(output.read_bytes(), b'complete')
            self.assertEqual(attempts, [-10] * 3)
            self.assertEqual([c.args[0] for c in sleep.await_args_list], [2, 5])

    def test_403_continues_past_four_attempts_with_capped_backoff(self):
        class Forbidden(Exception):
            status = 403
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'speech.mp3'
            calls, messages = [], []
            async def synthesize(text, voice, rate, path):
                self.assertFalse(path.exists())
                calls.append(text)
                path.write_bytes(b'partial')
                if len(calls) <= 8:
                    raise Forbidden('wss://secret-url')
                path.write_bytes(b'complete')
            sleep = AsyncMock()
            asyncio.run(dub.synthesize_with_retry('Hallo', 'voice', 0, output,
                synthesize=synthesize, sleep=sleep, notify=lambda message: messages.append(message)))
            self.assertEqual(len(calls), 9)
            self.assertEqual(output.read_bytes(), b'complete')
            self.assertEqual([c.args[0] for c in sleep.await_args_list], [2, 5, 10, 10, 10, 10, 10, 10])
            self.assertIn('Neuer Versuch 9', messages[-1])
            self.assertTrue(all('HTTP 403' in message and 'wss:' not in message for message in messages))

    def test_repeated_403_can_be_cancelled_during_backoff(self):
        class Forbidden(Exception):
            status = 403
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'speech.mp3'
            synthesize = AsyncMock(side_effect=Forbidden('secret'))
            sleep = AsyncMock(side_effect=[None] * 7 + [asyncio.CancelledError()])
            with self.assertRaises(asyncio.CancelledError):
                asyncio.run(dub.synthesize_with_retry('Hallo', 'voice', 0, output,
                    synthesize=synthesize, sleep=sleep, notify=lambda *a, **k: None))
            self.assertEqual(synthesize.await_count, 8)
            self.assertFalse(output.exists())

    def test_other_transient_errors_still_stop_after_four_attempts(self):
        class Unavailable(Exception):
            status = 503
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'speech.mp3'
            synthesize = AsyncMock(side_effect=Unavailable('wss://secret-url'))
            with self.assertRaises(dub.SpeechServiceError) as failure:
                asyncio.run(dub.synthesize_with_retry('Hallo', 'voice', 0, output,
                    synthesize=synthesize, sleep=AsyncMock(), notify=lambda *a, **k: None))
            self.assertEqual(synthesize.await_count, 4)
            self.assertIn('HTTP 503', str(failure.exception))
            self.assertNotIn('wss:', str(failure.exception))
            self.assertFalse(output.exists())

    def test_plain_mp3_uses_retry_and_preserves_destination_until_success(self):
        class Forbidden(Exception):
            status = 403
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'existing.mp3'
            output.write_bytes(b'original')
            calls = []
            async def synthesize(text, voice, rate, path):
                self.assertEqual(output.read_bytes(), b'original')
                calls.append((text, voice, rate))
                if len(calls) < 6:
                    raise Forbidden()
                path.write_bytes(b'complete')
            asyncio.run(dub.create_plain_mp3({'text': 'Grüße'}, output, 'voice', -10,
                synthesize=synthesize, sleep=AsyncMock(), notify=lambda *a, **k: None))
            self.assertEqual(calls, [('Grüße', 'voice', -10)] * 6)
            self.assertEqual(output.read_bytes(), b'complete')
            self.assertFalse(list(Path(temp).glob('deepler_mp3_*')))


@unittest.skipUnless(FFMPEG and FFPROBE, 'FFmpeg and FFprobe required')
class TimelineTests(unittest.TestCase):
    def test_timed_mp3_preserves_gaps_queues_speech_and_keeps_overrun(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'original.wav'
            with wave.open(str(source), 'wb') as audio:
                audio.setparams((1, 2, dub.SAMPLE_RATE, 0, 'NONE', 'not compressed'))
                audio.writeframes(b'\0\0' * (4 * dub.SAMPLE_RATE))
            output = root / 'timed.mp3'
            manifest = {'source': str(source), 'segments': [
                row(0.5, 0.9, 'a'), row(1, 1.4, 'b'), row(3.5, 3.9, 'c')]}
            calls, events = [], []
            asyncio.run(dub.create_timed_mp3(manifest, output, 'voice', -10,
                synthesize=synth_factory({'a': 1, 'b': 0.75, 'c': 0.8}, calls),
                notify=lambda message, **data: events.append(data)))
            self.assertEqual(calls, [('a', 'voice', -10), ('b', 'voice', -10), ('c', 'voice', -10)])
            self.assertEqual(events[-1]['delayed'], 1)
            self.assertAlmostEqual(events[-1]['duration'], 4.3)
            decoded = root / 'decoded.wav'
            dub.run_tool([FFMPEG, '-v', 'error', '-y', '-i', str(output), str(decoded)])
            with wave.open(str(decoded), 'rb') as audio:
                self.assertAlmostEqual(audio.getnframes() / audio.getframerate(), 4.3, delta=0.05)
                for start, end, silent in [(0, 0.3, True), (0.65, 0.8, False),
                                           (1.8, 2, False), (2.5, 3.3, True), (3.7, 4.2, False)]:
                    audio.setpos(round(start * audio.getframerate()))
                    data = audio.readframes(round((end - start) * audio.getframerate()))
                    samples = struct.unpack('<' + 'h' * (len(data) // 2), data)
                    amplitude = sum(abs(s) for s in samples) / len(samples)
                    self.assertLess(amplitude, 100) if silent else self.assertGreater(amplitude, 3000)
            before = output.read_bytes()
            async def fail(*args):
                raise ValueError('failed')
            with self.assertRaises(ValueError):
                asyncio.run(dub.create_timed_mp3(manifest, output, 'voice', 0,
                    synthesize=fail, notify=lambda *a, **k: None))
            self.assertEqual(output.read_bytes(), before)
            self.assertFalse(list(root.glob('deepler_mp3_*')))
            with self.assertRaises(ValueError):
                asyncio.run(dub.create_timed_mp3(manifest, source, 'voice', 0))

    def test_failed_job_resumes_cached_clips_and_voice_changes_invalidate_cache(self):
        rows = [row(0, 0.5, 'a'), row(1, 1.5, 'b')]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cache = root / 'cache'
            calls = []
            good = synth_factory({'a': 0.5, 'b': 0.5}, calls)
            async def fail_second(text, voice, rate, output):
                if text == 'b':
                    raise ValueError('failed second clip')
                await good(text, voice, rate, output)
            with self.assertRaises(ValueError):
                asyncio.run(dub.render_timeline(rows, 2, root, 'voice', 0, FFMPEG,
                    synthesize=fail_second, cache_dir=cache, sleep=AsyncMock(), notify=lambda *a, **k: None))
            self.assertEqual(len(list(cache.glob('*.wav'))), 1)
            asyncio.run(dub.render_timeline(rows, 2, root, 'voice', 0, FFMPEG,
                synthesize=good, cache_dir=cache, sleep=AsyncMock(), notify=lambda *a, **k: None))
            self.assertEqual([c[0] for c in calls], ['a', 'b'])
            calls.clear()
            for clip in cache.glob('*.wav'):
                clip.write_bytes(b'broken')
            asyncio.run(dub.render_timeline(rows, 2, root, 'voice', 0, FFMPEG,
                synthesize=good, cache_dir=cache, sleep=AsyncMock(), notify=lambda *a, **k: None))
            self.assertEqual(len(calls), 2)
            asyncio.run(dub.render_timeline(rows, 2, root, 'other-voice', 0, FFMPEG,
                synthesize=good, cache_dir=cache, sleep=AsyncMock(), notify=lambda *a, **k: None))
            self.assertEqual(len(calls), 4)
            asyncio.run(dub.render_timeline(rows, 2, root, 'other-voice', 10, FFMPEG,
                synthesize=good, cache_dir=cache, sleep=AsyncMock(), notify=lambda *a, **k: None))
            self.assertEqual(len(calls), 6)
    def test_queue_preserves_speed_and_recovers_original_start_after_pause(self):
        calls = []
        durations = {'a': 1.0, 'b': 0.75, 'c': 0.4}
        rows = [row(0.5, 0.9, 'a'), row(1.0, 1.4, 'b'), row(3.5, 3.9, 'c')]
        with tempfile.TemporaryDirectory() as temp:
            audio, schedule = asyncio.run(dub.render_timeline(
                rows, 4, Path(temp), 'voice', -10, FFMPEG,
                synthesize=synth_factory(durations, calls), notify=lambda *a, **k: None))
            self.assertEqual([r['actual_start'] for r in schedule], [0.5, 1.5, 3.5])
            self.assertEqual([round(r['actual_end'] - r['actual_start'], 5) for r in schedule], [1.0, 0.75, 0.4])
            self.assertEqual(calls, [('a', 'voice', -10), ('b', 'voice', -10), ('c', 'voice', -10)])
            with wave.open(str(audio), 'rb') as source:
                self.assertEqual(source.getnframes(), 4 * dub.SAMPLE_RATE)
                self.assertEqual(source.readframes(dub.SAMPLE_RATE // 2), b'\0\0' * (dub.SAMPLE_RATE // 2))
                # Sample data is unchanged, so there is no time stretch or trim.
                expected = b''.join(struct.pack('<h', 6000 if i % 48 < 24 else -6000) for i in range(dub.SAMPLE_RATE))
                self.assertEqual(source.readframes(dub.SAMPLE_RATE), expected)
                source.setpos(round(2.5 * dub.SAMPLE_RATE))
                self.assertEqual(source.readframes(dub.SAMPLE_RATE // 2), b'\0\0' * (dub.SAMPLE_RATE // 2))

    def test_overrun_extends_audio_instead_of_cutting_words(self):
        with tempfile.TemporaryDirectory() as temp:
            audio, schedule = asyncio.run(dub.render_timeline(
                [row(0.5, 0.9, 'a'), row(1, 1.8, 'b')], 2, Path(temp), 'voice', 15, FFMPEG,
                synthesize=synth_factory({'a': 1.2, 'b': 1.1}, []), notify=lambda *a, **k: None))
            self.assertAlmostEqual(schedule[-1]['actual_end'], 2.8)
            self.assertEqual(dub.pcm_frames(audio), round(2.8 * dub.SAMPLE_RATE))

    def test_video_retains_original_audio_and_freezes_last_frame_to_spoken_end(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'original.mp4'
            subprocess.run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i',
                            'color=c=blue:s=160x120:r=25:d=2', '-f', 'lavfi', '-i',
                            'sine=frequency=880:duration=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                            '-c:a', 'aac', '-shortest', str(source)], check=True, capture_output=True)
            original_hash = hashlib.sha256(source.read_bytes()).digest()
            output = root / 'german.mp4'
            manifest = {'source': str(source), 'segments': [row(0.5, 0.9, 'a'), row(1, 1.8, 'b')]}
            asyncio.run(dub.create_dub(manifest, output, 'voice', 0,
                synthesize=synth_factory({'a': 1.2, 'b': 1.1}, []), notify=lambda *a, **k: None))
            metadata = dub.probe(output, FFPROBE)
            audio = [s for s in metadata['streams'] if s['codec_type'] == 'audio']
            video = next(s for s in metadata['streams'] if s['codec_type'] == 'video')
            self.assertEqual(len(audio), 2)
            self.assertEqual(audio[0]['tags']['language'], 'deu')
            self.assertEqual(audio[0]['disposition']['default'], 1)
            self.assertEqual(audio[1]['disposition']['default'], 0)
            self.assertEqual(audio[1]['tags']['handler_name'], 'Original (25 %)')
            # Measure decoded samples, rather than just checking FFmpeg arguments.
            def rms(path, track):
                data = subprocess.run([FFMPEG, '-v', 'error', '-i', str(path),
                    '-map', f'0:a:{track}', '-ss', '0.1', '-t', '0.2', '-ar', '24000',
                    '-ac', '1', '-f', 's16le', 'pipe:1'], check=True, capture_output=True).stdout
                samples = struct.unpack('<' + 'h' * (len(data) // 2), data)
                return (sum(s * s for s in samples) / len(samples)) ** 0.5
            self.assertAlmostEqual(rms(output, 1) / rms(source, 0), 0.25, delta=0.02)
            # The translated track stays silent before its first section:
            # it contains no mixed-in original tone.
            self.assertLess(rms(output, 0), 50)
            self.assertAlmostEqual(float(video['duration']), 2.8, delta=0.05)
            self.assertAlmostEqual(float(audio[0]['duration']), 2.8, delta=0.05)
            frame = subprocess.run([FFMPEG, '-v', 'error', '-sseof', '-0.1', '-i', str(output),
                                    '-map', '0:v:0', '-frames:v', '1', '-f', 'rawvideo',
                                    '-pix_fmt', 'rgb24', 'pipe:1'], check=True, capture_output=True).stdout
            self.assertGreater(len(frame), 0)
            self.assertGreater(sum(frame[2::3]) / len(frame[2::3]), 200)  # Blue, not black.
            self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), original_hash)
            # Synthesis failure must leave an existing destination untouched.
            before = output.read_bytes()
            async def fail(*args):
                raise ValueError('invalid synthesis')
            with self.assertRaises(ValueError):
                asyncio.run(dub.create_dub(manifest, output, 'voice', 0, synthesize=fail, notify=lambda *a, **k: None))
            self.assertEqual(output.read_bytes(), before)
            self.assertFalse(list(root.glob('deepler_dub_*')))
            with self.assertRaises(ValueError):
                asyncio.run(dub.create_dub(manifest, source, 'voice', 0))

    def test_translated_video_track_has_selected_language(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'original.mp4'
            subprocess.run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i',
                            'color=c=blue:s=160x120:r=25:d=1', '-c:v', 'libx264',
                            '-pix_fmt', 'yuv420p', str(source)], check=True, capture_output=True)
            for code, tag, title in [('en', 'eng', 'Englisch'), ('it', 'ita', 'Italienisch'),
                                     ('es', 'spa', 'Spanisch')]:
                with self.subTest(language=code):
                    output = root / f'{code}.mp4'
                    manifest = {'source': str(source), 'language': code,
                                'segments': [row(0.1, 0.5, 'a')]}
                    asyncio.run(dub.create_dub(manifest, output, 'voice', 0,
                        synthesize=synth_factory({'a': 0.3}, []), mix_original=True, notify=lambda *a, **k: None))
                    tracks = [s for s in dub.probe(output, FFPROBE)['streams']
                              if s['codec_type'] == 'audio']
                    self.assertEqual(len(tracks), 1)  # Silent source has no original track.
                    audio = tracks[0]
                    self.assertEqual(audio['tags']['language'], tag)
                    self.assertEqual(audio['tags']['handler_name'], title)

    def test_video_can_mix_quiet_original_under_speech_without_cutting_overrun(self):
        for channels in [1, 2]:
            with self.subTest(channels=channels):
                self._check_background_mix(channels)

    def _check_background_mix(self, channels):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'original.mp4'
            subprocess.run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i',
                            'color=c=blue:s=160x120:r=25:d=2', '-f', 'lavfi', '-i',
                            'sine=frequency=880:duration=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                            '-c:a', 'aac', '-ac', str(channels), '-shortest', str(source)], check=True, capture_output=True)
            manifest = {'source': str(source), 'language': 'de',
                        'segments': [row(0.5, 0.9, 'a')]}
            pure, mixed = root / 'pure.mp4', root / 'mixed.mp4'
            for output, enabled in [(pure, False), (mixed, True)]:
                asyncio.run(dub.create_dub(manifest, output, 'voice', 0,
                    synthesize=synth_factory({'a': 2}, []), mix_original=enabled,
                    cache_dir=root / 'cache', notify=lambda *a, **k: None))
                tracks = [s for s in dub.probe(output, FFPROBE)['streams'] if s['codec_type'] == 'audio']
                self.assertEqual(len(tracks), 2)
                self.assertEqual(tracks[0]['disposition']['default'], 1)
                self.assertEqual(tracks[1]['tags']['handler_name'], 'Original (25 %)')
                self.assertAlmostEqual(float(tracks[0]['duration']), 2.5, delta=0.05)

            def samples(path, start, track=0):
                data = subprocess.run([FFMPEG, '-v', 'error', '-i', str(path),
                    '-map', f'0:a:{track}', '-ss', str(start), '-t', '0.2', '-ar', '24000',
                    '-af', 'pan=mono|c0=c0', '-f', 's16le', 'pipe:1'], check=True, capture_output=True).stdout
                return struct.unpack('<' + 'h' * (len(data) // 2), data)

            def amplitude(data, hz):
                real = sum(s * math.cos(2 * math.pi * hz * i / 24000) for i, s in enumerate(data))
                imag = sum(s * math.sin(2 * math.pi * hz * i / 24000) for i, s in enumerate(data))
                return 2 * math.hypot(real, imag) / len(data)

            # Original tone remains audible during the pause and underneath speech.
            original_level = amplitude(samples(source, 0.1), 880)
            self.assertAlmostEqual(amplitude(samples(mixed, 0.1), 880) / original_level, 0.25, delta=0.02)
            self.assertAlmostEqual(amplitude(samples(mixed, 0.65), 880) / original_level, 0.25, delta=0.03)
            self.assertLess(amplitude(samples(pure, 0.1), 880), 50)
            # Foreground speech keeps its level, including after the original ends.
            for start in [0.65, 2.15]:
                self.assertAlmostEqual(amplitude(samples(mixed, start), 500) /
                                       amplitude(samples(pure, start), 500), 1, delta=0.05)


if __name__ == '__main__':
    unittest.main()
