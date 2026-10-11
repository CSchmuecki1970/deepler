import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deepler/audio_exporter.dart';
import 'package:deepler/timed_transcript.dart';
import 'package:deepler/video_exporter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final python = Platform.environment['DEEPLER_TEST_PYTHON'] ?? 'python';
  late Directory root;
  const worker = '''
import argparse, json, time
from pathlib import Path
parser = argparse.ArgumentParser()
for name in ('manifest', 'output', 'voice', 'rate', 'cache-dir'):
    parser.add_argument('--' + name)
parser.add_argument('--audio-only', action='store_true')
parser.add_argument('--plain-audio', action='store_true')
parser.add_argument('--mix-original', action='store_true')
args = parser.parse_args()
manifest = json.loads(Path(args.manifest).read_text(encoding='utf-8'))
text = manifest['text'] if args.plain_audio else manifest['segments'][0]['text']
if text == 'wait':
    print(json.dumps({'message': 'HTTP 403. Neuer Versuch in 10 Sekunden …'}), flush=True)
    time.sleep(600)
else:
    Path(args.output).write_bytes(b'mixed' if args.mix_original else b'complete')
''';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('deepler_cancel_test_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      if (key != 'python/dub_video.py') return null;
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(worker)));
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    messenger.setMockMessageHandler('flutter/assets', null);
    await root.delete(recursive: true);
  });

  for (final timed in [false, true]) {
    test(
      '${timed ? 'timed' : 'plain'} MP3 can cancel a waiting worker and export again',
      () async {
        final source = File('${root.path}/source.wav');
        await source.writeAsString('source');
        final output = File('${root.path}/existing.mp3');
        await output.writeAsString('original');
        final exporter = AudioExporter();
        final waiting = Completer<void>();
        final transcript = timed
            ? TimedTranscript(
                source: source.path,
                language: 'de',
                segments: const [TimedSegment(start: 0, end: 1, text: 'wait')],
              )
            : null;
        final export = exporter.export(
          python: python,
          text: 'wait',
          transcript: transcript,
          voice: 'voice',
          rate: 0,
          output: output.path,
          onProgress: (_, _, _) {
            if (!waiting.isCompleted) waiting.complete();
          },
        );
        final failure = expectLater(
          export,
          throwsA(
            predicate((e) => e.toString().contains('Export abgebrochen')),
          ),
        );
        try {
          await waiting.future.timeout(const Duration(seconds: 15));
        } finally {
          await exporter.cancel();
        }
        await failure;
        expect(await output.readAsString(), 'original');
        expect(root.listSync().whereType<Directory>(), isEmpty);
        await exporter.export(
          python: python,
          text: 'success',
          voice: 'voice',
          rate: 0,
          output: output.path,
        );
        expect(await output.readAsString(), 'complete');
        expect(root.listSync().whereType<Directory>(), isEmpty);
      },
    );
  }

  test('video forwards selected background mixing option to worker', () async {
    final source = File('${root.path}/source.mp4');
    await source.writeAsString('source');
    final transcript = TimedTranscript(
      source: source.path,
      language: 'de',
      segments: const [TimedSegment(start: 0, end: 1, text: 'success')],
    );
    final output = File('${root.path}/output.mp4');
    for (final mix in [true, false]) {
      await VideoExporter().export(
        python: python,
        transcript: transcript,
        voice: 'voice',
        rate: 0,
        output: output.path,
        mixOriginalAudio: mix,
        onProgress: (_, _, _) {},
      );
      expect(await output.readAsString(), mix ? 'mixed' : 'complete');
    }
  });
}
