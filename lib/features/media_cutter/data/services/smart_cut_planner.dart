import 'dart:math' as math;

/// Processing mode for a single planned video segment in Smart Cut.
enum SmartCutPartKind { reencode, copy }

/// Reason Smart Cut declined or aborted and handed off to standard re-encode.
enum SmartCutFallbackReason {
  unsupportedCodec,
  vfrSource,
  openGop,
  missingPackets,
  encodeFailed,
  verificationFailed,
}

/// Probed parameters of the source video stream needed to plan Smart Cut
/// compatibility and match re-encoded edge segments to copied GOPs.
class SmartCutVideoParams {
  final String codecName;
  final String? profile;
  final String? level;
  final String? pixFmt;
  final int width;
  final int height;
  final double fps;
  final String? timeBase;
  final int hasBFrames;
  final String? colorSpace;
  final String? colorPrimaries;
  final String? colorTransfer;
  final String? colorRange;
  final bool isVfr;

  const SmartCutVideoParams({
    required this.codecName,
    this.profile,
    this.level,
    this.pixFmt,
    required this.width,
    required this.height,
    required this.fps,
    this.timeBase,
    this.hasBFrames = 0,
    this.colorSpace,
    this.colorPrimaries,
    this.colorTransfer,
    this.colorRange,
    this.isVfr = false,
  });
}

/// One video packet from FFprobe (`pts_time`, `dts_time`, `flags`) in demuxer
/// decode order.
class SmartCutPacket {
  final double pts;
  final double dts;
  final bool isKeyFrame;

  const SmartCutPacket({
    required this.pts,
    required this.dts,
    this.isKeyFrame = false,
  });
}

/// A planned sub-segment produced by [SmartCutPlanner.planSegment].
class SmartCutPart {
  final SmartCutPartKind kind;
  final double start;
  final double end;
  final int frameCount;
  final double? keyDts;
  final double? endDts;

  const SmartCutPart({
    required this.kind,
    required this.start,
    required this.end,
    required this.frameCount,
    this.keyDts,
    this.endDts,
  });

  double get duration => (end - start) > 0 ? (end - start) : 0.0;
}

/// Complete Smart Cut plan for one kept output range.
class SmartCutPlan {
  final List<SmartCutPart> parts;
  final double actualStart;
  final double actualEnd;
  final SmartCutFallbackReason? fallbackReason;

  SmartCutPlan({
    required List<SmartCutPart> parts,
    required this.actualStart,
    required this.actualEnd,
  }) : parts = List<SmartCutPart>.unmodifiable(parts),
       fallbackReason = null;

  const SmartCutPlan.fallback(SmartCutFallbackReason reason)
    : parts = const <SmartCutPart>[],
      actualStart = 0.0,
      actualEnd = 0.0,
      fallbackReason = reason;

  bool get canSmartCut => fallbackReason == null && parts.isNotEmpty;

  double get expectedDuration =>
      (actualEnd - actualStart) > 0 ? (actualEnd - actualStart) : 0.0;

  bool get hasCopyParts =>
      parts.any((part) => part.kind == SmartCutPartKind.copy);

  bool get isPureCopy =>
      parts.isNotEmpty &&
      parts.every((part) => part.kind == SmartCutPartKind.copy);
}

/// Outcome of mandatory post-export FFprobe verification.
class SmartCutVerificationResult {
  final bool isValid;
  final String? failureReason;

  const SmartCutVerificationResult.valid()
    : isValid = true,
      failureReason = null;

  const SmartCutVerificationResult.invalid(String reason)
    : isValid = false,
      failureReason = reason;
}

/// Pure Dart Smart Cut planning, Open-GOP detection, matched x264 flag
/// construction, de-click audio filter graph generation, and probe validation.
class SmartCutPlanner {
  SmartCutPlanner._();

  static const Set<String> _supportedPixFmts = {
    'yuv420p',
    'yuvj420p',
    'yuv422p',
    'yuvj422p',
    'yuv444p',
    'yuvj444p',
  };

  static const Set<String> _unknownTagValues = {
    'unknown',
    'unspecified',
    'reserved',
    'n/a',
  };

  /// Parses FFprobe rational (`30000/1001`) or decimal (`29.97`) frame rates.
  /// Returns `0.0` when missing, zero, or non-finite.
  static double parseFrameRate(String? value) {
    if (value == null) return 0.0;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.toUpperCase() == 'N/A') return 0.0;
    if (trimmed.contains('/')) {
      final parts = trimmed.split('/');
      if (parts.length != 2) return 0.0;
      final numVal = double.tryParse(parts[0].trim());
      final denVal = double.tryParse(parts[1].trim());
      if (numVal == null ||
          denVal == null ||
          !numVal.isFinite ||
          !denVal.isFinite ||
          denVal <= 0) {
        return 0.0;
      }
      final rate = numVal / denVal;
      return (rate.isFinite && rate > 0) ? rate : 0.0;
    }
    final parsed = double.tryParse(trimmed);
    if (parsed == null || !parsed.isFinite || parsed <= 0) return 0.0;
    return parsed;
  }

  /// Heuristic VFR detector comparing `avg_frame_rate` and `r_frame_rate`.
  static bool detectVfr({String? avgFrameRate, String? rFrameRate}) {
    final avg = parseFrameRate(avgFrameRate);
    final r = parseFrameRate(rFrameRate);
    if (r > 240.0 && avg > 0.0 && avg <= 240.0) {
      return true;
    }
    if (avg > 0.0 && r > 0.0) {
      final diffRatio = (avg - r).abs() / math.max(avg, r);
      return diffRatio > 0.02;
    }
    return false;
  }

  /// Extracts integer timescale from a stream `time_base` string (`1/90000`).
  static int? parseTimescale(String? timeBase) {
    if (timeBase == null) return null;
    final trimmed = timeBase.trim();
    final parts = trimmed.split('/');
    if (parts.length != 2) return null;
    final numVal = int.tryParse(parts[0].trim());
    final denVal = int.tryParse(parts[1].trim());
    if (numVal == 1 && denVal != null && denVal > 0) {
      return denVal;
    }
    return null;
  }

  /// Parses FFprobe packet CSV (`-show_entries packet=pts_time,dts_time,flags -of csv=p=0`),
  /// preserving original demuxer/decode order for [isOpenGop].
  static List<SmartCutPacket> parsePacketsCsv(String csvOutput) {
    if (csvOutput.trim().isEmpty) return const <SmartCutPacket>[];
    final packets = <SmartCutPacket>[];
    final lines = csvOutput.split(RegExp(r'\r?\n'));
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final fields = line.split(',');
      final offset = fields.isNotEmpty && fields[0].trim() == 'packet' ? 1 : 0;
      if (fields.length < offset + 3) continue;

      final ptsRaw = double.tryParse(fields[offset].trim());
      final dtsRaw = double.tryParse(fields[offset + 1].trim());
      final validPts = ptsRaw != null && ptsRaw.isFinite ? ptsRaw : null;
      final validDts = dtsRaw != null && dtsRaw.isFinite ? dtsRaw : null;
      if (validPts == null && validDts == null) continue;

      final flags = fields[offset + 2].trim();
      packets.add(
        SmartCutPacket(
          pts: validPts ?? validDts!,
          dts: validDts ?? validPts!,
          isKeyFrame: flags.contains('K'),
        ),
      );
    }
    return packets;
  }

  /// Returns `null` when [params] is eligible for H.264 CFR Smart Cut, or the
  /// corresponding [SmartCutFallbackReason].
  static SmartCutFallbackReason? checkCompatibility(SmartCutVideoParams params) {
    final codec = params.codecName.trim().toLowerCase();
    if (codec != 'h264') {
      return SmartCutFallbackReason.unsupportedCodec;
    }
    if (params.isVfr) {
      return SmartCutFallbackReason.vfrSource;
    }
    if (!params.fps.isFinite || params.fps <= 0.0 || params.fps > 240.0) {
      return SmartCutFallbackReason.unsupportedCodec;
    }
    if (params.width <= 0 || params.height <= 0) {
      return SmartCutFallbackReason.unsupportedCodec;
    }
    final pixFmt = params.pixFmt?.trim().toLowerCase() ?? '';
    if (!_supportedPixFmts.contains(pixFmt)) {
      return SmartCutFallbackReason.unsupportedCodec;
    }
    return null;
  }

  /// Whether [params] passes pre-flight Smart Cut requirements (H.264, CFR,
  /// valid FPS and dimensions, supported 8-bit pixel format).
  static bool canAttemptSmartCut(SmartCutVideoParams params) =>
      checkCompatibility(params) == null;

  /// Detects an Open-GOP boundary at [keyIndex] in decode-ordered [packets]:
  /// returns `true` if any packet decoded after [keyIndex] within that GOP has
  /// a presentation timestamp strictly earlier than `packets[keyIndex].pts`.
  static bool isOpenGop(List<SmartCutPacket> packets, int keyIndex) {
    if (keyIndex < 0 || keyIndex >= packets.length) return false;
    final key = packets[keyIndex];
    if (!key.isKeyFrame) return false;

    const eps = 1e-6;
    for (var i = keyIndex + 1; i < packets.length; i++) {
      final packet = packets[i];
      if (packet.isKeyFrame && packet.pts > key.pts + eps) {
        break;
      }
      if (packet.pts < key.pts - eps) {
        return true;
      }
    }
    return false;
  }

  /// Plans a single kept interval `[start, end)` in seconds against
  /// decode-ordered [packets] over a source video of [totalDuration] seconds.
  static SmartCutPlan planSegment(
    List<SmartCutPacket> packets,
    double start,
    double end,
    double totalDuration, {
    double? fps,
  }) {
    if (packets.isEmpty ||
        !start.isFinite ||
        !end.isFinite ||
        !totalDuration.isFinite ||
        totalDuration <= 0.0) {
      return const SmartCutPlan.fallback(SmartCutFallbackReason.missingPackets);
    }

    final clampedStart = start.clamp(0.0, totalDuration).toDouble();
    final clampedEnd = end.clamp(0.0, totalDuration).toDouble();
    if (clampedEnd <= clampedStart) {
      return const SmartCutPlan.fallback(SmartCutFallbackReason.missingPackets);
    }

    final byPts = <({int decodeIndex, SmartCutPacket packet})>[
      for (var i = 0; i < packets.length; i++)
        (decodeIndex: i, packet: packets[i]),
    ]..sort((a, b) {
        final cmp = a.packet.pts.compareTo(b.packet.pts);
        return cmp != 0 ? cmp : a.decodeIndex.compareTo(b.decodeIndex);
      });

    final frameDur = _inferFrameDuration(byPts, fps);
    const eps = 1e-4;

    var firstPos = -1;
    var lastPos = -1;
    for (var i = 0; i < byPts.length; i++) {
      final pts = byPts[i].packet.pts;
      if (pts >= clampedStart - eps && pts < clampedEnd - eps) {
        if (firstPos == -1) firstPos = i;
        lastPos = i;
      }
    }

    if (firstPos == -1 || lastPos == -1) {
      return const SmartCutPlan.fallback(SmartCutFallbackReason.missingPackets);
    }

    final firstItem = byPts[firstPos];
    final lastItem = byPts[lastPos];
    final extendsToEof = lastPos == byPts.length - 1;
    final nextItem = extendsToEof ? null : byPts[lastPos + 1];

    final actualStart = firstItem.packet.pts;
    final double actualEnd;
    if (nextItem != null) {
      actualEnd = nextItem.packet.pts;
    } else {
      final inferredEnd = lastItem.packet.pts + frameDur;
      actualEnd =
          (totalDuration > lastItem.packet.pts &&
              (totalDuration - inferredEnd).abs() <= frameDur * 2.0)
          ? totalDuration
          : inferredEnd;
    }

    final internalKeys = <int>[];
    for (var i = firstPos; i <= lastPos; i++) {
      if (byPts[i].packet.isKeyFrame) {
        internalKeys.add(i);
      }
    }

    if (internalKeys.isEmpty) {
      return SmartCutPlan(
        parts: [
          SmartCutPart(
            kind: SmartCutPartKind.reencode,
            start: actualStart,
            end: actualEnd,
            frameCount: lastPos - firstPos + 1,
          ),
        ],
        actualStart: actualStart,
        actualEnd: actualEnd,
      );
    }

    final k1Pos = internalKeys.first;
    final k1Item = byPts[k1Pos];

    final int copyEndPos;
    final double copyEndPts;
    final double? copyEndDts;
    final int? copyEndKeyDecodeIndex;

    if (extendsToEof) {
      copyEndPos = lastPos + 1;
      copyEndPts = actualEnd;
      copyEndDts = null;
      copyEndKeyDecodeIndex = null;
    } else if (nextItem != null && nextItem.packet.isKeyFrame) {
      copyEndPos = lastPos + 1;
      copyEndPts = nextItem.packet.pts;
      copyEndDts = nextItem.packet.dts;
      copyEndKeyDecodeIndex = nextItem.decodeIndex;
    } else {
      final k2Pos = internalKeys.last;
      if (k2Pos <= k1Pos) {
        return SmartCutPlan(
          parts: [
            SmartCutPart(
              kind: SmartCutPartKind.reencode,
              start: actualStart,
              end: actualEnd,
              frameCount: lastPos - firstPos + 1,
            ),
          ],
          actualStart: actualStart,
          actualEnd: actualEnd,
        );
      }
      final k2Item = byPts[k2Pos];
      copyEndPos = k2Pos;
      copyEndPts = k2Item.packet.pts;
      copyEndDts = k2Item.packet.dts;
      copyEndKeyDecodeIndex = k2Item.decodeIndex;
    }

    if (isOpenGop(packets, k1Item.decodeIndex)) {
      return const SmartCutPlan.fallback(SmartCutFallbackReason.openGop);
    }
    if (copyEndKeyDecodeIndex != null &&
        isOpenGop(packets, copyEndKeyDecodeIndex)) {
      return const SmartCutPlan.fallback(SmartCutFallbackReason.openGop);
    }

    final parts = <SmartCutPart>[];
    if (k1Pos > firstPos) {
      parts.add(
        SmartCutPart(
          kind: SmartCutPartKind.reencode,
          start: actualStart,
          end: k1Item.packet.pts,
          frameCount: k1Pos - firstPos,
        ),
      );
    }

    final copyFrames = copyEndPos - k1Pos;
    if (copyFrames > 0) {
      parts.add(
        SmartCutPart(
          kind: SmartCutPartKind.copy,
          start: k1Item.packet.pts,
          end: copyEndPts,
          frameCount: copyFrames,
          keyDts: k1Item.packet.dts,
          endDts: copyEndDts,
        ),
      );
    }

    if (copyEndPos <= lastPos) {
      parts.add(
        SmartCutPart(
          kind: SmartCutPartKind.reencode,
          start: copyEndPts,
          end: actualEnd,
          frameCount: lastPos - copyEndPos + 1,
        ),
      );
    }

    return SmartCutPlan(
      parts: parts,
      actualStart: actualStart,
      actualEnd: actualEnd,
    );
  }

  /// Builds `libx264` encoding flags matching the probed source stream so
  /// re-encoded edge parts concatenate seamlessly with stream-copied middle
  /// GOPs.
  static String buildMatchedX264Flags(SmartCutVideoParams params) {
    final flags = <String>['-c:v libx264', '-crf 18', '-preset veryfast'];

    final mappedProfile = _mapX264Profile(params.profile);
    if (mappedProfile != null) {
      flags.add('-profile:v $mappedProfile');
    }

    final mappedLevel = _mapX264Level(params.level);
    if (mappedLevel != null) {
      flags.add('-level:v $mappedLevel');
    }

    final pixFmt = params.pixFmt?.trim().toLowerCase();
    if (_isValidTag(pixFmt)) {
      flags.add('-pix_fmt $pixFmt');
    }

    final bFrames = mappedProfile == 'baseline'
        ? 0
        : params.hasBFrames.clamp(0, 16);
    flags.add('-x264-params "bf=$bFrames:open-gop=0"');

    if (_isValidTag(params.colorSpace)) {
      flags.add('-colorspace ${params.colorSpace!.trim().toLowerCase()}');
    }
    if (_isValidTag(params.colorPrimaries)) {
      flags.add(
        '-color_primaries ${params.colorPrimaries!.trim().toLowerCase()}',
      );
    }
    if (_isValidTag(params.colorTransfer)) {
      flags.add('-color_trc ${params.colorTransfer!.trim().toLowerCase()}');
    }
    if (_isValidTag(params.colorRange)) {
      flags.add('-color_range ${params.colorRange!.trim().toLowerCase()}');
    }

    return flags.join(' ');
  }

  /// Builds an FFmpeg `filter_complex` string that extracts audio for each
  /// kept segment, locks sync with `aresample=async=1:first_pts=0` and
  /// `apad=whole_dur=...`, and applies short anti-click fades (`0.005s`) only
  /// on internal splice boundaries.
  static String buildAudioDeclickFilter({
    required List<(double, double)> segments,
    int audioInputIndex = 1,
    double fadeDurationSeconds = 0.005,
  }) {
    if (segments.isEmpty) {
      throw ArgumentError('At least one audio segment is required');
    }

    final filter = StringBuffer();
    final concatInputs = StringBuffer();
    final n = segments.length;

    for (var i = 0; i < n; i++) {
      final start = segments[i].$1;
      final end = segments[i].$2;
      if (!start.isFinite || !end.isFinite || start < 0.0 || end <= start) {
        throw ArgumentError('Invalid audio segment: $start - $end');
      }

      final dur = end - start;
      final fade = fadeDurationSeconds.isFinite && fadeDurationSeconds > 0
          ? fadeDurationSeconds.clamp(0.0, dur / 3.0).toDouble()
          : 0.0;
      final hasInFade = n > 1 && i > 0 && fade >= 0.0005;
      final hasOutFade = n > 1 && i < n - 1 && fade >= 0.0005;

      filter.write(
        '[$audioInputIndex:a]atrim=start=${_fmt6(start)}:end=${_fmt6(end)},'
        'asetpts=PTS-STARTPTS,aresample=async=1:first_pts=0',
      );
      if (hasInFade) {
        filter.write(',afade=t=in:st=0:d=${_fmtFade(fade)}');
      }
      if (hasOutFade) {
        final fadeOutStart = (dur - fade).clamp(0.0, dur).toDouble();
        filter.write(',afade=t=out:st=${_fmt6(fadeOutStart)}:d=${_fmtFade(fade)}');
      }
      filter.write(',apad=whole_dur=${_fmt6(dur)}');

      if (n == 1) {
        filter.write('[outa]');
      } else {
        filter.write('[a$i];');
        concatInputs.write('[a$i]');
      }
    }

    if (n > 1) {
      filter.write('${concatInputs}concat=n=$n:v=0:a=1[outa]');
    }
    return filter.toString();
  }

  /// Validates the probed exported file against expected streams, file size,
  /// and duration tolerance `max(0.5s, 3 frames)`.
  static SmartCutVerificationResult validateOutputProbe({
    required bool hasVideoStream,
    required bool hasAudioStream,
    required bool expectAudio,
    required double? actualDurationSeconds,
    required double expectedDurationSeconds,
    required double fps,
    int? fileSizeBytes,
  }) {
    if (fileSizeBytes != null && fileSizeBytes <= 0) {
      return const SmartCutVerificationResult.invalid(
        'Output file is empty',
      );
    }
    if (!hasVideoStream) {
      return const SmartCutVerificationResult.invalid(
        'Output file has no video stream',
      );
    }
    if (expectAudio && !hasAudioStream) {
      return const SmartCutVerificationResult.invalid(
        'Output file is missing expected audio stream',
      );
    }
    if (actualDurationSeconds == null ||
        !actualDurationSeconds.isFinite ||
        actualDurationSeconds <= 0.0) {
      return const SmartCutVerificationResult.invalid(
        'Output file has invalid duration',
      );
    }
    if (!expectedDurationSeconds.isFinite || expectedDurationSeconds <= 0.0) {
      return const SmartCutVerificationResult.invalid(
        'Expected output duration is invalid',
      );
    }

    final threeFrames = (fps.isFinite && fps > 0.0) ? (3.0 / fps) : 0.0;
    final tolerance = math.max(0.5, threeFrames);
    final diff = (actualDurationSeconds - expectedDurationSeconds).abs();
    if (diff > tolerance) {
      return SmartCutVerificationResult.invalid(
        'Output duration drift ${diff.toStringAsFixed(3)}s exceeds tolerance '
        '${tolerance.toStringAsFixed(3)}s '
        '(actual=${actualDurationSeconds.toStringAsFixed(3)}s, '
        'expected=${expectedDurationSeconds.toStringAsFixed(3)}s)',
      );
    }
    return const SmartCutVerificationResult.valid();
  }

  /// Builds the video-only FFmpeg command for a re-encoded edge part.
  static String buildReencodePartCommand({
    required String inputPath,
    required String outputPath,
    required SmartCutPart part,
    required SmartCutVideoParams params,
  }) {
    final frameDur = params.fps > 0 ? 1.0 / params.fps : 1.0 / 30.0;
    final seekStart = part.start <= 0.0005
        ? 0.0
        : (part.start - math.min(0.001, frameDur * 0.25))
              .clamp(0.0, double.infinity)
              .toDouble();
    final timescale = parseTimescale(params.timeBase);
    final timescaleFlag = timescale != null
        ? ' -video_track_timescale $timescale'
        : '';

    return '-ss ${_fmt6(seekStart)} -i ${_q(inputPath)} -map 0:v:0 -an '
        '${buildMatchedX264Flags(params)} -frames:v ${part.frameCount}'
        '$timescaleFlag -avoid_negative_ts make_zero -y ${_q(outputPath)}';
  }

  /// Builds the video-only FFmpeg command for a stream-copied interior GOP part.
  static String buildCopyPartCommand({
    required String inputPath,
    required String outputPath,
    required SmartCutPart part,
    required SmartCutVideoParams params,
  }) {
    final frameDur = params.fps > 0 ? 1.0 / params.fps : 1.0 / 30.0;
    final seekStart = part.start <= 0.0005
        ? 0.0
        : part.start + math.min(0.001, frameDur * 0.25);
    final framesFlag = part.endDts != null
        ? ' -frames:v ${part.frameCount}'
        : '';

    return '-ss ${_fmt6(seekStart)} -i ${_q(inputPath)} -map 0:v:0 -an '
        '-c:v copy$framesFlag -avoid_negative_ts make_zero -y ${_q(outputPath)}';
  }

  /// Builds an `ffconcat version 1.0` list with explicit per-part `duration`
  /// entries for accurate demuxer timestamps.
  static String buildConcatListContent(
    List<({String path, double duration})> entries,
  ) {
    final buffer = StringBuffer('ffconcat version 1.0\n');
    for (final entry in entries) {
      final escaped = entry.path
          .replaceAll('\\', '/')
          .replaceAll("'", "'\\''");
      buffer.writeln("file '$escaped'");
      buffer.writeln('duration ${_fmt6(entry.duration)}');
    }
    return buffer.toString();
  }

  /// Builds the final merge command that stream-copies the concatenated video
  /// parts and muxes either no audio or the de-clicked AAC audio track.
  static String buildMergeCommand({
    required String concatListPath,
    required String sourceInputPath,
    required String outputPath,
    required List<(double, double)> keptSegments,
    required bool hasAudio,
  }) {
    if (!hasAudio) {
      return '-f concat -safe 0 -i ${_q(concatListPath)} '
          '-map 0:v:0 -an -c:v copy -movflags +faststart -y ${_q(outputPath)}';
    }

    final audioFilter = buildAudioDeclickFilter(
      segments: keptSegments,
      audioInputIndex: 1,
    );
    return '-f concat -safe 0 -i ${_q(concatListPath)} -i ${_q(sourceInputPath)} '
        '-filter_complex "$audioFilter" -map 0:v:0 -map "[outa]" '
        '-c:v copy -c:a aac -b:a 192k -movflags +faststart -y ${_q(outputPath)}';
  }

  /// Computes sorted, non-overlapping kept `(start, end)` segments from
  /// removal intervals within `[0, totalDurationSeconds]`.
  static List<(double, double)> computeKeptSegments(
    List<(double, double)> removeRanges,
    double totalDurationSeconds,
  ) {
    if (!totalDurationSeconds.isFinite || totalDurationSeconds <= 0.0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }
    if (removeRanges.isEmpty) {
      throw ArgumentError('At least one removal range is required');
    }

    for (final range in removeRanges) {
      if (!range.$1.isFinite ||
          !range.$2.isFinite ||
          range.$1 < 0.0 ||
          range.$2 <= range.$1) {
        throw ArgumentError('Invalid removal range: ${range.$1} - ${range.$2}');
      }
    }

    final sorted = [...removeRanges]..sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].$1 < sorted[i - 1].$2) {
        throw ArgumentError('Removal ranges overlap');
      }
    }

    final kept = <(double, double)>[];
    var cursor = 0.0;
    for (final range in sorted) {
      final start = range.$1.clamp(0.0, totalDurationSeconds).toDouble();
      final end = range.$2.clamp(0.0, totalDurationSeconds).toDouble();
      if (start > cursor) kept.add((cursor, start));
      if (end > cursor) cursor = end;
    }
    if (cursor < totalDurationSeconds) {
      kept.add((cursor, totalDurationSeconds));
    }

    return kept.where((segment) => segment.$2 - segment.$1 >= 0.001).toList();
  }

  static double _inferFrameDuration(
    List<({int decodeIndex, SmartCutPacket packet})> byPts,
    double? fps,
  ) {
    if (fps != null && fps.isFinite && fps > 0.0) {
      return 1.0 / fps;
    }
    final diffs = <double>[];
    for (var i = 1; i < byPts.length; i++) {
      final diff = byPts[i].packet.pts - byPts[i - 1].packet.pts;
      if (diff > 1e-5 && diff.isFinite) {
        diffs.add(diff);
      }
    }
    if (diffs.isEmpty) return 1.0 / 30.0;
    diffs.sort();
    return diffs[diffs.length ~/ 2];
  }

  static String? _mapX264Profile(String? rawProfile) {
    final normalized = rawProfile?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty || _unknownTagValues.contains(normalized)) {
      return null;
    }
    switch (normalized) {
      case 'constrained baseline':
      case 'baseline':
        return 'baseline';
      case 'main':
        return 'main';
      case 'high':
        return 'high';
      case 'high 10':
      case 'high10':
        return 'high10';
      case 'high 4:2:2':
      case 'high422':
        return 'high422';
      case 'high 4:4:4':
      case 'high 4:4:4 predictive':
      case 'high444':
        return 'high444';
      default:
        return null;
    }
  }

  static String? _mapX264Level(String? rawLevel) {
    final normalized = rawLevel?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty ||
        _unknownTagValues.contains(normalized) ||
        normalized == '-99' ||
        normalized == '0') {
      return null;
    }
    final intVal = int.tryParse(normalized);
    if (intVal != null) {
      if (intVal >= 10 && intVal <= 62) {
        return '${intVal ~/ 10}.${intVal % 10}';
      }
      return null;
    }
    if (RegExp(r'^\d+\.\d+$').hasMatch(normalized)) {
      return normalized;
    }
    return null;
  }

  static bool _isValidTag(String? value) {
    if (value == null) return false;
    final normalized = value.trim().toLowerCase();
    return normalized.isNotEmpty && !_unknownTagValues.contains(normalized);
  }

  static String _q(String path) => '"${path.replaceAll('\\', '/')}"';

  static String _fmt6(double seconds) => seconds.toStringAsFixed(6);

  static String _fmtFade(double seconds) {
    final ms = seconds * 1000.0;
    if ((ms - ms.round()).abs() < 1e-6) {
      return seconds.toStringAsFixed(3);
    }
    return seconds.toStringAsFixed(6);
  }
}
