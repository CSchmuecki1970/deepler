import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum ExtractionPhase { preparing, loading, recognizing, finishing }

class ExtractionActivity extends StatefulWidget {
  const ExtractionActivity({super.key, required this.phase});

  final ExtractionPhase phase;

  @override
  State<ExtractionActivity> createState() => _ExtractionActivityState();
}

class _ExtractionActivityState extends State<ExtractionActivity>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );
  final Stopwatch _elapsed = Stopwatch();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _elapsed.start();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.stop();
    } else {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _elapsed.stop();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const labels = [
      'Vorbereiten',
      'Modell laden',
      'Sprache erkennen',
      'Text übernehmen',
    ];
    const descriptions = [
      'Dein Video wird für die Texterkennung vorbereitet.',
      'Das Sprachmodell wird geladen. Beim ersten Mal kann ein Download nötig sein.',
      'Die Aufnahme wird Abschnitt für Abschnitt in Text umgewandelt.',
      'Das Transkript ist erkannt und wird in das Textfeld übernommen.',
    ];
    final seconds = _elapsed.elapsed.inSeconds;
    final time =
        '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
    final phase = widget.phase.index;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF282a36),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF6272a4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.graphic_eq, color: Color(0xFF8be9fd)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Aus Stimme wird Text',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(time, style: const TextStyle(color: Color(0xFF8be9fd))),
            ],
          ),
          const SizedBox(height: 8),
          // Decorative activity animation, not a measured audio waveform.
          ExcludeSemantics(
            child: SizedBox(
              height: 64,
              width: double.infinity,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) =>
                      CustomPaint(painter: _WavePainter(_animation.value)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(labels.length, (index) {
              final active = index == phase;
              final done = index < phase;
              final color = done
                  ? const Color(0xFF50fa7b)
                  : active
                  ? const Color(0xFFbd93f9)
                  : const Color(0xFFa3a6b8);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: active ? 0.16 : 0.06),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      done
                          ? Icons.check_rounded
                          : active
                          ? Icons.more_horiz
                          : Icons.circle_outlined,
                      size: 15,
                      color: color,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      labels[index],
                      style: TextStyle(fontSize: 12, color: color),
                    ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              descriptions[phase],
              style: const TextStyle(fontSize: 12, color: Color(0xFFc2c4d0)),
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const count = 40;
    final step = size.width / count;
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF8be9fd), Color(0xFFbd93f9), Color(0xFFff79c6)],
      ).createShader(Offset.zero & size);
    for (var i = 0; i < count; i++) {
      final envelope = math.sin(math.pi * (i + 0.5) / count);
      final wave = (math.sin(i * 0.7 + progress * math.pi * 2) + 1) / 2;
      final height = 5 + envelope * (12 + wave * 40);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(step * (i + 0.5), size.height / 2),
            width: math.min(6, step * 0.6),
            height: height,
          ),
          const Radius.circular(4),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      progress != oldDelegate.progress;
}
