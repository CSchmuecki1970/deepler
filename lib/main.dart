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
  String _translatedText = '';
  bool _isLoading = false;
  String _errorMessage = '';
  final List<String> _logs = [];
  bool _showLogs = false;
  bool _saveApiKey = true;
  bool _isExporting = false;
  double _pdfFontSize = 12.0;
  String? _selectedDirectory;
  String _selectedDirectoryName = 'Default (Documents)';

  @override
  void initState() {
    super.initState();
    _loadApiKey();
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
              'Translation (German)',
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
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().toString();
      await prefs.setString('last_translation_original', _inputController.text);
      await prefs.setString('last_translation_german', _translatedText);
      await prefs.setString('last_translation_time', timestamp);
      _addLog('Translation cached successfully');
    } catch (e) {
      _addLog('Error caching translation: $e');
    }
  }

  Future<void> _loadCachedTranslation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final original = prefs.getString('last_translation_original');
      final german = prefs.getString('last_translation_german');
      final time = prefs.getString('last_translation_time');

      if (original != null && german != null) {
        setState(() {
          _inputController.text = original;
          _translatedText = german;
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
          decoration: const InputDecoration(
            hintText: 'Edit your translation here...',
            border: OutlineInputBorder(),
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

  Future<void> _translateText() async {
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

    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _showLogs = true;
    });

    _addLog('API Key: ${_apiKeyController.text.substring(0, 5)}...');
    _addLog('Text length: ${_inputController.text.length} characters');
    _addLog('Target language: DE (German)');

    try {
      _addLog('Sending request to DeepL API...');
      final response = await http.post(
        Uri.parse('https://api-free.deepl.com/v2/translate'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Authorization': 'DeepL-Auth-Key ${_apiKeyController.text}',
        },
        body: {'text': _inputController.text, 'target_lang': 'DE'},
      );

      _addLog('Response status code: ${response.statusCode}');
      _addLog('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _addLog('Translation successful!');
        final translatedText = data['translations'][0]['text'];
        final charCount = _inputController.text.length;
        setState(() {
          _translatedText = translatedText;
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

            // Input Text
            TextField(
              controller: _inputController,
              onChanged: (value) {
                setState(() {});
              },
              decoration: const InputDecoration(
                labelText: 'Text to Translate (English)',
                hintText: 'Enter your text here...',
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
                    onPressed: _isLoading ? null : _translateText,
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
                    onPressed: _importTranslation,
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
                    onPressed: _loadCachedTranslation,
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
                          'Translation (German):',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.purple[300],
                          ),
                        ),
                        GestureDetector(
                          onTap: _editTranslation,
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
