/// Solar Dusk — the chosen 21st.dev community theme, plus the session-state
/// ladder built on top of it.
///
/// The theme was picked because it is close to a Pembroke corgi rendered as a
/// palette *and* because it ships a cool accent. That second property is what
/// makes the safety signalling possible: every other warm-earth candidate was
/// warm all the way through, which would have forced a foreign hue to be bolted
/// on for form warnings.
library;

import 'dart:ui';

class SolarDuskLight {
  const SolarDuskLight._();

  static const background = Color(0xFFFDFBF7);
  static const foreground = Color(0xFF4A3B33);
  static const card = Color(0xFFF8F4EE);
  static const primary = Color(0xFFB45309);
  static const primaryForeground = Color(0xFFFFFFFF);
  static const secondary = Color(0xFFE4C090);
  static const secondaryForeground = Color(0xFF57534E);
  static const muted = Color(0xFFF1E9DA);
  static const mutedForeground = Color(0xFF78716C);
  static const accent = Color(0xFFF2DABA);
  static const destructive = Color(0xFF991B1B);
  static const border = Color(0xFFE4D9BC);
  static const ring = Color(0xFFB45309);
}

class SolarDuskDark {
  const SolarDuskDark._();

  static const background = Color(0xFF1C1917);
  static const foreground = Color(0xFFF5F5F4);
  static const card = Color(0xFF292524);
  static const primary = Color(0xFFF97316);
  static const primaryForeground = Color(0xFFFFFFFF);
  static const secondary = Color(0xFF57534E);
  static const secondaryForeground = Color(0xFFE7E5E4);
  static const muted = Color(0xFF201D1A);
  static const mutedForeground = Color(0xFFA8A29E);
  static const accent = Color(0xFF1E4252);
  static const destructive = Color(0xFFDC2626);
  static const border = Color(0xFF44403C);
  static const ring = Color(0xFFF97316);
}

/// Categorical series for progress charts.
///
/// The theme's own light-mode ramp has a duplicate and two adjacent golds,
/// which reads as orange/gold/gold and is unusable for deuteranopes. So the
/// primary pair is orange against blue, the most hue-separable option.
///
/// But the theme's `chart-2` (`#0EA5E9`) and `primary` (`#F97316`) turn out to
/// sit within 0.004 of each other in relative luminance — they are separable by
/// hue and completely identical in greyscale, which fails achromatopsia and any
/// monochrome rendering. The blue is deepened here so the pair separates on
/// *both* channels. `#0EA5E9` survives untouched as the skeleton colour, where
/// it sits on a dark field and contrast is not in question.
class ChartPalette {
  const ChartPalette._();

  static const clean = Color(0xFFF97316);
  static const recovered = Color(0xFF0369A1);
  static const incomplete = Color(0xFF57534E);
  static const tertiary = Color(0xFFEAB308);
}

/// The live-session states, in the order a user meets them.
enum SessionSurface { holding, paused, lost, settling, completed }

/// Field, ink and geometry for each session state.
///
/// The organising rule: **hue is never the sole carrier.** A corgi is
/// `#F97316`, and amber — the reflexive choice for a form warning — sits in
/// that same band. At five feet, sideways, in a dim room, brand furniture and
/// the most safety-critical signal in the app would be indistinguishable. So
/// the warning is a *luminance event* instead: the screen inverts to near-white.
/// Every adjacent pair below is a large luminance step, which survives full
/// achromatopsia, bad lighting and a glance out of the corner of an eye.
///
/// Warm hues are banned from session surfaces entirely. The first warm pixel of
/// a session is the success field — you earn the orange.
class SessionPalette {
  const SessionPalette._();

  /// Deeper than the theme background: the near-white warning needs headroom to
  /// flash into, and this runs full-screen for up to ninety seconds on OLED.
  static const void_ = Color(0xFF0C0A09);

  static const holdingField = Color(0xFF15323D);
  static const holdingInk = Color(0xFFF5F5F4);

  /// Brightened from the theme's `chart-2`, which loses its edge against a dark
  /// field at five feet.
  static const skeleton = Color(0xFF38BDF8);

  static const pausedField = Color(0xFFF5F5F4);
  static const pausedInk = Color(0xFF1C1917);

  /// Tracking loss shares the paused field but adds a diagonal hatch, so "we
  /// cannot see you" never reads as "your form is wrong".
  static const lostHatch = Color(0x2EA8A29E);

  /// The closing-iris state. Note this no longer signals an impending penalty —
  /// there is none — it signals that the attempt is about to be concluded and
  /// settled at whatever was earned.
  static const settlingField = Color(0xFFDC2626);
  static const settlingIris = Color(0xFFEF4444);
  static const settlingInk = Color(0xFFFFFFFF);

  static const completedField = Color(0xFFF97316);
  static const completedInk = Color(0xFF1C1917);

  static Color fieldFor(SessionSurface surface) => switch (surface) {
        SessionSurface.holding => holdingField,
        SessionSurface.paused => pausedField,
        SessionSurface.lost => pausedField,
        SessionSurface.settling => settlingField,
        SessionSurface.completed => completedField,
      };

  static Color inkFor(SessionSurface surface) => switch (surface) {
        SessionSurface.holding => holdingInk,
        SessionSurface.paused => pausedInk,
        SessionSurface.lost => pausedInk,
        SessionSurface.settling => settlingInk,
        SessionSurface.completed => completedInk,
      };

  /// Border thickness in logical pixels — the redundant geometric channel.
  static double borderFor(SessionSurface surface) => switch (surface) {
        SessionSurface.holding => 0,
        SessionSurface.paused => 24,
        SessionSurface.lost => 24,
        SessionSurface.settling => 48,
        SessionSurface.completed => 0,
      };

  /// Pulse rate in Hz — the redundant motion channel. Capped at 2 Hz
  /// throughout for photosensitivity.
  static double pulseHzFor(SessionSurface surface) => switch (surface) {
        SessionSurface.holding => 0,
        SessionSurface.paused => 1,
        SessionSurface.lost => 0.5,
        SessionSurface.settling => 2,
        SessionSurface.completed => 0,
      };
}

/// Nothing below 40 renders on a framing or workout screen. If a piece of
/// information cannot earn 40, it belongs in the audio channel or nowhere.
class TypeScale {
  const TypeScale._();

  static const double sessionFloor = 40;

  static const double sessionCounter = 240;
  static const double sessionState = 88;
  static const double sessionCoach = 56;
  static const double display = 44;
  static const double titleLarge = 32;
  static const double titleMedium = 24;
  static const double ctaPrimary = 28;
  static const double bodyLarge = 19;
  static const double body = 17;
  static const double label = 15;
  static const double caption = 13;
}

class Spacing {
  const Spacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  static const double screenMargin = 20;
  static const double sessionMargin = 32;

  /// Anything pressed with sweaty hands.
  static const double touchTargetLarge = 56;
  static const double touchTargetMin = 44;
}

class Radii {
  const Radii._();

  static const double xs = 4;
  static const double sm = 6;
  static const double md = 10;
  static const double card = 14;
  static const double sheet = 20;
}
