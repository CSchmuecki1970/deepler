import 'dart:convert';

import 'package:deepler/main.dart';
import 'package:deepler/timed_transcript.dart';
import 'package:deepler/translation_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final source = TimedTranscript(
    source: 'C:/example/video.mp4',
    language: 'ru',
    segments: const [
      TimedSegment(start: 1, end: 3, text: 'Привет'),
      TimedSegment(start: 5, end: 8, text: 'Другой'),
    ],
  );
  final translated = source.withTexts([
    'Hallo',
    'Ein anderer Satz',
  ], language: 'de');

  void cached({bool timing = true}) {
    SharedPreferences.setMockInitialValues({
      'whisper_python_path': 'python',
      'last_translation_original': source.text,
      'last_translation_german': translated.text,
      'last_translation_time': 'test',
      if (timing) 'last_source_timeline': jsonEncode(source.toJson()),
      if (timing) 'last_translated_timeline': jsonEncode(translated.toJson()),
    });
  }

  Future<void> loadSaved(WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Load Saved'));
    await tester.tap(find.text('Load Saved'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'saved timeline enables video export; changing section count invalidates it',
    (tester) async {
      cached();
      await loadSaved(tester);
      final button = find.ancestor(
        of: find.text('Video mit deutscher Tonspur'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      final input = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Text to Translate',
      );
      await tester.ensureVisible(input);
      await tester.enterText(input, 'Ein einzelner neuer Absatz');
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('older text-only cache loads without inventing timestamps', (
    tester,
  ) async {
    cached(timing: false);
    await loadSaved(tester);
    expect(find.text(translated.text), findsOneWidget);
    expect(find.text('Video mit deutscher Tonspur'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'MP3 offers original start times by default when timing is available',
    (tester) async {
      cached();
      await loadSaved(tester);
      await tester.ensureVisible(find.text('Als MP3 speichern'));
      await tester.tap(find.text('Als MP3 speichern'));
      await tester.pumpAndSettle();
      final timing = find.widgetWithText(
        CheckboxListTile,
        'Ursprüngliche Startzeiten berücksichtigen',
      );
      expect(timing, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(timing).value, isTrue);
      await tester.tap(timing);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(timing).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('MP3 explains missing timing for older saved text', (
    tester,
  ) async {
    cached(timing: false);
    await loadSaved(tester);
    await tester.ensureVisible(find.text('Als MP3 speichern'));
    await tester.tap(find.text('Als MP3 speichern'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(
      find.textContaining('Keine passenden Zeitstempel vorhanden.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('video offers background original audio and can disable it', (
    tester,
  ) async {
    cached();
    await loadSaved(tester);
    await tester.ensureVisible(find.text('Video mit deutscher Tonspur'));
    await tester.tap(find.text('Video mit deutscher Tonspur'));
    await tester.pumpAndSettle();
    final background = find.widgetWithText(
      CheckboxListTile,
      'Originalton leise im Hintergrund (25 %)',
    );
    expect(background, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(background).value, isTrue);
    await tester.tap(background);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(background).value, isFalse);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video mit deutscher Tonspur'));
    await tester.pumpAndSettle();
    // Cancelling the dialog must not change the chosen export settings.
    expect(tester.widget<CheckboxListTile>(background).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final language in TranslationLanguage.values) {
    testWidgets('saved ${language.label} uses matching speech voices', (
      tester,
    ) async {
      final timeline = source.withTexts([
        'Hello',
        'Another sentence',
      ], language: language.code);
      SharedPreferences.setMockInitialValues({
        'whisper_python_path': 'python',
        'last_translation_original': source.text,
        'last_translation_text': timeline.text,
        'last_translation_language': language.code,
        'last_source_timeline': jsonEncode(source.toJson()),
        'last_translated_timeline': jsonEncode(timeline.toJson()),
      });
      await loadSaved(tester);
      expect(
        find.text('Translation (${language.englishLabel}):'),
        findsOneWidget,
      );
      expect(find.text(language.videoLabel), findsOneWidget);
      // Selecting another future target must not relabel or revoice this result.
      final target = find.byType(DropdownButtonFormField<TranslationLanguage>);
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      final other = language == TranslationLanguage.german
          ? TranslationLanguage.english
          : TranslationLanguage.german;
      await tester.tap(find.text(other.label).last);
      await tester.pumpAndSettle();
      expect(
        find.text('Translation (${language.englishLabel}):'),
        findsOneWidget,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('translation_target_language'), other.code);
      await tester.ensureVisible(find.text('Als MP3 speichern'));
      await tester.tap(find.text('Als MP3 speichern'));
      await tester.pumpAndSettle();
      final voice = tester.widget<DropdownButtonFormField<String>>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(DropdownButtonFormField<String>),
        ),
      );
      expect(voice.initialValue, language.voices.first.$1);
      final dropdown = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(
        dropdown.items!.map((item) => item.value),
        language.voices.map((option) => option.$1),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
