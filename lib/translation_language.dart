enum TranslationLanguage {
  german('DE', 'de', 'Deutsch', 'German', 'deutscher', [
    ('de-DE-KatjaNeural', 'Katja · weiblich'),
    ('de-DE-ConradNeural', 'Conrad · männlich'),
    ('de-DE-SeraphinaMultilingualNeural', 'Seraphina · weiblich'),
    ('de-DE-FlorianMultilingualNeural', 'Florian · männlich'),
  ]),
  english('EN-GB', 'en', 'Englisch', 'English', 'englischer', [
    ('en-GB-SoniaNeural', 'Sonia · weiblich'),
    ('en-GB-RyanNeural', 'Ryan · männlich'),
  ]),
  italian('IT', 'it', 'Italienisch', 'Italian', 'italienischer', [
    ('it-IT-ElsaNeural', 'Elsa · weiblich'),
    ('it-IT-DiegoNeural', 'Diego · männlich'),
  ]),
  spanish('ES', 'es', 'Spanisch', 'Spanish', 'spanischer', [
    ('es-ES-ElviraNeural', 'Elvira · weiblich'),
    ('es-ES-AlvaroNeural', 'Alvaro · männlich'),
  ]);

  const TranslationLanguage(
    this.apiCode,
    this.code,
    this.label,
    this.englishLabel,
    this.trackAdjective,
    this.voices,
  );

  final String apiCode;
  final String code;
  final String label;
  final String englishLabel;
  final String trackAdjective;
  final List<(String, String)> voices;

  String get videoLabel => 'Video mit $trackAdjective Tonspur';

  static TranslationLanguage fromCode(String? code) => values.firstWhere(
    (language) => language.code == code?.toLowerCase().split('-').first,
    orElse: () => german,
  );
}
