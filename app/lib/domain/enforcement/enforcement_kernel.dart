/// The single source of truth for "is this app blocked right now".
///
/// This logic is mirrored in Swift (for the iOS extensions, which run while the
/// Flutter engine is dead) and in Kotlin. The three implementations are held in
/// agreement by a shared JSON conformance corpus, not by sharing code — a 6 MB
/// DeviceActivityMonitor extension cannot host a Dart VM.
///
/// Keep it pure and total: any state plus any instant yields a verdict.
library;

import '../schedule/block_schedule.dart';

class UnlockGrant {
  const UnlockGrant({
    required this.id,
    required this.grantedAt,
    required this.expiresAt,
    required this.earnedFrom,
  });

  final String id;
  final DateTime grantedAt;
  final DateTime expiresAt;

  /// Seconds of verified effort that bought this window.
  final int earnedFrom;

  bool isLiveAt(DateTime now) => now.isBefore(expiresAt);

  Duration remainingAt(DateTime now) {
    final remaining = expiresAt.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }
}

class EnforcementState {
  const EnforcementState({
    this.masterEnabled = true,
    this.schedules = const [],
    this.blockedAppCount = 0,
    this.activeGrant,
    this.disableEffectiveAt,
  });

  final bool masterEnabled;
  final List<BlockSchedule> schedules;

  /// iOS returns opaque tokens, so a count is all we can know there.
  final int blockedAppCount;
  final UnlockGrant? activeGrant;

  /// Set when the user starts the friction wait. Blocking stays on until it
  /// passes; losing this timestamp can only ever lengthen the wait.
  final DateTime? disableEffectiveAt;

  bool get hasBlocklist => blockedAppCount > 0;

  EnforcementState copyWith({
    bool? masterEnabled,
    List<BlockSchedule>? schedules,
    int? blockedAppCount,
    UnlockGrant? activeGrant,
    bool clearGrant = false,
    DateTime? disableEffectiveAt,
    bool clearDisable = false,
  }) =>
      EnforcementState(
        masterEnabled: masterEnabled ?? this.masterEnabled,
        schedules: schedules ?? this.schedules,
        blockedAppCount: blockedAppCount ?? this.blockedAppCount,
        activeGrant: clearGrant ? null : (activeGrant ?? this.activeGrant),
        disableEffectiveAt:
            clearDisable ? null : (disableEffectiveAt ?? this.disableEffectiveAt),
      );
}

enum EnforcementMode { off, wallUp, passActive, wallDown, unconfigured }

class EnforcementVerdict {
  const EnforcementVerdict({
    required this.blocking,
    required this.mode,
    this.activeScheduleIds = const [],
    this.passRemaining,
  });

  final bool blocking;
  final EnforcementMode mode;
  final List<String> activeScheduleIds;
  final Duration? passRemaining;
}

class EnforcementKernel {
  const EnforcementKernel();

  EnforcementVerdict evaluate(EnforcementState state, DateTime now) {
    final disabled = !state.masterEnabled ||
        (state.disableEffectiveAt != null &&
            !now.isBefore(state.disableEffectiveAt!));
    if (disabled) {
      return const EnforcementVerdict(
          blocking: false, mode: EnforcementMode.off);
    }

    if (!state.hasBlocklist) {
      return const EnforcementVerdict(
          blocking: false, mode: EnforcementMode.unconfigured);
    }

    final activeIds = state.schedules
        .where((s) => s.containsLocal(now))
        .map((s) => s.id)
        .toList(growable: false);

    // An earned pass outranks a scheduled window. That is the whole product.
    final grant = state.activeGrant;
    if (grant != null && grant.isLiveAt(now)) {
      return EnforcementVerdict(
        blocking: false,
        mode: EnforcementMode.passActive,
        activeScheduleIds: activeIds,
        passRemaining: grant.remainingAt(now),
      );
    }

    if (activeIds.isNotEmpty) {
      return EnforcementVerdict(
        blocking: true,
        mode: EnforcementMode.wallUp,
        activeScheduleIds: activeIds,
      );
    }

    return const EnforcementVerdict(
        blocking: false, mode: EnforcementMode.wallDown);
  }

  /// Working out while nothing is blocked would earn a pass against a wall that
  /// isn't there. Closing it here removes any incentive to pre-farm access just
  /// before a window opens.
  bool canStartAttempt(EnforcementState state, DateTime now) =>
      evaluate(state, now).blocking;
}
