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
import 'camera_pose.dart';
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
  bool _useCamera = false;
  bool _recording = false;
  bool _showLandmarks = true;
  ExerciseId _exercise = ExerciseId.plank;
  Duration _target = const Duration(seconds: 30);

  final CameraPose _camera = CameraPose();

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
    _evaluator = evaluatorFor(_exercise)..reset();
    _machine.beginCountdown();
  }

  void _onTick(Duration elapsed) {
    final outstanding = elapsed - _lastRealElapsed;
    if (outstanding < _frameStep) return;
    _lastRealElapsed = elapsed;

    if (_useCamera) {
      // Real capture runs on real time, gaps and all. The staleness guard is
      // supposed to fire when frames stop arriving — that is production
      // behaviour, not something to paper over.
      _now += outstanding;
      final frame = _camera.read(_now) ?? emptyFrame(_now);
      final output = _evaluator.evaluate(frame);
      _machine.onFrame(SessionFrame(monotonic: _now, verdict: output.verdict));
      setState(() {
        _frame = frame;
        _output = output;
      });
      return;
    }

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

  /// How many landmarks the model is confident about, against how many it is
  /// reporting at all. A wide gap is the interesting case: it means most of the
  /// skeleton on screen is inferred rather than seen.
  (int, int) get _trustedJoints {
    final f = _frame;
    if (f == null) return (0, 0);
    var trusted = 0;
    var reported = 0;
    for (final joint in Joint.values) {
      final c = f[joint].confidence;
      if (c <= 0.05) continue;
      reported++;
      if (c >= _LandmarkPainter.trustFloor) trusted++;
    }
    return (trusted, reported);
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
                // Above the product skeleton, not below it. The spine is drawn
                // 12px wide and would otherwise swallow the very dots worth
                // inspecting — the shoulder, hip and ankle it is derived from.
                if (_showLandmarks)
                  CustomPaint(
                    painter: _LandmarkPainter(frame: _frame, ink: ink),
                  ),
                _Readout(
                  machine: _machine,
                  word: _stateWord,
                  ink: ink,
                  earned: earned,
                  metric: _output?.primaryMetric,
                  reps: _output?.reps ?? 0,
                  showReps: _exercise == ExerciseId.pushup ||
                      _exercise == ExerciseId.chairSitToStand,
                ),
              ],
            ),
          ),
          _Controls(
            deviation: _deviation,
            cameraSees: _cameraSees,
            useCamera: _useCamera,
            cameraStatus: _camera.status,
            cameraError: _camera.error,
            clipLabel: _camera.label,
            clipProgress: _camera.progress,
            isFile: _camera.source == PoseSource.file,
            recording: _recording,
            recordedFrames: _camera.recordedFrames,
            showLandmarks: _showLandmarks,
            onShowLandmarks: (v) => setState(() => _showLandmarks = v),
            trustedJoints: _trustedJoints,
            exercise: _exercise,
            onExercise: (e) => setState(() {
              _exercise = e;
              _restart();
            }),
            onLoadVideo: () => setState(() {
              _useCamera = true;
              _camera.startFile();
              _restart();
            }),
            onRecord: (v) => setState(() {
              _recording = v;
              _camera.setRecording(v);
            }),
            onSaveFixture: () => _camera.downloadFixture(),
            faults: _output?.faults ?? const {},
            target: _target,
            onDeviation: (v) => setState(() => _deviation = v),
            onCamera: (v) => setState(() => _cameraSees = v),
            onUseCamera: (v) => setState(() {
              _useCamera = v;
              if (v) {
                _camera.start();
              } else {
                _camera.stop();
              }
              _restart();
            }),
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
    required this.reps,
    required this.showReps,
  });

  final SessionMachine machine;
  final String word;
  final Color ink;
  final Duration earned;
  final double? metric;
  final int reps;
  final bool showReps;

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
                showReps
                    ? '$reps reps'
                    : machine.isTerminal
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

/// Every tracked landmark, drawn as the model actually reports it.
///
/// This is a diagnostic view, not the product one. The session screen shows
/// seven points and one line because that is what reads at five feet; this
/// shows all fifteen so it is possible to see *which* joints the model is
/// confident about and which it is guessing at.
///
/// Confidence is the whole point of the overlay. A filled dot is a landmark the
/// model claims to see; a hollow one is below the threshold the evaluators use
/// to trust a forearm. In a side-on view the far limbs and often the near wrist
/// come back hollow — inferred from a learned prior rather than observed — which
/// is exactly why depth is not decided by elbow angle alone.
class _LandmarkPainter extends CustomPainter {
  _LandmarkPainter({required this.frame, required this.ink});

  final PoseFrame? frame;
  final Color ink;

  /// The confidence floor the pushup evaluator applies to the forearm.
  static const double trustFloor = 0.6;

  static const List<(Joint, Joint)> _edges = [
    (Joint.nose, Joint.leftEar),
    (Joint.nose, Joint.rightEar),
    (Joint.leftShoulder, Joint.rightShoulder),
    (Joint.leftShoulder, Joint.leftElbow),
    (Joint.leftElbow, Joint.leftWrist),
    (Joint.rightShoulder, Joint.rightElbow),
    (Joint.rightElbow, Joint.rightWrist),
    (Joint.leftShoulder, Joint.leftHip),
    (Joint.rightShoulder, Joint.rightHip),
    (Joint.leftHip, Joint.rightHip),
    (Joint.leftHip, Joint.leftKnee),
    (Joint.leftKnee, Joint.leftAnkle),
    (Joint.rightHip, Joint.rightKnee),
    (Joint.rightKnee, Joint.rightAnkle),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame;
    if (f == null) return;

    Offset at(Landmark lm) => Offset(lm.x * size.width, lm.y * size.height);

    for (final (a, b) in _edges) {
      final la = f[a];
      final lb = f[b];
      if (la.confidence <= 0.05 || lb.confidence <= 0.05) continue;
      final weakest =
          la.confidence < lb.confidence ? la.confidence : lb.confidence;
      canvas.drawLine(
        at(la),
        at(lb),
        Paint()
          ..color = ink.withValues(alpha: 0.15 + 0.45 * weakest.clamp(0.0, 1.0))
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }

    for (final joint in Joint.values) {
      final lm = f[joint];
      if (lm.confidence <= 0.05) continue;
      final p = at(lm);
      final trusted = lm.confidence >= trustFloor;

      if (trusted) {
        canvas.drawCircle(
          p,
          5,
          Paint()..color = ink.withValues(alpha: 0.85),
        );
      } else {
        // Hollow: the model is reporting a position it did not really see.
        canvas.drawCircle(
          p,
          5,
          Paint()
            ..color = ink.withValues(alpha: 0.55)
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LandmarkPainter old) =>
      old.frame != frame || old.ink != ink;
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
    required this.useCamera,
    required this.cameraStatus,
    required this.cameraError,
    required this.clipLabel,
    required this.clipProgress,
    required this.isFile,
    required this.recording,
    required this.recordedFrames,
    required this.showLandmarks,
    required this.onShowLandmarks,
    required this.trustedJoints,
    required this.exercise,
    required this.onExercise,
    required this.onLoadVideo,
    required this.onRecord,
    required this.onSaveFixture,
    required this.faults,
    required this.target,
    required this.onDeviation,
    required this.onCamera,
    required this.onUseCamera,
    required this.onTarget,
    required this.onRestart,
  });

  final double deviation;
  final bool cameraSees;
  final bool useCamera;
  final CameraStatus cameraStatus;
  final String cameraError;
  final String clipLabel;
  final double clipProgress;
  final bool isFile;
  final bool recording;
  final int recordedFrames;
  final bool showLandmarks;
  final ValueChanged<bool> onShowLandmarks;
  final (int, int) trustedJoints;
  final ExerciseId exercise;
  final ValueChanged<ExerciseId> onExercise;
  final VoidCallback onLoadVideo;
  final ValueChanged<bool> onRecord;
  final VoidCallback onSaveFixture;
  final Set<FaultCode> faults;
  final Duration target;
  final ValueChanged<double> onDeviation;
  final ValueChanged<bool> onCamera;
  final ValueChanged<bool> onUseCamera;
  final ValueChanged<Duration> onTarget;
  final VoidCallback onRestart;

  String _statusLabel() => switch (cameraStatus) {
        CameraStatus.running => isFile
            ? 'playing  ${(clipProgress * 100).toStringAsFixed(0)}%'
            : 'tracking',
        CameraStatus.ended => 'clip finished',
        CameraStatus.starting => 'starting…',
        CameraStatus.error => 'error',
        CameraStatus.unsupported => 'unsupported here',
        CameraStatus.idle => 'idle',
      };

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
                useCamera
                    ? 'LIVE CAMERA  ·  ${_statusLabel()}'
                    : 'HIP DEVIATION  ${deviation >= 0 ? '+' : ''}'
                        '${deviation.toStringAsFixed(0)}°',
                style: const TextStyle(
                  color: SolarDuskDark.mutedForeground,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 16),
              if (faults.isNotEmpty)
                Expanded(
                  child: Text(
                    faults.map((f) => f.name).join('  ·  '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ChartPalette.tertiary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                const Spacer(),
              Text(
                useCamera
                    ? ''
                    : deviation < -2
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
          Opacity(
            opacity: useCamera ? 0.3 : 1,
            child: Slider(
              value: deviation,
              min: -40,
              max: 40,
              activeColor: SolarDuskDark.primary,
              onChanged: useCamera ? null : onDeviation,
            ),
          ),
          // Wraps rather than overflows: this panel has to survive a narrow
          // window, and a Row here silently blows its constraints.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final e in const [ExerciseId.plank, ExerciseId.pushup])
                ChoiceChip(
                  label: Text(e == ExerciseId.plank ? 'plank' : 'pushups'),
                  selected: exercise == e,
                  selectedColor: SolarDuskDark.accent,
                  onSelected: (_) => onExercise(e),
                ),
              for (final t in UnlockEconomy.tiers)
                ChoiceChip(
                  label: Text('${t.inSeconds}s'),
                  selected: target == t,
                  onSelected: (_) => onTarget(t),
                ),
              FilterChip(
                label: Text(useCamera && !isFile ? 'live camera' : 'use real camera'),
                selected: useCamera && !isFile,
                selectedColor: SolarDuskDark.primary,
                onSelected: onUseCamera,
              ),
              FilterChip(
                avatar: const Icon(Icons.scatter_plot_outlined, size: 18),
                label: Text(showLandmarks
                    ? 'landmarks  ${trustedJoints.$1}/${trustedJoints.$2}'
                    : 'landmarks'),
                selected: showLandmarks,
                onSelected: onShowLandmarks,
              ),
              ActionChip(
                avatar: const Icon(Icons.movie_outlined, size: 18),
                label: Text(isFile && clipLabel.isNotEmpty
                    ? clipLabel
                    : 'load a video'),
                onPressed: onLoadVideo,
              ),
              if (useCamera)
                FilterChip(
                  avatar: Icon(
                    recording ? Icons.fiber_manual_record : Icons.circle_outlined,
                    size: 18,
                    color: recording ? SolarDuskDark.destructive : null,
                  ),
                  label: Text(recording
                      ? 'recording  $recordedFrames'
                      : 'record landmarks'),
                  selected: recording,
                  onSelected: onRecord,
                ),
              if (recordedFrames > 0)
                ActionChip(
                  avatar: const Icon(Icons.download, size: 18),
                  label: const Text('save fixture'),
                  onPressed: onSaveFixture,
                ),
              if (!useCamera)
                FilterChip(
                  label: const Text('camera sees me'),
                  selected: cameraSees,
                  onSelected: onCamera,
                ),
              TextButton(onPressed: onRestart, child: const Text('Restart')),
            ],
          ),
          if (useCamera && cameraStatus == CameraStatus.error)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                cameraError,
                style: const TextStyle(
                  color: SolarDuskDark.destructive,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
