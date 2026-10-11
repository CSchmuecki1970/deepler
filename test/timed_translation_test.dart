import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deepler/timed_transcript.dart';
import 'package:deepler/timeline_translator.dart';
import 'package:deepler/translation_language.dart';

TimedTranscript transcript(List<String> texts) => TimedTranscript(
  source: 'video.mp4',
  language: 'ru',
  segments: List.generate(
    texts.length,
    (i) => TimedSegment(
      start: i * 3.0 + 0.125,
      end: i * 3.0 + 2.5,
      text: texts[i],
    ),
  ),
);

void main() {
  for (final language in TranslationLanguage.values) {
    test(
      '${language.label} sends the target code and preserves timing',
      () async {
        final source = transcript(['Привет']);
        final client = MockClient((request) async {
          final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map;
          expect(body['target_lang'], language.apiCode);
          return http.Response('{"translations": [{"text": "Test"}]}', 200);
        });
        final result = await TimelineTranslator(client).translate(
          source,
          'key',
          targetLanguage: language,
          onProgress: (_, _) {},
        );
        expect(result.language, language.code);
        expect(result.hasSameTiming(source), isTrue);
        client.close();
      },
    );
  }

  test(
    'batched translations retain order, Unicode, and original timing',
    () async {
      final source = transcript(List.generate(51, (i) => 'Привет $i'));
      final batches = <int>[];
      final progress = <int>[];
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'DeepL-Auth-Key test-key');
        final body =
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
        expect(body['target_lang'], 'DE');
        expect(body['source_lang'], 'RU');
        final texts = body['text'] as List;
        batches.add(texts.length);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'translations': texts
                  .map((text) => {'text': 'Grüße $text'})
                  .toList(),
            }),
          ),
          200,
        );
      });
      final result = await TimelineTranslator(client).translate(
        source,
        'test-key',
        onProgress: (done, total) {
          expect(total, 51);
          progress.add(done);
        },
      );
      expect(batches, [50, 1]);
      expect(progress, [50, 51]);
      expect(result.hasSameTiming(source), isTrue);
      expect(result.language, 'de');
      expect(result.segments.last.text, 'Grüße Привет 50');
      client.close();
    },
  );

  test('batch sizing counts UTF-8 bytes, not just characters', () async {
    final source = transcript(List.filled(3, List.filled(31000, 'Ж').join()));
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.bodyBytes.length, lessThanOrEqualTo(120000));
      final texts =
          (jsonDecode(utf8.decode(request.bodyBytes)) as Map)['text'] as List;
      expect(texts.length, 1);
      return http.Response(
        jsonEncode({
          'translations': [
            {'text': 'Hallo'},
          ],
        }),
        200,
      );
    });
    await TimelineTranslator(
      client,
    ).translate(source, 'key', onProgress: (_, _) {});
    expect(calls, 3);
    client.close();
  });

  test('missing translations cannot silently shift later timestamps', () async {
    final client = MockClient(
      (_) async => http.Response(' {"translations": []}', 200),
    );
    await expectLater(
      TimelineTranslator(
        client,
      ).translate(transcript(['Привет']), 'key', onProgress: (_, _) {}),
      throwsFormatException,
    );
    client.close();
  });

  test('HTTP failure does not return a partial timeline', () async {
    final client = MockClient(
      (_) async => http.Response('quota exceeded', 456),
    );
    await expectLater(
      TimelineTranslator(
        client,
      ).translate(transcript(['Привет']), 'key', onProgress: (_, _) {}),
      throwsException,
    );
    client.close();
  });

  test(
    'cache round-trip preserves timing and edited lines keep their association',
    () {
      final source = transcript(['Первый', 'Второй']);
      final restored = TimedTranscript.fromJson(
        jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
      );
      expect(restored.hasSameTiming(source), isTrue);
      final edited = restored.editedText('Erster Satz\nZweiter längerer Satz');
      expect(edited!.hasSameTiming(source), isTrue);
      expect(edited.segments[1].text, 'Zweiter längerer Satz');
      expect(restored.editedText('Ein einziger Absatz'), isNull);
      expect(restored.editedText('Erster Satz\n'), isNull);
    },
  );
}
