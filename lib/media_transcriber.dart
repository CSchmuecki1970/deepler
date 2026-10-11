import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'timed_transcript.dart';

/// Uses the transcription worker from DmitrysVideo, bundled for release builds.
class MediaTranscriber {
  static Future<Directory?> findDmitrysVideo() async {
    for (final start in [
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ]) {
      var directory = start;
      while (true) {
        final candidate = Directory('${directory.path}/DmitrysVideo');
        final python = File(
          '${candidate.path}/.venv/${Platform.isWindows ? 'Scripts/python.exe' : 'bin/python'}',
        );
        if (await python.exists()) return candidate;
        final parent = directory.parent;
        if (parent.path == directory.path) break;
        directory = parent;
      }
    }
    return null;
  }

  static Future<String> defaultPython() async {
    final project = await findDmitrysVideo();
    if (project != null) {
      return '${project.path}/.venv/${Platform.isWindows ? 'Scripts/python.exe' : 'bin/python'}';
    }
    return Platform.isWindows ? 'py' : 'python3';
  }

  Future<TimedTranscript> transcribe({
    required String python,
    required String input,
    required String model,
    required String language,
    required void Function(String) onLog,
  }) async {
    final temp = await getTemporaryDirectory();
    final job = await temp.createTemp('deepler_transcribe_');
    try {
      final worker = File('${job.path}/transcribe.py');
      await worker.writeAsString(
        await rootBundle.loadString('python/transcribe.py'),
      );
      final project = await findDmitrysVideo();
      final support = await getApplicationSupportDirectory();
      final models = project == null
          ? '${support.path}/whisper_models'
          : '${project.path}/models';
      onLog('DmitrysVideo extraction: $model, language: $language');
      onLog('Python: $python');
      onLog('Model cache: $models');
      final process = await Process.start(
        python,
        [
          '-u',
          worker.path,
          input,
          '--output-dir',
          job.path,
          '--models-dir',
          models,
          '--model',
          model,
          '--language',
          language,
        ],
        environment: {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
      );

      // Drain both pipes concurrently: verbose workers can otherwise deadlock.
      final errors = StringBuffer();
      final stdoutDone = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(onLog);
      final stderrDone = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
            errors.writeln(line);
            onLog(line);
          });
      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      if (exitCode != 0) {
        final details = errors.toString().trim();
        throw Exception(
          'Extraction failed (exit $exitCode). $details'
          '\nCheck the Python executable and install python/requirements.txt in that environment.',
        );
      }

      // Read structured output so status messages and timestamps never become
      // part of the text sent to DeepL. Preserve names such as clip.part1.mp4.
      final name = File(input).uri.pathSegments.last;
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final result =
          jsonDecode(await File('${job.path}/$stem.json').readAsString())
              as Map<String, dynamic>;
      onLog('Detected language: ${result['language']}');
      final rows = result['segments'] as List;
      result['segments'] = rows
          .where((row) => (row['text'] as String).trim().isNotEmpty)
          .toList();
      if ((result['segments'] as List).isEmpty) {
        throw Exception('No speech was detected in the media.');
      }
      return TimedTranscript.fromJson(result);
    } finally {
      await job.delete(recursive: true);
    }
  }
}
