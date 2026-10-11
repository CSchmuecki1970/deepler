import 'dart:convert';

import 'package:http/http.dart' as http;

import 'timed_transcript.dart';
import 'translation_language.dart';

class TimelineTranslator {
  TimelineTranslator(this.client);

  final http.Client client;

  Future<TimedTranscript> translate(
    TimedTranscript source,
    String apiKey, {
    TranslationLanguage targetLanguage = TranslationLanguage.german,
    required void Function(int done, int total) onProgress,
  }) async {
    final translated = <String>[];
    Map<String, dynamic> payload(List<String> texts) => {
      'text': texts,
      'target_lang': targetLanguage.apiCode,
      if ({'ru', 'en', 'de', 'it', 'es'}.contains(source.language))
        'source_lang': source.language.toUpperCase(),
    };
    var offset = 0;
    while (offset < source.segments.length) {
      final batch = <String>[];
      // Stay below both DeepL request limits, including multibyte Unicode.
      while (offset + batch.length < source.segments.length &&
          batch.length < 50) {
        final text = source.segments[offset + batch.length].text;
        final candidate = jsonEncode(payload([...batch, text]));
        if (utf8.encode(candidate).length > 120000) {
          if (batch.isEmpty) {
            throw Exception(
              'Ein Textabschnitt ist zu lang für DeepL. Bitte kürzer aufteilen.',
            );
          }
          break;
        }
        batch.add(text);
      }
      final response = await client
          .post(
            Uri.parse('https://api-free.deepl.com/v2/translate'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'DeepL-Auth-Key $apiKey',
            },
            body: utf8.encode(jsonEncode(payload(batch))),
          )
          .timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        throw Exception(
          'DeepL-Übersetzung fehlgeschlagen (HTTP ${response.statusCode}). '
          'Bitte API-Schlüssel, Kontingent und Verbindung prüfen.',
        );
      }
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final results = data['translations'] as List;
      if (results.length != batch.length) {
        throw const FormatException(
          'DeepL hat eine andere Anzahl an Abschnitten zurückgegeben.',
        );
      }
      translated.addAll(results.map((row) => row['text'] as String));
      offset += batch.length;
      onProgress(offset, source.segments.length);
    }
    return source.withTexts(translated, language: targetLanguage.code);
  }
}
