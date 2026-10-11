import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'timed_transcript.dart';

class VideoExporter {
  Process? _process;
  bool _cancelRequested = false;

  Future<void> cancel() async {
    _cancelRequested = true;
    final process = _process;
    if (process == null) return;
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill();
    }
  }

  Future<void> exportSpeech({
    required String python,
    required String text,
    required String voice,
    required int rate,
    required String output,
    required void Function(String message, int? done, int? total) onProgress,
  }) async {
    await _exportManifest(
      python: python,
      manifestData: {'text': text},
      voice: voice,
      rate: rate,
      output: output,
      onProgress: onProgress,
      audioOnly: true,
      plainAudio: true,
    );
  }

  Future<int> export({
    required String python,
    required TimedTranscript transcript,
    required String voice,
    required int rate,
    required String output,
    required void Function(String message, int? done, int? total) onProgress,
    bool audioOnly = false,
    bool mixOriginalAudio = false,
  }) async {
    final source = File(transcript.source);
    if (!await source.exists()) {
      throw Exception('Die Originaldatei wurde nicht gefunden.');
    }
    if (await File(output).exists()) {
      var original = await source.resolveSymbolicLinks();
      var destination = await File(output).resolveSymbolicLinks();
      if (Platform.isWindows) {
        original = original.toLowerCase();
        destination = destination.toLowerCase();
      }
      if (original == destination) {
        throw Exception(
          'Bitte einen neuen Dateinamen wählen. Das Original bleibt erhalten.',
        );
      }
    }
    return _exportManifest(
      python: python,
      manifestData: transcript.toJson(),
      voice: voice,
      rate: rate,
      output: output,
      onProgress: onProgress,
      audioOnly: audioOnly,
      mixOriginalAudio: mixOriginalAudio,
    );
  }

  Future<int> _exportManifest({
    required String python,
    required Map<String, dynamic> manifestData,
    required String voice,
    required int rate,
    required String output,
    required void Function(String message, int? done, int? total) onProgress,
    bool audioOnly = false,
    bool plainAudio = false,
    bool mixOriginalAudio = false,
  }) async {
    _cancelRequested = false;
    final temp = await getTemporaryDirectory();
    final support = await getApplicationSupportDirectory();
    final job = await temp.createTemp('deepler_video_');
    try {
      final worker = File('${job.path}/dub_video.py');
      final manifest = File('${job.path}/segments.json');
      final result = File('${job.path}/result.${audioOnly ? 'mp3' : 'mp4'}');
      await worker.writeAsString(
        await rootBundle.loadString('python/dub_video.py'),
      );
      await manifest.writeAsString(jsonEncode(manifestData));
      if (_cancelRequested) throw Exception('Export abgebrochen.');
      final process = await Process.start(
        python,
        [
          '-u',
          worker.path,
          '--manifest',
          manifest.path,
          '--output',
          result.path,
          '--voice',
          voice,
          '--rate=$rate',
          '--cache-dir',
          '${support.path}/speech_cache',
          if (audioOnly) '--audio-only',
          if (plainAudio) '--plain-audio',
          if (mixOriginalAudio && !audioOnly) '--mix-original',
        ],
        environment: {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
      );
      _process = process;
      if (_cancelRequested) await cancel();
      String? failure;
      var delayed = 0;
      final stdoutDone = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
            try {
              final event = jsonDecode(line) as Map<String, dynamic>;
              final message = event['message'] as String;
              if (event['error'] == true) {
                failure = message;
                return;
              }
              if (event['delayed'] is int) delayed = event['delayed'] as int;
              onProgress(
                message,
                event['done'] as int?,
                event['total'] as int?,
              );
            } on FormatException {
              onProgress(line, null, null);
            }
          });
      final stderrDone = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await process.exitCode;
      await stdoutDone;
      final errors = await stderrDone;
      if (_cancelRequested) throw Exception('Export abgebrochen.');
      if (exitCode != 0) {
        throw Exception(
          failure ??
              (errors.contains('No module named')
                  ? 'Bitte python/requirements.txt in der gewählten Python-Umgebung installieren.'
                  : 'Der Medienexport ist fehlgeschlagen. Bitte Verbindung, Python und FFmpeg prüfen.'),
        );
      }
      if (!await result.exists() || await result.length() == 0) {
        throw Exception('Es wurde keine Mediendatei erzeugt.');
      }
      await result.copy(output);
      return delayed;
    } finally {
      _process = null;
      await job.delete(recursive: true);
    }
  }
}
