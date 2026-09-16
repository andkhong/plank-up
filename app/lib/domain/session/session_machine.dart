/// Drives one exercise attempt from framing to outcome.
///
/// Every timing decision comes from the monotonic capture timestamp carried on
/// each frame, never from a wall clock. That makes pipeline latency and UI jank
/// mathematically irrelevant to what the user is credited with — which is what
/// makes it safe for this to live in Dart at all.
///
/// There is no failure state. Breaking form pauses accumulation; it does not
/// end the attempt and it costs nothing. The grace periods here answer "how
/// long before we conclude they have stopped", not "how long before we punish".
library;

enum FormVerdict {
  /// Holding the target position within tolerance.
  good,

  /// In position but outside tolerance — hips sagging, piking, collapsing.
  broken,

  /// Recognisably a person, but no longer attempting the exercise.
  outOfPosition,

  /// We cannot see well enough to judge. Never counts against the user.
  indeterminate,
}

enum SessionState {
  framing,
  countdown,
  holding,

  /// Form broke or they left position. Timer stopped, grace running.
  paused,

  /// We lost the skeleton. Timer stopped, longer grace, and this is our fault.
  lost,

  completed,

  /// They stopped before the target. Whatever they held is still credited.
  ended,

  /// Aborted early enough that it reads as "never mind" rather than an attempt.
  cancelled,
}

enum SessionOutcome { completed, ended, cancelled }

class SessionConfig {
  const SessionConfig({
    this.countdown = const Duration(seconds: 3),
    this.graceAfterFormBreak = const Duration(seconds: 3),
    this.graceAfterTrackingLoss = const Duration(seconds: 10),
    this.cancelWindow = const Duration(seconds: 3),
    this.maxSingleFrameGap = const Duration(milliseconds: 400),
  });

  final Duration countdown;
  final Duration graceAfterFormBreak;

  /// Deliberately longer than the form grace. Losing the skeleton is a
  /// perception failure on our side, so we wait considerably longer before
  /// concluding anything.
  final Duration graceAfterTrackingLoss;

  /// Stopping inside this window after the timer starts reads as an abort
  /// rather than a real attempt.
  final Duration cancelWindow;

  /// A gap larger than this means frames stopped arriving. Time inside the gap
  /// is credited to nobody — it neither accumulates hold nor burns grace.
  final Duration maxSingleFrameGap;
}

class SessionFrame {
  const SessionFrame({required this.monotonic, required this.verdict});

  final Duration monotonic;
  final FormVerdict verdict;
}

class SessionMachine {
  SessionMachine({
    required this.target,
    this.config = const SessionConfig(),
  });

  final Duration target;
  final SessionConfig config;

  SessionState _state = SessionState.framing;
  Duration _creditedHold = Duration.zero;
  Duration _graceElapsed = Duration.zero;
  Duration _countdownElapsed = Duration.zero;
  Duration? _lastFrame;

  SessionState get state => _state;
  Duration get creditedHold => _creditedHold;
  Duration get graceElapsed => _graceElapsed;

  bool get isTerminal =>
      _state == SessionState.completed ||
      _state == SessionState.ended ||
      _state == SessionState.cancelled;

  SessionOutcome? get outcome => switch (_state) {
        SessionState.completed => SessionOutcome.completed,
        SessionState.ended => SessionOutcome.ended,
        SessionState.cancelled => SessionOutcome.cancelled,
        _ => null,
      };

  Duration get remaining {
    final left = target - _creditedHold;
    return left.isNegative ? Duration.zero : left;
  }

  double get progress =>
      target.inMicroseconds == 0 ? 1 : (_creditedHold.inMicroseconds / target.inMicroseconds).clamp(0.0, 1.0);

  /// Framing has stabilised; begin the 3-2-1.
  void beginCountdown() {
    if (_state != SessionState.framing) return;
    _state = SessionState.countdown;
    _countdownElapsed = Duration.zero;
  }

  /// The user walked away from the attempt deliberately. Settles exactly as a
  /// grace expiry does — giving up and being timed out earn the same credit.
  void abandon() {
    if (isTerminal) return;
    _settle();
  }

  void onFrame(SessionFrame frame) {
    if (isTerminal) return;

    final delta = _delta(frame.monotonic);
    _lastFrame = frame.monotonic;

    switch (_state) {
      case SessionState.framing:
        return;

      case SessionState.countdown:
        _countdownElapsed += delta;
        if (_countdownElapsed >= config.countdown) {
          _state = SessionState.holding;
          _graceElapsed = Duration.zero;
        }
        return;

      case SessionState.holding:
        if (frame.verdict == FormVerdict.good) {
          _creditedHold += delta;
          if (_creditedHold >= target) {
            _creditedHold = target;
            _state = SessionState.completed;
          }
          return;
        }
        _state = frame.verdict == FormVerdict.indeterminate
            ? SessionState.lost
            : SessionState.paused;
        _graceElapsed = Duration.zero;
        return;

      case SessionState.paused:
      case SessionState.lost:
        if (frame.verdict == FormVerdict.good) {
          _state = SessionState.holding;
          _graceElapsed = Duration.zero;
          return;
        }
        // Moving between "bad form" and "can't see you" re-targets the budget
        // without forgiving time already spent.
        _state = frame.verdict == FormVerdict.indeterminate
            ? SessionState.lost
            : SessionState.paused;
        _graceElapsed += delta;
        if (_graceElapsed >= _graceBudget) _settle();
        return;

      case SessionState.completed:
      case SessionState.ended:
      case SessionState.cancelled:
        return;
    }
  }

  Duration get _graceBudget => _state == SessionState.lost
      ? config.graceAfterTrackingLoss
      : config.graceAfterFormBreak;

  Duration _delta(Duration now) {
    final last = _lastFrame;
    if (last == null) return Duration.zero;
    final delta = now - last;
    if (delta.isNegative) return Duration.zero;
    return delta > config.maxSingleFrameGap ? Duration.zero : delta;
  }

  void _settle() {
    _state = _creditedHold < config.cancelWindow
        ? SessionState.cancelled
        : SessionState.ended;
  }
}
