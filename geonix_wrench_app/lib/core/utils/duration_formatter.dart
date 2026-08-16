/// Job-card labour time, rendered the way a mechanic reads a clock.
///
/// The API carries labour as a decimal hour count because that is what it
/// multiplies by the hourly rate — but "0.75" is not how anyone describes
/// three quarters of an hour out loud, and reading it off a screen invites
/// the mistake of billing 75 minutes.
///
/// This deliberately matches `_format_labor_time` in the backend's
/// `pdf_generator.py` character for character, so the review screen and the
/// printed job card never disagree about the same number. Change one and you
/// must change the other.
String formatLaborTime(double hours) {
  final totalMinutes = (hours.isFinite ? hours : 0) * 60;
  final minutes = totalMinutes.round().clamp(0, 1 << 31);
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  return '${m}m';
}
