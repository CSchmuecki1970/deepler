import 'timed_transcript.dart';
import 'video_exporter.dart';

class AudioExporter {
  final VideoExporter _worker = VideoExporter();

  Future<void> cancel() => _worker.cancel();

  Future<void> export({
    required String python,
    required String text,
    required String voice,
    required int rate,
    required String output,
    TimedTranscript? transcript,
    void Function(String message, int? done, int? total)? onProgress,
  }) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('Kein Text zum Vorlesen vorhanden.');
    }
    if (transcript != null) {
      if (transcript.text != text) {
        throw ArgumentError('Text und Zeitzuordnung stimmen nicht überein.');
      }
      await _worker.export(
        python: python,
        transcript: transcript,
        voice: voice,
        rate: rate,
        output: output,
        audioOnly: true,
        onProgress: onProgress ?? (_, _, _) {},
      );
      return;
    }
    await _worker.exportSpeech(
      python: python,
      text: text,
      voice: voice,
      rate: rate,
      output: output,
      onProgress: onProgress ?? (_, _, _) {},
    );
  }
}
