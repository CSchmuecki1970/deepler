import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'media_transcriber.dart';
import 'extraction_activity.dart';
import 'audio_exporter.dart';
import 'timed_transcript.dart';
import 'timeline_translator.dart';
import 'video_exporter.dart';
import 'translation_language.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepL Translator',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF282a36),
        colorScheme: ColorScheme.dark(
          surface: const Color(0xFF44475a),
          onSurface: const Color(0xFff8f8f2),
          primary: const Color(0xFFbd93f9),
          onPrimary: const Color(0xFff8f8f2),
        ),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF44475a),
          labelStyle: const TextStyle(color: Color(0x0ff8f8f2)),
          hintStyle: TextStyle(color: Colors.grey[400]),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF6272a4)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF6272a4)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFbd93f9), width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF44475a),
          foregroundColor: Color(0xFff8f8f2),
          elevation: 0,
        ),
      ),
      home: const TranslatorScreen(),
    );
  }
}

class TranslatorScreen extends StatefulWidget {
  const TranslatorScreen({super.key});

  @override
  State<TranslatorScreen> createState() => _TranslatorScreenState();
}

class _TranslatorScreenState extends State<TranslatorScreen> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _fileNameController = TextEditingController();
  final TextEditingController _pythonPathController = TextEditingController();
  final TextEditingController _whisperModelController = TextEditingController(
    text: 'small',
  );
  final TextEditingController _whisperLanguageController =
      TextEditingController(text: 'auto');
  String _translatedText = '';
  TranslationLanguage _targetLanguage = TranslationLanguage.german;
  TranslationLanguage _translationLanguage = TranslationLanguage.german;
  bool _isLoading = false;
  bool _isExtractingMediaText = false;
  ExtractionPhase _extractionPhase = ExtractionPhase.preparing;
  String _errorMessage = '';
  String _selectedMediaPath = '';
  String _selectedMediaName = 'No media file selected';
  final List<String> _logs = [];
  bool _showLogs = false;
  bool _saveApiKey = true;
  bool _isExporting = false;
  bool _isExportingAudio = false;
  final AudioExporter _audioExporter = AudioExporter();
  final VideoExporter _videoExporter = VideoExporter();
  String _audioStatus = '';
  double? _audioProgress;
  String _audioVoice = 'de-DE-KatjaNeural';
  int _audioRate = 0;
  bool _mixOriginalAudio = true;
  TimedTranscript? _sourceTranscript;
  TimedTranscript? _translatedTimeline;
  bool _isExportingVideo = false;
  String _videoStatus = '';
  double? _videoProgress;
  String _translationStatus = '';

  bool get _hasVideo => RegExp(
    r'\.(mp4|mov|mkv|avi|wmv|webm|m4v|flv)$',
    caseSensitive: false,
  ).hasMatch(_selectedMediaPath);

  bool get _canExportTimedAudio =>
      _translatedTimeline != null &&
      _translatedTimeline!.source == _selectedMediaPath &&
      _translatedTimeline!.text == _translatedText;
  bool get _canExportVideo => _hasVideo && _canExportTimedAudio;
  double _pdfFontSize = 12.0;
  String? _selectedDirectory;
  String _selectedDirectoryName = 'Default (Documents)';

  @override
  void initState() {
    super.initState();
    _loadApiKey();
    _loadWhisperSettings();
  }

  Future<void> _loadApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = prefs.getString('deepl_api_key');
      if (savedKey != null) {
        setState(() {
          _apiKeyController.text = savedKey;
        });
        _addLog('API key loaded from storage');
      }
    } catch (e) {
      _addLog('Error loading API key: $e');
    }
  }

  Future<void> _storeApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('deepl_api_key', _apiKeyController.text);
      setState(() {
        _saveApiKey = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('API key saved successfully'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving API key: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _loadWhisperSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPythonPath = prefs.getString('whisper_python_path') ?? '';
      final pythonPath = savedPythonPath.isEmpty
          ? await MediaTranscriber.defaultPython()
          : savedPythonPath;
      final savedModel = prefs.getString('whisper_model') ?? 'small';
      final savedLanguage = prefs.getString('whisper_language') ?? 'auto';
      final targetLanguage = TranslationLanguage.fromCode(
        prefs.getString('translation_target_language'),
      );

      if (!mounted) return;
      setState(() {
        _pythonPathController.text = pythonPath;
        _whisperModelController.text = savedModel;
        _whisperLanguageController.text = savedLanguage;
        _targetLanguage = targetLanguage;
      });
    } catch (e) {
      _addLog('Error loading Whisper settings: $e');
    }
  }

  Future<void> _saveWhisperSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'whisper_python_path',
        _pythonPathController.text.trim(),
      );
      await prefs.setString(
        'whisper_model',
        _whisperModelController.text.trim(),
      );
      await prefs.setString(
        'whisper_language',
        _whisperLanguageController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Whisper settings saved'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving Whisper settings: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _selectMediaFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'mp3',
          'wav',
          'm4a',
          'mp4',
          'mov',
          'mkv',
          'avi',
          'wmv',
          'webm',
        ],
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        setState(() {
          if (_selectedMediaPath != path) {
            _sourceTranscript = null;
            _translatedTimeline = null;
          }
          _selectedMediaPath = path;
          _selectedMediaName = path.split(Platform.pathSeparator).last;
        });
        _addLog('Selected media file: $path');
      }
    } catch (e) {
      _addLog('Error selecting media file: $e');
    }
  }

  Future<void> _extractTextFromMedia() async {
    if (_selectedMediaPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a video or audio file first'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final pythonExecutable = _pythonPathController.text.trim().isEmpty
        ? await MediaTranscriber.defaultPython()
        : _pythonPathController.text.trim();
    if (!mounted) return;
    if (pythonExecutable.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please set a Python executable path first'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _isExtractingMediaText = true;
      _extractionPhase = ExtractionPhase.preparing;
      _showLogs = true;
      _errorMessage = '';
    });

    try {
      final extractedText = await MediaTranscriber().transcribe(
        python: pythonExecutable,
        input: _selectedMediaPath,
        model: _whisperModelController.text.trim().isEmpty
            ? 'small'
            : _whisperModelController.text.trim(),
        language: _whisperLanguageController.text.trim().isEmpty
            ? 'auto'
            : _whisperLanguageController.text.trim(),
        onLog: (line) {
          if (!mounted) return;
          final phase = line.startsWith('Lade Modell')
              ? ExtractionPhase.loading
              : line.startsWith('Transkribiere:') || line.startsWith('[')
              ? ExtractionPhase.recognizing
              : line.startsWith('Fertig.') ||
                    line.startsWith('Detected language:')
              ? ExtractionPhase.finishing
              : null;
          if (phase != null && phase != _extractionPhase) {
            setState(() => _extractionPhase = phase);
          }
          _addLog(line);
        },
      );
      if (!mounted) return;

      setState(() {
        _inputController.text = extractedText.text;
        _sourceTranscript = extractedText;
        _selectedMediaPath = extractedText.source;
        _translatedTimeline = null;
        _errorMessage = '';
      });

      _addLog('Transcript loaded into input field');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Text extracted successfully from $_selectedMediaName'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _addLog('Error extracting text from media: $e');
      setState(() {
        _errorMessage = 'Whisper error: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Extraction failed: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isExtractingMediaText = false;
        });
      }
    }
  }

  Future<({String voice, int rate, bool timed, bool mixOriginalAudio})?>
  _chooseSpeechOptions({bool forVideo = false}) async {
    final voices = _translationLanguage.voices;
    var voice = voices.any((option) => option.$1 == _audioVoice)
        ? _audioVoice
        : voices.first.$1;
    var rate = _audioRate;
    var timed = forVideo || _canExportTimedAudio;
    var mixOriginalAudio = _mixOriginalAudio;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: Text(
            forVideo ? _translationLanguage.videoLabel : 'Als MP3 speichern',
          ),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: voice,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Stimme (${_translationLanguage.label})',
                    ),
                    items: voices
                        .map(
                          (option) => DropdownMenuItem(
                            value: option.$1,
                            child: Text(option.$2),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) updateDialog(() => voice = value);
                    },
                  ),
                  const SizedBox(height: 20),
                  if (!forVideo) ...[
                    if (_canExportTimedAudio)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Ursprüngliche Startzeiten berücksichtigen',
                        ),
                        subtitle: const Text(
                          'Pausen bleiben erhalten. Läuft ein Abschnitt noch, '
                          'schließt der nächste ohne Überschneidung an. '
                          'Das eingestellte Sprechtempo bleibt unverändert.',
                        ),
                        value: timed,
                        onChanged: (value) =>
                            updateDialog(() => timed = value ?? false),
                      )
                    else
                      const Text(
                        'Keine passenden Zeitstempel vorhanden. Die MP3 wird fortlaufend vorgelesen. '
                        'Für ursprüngliche Startzeiten zuerst die Mediendatei extrahieren '
                        'und abschnittsweise übersetzen.',
                        style: TextStyle(fontSize: 12),
                      ),
                    const SizedBox(height: 16),
                  ],
                  if (forVideo) ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Originalton leise im Hintergrund (25 %)',
                      ),
                      subtitle: const Text(
                        'Übersetzung und gedämpfter Originalton werden gleichzeitig '
                        'abgespielt. Ohne Häkchen enthält die Standardspur nur die '
                        'Übersetzung. Der Originalton bleibt separat auswählbar.',
                      ),
                      value: mixOriginalAudio,
                      onChanged: (value) =>
                          updateDialog(() => mixOriginalAudio = value ?? false),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Jeder Abschnitt startet frühestens am ursprünglichen Zeitstempel. '
                      'Läuft der vorherige Abschnitt noch, schließt der nächste direkt daran an. '
                      'Das eingestellte Sprechtempo bleibt unverändert. '
                      'Bei Bedarf bleibt das letzte Bild bis zum Sprachende stehen. '
                      'Die zusätzliche Originaltonspur hat 25 % Lautstärke.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    'Sprechtempo: ${rate == 0 ? 'Normal' : '${rate > 0 ? '+' : ''}$rate %'}',
                  ),
                  Slider(
                    value: rate.toDouble(),
                    min: -30,
                    max: 30,
                    divisions: 12,
                    label: '${rate > 0 ? '+' : ''}$rate %',
                    onChanged: (value) =>
                        updateDialog(() => rate = value.round()),
                  ),
                  const Text(
                    'Die Sprachausgabe benötigt Internet. Der Übersetzungstext '
                    'wird dafür an Microsoft übermittelt. Kein API-Schlüssel nötig.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Speicherort wählen'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return null;
    return (
      voice: voice,
      rate: rate,
      timed: timed,
      mixOriginalAudio: mixOriginalAudio,
    );
  }

  Future<void> _exportMp3() async {
    if (_isExportingAudio || _translatedText.trim().isEmpty) return;
    final text = _translatedText;
    final timeline = _canExportTimedAudio ? _translatedTimeline : null;
    final options = await _chooseSpeechOptions();
    if (options == null || !mounted) return;
    final voice = options.voice;
    final rate = options.rate;
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'MP3 speichern',
        fileName: 'Uebersetzung_${DateTime.now().millisecondsSinceEpoch}.mp3',
        type: FileType.custom,
        allowedExtensions: ['mp3'],
        lockParentWindow: true,
      );
      if (path == null || !mounted) return;
      final output = path.toLowerCase().endsWith('.mp3') ? path : '$path.mp3';
      if (output != path && await File(output).exists()) {
        if (!mounted) return;
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Datei ersetzen?'),
            content: Text('Diese MP3 existiert bereits:\n$output'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Ersetzen'),
              ),
            ],
          ),
        );
        if (replace != true) return;
      }
      if (!mounted) return;
      setState(() {
        _audioVoice = voice;
        _audioRate = rate;
        _isExportingAudio = true;
        _audioStatus = 'Die Audiodatei wird erzeugt …';
        _audioProgress = null;
        _errorMessage = '';
      });
      final python = _pythonPathController.text.trim().isEmpty
          ? await MediaTranscriber.defaultPython()
          : _pythonPathController.text.trim();
      if (mounted) _addLog('MP3 erstellen: $voice, Tempo $rate %');
      await _audioExporter.export(
        python: python,
        text: text,
        voice: voice,
        rate: rate,
        output: output,
        transcript: options.timed ? timeline : null,
        onProgress: (message, done, total) {
          if (!mounted) return;
          setState(() {
            _audioStatus = message;
            if (done != null && total != null && total > 0) {
              _audioProgress = done < total ? done / total : null;
            }
          });
          _addLog(message);
        },
      );
      if (!mounted) return;
      _addLog('MP3 gespeichert: $output');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('MP3 gespeichert: $output'),
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _addLog('MP3-Export fehlgeschlagen: $e');
      setState(() => _errorMessage = 'MP3-Export fehlgeschlagen: $e');
    } finally {
      if (mounted) setState(() => _isExportingAudio = false);
    }
  }

  Future<void> _exportVideo() async {
    if (!_canExportVideo || _isExportingVideo) return;
    final timeline = _translatedTimeline!;
    final options = await _chooseSpeechOptions(forVideo: true);
    if (options == null || !mounted) return;
    try {
      final sourceName = File(timeline.source).uri.pathSegments.last;
      final stem = sourceName.substring(0, sourceName.lastIndexOf('.'));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '${_translationLanguage.videoLabel} speichern',
        fileName: '$stem.${_translationLanguage.code}.mp4',
        type: FileType.custom,
        allowedExtensions: ['mp4'],
        lockParentWindow: true,
      );
      if (path == null || !mounted) return;
      final output = path.toLowerCase().endsWith('.mp4') ? path : '$path.mp4';
      if (output != path && await File(output).exists()) {
        if (!mounted) return;
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Datei ersetzen?'),
            content: Text('Dieses Video existiert bereits:\n$output'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Ersetzen'),
              ),
            ],
          ),
        );
        if (replace != true) return;
      }
      if (!mounted) return;
      setState(() {
        _isExportingVideo = true;
        _videoStatus =
            'Tonspur (${_translationLanguage.label}) wird vorbereitet …';
        _videoProgress = null;
        _audioVoice = options.voice;
        _audioRate = options.rate;
        _mixOriginalAudio = options.mixOriginalAudio;
        _errorMessage = '';
      });
      final python = _pythonPathController.text.trim().isEmpty
          ? await MediaTranscriber.defaultPython()
          : _pythonPathController.text.trim();
      final delayed = await _videoExporter.export(
        python: python,
        transcript: timeline,
        voice: options.voice,
        rate: options.rate,
        output: output,
        mixOriginalAudio: options.mixOriginalAudio,
        onProgress: (message, done, total) {
          if (!mounted) return;
          setState(() {
            _videoStatus = message;
            if (done != null && total != null && total > 0) {
              _videoProgress = done < total ? done / total : null;
            }
          });
          _addLog(message);
        },
      );
      if (!mounted) return;
      _addLog(
        'Video (${_translationLanguage.label}) gespeichert: $output ($delayed Abschnitte später gestartet)',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Video gespeichert: $output'
            '${delayed > 0 ? '\n$delayed Abschnitte wurden ohne Überlappung später gestartet.' : ''}',
          ),
          duration: const Duration(seconds: 10),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
      _addLog('Videoexport fehlgeschlagen: $message');
      setState(() => _errorMessage = 'Videoexport fehlgeschlagen: $message');
    } finally {
      if (mounted) setState(() => _isExportingVideo = false);
    }
  }

  void _showFontSizeDialog() {
    _fileNameController.clear();
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Export PDF Settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Filename:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _fileNameController,
                  decoration: InputDecoration(
                    hintText: 'translation',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    suffixText: '.pdf',
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Font Size:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SegmentedButton<double>(
                  segments: const <ButtonSegment<double>>[
                    ButtonSegment<double>(value: 10.0, label: Text('10px')),
                    ButtonSegment<double>(value: 12.0, label: Text('12px')),
                    ButtonSegment<double>(value: 14.0, label: Text('14px')),
                    ButtonSegment<double>(value: 16.0, label: Text('16px')),
                  ],
                  selected: <double>{_pdfFontSize},
                  onSelectionChanged: (Set<double> newSelection) {
                    setDialogState(() {
                      _pdfFontSize = newSelection.first;
                    });
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  'Save Location:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _selectDirectory,
                  icon: const Icon(Icons.folder),
                  label: const Text('Choose Folder'),
                  style: ElevatedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _selectedDirectoryName,
                  style: const TextStyle(fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _exportToPdf();
              },
              child: const Text('Export'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null) {
      setState(() {
        _selectedDirectory = selectedDirectory;
        _selectedDirectoryName = selectedDirectory
            .split(Platform.pathSeparator)
            .last;
      });
      _addLog('Directory selected: $_selectedDirectory');
    }
  }

  Future<void> _exportToPdf() async {
    if (_translatedText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No translated text to export'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Validate filename
    String filename = _fileNameController.text.trim();
    if (filename.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a filename'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Add .pdf extension if not present
    if (!filename.endsWith('.pdf')) {
      filename += '.pdf';
    }

    setState(() {
      _isExporting = true;
    });

    try {
      _addLog('Generating PDF...');
      final pdf = pw.Document();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(40),
          build: (pw.Context context) => [
            pw.Text(
              'Translation (${_translationLanguage.englishLabel})',
              style: pw.TextStyle(
                fontSize: _pdfFontSize + 6,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.black,
              ),
            ),
            pw.SizedBox(height: 20),
            pw.Paragraph(
              text: _translatedText,
              style: pw.TextStyle(
                fontSize: _pdfFontSize,
                color: PdfColors.black,
                font: pw.Font.helvetica(),
              ),
              textAlign: pw.TextAlign.left,
            ),
            pw.SizedBox(height: 40),
            pw.Align(
              alignment: pw.Alignment.bottomRight,
              child: pw.Text(
                'Generated: ${DateTime.now().toString().split('.')[0]}',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.normal,
                  color: PdfColors.grey400,
                ),
              ),
            ),
          ],
        ),
      );

      // Use selected directory or default to Documents
      Directory directory;
      if (_selectedDirectory != null) {
        directory = Directory(_selectedDirectory!);
      } else {
        directory = await getApplicationDocumentsDirectory();
      }

      final file = File('${directory.path}${Platform.pathSeparator}$filename');

      await file.writeAsBytes(await pdf.save());
      _addLog('PDF saved to: ${file.path}');

      // Also save the translation to cache
      await _cacheTranslation();

      setState(() {
        _isExporting = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('PDF saved: ${file.path}'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      _addLog('Error generating PDF: $e');
      setState(() {
        _isExporting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving PDF: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _apiKeyController.dispose();
    _fileNameController.dispose();
    _pythonPathController.dispose();
    _whisperModelController.dispose();
    _whisperLanguageController.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    final timestamp = DateTime.now().toString().split('.')[0];
    setState(() {
      _logs.add('[$timestamp] $message');
    });
    print('[$timestamp] $message');
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  Future<void> _cacheTranslation() async {
    final originalText = _inputController.text;
    final translatedText = _translatedText;
    final language = _translationLanguage;
    final source = _sourceTranscript;
    final translation = _translatedTimeline;
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().toString();
      await prefs.setString('last_translation_original', originalText);
      await prefs.setString('last_translation_text', translatedText);
      await prefs.setString('last_translation_language', language.code);
      // Keep the legacy key only for German translations.
      if (language == TranslationLanguage.german) {
        await prefs.setString('last_translation_german', translatedText);
      } else {
        await prefs.remove('last_translation_german');
      }
      await prefs.setString('last_translation_time', timestamp);
      if (source != null &&
          translation != null &&
          source.text == originalText &&
          translation.text == translatedText &&
          source.hasSameTiming(translation)) {
        await prefs.setString(
          'last_source_timeline',
          jsonEncode(source.toJson()),
        );
        await prefs.setString(
          'last_translated_timeline',
          jsonEncode(translation.toJson()),
        );
      } else {
        await prefs.remove('last_source_timeline');
        await prefs.remove('last_translated_timeline');
      }
      if (mounted) _addLog('Translation cached successfully');
    } catch (e) {
      _addLog('Error caching translation: $e');
    }
  }

  Future<void> _loadCachedTranslation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final original = prefs.getString('last_translation_original');
      final translatedText =
          prefs.getString('last_translation_text') ??
          prefs.getString('last_translation_german');
      final time = prefs.getString('last_translation_time');

      if (original != null && translatedText != null) {
        TimedTranscript? source;
        TimedTranscript? translation;
        try {
          final storedSource = prefs.getString('last_source_timeline');
          final storedTranslation = prefs.getString('last_translated_timeline');
          if (storedSource != null && storedTranslation != null) {
            final candidateSource = TimedTranscript.fromJson(
              jsonDecode(storedSource) as Map<String, dynamic>,
            );
            final candidateTranslation = TimedTranscript.fromJson(
              jsonDecode(storedTranslation) as Map<String, dynamic>,
            );
            if (candidateSource.text == original &&
                candidateTranslation.text == translatedText &&
                candidateSource.hasSameTiming(candidateTranslation)) {
              source = candidateSource;
              translation = candidateTranslation;
            }
          }
        } catch (_) {
          // Older or incomplete caches still load as plain text.
        }
        if (!mounted) return;
        setState(() {
          _inputController.text = original;
          _translatedText = translatedText;
          _translationLanguage = TranslationLanguage.fromCode(
            translation?.language ??
                prefs.getString('last_translation_language'),
          );
          _targetLanguage = _translationLanguage;
          _sourceTranscript = source;
          _translatedTimeline = translation;
          if (source != null) {
            _selectedMediaPath = source.source;
            _selectedMediaName = File(source.source).uri.pathSegments.last;
          }
        });
        _addLog('Translation loaded from cache');
        _addLog('Cached at: $time');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Translation loaded successfully!'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No saved translation found. Translate something first!',
            ),
            duration: Duration(seconds: 2),
          ),
        );
        _addLog('No cached translation available');
      }
    } catch (e) {
      _addLog('Error loading cached translation: $e');
    }
  }

  Future<void> _updateQuotaUsage(int characters) async {
    // No longer needed - we fetch directly from DeepL API
  }

  Future<Map<String, dynamic>> _getQuotaStats() async {
    try {
      if (_apiKeyController.text.isEmpty) {
        return {
          'used': 0,
          'remaining': 0,
          'percentage': 0,
          'month': 'Unknown',
          'error': 'API key required',
        };
      }

      _addLog('Fetching quota from DeepL API...');
      final response = await http.get(
        Uri.parse('https://api-free.deepl.com/v2/usage'),
        headers: {'Authorization': 'DeepL-Auth-Key ${_apiKeyController.text}'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        int used = data['character_count'] ?? 0;
        int limit = data['character_limit'] ?? 500000;
        int remaining = limit - used;
        double percentage = (used / limit) * 100;

        _addLog('Quota fetched: $used / $limit characters used');

        return {
          'used': used,
          'remaining': remaining,
          'percentage': percentage,
          'limit': limit,
          'month': 'Current Month',
        };
      } else {
        _addLog('Error fetching quota: ${response.statusCode}');
        return {
          'used': 0,
          'remaining': 0,
          'percentage': 0,
          'month': 'Unknown',
          'error': 'Failed to fetch quota',
        };
      }
    } catch (e) {
      _addLog('Error getting quota stats: $e');
      return {
        'used': 0,
        'remaining': 0,
        'percentage': 0,
        'month': 'Unknown',
        'error': 'Error: $e',
      };
    }
  }

  void _showQuotaStats() {
    _getQuotaStats().then((stats) {
      if (stats.containsKey('error')) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Quota Error'),
            content: Text(stats['error'] ?? 'Unknown error'),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        return;
      }

      final limit = stats['limit'] ?? 500000;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('DeepL Monthly Quota Overview'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Month: ${stats['month']}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Text(
                'Used: ${stats['used'].toString().padLeft(7)} / ${limit.toString()} characters',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (stats['percentage'] as double) / 100,
                minHeight: 10,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(
                  stats['percentage'] > 90
                      ? Colors.red
                      : stats['percentage'] > 70
                      ? Colors.orange
                      : Colors.green,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${stats['percentage'].toStringAsFixed(2)}% used',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    'Remaining: ${stats['remaining'].toString()}',
                    style: TextStyle(
                      color: Colors.blue[700],
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Data retrieved directly from DeepL API',
                  style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                ),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    });
  }

  void _saveCacheToUi() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Current Translation'),
        content: const Text(
          'Save this translation to your device so you can access it later without retranslating?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              _cacheTranslation();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Translation saved to cache!'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyToClipboard() async {
    try {
      await Clipboard.setData(ClipboardData(text: _translatedText));
      _addLog('Translation copied to clipboard');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Translation copied to clipboard!'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      _addLog('Error copying to clipboard: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error copying to clipboard: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _editTranslation() {
    final editController = TextEditingController(text: _translatedText);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Translation'),
        content: TextField(
          controller: editController,
          maxLines: 12,
          decoration: InputDecoration(
            hintText: 'Edit your translation here...',
            border: const OutlineInputBorder(),
            helperText: _translatedTimeline != null
                ? 'Für die Zeitzuordnung eine Zeile pro Abschnitt beibehalten.'
                : null,
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _translatedText = editController.text;
                _translatedTimeline = _translatedTimeline?.editedText(
                  editController.text,
                );
              });
              _addLog('Translation edited');
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Translation updated!'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _importTranslation() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData != null && clipboardData.text != null) {
        setState(() {
          _translatedText = clipboardData.text!;
          _translationLanguage = _targetLanguage;
          _translatedTimeline = null;
        });
        _addLog('Translation imported from clipboard');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Translation imported from clipboard!'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Clipboard is empty'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      _addLog('Error importing from clipboard: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error importing: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _translateTimedTranscript(TimedTranscript source) async {
    final targetLanguage = _targetLanguage;
    setState(() {
      _isLoading = true;
      _translatedTimeline = null;
      _translationStatus = 'Übersetze ${source.segments.length} Abschnitte …';
      _errorMessage = '';
    });
    final client = http.Client();
    try {
      final timeline = await TimelineTranslator(client).translate(
        source,
        _apiKeyController.text.trim(),
        targetLanguage: targetLanguage,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(
            () => _translationStatus = '$done von $total Abschnitten übersetzt',
          );
          _addLog(_translationStatus);
        },
      );
      if (!mounted) return;
      setState(() {
        _translatedTimeline = timeline;
        _translatedText = timeline.text;
        _translationLanguage = targetLanguage;
      });
      await _cacheTranslation();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${timeline.segments.length} Abschnitte mit Zeitzuordnung übersetzt und gespeichert.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _addLog('Abschnittsübersetzung fehlgeschlagen: $e');
      setState(() => _errorMessage = 'Übersetzung fehlgeschlagen: $e');
    } finally {
      client.close();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _translationStatus = '';
        });
      }
    }
  }

  Future<void> _translateText() async {
    final targetLanguage = _targetLanguage;
    _clearLogs();
    _addLog('Translation request started...');

    if (_inputController.text.isEmpty) {
      _addLog('Error: No text to translate');
      setState(() {
        _errorMessage = 'Please enter text to translate';
      });
      return;
    }

    if (_apiKeyController.text.isEmpty) {
      _addLog('Error: No API key provided');
      setState(() {
        _errorMessage = 'Please enter your DeepL API key';
      });
      return;
    }

    final source = _sourceTranscript;
    if (source != null &&
        source.text == _inputController.text &&
        source.source == _selectedMediaPath) {
      await _translateTimedTranscript(source);
      return;
    }

    setState(() {
      _isLoading = true;
      _translatedTimeline = null;
      _errorMessage = '';
      _showLogs = true;
    });

    _addLog('Text length: ${_inputController.text.length} characters');
    _addLog(
      'Target language: ${targetLanguage.apiCode} (${targetLanguage.label})',
    );

    try {
      _addLog('Sending request to DeepL API...');
      final response = await http.post(
        Uri.parse('https://api-free.deepl.com/v2/translate'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Authorization': 'DeepL-Auth-Key ${_apiKeyController.text}',
        },
        body: {
          'text': _inputController.text,
          'target_lang': targetLanguage.apiCode,
        },
      );

      _addLog('Response status code: ${response.statusCode}');
      _addLog('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        _addLog('Translation successful!');
        final translatedText = data['translations'][0]['text'];
        final charCount = _inputController.text.length;
        setState(() {
          _translatedText = translatedText;
          _translationLanguage = targetLanguage;
          _isLoading = false;
        });
        // Automatically cache the translation
        await _cacheTranslation();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Translation completed and saved! Used $charCount characters.',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        _addLog('Translation failed with status ${response.statusCode}');
        setState(() {
          _errorMessage =
              'Translation failed: ${response.statusCode} - ${response.body}';
          _isLoading = false;
        });
      }
    } catch (e) {
      _addLog('Exception: $e');
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFbd93f9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.translate, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            const Text('DeepL Translator'),
          ],
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // API Key Input
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'DeepL API Key',
                hintText: 'Enter your DeepL free API key',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 8),

            // Save API Key Button
            ElevatedButton(
              onPressed: _storeApiKey,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6272a4),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: const Text(
                'Save API Key',
                style: TextStyle(fontSize: 12, color: Colors.white),
              ),
            ),
            const SizedBox(height: 16),

            // Whisper / media transcription integration
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF44475a),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF6272a4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Video / MP3 → Text (DmitrysVideo)',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pythonPathController,
                    decoration: const InputDecoration(
                      labelText: 'Python executable',
                      hintText:
                          'Auto: DmitrysVideo/.venv, or Python executable',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(_whisperModelController.text),
                          initialValue: _whisperModelController.text.isNotEmpty
                              ? _whisperModelController.text
                              : 'small',
                          decoration: const InputDecoration(
                            labelText: 'Whisper model',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'tiny',
                              child: Text('tiny'),
                            ),
                            DropdownMenuItem(
                              value: 'base',
                              child: Text('base'),
                            ),
                            DropdownMenuItem(
                              value: 'small',
                              child: Text('small'),
                            ),
                            DropdownMenuItem(
                              value: 'medium',
                              child: Text('medium'),
                            ),
                            DropdownMenuItem(
                              value: 'large',
                              child: Text('large'),
                            ),
                          ],
                          onChanged: _isExtractingMediaText
                              ? null
                              : (value) {
                                  if (value != null) {
                                    _whisperModelController.text = value;
                                  }
                                },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(_whisperLanguageController.text),
                          initialValue:
                              _whisperLanguageController.text.isNotEmpty
                              ? _whisperLanguageController.text
                              : 'auto',
                          decoration: const InputDecoration(
                            labelText: 'Language',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'auto',
                              child: Text('auto'),
                            ),
                            DropdownMenuItem(
                              value: 'ru',
                              child: Text('Russian'),
                            ),
                            DropdownMenuItem(
                              value: 'de',
                              child: Text('German'),
                            ),
                            DropdownMenuItem(
                              value: 'en',
                              child: Text('English'),
                            ),
                          ],
                          onChanged: _isExtractingMediaText
                              ? null
                              : (value) {
                                  if (value != null) {
                                    _whisperLanguageController.text = value;
                                  }
                                },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed:
                              _isExtractingMediaText ||
                                  _isLoading ||
                                  _isExportingVideo
                              ? null
                              : _selectMediaFile,
                          icon: const Icon(Icons.attach_file),
                          label: const Text('Select media'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed:
                              _isExtractingMediaText ||
                                  _isLoading ||
                                  _isExportingVideo
                              ? null
                              : _extractTextFromMedia,
                          icon: _isExtractingMediaText
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.text_snippet),
                          label: Text(
                            _isExtractingMediaText
                                ? 'Extracting...'
                                : 'Extract text',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _selectedMediaName,
                    style: TextStyle(fontSize: 12, color: Colors.grey[300]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_isExtractingMediaText) ...[
                    const SizedBox(height: 12),
                    ExtractionActivity(phase: _extractionPhase),
                  ],
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: _saveWhisperSettings,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6272a4),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text(
                      'Save Whisper settings',
                      style: TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Input Text
            DropdownButtonFormField<TranslationLanguage>(
              key: ValueKey(_targetLanguage),
              initialValue: _targetLanguage,
              decoration: const InputDecoration(labelText: 'Zielsprache'),
              items: TranslationLanguage.values
                  .map(
                    (language) => DropdownMenuItem(
                      value: language,
                      child: Text(language.label),
                    ),
                  )
                  .toList(),
              onChanged: _isLoading || _isExportingAudio || _isExportingVideo
                  ? null
                  : (language) async {
                      if (language == null) return;
                      setState(() => _targetLanguage = language);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setString(
                        'translation_target_language',
                        language.code,
                      );
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _inputController,
              enabled:
                  !_isLoading && !_isExtractingMediaText && !_isExportingVideo,
              onChanged: (value) {
                setState(() {
                  _sourceTranscript = _sourceTranscript?.editedText(value);
                  _translatedTimeline = null;
                });
              },
              decoration: InputDecoration(
                labelText: 'Text to Translate',
                hintText: 'Enter your text here...',
                helperText: _sourceTranscript != null
                    ? '${_sourceTranscript!.segments.length} Abschnitte mit Zeitstempeln. Eine Zeile pro Abschnitt beibehalten.'
                    : null,
                helperMaxLines: 2,
              ),
              maxLines: 8,
            ),
            const SizedBox(height: 8),

            // Character Counter
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Characters: ${_inputController.text.length}',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[300],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Quota: ${((_inputController.text.length / 500000) * 100).toStringAsFixed(3)}%',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[300],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Main Action Buttons - Row
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        _isLoading ||
                            _isExtractingMediaText ||
                            _isExportingVideo
                        ? null
                        : _translateText,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFbd93f9),
                      disabledBackgroundColor: Colors.grey[700],
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Text(
                            'Translate',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        _isLoading ||
                            _isExportingVideo ||
                            _isExtractingMediaText
                        ? null
                        : _importTranslation,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8be9fd),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text(
                      'Import',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.black87,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        _isLoading ||
                            _isExportingVideo ||
                            _isExtractingMediaText
                        ? null
                        : _loadCachedTranslation,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6272a4),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text(
                      'Load Saved',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _showQuotaStats,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6272a4),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text(
                      'Quota',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Error Message
            if (_isLoading && _translationStatus.isNotEmpty) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(_translationStatus, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
            ],
            if (_errorMessage.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF3d2a2a),
                  border: Border.all(color: const Color(0xFFff79c6)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _errorMessage,
                  style: const TextStyle(
                    color: Color(0xFFff79c6),
                    fontSize: 13,
                  ),
                ),
              ),
            if (_errorMessage.isNotEmpty) const SizedBox(height: 16),

            // Translated Text
            if (_translatedText.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF44475a),
                  border: Border.all(color: const Color(0xFF6272a4)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Translation (${_translationLanguage.englishLabel}):',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.purple[300],
                          ),
                        ),
                        GestureDetector(
                          onTap: _isExportingVideo || _isLoading
                              ? null
                              : _editTranslation,
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6272a4),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(
                              Icons.edit,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _translatedText,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFff8f8f2),
                      ),
                    ),
                  ],
                ),
              ),

            // Export and Save buttons
            if (_translatedText.isNotEmpty) ...[
              if (_hasVideo) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed:
                      _canExportVideo &&
                          !_isExportingVideo &&
                          !_isLoading &&
                          !_isExtractingMediaText &&
                          !_isExportingAudio
                      ? _exportVideo
                      : null,
                  icon: const Icon(Icons.video_file_rounded),
                  label: Text(
                    _isExportingVideo
                        ? 'Video wird erstellt …'
                        : _translationLanguage.videoLabel,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _canExportVideo
                      ? '${_translatedTimeline!.segments.length} Abschnitte mit ursprünglichen Startzeiten. '
                            'Sprechtempo bleibt unverändert; Überschneidungen werden nach hinten verschoben.'
                      : 'Für den Videoexport das Video extrahieren und anschließend mit Translate abschnittsweise übersetzen.',
                  style: const TextStyle(fontSize: 12),
                ),
                if (_isExportingVideo) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _videoProgress),
                  const SizedBox(height: 6),
                  Text(_videoStatus, style: const TextStyle(fontSize: 12)),
                  TextButton.icon(
                    onPressed: _videoExporter.cancel,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Videoexport abbrechen'),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _isExportingAudio || _isExportingVideo
                    ? null
                    : _exportMp3,
                icon: const Icon(Icons.headphones_rounded),
                label: Text(
                  _isExportingAudio
                      ? 'Sprachausgabe wird erstellt …'
                      : 'Als MP3 speichern',
                ),
              ),
              if (_isExportingAudio) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _audioProgress),
                const SizedBox(height: 6),
                Text(_audioStatus, style: const TextStyle(fontSize: 12)),
                TextButton.icon(
                  onPressed: _audioExporter.cancel,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('MP3-Export abbrechen'),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isExporting ? null : _showFontSizeDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFffb86c),
                        disabledBackgroundColor: Colors.grey[700],
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: _isExporting
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Text(
                              'Export PDF',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.black87,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _copyToClipboard,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8be9fd),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text(
                        'Copy',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.black87,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saveCacheToUi,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF50fa7b),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text(
                        'Save This',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.black87,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // Logs Section
            if (_logs.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  border: Border.all(color: Colors.grey[700]!),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Logs',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.grey[300],
                          ),
                        ),
                        TextButton(
                          onPressed: _clearLogs,
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(40, 30),
                          ),
                          child: Text(
                            'Clear',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[400],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 120,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[950],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ListView.builder(
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _logs[index],
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontFamily: 'Courier',
                              fontSize: 11,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
