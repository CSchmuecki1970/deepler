"""Check the imported worker without downloads or installed speech models."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


WORKER = Path(__file__).resolve().parents[1] / "python" / "transcribe.py"


class TranscribeTests(unittest.TestCase):
    def run_worker(self, language):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            media = root / "Видео.part1.mp4"
            media.touch()
            output = root / "result"
            cache = root / "models"
            row = SimpleNamespace(start=1.125, end=4.75, text=" Привет, мир! ",
                                  avg_logprob=-0.2, no_speech_prob=0.01)
            model = Mock()
            model.transcribe.return_value = (iter([row]), SimpleNamespace(language="ru"))
            factory = Mock(return_value=model)
            module = ModuleType("faster_whisper")
            module.WhisperModel = factory
            audio = ModuleType("faster_whisper.audio")
            audio.decode_audio = Mock()
            argv = [str(WORKER), str(media), "--language", language,
                    "--output-dir", str(output), "--models-dir", str(cache)]
            with patch.dict(sys.modules, {"faster_whisper": module,
                                          "faster_whisper.audio": audio}), \
                 patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(WORKER), run_name="__main__")
            self.assertEqual(factory.call_args.args, ("small",))
            options = factory.call_args.kwargs
            self.assertEqual(options["device"], "cpu")
            self.assertEqual(options["compute_type"], "int8")
            self.assertEqual(options["download_root"], str(cache))
            model.transcribe.assert_called_once_with(
                str(media.resolve()), language=None if language == "auto" else "ru",
                beam_size=5, vad_filter=True)
            audio.decode_audio.assert_not_called()
            data = json.loads((output / "Видео.part1.json").read_text(encoding="utf-8"))
            self.assertEqual(data["language"], "ru")
            self.assertEqual(data["segments"][0]["text"], "Привет, мир!")
            self.assertEqual(data["segments"][0]["start"], 1.125)
            self.assertIn("00:00:01,125 --> 00:00:04,750",
                          (output / "Видео.part1.srt").read_text(encoding="utf-8-sig"))

    def test_russian_video_preserves_unicode_and_timing(self):
        self.run_worker("ru")

    def test_auto_language_uses_detection(self):
        self.run_worker("auto")

    def test_missing_input_fails_before_loading_model(self):
        with tempfile.TemporaryDirectory() as folder, \
             patch.object(sys, "argv", [str(WORKER), str(Path(folder) / "missing.mp4")]), \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                runpy.run_path(str(WORKER), run_name="__main__")
            self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
