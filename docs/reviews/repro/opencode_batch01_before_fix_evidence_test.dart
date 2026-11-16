// TEMPORARY — evidence only, deleted after the run is captured in
// docs/reviews/OPENCODE_BATCH_01_RESULT_AR.md.
//
// The bodies below are the PRE-FIX implementations copied verbatim from
// silence_detector_repository_impl.dart at the 2026-10-05 baseline. Each test
// asserts the invariant that is now enforced in test/, so every one of them is
// expected to FAIL here. That failure is the "before" half of the evidence.
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:flutter_test/flutter_test.dart';

List<SilenceSegment> oldMergeCloseSegments(
  List<SilenceSegment> segments,
  double maxGap,
) {
  if (segments.isEmpty) return [];

  final sorted = List<SilenceSegment>.from(segments)
    ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds));

  final merged = <SilenceSegment>[sorted.first];

  for (final segment in sorted.skip(1)) {
    final last = merged.last;
    if (segment.startSeconds - last.endSeconds <= maxGap) {
      merged[merged.length - 1] = SilenceSegment(
        startSeconds: last.startSeconds,
        endSeconds: segment.endSeconds,
      );
    } else {
      merged.add(segment);
    }
  }

  return merged;
}

List<SilenceSegment> oldApplyPadding(
  List<SilenceSegment> segments,
  double paddingBefore,
  double paddingAfter,
  double totalDuration,
) {
  return segments.map((segment) {
    var start =
        (segment.startSeconds - paddingBefore).clamp(0, totalDuration).toDouble();
    var end = (segment.endSeconds + paddingAfter).clamp(start, totalDuration).toDouble();
    if (end - start < 0.02) end = start;
    return SilenceSegment(startSeconds: start, endSeconds: end);
  }).where((s) => s.endSeconds > s.startSeconds).toList();
}

// Verbatim from ffmpeg_cutting_service.dart at the 2026-10-05 baseline.
List<Map<String, dynamic>> oldBuildSpeechSegments(
  List<SilenceSegment> silenceSegments,
  double totalDuration,
) {
  final speechSegments = <Map<String, dynamic>>[];
  var currentStart = 0.0;

  for (final silence in silenceSegments) {
    if (silence.startSeconds > currentStart) {
      speechSegments.add({'start': currentStart, 'end': silence.startSeconds});
    }
    currentStart = silence.endSeconds;
  }

  if (currentStart < totalDuration) {
    speechSegments.add({'start': currentStart, 'end': totalDuration});
  }

  return speechSegments;
}

void main() {
  const first = SilenceSegment(startSeconds: 1, endSeconds: 2);
  const second = SilenceSegment(startSeconds: 2.2, endSeconds: 3);

  test('SR-01 invariant: the 200ms speech island survives', () {
    final result = oldMergeCloseSegments([first, second], 0.25);
    expect(result, [first, second]);
  });

  test('SR-01 invariant: min silence 5s cannot widen the removals', () {
    // A 500ms island: kept apart at the 250ms default, absorbed at min=5s.
    const a = SilenceSegment(startSeconds: 1, endSeconds: 2);
    const b = SilenceSegment(startSeconds: 2.5, endSeconds: 3);
    final atDefault = oldMergeCloseSegments([a, b], 0.25);
    final atMax = oldMergeCloseSegments([a, b], 5.0);
    expect(atDefault, [a, b]);
    expect(atMax, atDefault);
  });

  test('SR-02 invariant: guards keep the removal inside the silence', () {
    final result = oldApplyPadding([first], 0.15, 0.15, 10).single;
    expect(result.startSeconds, greaterThanOrEqualTo(first.startSeconds));
    expect(result.endSeconds, lessThanOrEqualTo(first.endSeconds));
  });

  test('SR-02 invariant: raising a guard never increases the deletion', () {
    double removed(double g) => oldApplyPadding([first], g, g, 10)
        .fold<double>(0, (sum, s) => sum + s.durationSeconds);
    expect(removed(0.15), lessThan(removed(0.05)));
    expect(removed(0.5), lessThan(removed(0.15)));
  });

  test('SR-03 invariant: the union is what gets measured', () {
    final padded = oldApplyPadding(
      [first, const SilenceSegment(startSeconds: 2.6, endSeconds: 3.5)],
      0.5,
      0.5,
      10,
    );
    final sum = padded.fold<double>(0, (s, x) => s + x.durationSeconds);
    final union = padded.last.endSeconds - padded.first.startSeconds;
    expect(sum, closeTo(union, 1e-9));
  });

  test('SR-03 invariant: kept + removed equals the timeline', () {
    // The pre-fix complement in ffmpeg_cutting_service.dart walked the raw
    // padded list; with overlapping inputs it emitted a negative kept total.
    final padded = oldApplyPadding(
      [first, const SilenceSegment(startSeconds: 2.6, endSeconds: 3.5)],
      0.5,
      0.5,
      10,
    );
    final kept = oldBuildSpeechSegments(padded, 10);
    final keptTotal = kept.fold<double>(
      0,
      (sum, s) => sum + ((s['end'] as double) - (s['start'] as double)),
    );
    final removedTotal =
        padded.fold<double>(0, (sum, s) => sum + s.durationSeconds);
    expect(removedTotal + keptTotal, closeTo(10, 1e-9));
    expect(keptTotal, greaterThanOrEqualTo(0));
  });

  test('SR-05 invariant: a zero/absent duration cannot delete the timeline', () {
    // Old code clamped every interval to [0, totalDuration]; with a missing
    // waveform duration (0) all detected silences vanished.
    expect(oldApplyPadding([first], 0, 0, 10).length, 1);
    expect(oldApplyPadding([first], 0, 0, 0), isNotEmpty);
  });

  test('SR-19 invariant: a contained interval keeps the outer end', () {
    final result = oldMergeCloseSegments([
      const SilenceSegment(startSeconds: 1, endSeconds: 5),
      const SilenceSegment(startSeconds: 2, endSeconds: 3),
    ], 0);
    expect(result.single.endSeconds, 5);
  });
}