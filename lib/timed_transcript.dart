class TimedSegment {
  const TimedSegment({
    required this.start,
    required this.end,
    required this.text,
  });

  final double start;
  final double end;
  final String text;

  factory TimedSegment.fromJson(Map<String, dynamic> json) => TimedSegment(
    start: (json['start'] as num).toDouble(),
    end: (json['end'] as num).toDouble(),
    text: (json['text'] as String).trim(),
  );

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'text': text};
}

class TimedTranscript {
  TimedTranscript({
    required this.source,
    required this.language,
    required List<TimedSegment> segments,
  }) : segments = List.unmodifiable(segments) {
    var previousStart = -1.0;
    for (final segment in segments) {
      if (!segment.start.isFinite ||
          !segment.end.isFinite ||
          segment.start < 0 ||
          segment.end <= segment.start ||
          segment.start <= previousStart ||
          segment.text.isEmpty) {
        throw const FormatException(
          'Ungültige Zeitstempel oder leere Textabschnitte.',
        );
      }
      previousStart = segment.start;
    }
    if (segments.isEmpty) {
      throw const FormatException('Keine Sprachabschnitte vorhanden.');
    }
  }

  final String source;
  final String language;
  final List<TimedSegment> segments;

  String get text => segments.map((segment) => segment.text).join('\n');

  bool hasSameTiming(TimedTranscript other) =>
      source == other.source &&
      segments.length == other.segments.length &&
      List.generate(
        segments.length,
        (i) =>
            segments[i].start == other.segments[i].start &&
            segments[i].end == other.segments[i].end,
      ).every((same) => same);

  factory TimedTranscript.fromJson(Map<String, dynamic> json) =>
      TimedTranscript(
        source: json['source'] as String,
        language: json['language'] as String,
        segments: (json['segments'] as List)
            .map((row) => TimedSegment.fromJson(row as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'source': source,
    'language': language,
    'segments': segments.map((segment) => segment.toJson()).toList(),
  };

  TimedTranscript withTexts(List<String> texts, {String? language}) {
    if (texts.length != segments.length) {
      throw const FormatException(
        'Die Anzahl der Textabschnitte hat sich geändert.',
      );
    }
    return TimedTranscript(
      source: source,
      language: language ?? this.language,
      segments: List.generate(
        segments.length,
        (i) => TimedSegment(
          start: segments[i].start,
          end: segments[i].end,
          text: texts[i].trim(),
        ),
      ),
    );
  }

  /// Editing within an existing line keeps its timing. Adding/removing lines
  /// invalidates alignment instead of silently assigning the wrong timestamps.
  TimedTranscript? editedText(String text) {
    try {
      return withTexts(text.split('\n'));
    } on FormatException {
      return null;
    }
  }
}
