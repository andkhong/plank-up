/// A harness, not a product screen.
///
/// Drives the real `PlankEvaluator` and the real `SessionMachine` from a
/// synthetic body, so the form ladder, the grace budgets and the credit
/// accounting can be watched working before a camera exists. The controls at
/// the bottom stand in for a human on a floor.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../domain/economy/unlock_economy.dart';
import '../domain/exercise/evaluators.dart';
import '../domain/pose/pose_frame.dart';
import '../domain/session/session_machine.dart';
import '../theme/solar_dusk.dart';
import 'synthetic_body.dart';

class SessionDemo extends StatefulWidget {
  const SessionDemo({super.key});

  @override
  State<SessionDemo> createState() => _SessionDemoState();
}

class _SessionDemoState extends State<SessionDemo>
    with SingleTickerProviderStateMixin {
  static const _economy = UnlockEconomy();

  late Ticker _ticker;
  late SessionMachine _machine;
  late ExerciseEvaluator _evaluator;

  /// Simulated capture time, advanced a fixed step per processed tick rather
  /// than read from wall-clock elapsed. A throttled browser tab delivers frames
  /// seconds apart, and the session machine correctly discards any gap past its
  /// staleness guard as a stalled pipeline — so a wall-clock harness simply
  /// stops progressing when the tab loses focus. The camera will deliver an
  /// even cadence; the harness should too.
  Duration _now = Duration.zero;
  Duration _lastRealElapsed = Duration.zero;

  static const _frameStep = Duration(milliseconds: 33);

  double _deviation = 0;
  bool _cameraSees = true;
  Duration _target = const Duration(seconds: 30);

  PoseFrame? _frame;
  EvalOutput? _output;

  @override
  void initState() {
    super.initState();
    _restart();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _restart() {
    _machine = SessionMachine(target: _target);
    _evaluator = PlankEvaluator()..reset();
    _machine.beginCountdown();
  }

  void _onTick(Duration elapsed) {
    final outstanding = elapsed - _lastRealElapsed;
    if (outstanding < _frameStep) return;
    _lastRealElapsed = elapsed;

    // Emit at a steady 30 fps, catching up on whatever real time has passed.
    // A browser throttles a background tab to roughly one frame a second, and
    // stepping once per tick would run the simulation thirty times slow —
    // while stepping by the real gap would trip the machine's staleness guard
    // and be discarded entirely. Catching up in even strides is the only shape
    // that behaves like a camera. Capped so a long tab-switch cannot burn a
    // whole session in one burst.
    final steps =
        (outstanding.inMilliseconds ~/ _frameStep.inMilliseconds).clamp(1, 60);

    PoseFrame? frame;
    EvalOutput? output;

    for (var i = 0; i < steps; i++) {
      _now += _frameStep;
      frame = _cameraSees
          ? syntheticPlank(at: _now, deviationDegrees: _deviation)
          : emptyFrame(_now);
      output = _evaluator.evaluate(frame);
      _machine.onFrame(
        SessionFrame(monotonic: _now, verdict: output.verdict),
      );
      if (_machine.isTerminal) break;
    }

    setState(() {
      _frame = frame;
      _output = output;
    });
  }

  SessionSurface get _surface {
    switch (_machine.state) {
      case SessionState.completed:
        return SessionSurface.completed;
      case SessionState.paused:
      case SessionState.lost:
        return _graceFraction > 0.4
            ? SessionSurface.settling
            : SessionSurface.paused;
      case SessionState.ended:
      case SessionState.cancelled:
        return SessionSurface.settling;
      default:
        return SessionSurface.holding;
    }
  }

  double get _graceFraction {
    final budget = _machine.state == SessionState.lost
        ? _machine.config.graceAfterTrackingLoss
        : _machine.config.graceAfterFormBreak;
    if (budget.inMilliseconds == 0) return 0;
    return (_machine.graceElapsed.inMilliseconds / budget.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  String get _stateWord {
    switch (_machine.state) {
      case SessionState.countdown:
        return 'GET SET';
      case SessionState.holding:
        return 'HOLD';
      case SessionState.lost:
        return "CAN'T SEE YOU";
      case SessionState.paused:
        final faults = _output?.faults ?? const <FaultCode>{};
        if (faults.contains(FaultCode.hipSag)) return 'HIPS UP';
        if (faults.contains(FaultCode.hipPike)) return 'HIPS DOWN';
        return 'STRAIGHTEN';
      case SessionState.completed:
        return 'DONE';
      case SessionState.ended:
        return 'THAT’S IT';
      case SessionState.cancelled:
        return 'CANCELLED';
      case SessionState.framing:
        return 'FRAMING';
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = _surface;
    final field = SessionPalette.fieldFor(surface);
    final ink = SessionPalette.inkFor(surface);
    final earned = _economy.earnedFor(_machine.creditedHold);

    return Scaffold(
      backgroundColor: SessionPalette.void_,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  color: field,
                ),
                if (surface == SessionSurface.settling)
                  _Iris(fraction: _graceFraction),
                CustomPaint(
                  painter: _SkeletonPainter(
                    frame: _frame,
                    ink: ink,
                    surface: surface,
                  ),
                ),
                _Readout(
                  machine: _machine,
                  word: _stateWord,
                  ink: ink,
                  earned: earned,
                  metric: _output?.primaryMetric,
                ),
              ],
            ),
          ),
          _Controls(
            deviation: _deviation,
            cameraSees: _cameraSees,
            target: _target,
            credited: _machine.creditedHold,
            earned: earned,
            onDeviation: (v) => setState(() => _deviation = v),
            onCamera: (v) => setState(() => _cameraSees = v),
            onTarget: (t) => setState(() {
              _target = t;
              _restart();
            }),
            onRestart: () => setState(_restart),
          ),
        ],
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.machine,
    required this.word,
    required this.ink,
    required this.earned,
    required this.metric,
  });

  final SessionMachine machine;
  final String word;
  final Color ink;
  final Duration earned;
  final double? metric;

  @override
  Widget build(BuildContext context) {
    final remaining = machine.remaining.inSeconds +
        (machine.remaining.inMilliseconds % 1000 > 0 ? 1 : 0);

    return Padding(
      padding: const EdgeInsets.all(Spacing.sessionMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$remaining',
                style: TextStyle(
                  fontSize: 150,
                  height: 0.88,
                  fontWeight: FontWeight.w800,
                  color: ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: Spacing.md),
              if (metric != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${metric! >= 0 ? '+' : ''}${metric!.toStringAsFixed(1)}°',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: ink.withValues(alpha: 0.65),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                word,
                style: TextStyle(
                  fontSize: 64,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w800,
                  color: ink,
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                machine.isTerminal
                    ? 'earned ${earned.inMinutes} min'
                    : 'holding ${machine.creditedHold.inSeconds}s',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: ink.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The closing iris. Encodes remaining grace spatially, so it still reads for
/// someone who cannot make out the number, hear the audio, or distinguish the
/// colour. Linear, because it represents literal time.
class _Iris extends StatelessWidget {
  const _Iris({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final width = 48.0 * (1 - fraction) + 8;
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: SessionPalette.settlingIris,
            width: width,
          ),
        ),
      ),
    );
  }
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.frame,
    required this.ink,
    required this.surface,
  });

  final PoseFrame? frame;
  final Color ink;
  final SessionSurface surface;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null) return;

    Offset? at(Joint j) {
      final lm = f[j];
      if (lm.confidence < 0.3) return null;
      return Offset(lm.x * size.width, lm.y * size.height);
    }

    final shoulder = at(Joint.leftShoulder);
    final hip = at(Joint.leftHip);
    final ankle = at(Joint.leftAnkle);
    if (shoulder == null || hip == null || ankle == null) return;

    final stroke = surface == SessionSurface.holding
        ? SessionPalette.skeleton
        : ink;

    // Head, arm and knee at low weight. They are context so the shape reads as
    // a body; they are never the signal.
    final context = Paint()
      ..color = stroke.withValues(alpha: 0.35)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final elbow = at(Joint.leftElbow);
    final wrist = at(Joint.leftWrist);
    if (elbow != null && wrist != null) {
      canvas.drawPath(
        Path()
          ..moveTo(shoulder.dx, shoulder.dy)
          ..lineTo(elbow.dx, elbow.dy)
          ..lineTo(wrist.dx, wrist.dy),
        context,
      );
    }
    final nose = at(Joint.nose);
    if (nose != null) {
      canvas.drawCircle(
          nose, 16, Paint()..color = stroke.withValues(alpha: 0.35));
    }

    // The ideal: a straight line from shoulder to ankle.
    final reference = Paint()
      ..color = stroke.withValues(alpha: 0.45)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    _dashed(canvas, shoulder, ankle, reference);

    // The spine as actually held. The gap between the hip dot and the dashed
    // line is the error, made literal — no number required.
    final spine = Paint()
      ..color = stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(shoulder.dx, shoulder.dy)
        ..lineTo(hip.dx, hip.dy)
        ..lineTo(ankle.dx, ankle.dy),
      spine,
    );

    for (final p in [shoulder, ankle]) {
      canvas.drawCircle(p, 9, Paint()..color = stroke);
    }
    canvas.drawCircle(hip, 20, Paint()..color = stroke);
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dash = 14.0;
    const gap = 10.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final step = (b - a) / total;
    var travelled = 0.0;
    while (travelled < total) {
      final end = math.min(travelled + dash, total);
      canvas.drawLine(a + step * travelled, a + step * end, paint);
      travelled = end + gap;
    }
  }

  @override
  bool shouldRepaint(_SkeletonPainter old) =>
      old.frame != frame || old.surface != surface;
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.deviation,
    required this.cameraSees,
    required this.target,
    required this.credited,
    required this.earned,
    required this.onDeviation,
    required this.onCamera,
    required this.onTarget,
    required this.onRestart,
  });

  final double deviation;
  final bool cameraSees;
  final Duration target;
  final Duration credited;
  final Duration earned;
  final ValueChanged<double> onDeviation;
  final ValueChanged<bool> onCamera;
  final ValueChanged<Duration> onTarget;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: SolarDuskDark.card,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'HIP DEVIATION  ${deviation >= 0 ? '+' : ''}'
                '${deviation.toStringAsFixed(0)}°',
                style: const TextStyle(
                  color: SolarDuskDark.mutedForeground,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Text(
                deviation < -2
                    ? 'sagging'
                    : deviation > 2
                        ? 'piking'
                        : 'level',
                style: const TextStyle(
                  color: SolarDuskDark.mutedForeground,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          Slider(
            value: deviation,
            min: -40,
            max: 40,
            activeColor: SolarDuskDark.primary,
            onChanged: onDeviation,
          ),
          Row(
            children: [
              for (final t in UnlockEconomy.tiers)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${t.inSeconds}s'),
                    selected: target == t,
                    onSelected: (_) => onTarget(t),
                  ),
                ),
              const SizedBox(width: 16),
              FilterChip(
                label: const Text('camera sees me'),
                selected: cameraSees,
                onSelected: onCamera,
              ),
              const Spacer(),
              TextButton(onPressed: onRestart, child: const Text('Restart')),
            ],
          ),
        ],
      ),
    );
  }
}
