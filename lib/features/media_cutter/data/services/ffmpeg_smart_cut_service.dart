import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_session.dart';
import 'package:ffmpeg_kit_flutter_new/media_information.dart';
import 'package:ffmpeg_kit_flutter_new/media_information_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/stream_information.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/utils/logger.dart';
import 'ffmpeg_media_cutter_service.dart';
import 'smart_cut_planner.dart';

/// Result of a single-output Smart Cut attempt.
class SmartCutResult {
  final String? outputPath;
  final SmartCutFallbackReason? fallbackReason;
  final String? message;

  const SmartCutResult._({
    this.outputPath,
    this.fallbackReason,
    this.message,
  });

  const SmartCutResult.success(String path)
    : this._(outputPath: path);

  const SmartCutResult.fallback(SmartCutFallbackReason reason, [String? details])
    : this._(fallbackReason: reason, message: details);

  bool get succeeded => outputPath != null && fallbackReason == null;
}

/// Result of a multi-part split Smart Cut attempt.
class SmartCutSplitResult {
  final List<String>? outputs;
  final SmartCutFallbackReason? fallbackReason;
  final String? message;

  const SmartCutSplitResult._({
    this.outputs,
    this.fallbackReason,
    this.message,
  });

  const SmartCutSplitResult.success(List<String> files)
    : this._(outputs: files);

  const SmartCutSplitResult.fallback(
    SmartCutFallbackReason reason, [
    String? details,
  ]) : this._(fallbackReason: reason, message: details);

  bool get succeeded => outputs != null && fallbackReason == null;
}

/// Executes GOP-aware Smart Cut (probe -> plan -> edit -> verify) using
/// FFprobeKit and FFmpegKit, automatically falling back with full temp cleanup
/// when any compatibility, GOP, part, encode, or post-export check fails.
class FfmpegSmartCutService {
  FfmpegSmartCutService();

  static int _jobCounter = 0;

  bool _cancelled = false;
  FFmpegSession? _activeSession;
  FFprobeSession? _activeProbeSession;
  MediaInformationSession? _activeMediaInfoSession;

  /// Stops any active FFmpeg/FFprobe session immediately and marks the current
  /// export cancelled so callers throw [MediaCutterCancelledException].
  void cancel() {
    _cancelled = true;
    _activeSession?.cancel().ignore();
    _activeProbeSession?.cancel().ignore();
    _activeMediaInfoSession?.cancel().ignore();
  }

  /// Extracts [SmartCutVideoParams] from an already-probed [MediaInformation]
  /// without spawning an extra FFprobe call.
  static SmartCutVideoParams? extractVideoParams(MediaInformation? info) {
    if (info == null) return null;
    StreamInformation? videoStream;
    for (final stream in info.getStreams()) {
      if (stream.getType() == 'video') {
        videoStream = stream;
        break;
      }
    }
    if (videoStream == null) return null;

    final codecName = videoStream.getCodec()?.trim() ?? '';
    final avgFrameRate = videoStream.getAverageFrameRate();
    final rFrameRate = videoStream.getRealFrameRate();
    final avgFps = SmartCutPlanner.parseFrameRate(avgFrameRate);
    final rFps = SmartCutPlanner.parseFrameRate(rFrameRate);
    final fps = avgFps > 0.0 ? avgFps : rFps;
    final isVfr = SmartCutPlanner.detectVfr(
      avgFrameRate: avgFrameRate,
      rFrameRate: rFrameRate,
    );

    final rawSideData = videoStream.getProperty('side_data_list');
    final rotation = SmartCutPlanner.extractRotation(
      tags: videoStream.getTags(),
      sideDataList: rawSideData is List ? rawSideData : null,
    );

    final videoStart = _parseSignedDouble(
      _readStringProp(videoStream, 'start_time'),
    );
    final containerStart = _parseSignedDouble(info.getStartTime());
    final double startTimeSeconds;
    if (videoStart != null && containerStart != null) {
      startTimeSeconds = videoStart.abs() >= containerStart.abs()
          ? videoStart
          : containerStart;
    } else {
      startTimeSeconds = videoStart ?? containerStart ?? 0.0;
    }

    return SmartCutVideoParams(
      codecName: codecName,
      profile: _readStringProp(videoStream, 'profile'),
      level: _readStringProp(videoStream, 'level'),
      pixFmt: videoStream.getFormat()?.trim(),
      width: videoStream.getWidth() ?? 0,
      height: videoStream.getHeight() ?? 0,
      fps: fps,
      timeBase: videoStream.getTimeBase()?.trim(),
      hasBFrames: _readIntProp(videoStream, 'has_b_frames') ?? 0,
      colorSpace: _readStringProp(videoStream, 'color_space'),
      colorPrimaries: _readStringProp(videoStream, 'color_primaries'),
      colorTransfer: _readStringProp(videoStream, 'color_transfer'),
      colorRange: _readStringProp(videoStream, 'color_range'),
      isVfr: isVfr,
      rotation: rotation,
      startTimeSeconds: startTimeSeconds,
    );
  }

  /// Probes container and stream properties asynchronously for [inputPath].
  /// Returns `null` on failure without throwing; rethrows cancellation.
  Future<SmartCutVideoParams?> probeVideoParams(String inputPath) async {
    try {
      final session = await _runMediaInfo(inputPath);
      return extractVideoParams(session.getMediaInformation());
    } on MediaCutterCancelledException {
      rethrow;
    } catch (e, stack) {
      AppLogger().e('SmartCut probeVideoParams failed for $inputPath', e, stack);
      return null;
    }
  }

  /// Probes video packets (`pts_time`, `dts_time`, `flags`) in demuxer decode
  /// order using async FFprobe and parses CSV in a background isolate.
  /// Returns `null` on failure, oversized output, or cancellation-safe abort.
  Future<List<SmartCutPacket>?> probeVideoPackets(String inputPath) async {
    try {
      final command =
          '-v error -select_streams v:0 -show_entries '
          'packet=pts_time,dts_time,flags -of csv=p=0 ${_q(inputPath)}';
      final session = await _runFfprobe(command);
      final rc = await session.getReturnCode();
      if (!ReturnCode.isSuccess(rc)) {
        final logs = await session.getAllLogsAsString();
        AppLogger().w('SmartCut packet probe failed ($rc): $logs');
        return null;
      }
      final output = await session.getOutput();
      if (_cancelled) throw const MediaCutterCancelledException();
      if (output == null || output.trim().isEmpty) {
        return null;
      }
      if (output.length > SmartCutPlanner.maxProbeCsvBytes) {
        AppLogger().w(
          'SmartCut packet probe CSV exceeded ${SmartCutPlanner.maxProbeCsvBytes} '
          'bytes (${output.length}); falling back cleanly',
        );
        return null;
      }

      final packets = await Isolate.run(
        () => SmartCutPlanner.parsePacketsCsv(
          output,
          maxPackets: SmartCutPlanner.maxProbePackets,
        ),
      );
      if (_cancelled) throw const MediaCutterCancelledException();
      if (packets.isEmpty) {
        return null;
      }
      return packets;
    } on MediaCutterCancelledException {
      rethrow;
    } catch (e, stack) {
      AppLogger().e('SmartCut probeVideoPackets failed for $inputPath', e, stack);
      return null;
    }
  }

  /// Mandatory post-export probe verification: checks file existence, positive
  /// size, valid video stream, codec/dimensions match, audio presence when
  /// expected, and duration within `max(0.5s, 3 frames)`.
  Future<SmartCutVerificationResult> verifyOutput({
    required String outputPath,
    required double expectedDurationSeconds,
    double? requestedDurationSeconds,
    required bool hasAudio,
    required SmartCutVideoParams params,
  }) async {
    try {
      final file = File(outputPath);
      if (!file.existsSync()) {
        return const SmartCutVerificationResult.invalid(
          'Output file does not exist',
        );
      }
      final fileSize = await file.length();
      if (fileSize <= 0) {
        return const SmartCutVerificationResult.invalid(
          'Output file is empty',
        );
      }

      final session = await _runMediaInfo(outputPath);
      final info = session.getMediaInformation();
      if (info == null) {
        return const SmartCutVerificationResult.invalid(
          'FFprobe returned no media information for output',
        );
      }

      StreamInformation? videoStream;
      StreamInformation? audioStream;
      for (final stream in info.getStreams()) {
        final type = stream.getType();
        if (type == 'video' && videoStream == null) {
          videoStream = stream;
        } else if (type == 'audio' && audioStream == null) {
          audioStream = stream;
        }
      }

      final videoDuration = _parsePositiveDouble(
        _readStringProp(videoStream, 'duration'),
      );
      final containerDuration = _parsePositiveDouble(info.getDuration());
      final actualDuration = videoDuration ?? containerDuration;

      return SmartCutPlanner.validateOutputProbe(
        hasVideoStream: videoStream != null,
        hasAudioStream: audioStream != null,
        expectAudio: hasAudio,
        actualDurationSeconds: actualDuration,
        expectedDurationSeconds: expectedDurationSeconds,
        requestedDurationSeconds: requestedDurationSeconds,
        fps: params.fps,
        fileSizeBytes: fileSize,
        outputCodec: videoStream?.getCodec(),
        expectedCodec: params.codecName,
        outputWidth: videoStream?.getWidth(),
        outputHeight: videoStream?.getHeight(),
        expectedWidth: params.width,
        expectedHeight: params.height,
      );
    } on MediaCutterCancelledException {
      rethrow;
    } catch (e, stack) {
      AppLogger().e('SmartCut output verification threw', e, stack);
      return SmartCutVerificationResult.invalid('Verification probe error: $e');
    }
  }

  /// Executes Smart Cut for one or more kept `(start, end)` intervals in
  /// [keptSegments]. Returns [SmartCutResult.fallback] on incompatibility,
  /// Open-GOP boundaries, part verification mismatch, FFmpeg error, or
  /// post-export failure; rethrows [MediaCutterCancelledException] if cancelled.
  Future<SmartCutResult> smartCutSegments({
    required String inputPath,
    required String outputPath,
    required List<(double, double)> keptSegments,
    required double totalDurationSeconds,
    required bool hasAudio,
    SmartCutVideoParams? preProbedParams,
    List<SmartCutPacket>? preProbedPackets,
    void Function(double progress)? onProgress,
  }) async {
    _cancelled = false;
    return _executeSmartCutSegments(
      inputPath: inputPath,
      outputPath: outputPath,
      keptSegments: keptSegments,
      totalDurationSeconds: totalDurationSeconds,
      hasAudio: hasAudio,
      preProbedParams: preProbedParams,
      preProbedPackets: preProbedPackets,
      onProgress: onProgress,
    );
  }

  /// Executes Smart Cut across multiple split points in [cutPointsSeconds],
  /// probing the source video once before producing every part.
  Future<SmartCutSplitResult> smartSplitAtCuts({
    required String inputPath,
    required String outputDirectory,
    required String baseName,
    required List<double> cutPointsSeconds,
    required double totalDurationSeconds,
    required bool hasAudio,
    SmartCutVideoParams? preProbedParams,
    void Function(double progress)? onProgress,
  }) async {
    _cancelled = false;
    if (totalDurationSeconds <= 0) {
      throw ArgumentError('totalDurationSeconds must be positive');
    }

    final cuts =
        cutPointsSeconds
            .where((point) => point > 0 && point < totalDurationSeconds)
            .map((point) => double.parse(point.toStringAsFixed(3)))
            .toSet()
            .toList()
          ..sort();
    if (cuts.isEmpty) {
      throw ArgumentError('At least one cut point is required');
    }

    final points = <double>[0.0, ...cuts, totalDurationSeconds];
    final ranges = <(double, double)>[
      for (var i = 0; i < points.length - 1; i++) (points[i], points[i + 1]),
    ];

    final params = preProbedParams ?? await probeVideoParams(inputPath);
    if (_cancelled) throw const MediaCutterCancelledException();
    if (params == null) {
      return _logAndReturnSplitFallback(
        SmartCutFallbackReason.unsupportedCodec,
        'Unable to probe video parameters',
      );
    }

    final compatFailure = SmartCutPlanner.checkCompatibility(params);
    if (compatFailure != null) {
      return _logAndReturnSplitFallback(
        compatFailure,
        'Source video is not compatible with Smart Cut',
      );
    }

    if (totalDurationSeconds > SmartCutPlanner.maxSmartCutDurationSeconds ||
        (totalDurationSeconds * params.fps) > SmartCutPlanner.maxProbePackets) {
      return _logAndReturnSplitFallback(
        SmartCutFallbackReason.missingPackets,
        'Video exceeds Smart Cut packet index safety limit',
      );
    }

    final packets = await probeVideoPackets(inputPath);
    if (_cancelled) throw const MediaCutterCancelledException();
    if (packets == null || packets.isEmpty) {
      return _logAndReturnSplitFallback(
        SmartCutFallbackReason.missingPackets,
        'FFprobe returned no video packet index',
      );
    }

    final plans = <SmartCutPlan>[];
    for (final range in ranges) {
      final plan = SmartCutPlanner.planSegment(
        packets,
        range.$1,
        range.$2,
        totalDurationSeconds,
        fps: params.fps,
      );
      if (!plan.canSmartCut) {
        return _logAndReturnSplitFallback(
          plan.fallbackReason ?? SmartCutFallbackReason.missingPackets,
          'Segment planning declined [${range.$1}, ${range.$2})',
        );
      }
      if (hasAudio &&
          SmartCutPlanner.hasExcessiveAvOffset(
            requestedStart: range.$1,
            actualStart: plan.actualStart,
            fps: params.fps,
          )) {
        return _logAndReturnSplitFallback(
          SmartCutFallbackReason.verificationFailed,
          'Excessive A/V start offset for [${range.$1}, ${range.$2})',
        );
      }
      plans.add(plan);
    }

    final outputs = <String>[];
    final normalizedDir = outputDirectory.replaceAll('\\', '/');
    try {
      for (var i = 0; i < ranges.length; i++) {
        if (_cancelled) throw const MediaCutterCancelledException();
        final outPath =
            '$normalizedDir/${baseName}_part_${(i + 1).toString().padLeft(3, '0')}.mp4';
        final result = await _executeSmartCutSegments(
          inputPath: inputPath,
          outputPath: outPath,
          keptSegments: [ranges[i]],
          totalDurationSeconds: totalDurationSeconds,
          hasAudio: hasAudio,
          preProbedParams: params,
          preProbedPackets: packets,
          prePlannedSegments: [plans[i]],
          onProgress: onProgress == null
              ? null
              : (partProgress) {
                  final overall =
                      (i + partProgress.clamp(0.0, 1.0)) / ranges.length;
                  onProgress(overall.clamp(0.0, 1.0));
                },
        );
        if (!result.succeeded) {
          _deleteFilesQuietly(outputs);
          return _logAndReturnSplitFallback(
            result.fallbackReason ?? SmartCutFallbackReason.encodeFailed,
            result.message ?? 'Split part ${i + 1} fell back',
          );
        }
        outputs.add(outPath);
      }
      onProgress?.call(1.0);
      return SmartCutSplitResult.success(outputs);
    } on MediaCutterCancelledException {
      _deleteFilesQuietly(outputs);
      rethrow;
    }
  }

  Future<SmartCutResult> _executeSmartCutSegments({
    required String inputPath,
    required String outputPath,
    required List<(double, double)> keptSegments,
    required double totalDurationSeconds,
    required bool hasAudio,
    SmartCutVideoParams? preProbedParams,
    List<SmartCutPacket>? preProbedPackets,
    List<SmartCutPlan>? prePlannedSegments,
    void Function(double progress)? onProgress,
  }) async {
    if (keptSegments.isEmpty || totalDurationSeconds <= 0) {
      return _logAndReturnFallback(
        SmartCutFallbackReason.missingPackets,
        'No kept segments to export',
      );
    }

    Directory? jobDir;
    try {
      if (_cancelled) throw const MediaCutterCancelledException();

      final tempRoot = await getTemporaryDirectory();
      jobDir = Directory(
        '${tempRoot.path}/smart_cut_${DateTime.now().microsecondsSinceEpoch}_${++_jobCounter}',
      );
      await jobDir.create(recursive: true);

      final params = preProbedParams ?? await probeVideoParams(inputPath);
      if (_cancelled) throw const MediaCutterCancelledException();
      if (params == null) {
        return _logAndReturnFallback(
          SmartCutFallbackReason.unsupportedCodec,
          'Unable to probe video parameters',
        );
      }

      final compatFailure = SmartCutPlanner.checkCompatibility(params);
      if (compatFailure != null) {
        return _logAndReturnFallback(
          compatFailure,
          'Source video is not compatible with Smart Cut',
        );
      }

      if (preProbedPackets == null &&
          (totalDurationSeconds > SmartCutPlanner.maxSmartCutDurationSeconds ||
              (totalDurationSeconds * params.fps) >
                  SmartCutPlanner.maxProbePackets)) {
        return _logAndReturnFallback(
          SmartCutFallbackReason.missingPackets,
          'Video exceeds Smart Cut packet index safety limit',
        );
      }

      final packets = preProbedPackets ?? await probeVideoPackets(inputPath);
      if (_cancelled) throw const MediaCutterCancelledException();
      if (packets == null || packets.isEmpty) {
        return _logAndReturnFallback(
          SmartCutFallbackReason.missingPackets,
          'FFprobe returned no video packet index',
        );
      }

      final plans = prePlannedSegments ?? <SmartCutPlan>[];
      if (prePlannedSegments == null) {
        for (final segment in keptSegments) {
          final plan = SmartCutPlanner.planSegment(
            packets,
            segment.$1,
            segment.$2,
            totalDurationSeconds,
            fps: params.fps,
          );
          if (!plan.canSmartCut) {
            return _logAndReturnFallback(
              plan.fallbackReason ?? SmartCutFallbackReason.missingPackets,
              'Segment planning declined [${segment.$1}, ${segment.$2})',
            );
          }
          plans.add(plan);
        }
      }

      if (hasAudio && plans.length == keptSegments.length) {
        for (var idx = 0; idx < plans.length; idx++) {
          if (SmartCutPlanner.hasExcessiveAvOffset(
            requestedStart: keptSegments[idx].$1,
            actualStart: plans[idx].actualStart,
            fps: params.fps,
          )) {
            return _logAndReturnFallback(
              SmartCutFallbackReason.verificationFailed,
              'Excessive A/V start offset: requested=${keptSegments[idx].$1}, '
              'actual=${plans[idx].actualStart}',
            );
          }
        }
      }

      onProgress?.call(0.05);

      final allParts = <SmartCutPart>[
        for (final plan in plans) ...plan.parts,
      ];
      if (allParts.isEmpty) {
        return _logAndReturnFallback(
          SmartCutFallbackReason.missingPackets,
          'Smart Cut plan produced zero parts',
        );
      }

      final totalPartDuration = allParts.fold<double>(
        0.0,
        (sum, part) => sum + part.duration,
      );
      final concatEntries = <({String path, double duration})>[];
      var completedDuration = 0.0;

      for (var i = 0; i < allParts.length; i++) {
        if (_cancelled) throw const MediaCutterCancelledException();
        final part = allParts[i];

        if (part.kind == SmartCutPartKind.copy && part.start > 0.0005) {
          final seekStart = SmartCutPlanner.computeCopySeekStart(part, params);
          final landingPts = await _probeCopyLandingPts(inputPath, seekStart);
          if (_cancelled) throw const MediaCutterCancelledException();
          if (!SmartCutPlanner.isValidCopyLanding(
            landingPts: landingPts,
            expectedStartPts: part.start,
            fps: params.fps,
          )) {
            return _logAndReturnFallback(
              SmartCutFallbackReason.verificationFailed,
              'Copy part ${i + 1} seek landed at PTS=$landingPts '
              'instead of expected=${part.start}',
            );
          }
        }

        final partPath =
            '${jobDir.path}/part_${i.toString().padLeft(4, '0')}.ts';
        final cmd = part.kind == SmartCutPartKind.reencode
            ? SmartCutPlanner.buildReencodePartCommand(
                inputPath: inputPath,
                outputPath: partPath,
                part: part,
                params: params,
              )
            : SmartCutPlanner.buildCopyPartCommand(
                inputPath: inputPath,
                outputPath: partPath,
                part: part,
                params: params,
              );

        AppLogger().i(
          'SmartCut part ${i + 1}/${allParts.length} (${part.kind.name}): $cmd',
        );

        final partWeight = totalPartDuration > 0
            ? part.duration / totalPartDuration
            : 1.0 / allParts.length;
        final partStartProgress =
            0.05 +
            0.80 *
                (totalPartDuration > 0
                    ? completedDuration / totalPartDuration
                    : i / allParts.length);
        final partDurationMs = math.max(1.0, part.duration * 1000.0);

        final session = await _runFfmpeg(
          cmd,
          onTimeMs: onProgress == null
              ? null
              : (timeMs) {
                  final frac = (timeMs / partDurationMs).clamp(0.0, 1.0);
                  final mapped = partStartProgress + 0.80 * partWeight * frac;
                  onProgress(mapped.clamp(0.05, 0.85));
                },
        );
        if (_cancelled) throw const MediaCutterCancelledException();

        final rc = await session.getReturnCode();
        final partFile = File(partPath);
        if (!ReturnCode.isSuccess(rc) ||
            !partFile.existsSync() ||
            await partFile.length() <= 0) {
          final logs = await session.getAllLogsAsString();
          return _logAndReturnFallback(
            SmartCutFallbackReason.encodeFailed,
            'Part ${i + 1} failed ($rc): $logs',
          );
        }

        final writtenCount = await _countWrittenPartPackets(partPath);
        if (_cancelled) throw const MediaCutterCancelledException();
        if (!SmartCutPlanner.validateWrittenPart(
          part: part,
          writtenPacketCount: writtenCount,
        )) {
          return _logAndReturnFallback(
            SmartCutFallbackReason.verificationFailed,
            'Part ${i + 1} (${part.kind.name}) packet count mismatch: '
            'written=$writtenCount, expected=${part.frameCount}',
          );
        }

        concatEntries.add((path: partPath, duration: part.duration));
        completedDuration += part.duration;
        onProgress?.call(
          (partStartProgress + 0.80 * partWeight).clamp(0.05, 0.85),
        );
      }

      if (_cancelled) throw const MediaCutterCancelledException();

      final concatFile = File('${jobDir.path}/concat.txt');
      await concatFile.writeAsString(
        SmartCutPlanner.buildConcatListContent(concatEntries),
      );

      final audioSegments = <(double, double)>[
        for (final plan in plans)
          () {
            final safeStart = plan.actualStart < 0.0 ? 0.0 : plan.actualStart;
            final safeEnd = math.max(safeStart + 0.001, plan.actualEnd);
            return (safeStart, safeEnd);
          }(),
      ];

      final mergeCmd = SmartCutPlanner.buildMergeCommand(
        concatListPath: concatFile.path,
        sourceInputPath: inputPath,
        outputPath: outputPath,
        keptSegments: audioSegments,
        hasAudio: hasAudio,
        videoParams: params,
      );
      AppLogger().i('SmartCut merge command: $mergeCmd');

      final expectedDuration = plans.fold<double>(
        0.0,
        (sum, plan) => sum + plan.expectedDuration,
      );
      final requestedDuration = keptSegments.fold<double>(
        0.0,
        (sum, seg) => sum + (seg.$2 - seg.$1),
      );
      final expectedMs = math.max(1.0, expectedDuration * 1000.0);

      final mergeSession = await _runFfmpeg(
        mergeCmd,
        onTimeMs: onProgress == null
            ? null
            : (timeMs) {
                final frac = (timeMs / expectedMs).clamp(0.0, 1.0);
                onProgress((0.85 + 0.10 * frac).clamp(0.85, 0.95));
              },
      );
      if (_cancelled) {
        _deleteFileQuietly(outputPath);
        throw const MediaCutterCancelledException();
      }

      final mergeRc = await mergeSession.getReturnCode();
      if (!ReturnCode.isSuccess(mergeRc)) {
        final logs = await mergeSession.getAllLogsAsString();
        _deleteFileQuietly(outputPath);
        return _logAndReturnFallback(
          SmartCutFallbackReason.encodeFailed,
          'SmartCut merge failed ($mergeRc): $logs',
        );
      }

      onProgress?.call(0.95);

      final verification = await verifyOutput(
        outputPath: outputPath,
        expectedDurationSeconds: expectedDuration,
        requestedDurationSeconds: requestedDuration,
        hasAudio: hasAudio,
        params: params,
      );
      if (_cancelled) {
        _deleteFileQuietly(outputPath);
        throw const MediaCutterCancelledException();
      }
      if (!verification.isValid) {
        _deleteFileQuietly(outputPath);
        return _logAndReturnFallback(
          SmartCutFallbackReason.verificationFailed,
          verification.failureReason ?? 'Post-export verification failed',
        );
      }

      onProgress?.call(1.0);
      return SmartCutResult.success(outputPath);
    } on MediaCutterCancelledException {
      _deleteFileQuietly(outputPath);
      rethrow;
    } catch (e, stack) {
      AppLogger().e('SmartCut execution error', e, stack);
      _deleteFileQuietly(outputPath);
      return _logAndReturnFallback(
        SmartCutFallbackReason.encodeFailed,
        e.toString(),
      );
    } finally {
      _deleteDirQuietly(jobDir);
    }
  }

  Future<double?> _probeCopyLandingPts(
    String inputPath,
    double seekStart,
  ) async {
    final cmd =
        '-v error -select_streams v:0 '
        '-read_intervals ${_fmt6(seekStart)}%+#5 '
        '-show_entries packet=pts_time,flags -of csv=p=0 ${_q(inputPath)}';
    final session = await _runFfprobe(cmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) return null;
    final output = await session.getOutput();
    if (output == null || output.trim().isEmpty) return null;
    return SmartCutPlanner.parseFirstPacketPts(output);
  }

  Future<int> _countWrittenPartPackets(String partPath) async {
    final cmd =
        '-v error -select_streams v:0 '
        '-show_entries packet=pts_time -of csv=p=0 ${_q(partPath)}';
    final session = await _runFfprobe(cmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) return -1;
    final output = await session.getOutput();
    if (output == null || output.trim().isEmpty) return 0;
    return SmartCutPlanner.countCsvPackets(output);
  }

  Future<FFmpegSession> _runFfmpeg(
    String command, {
    void Function(double timeMs)? onTimeMs,
  }) async {
    if (_cancelled) throw const MediaCutterCancelledException();
    final completer = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeAsync(
      command,
      (completed) {
        if (!completer.isCompleted) completer.complete(completed);
      },
      (log) {},
      (statistics) {
        if (_cancelled || onTimeMs == null) return;
        final timeMs = statistics.getTime();
        if (timeMs > 0) {
          onTimeMs(timeMs.toDouble());
        }
      },
    );
    _activeSession = session;
    if (_cancelled) session.cancel().ignore();
    final completed = await completer.future;
    _activeSession = null;
    if (_cancelled) throw const MediaCutterCancelledException();
    return completed;
  }

  Future<FFprobeSession> _runFfprobe(String command) async {
    if (_cancelled) throw const MediaCutterCancelledException();
    final completer = Completer<FFprobeSession>();
    final session = await FFprobeKit.executeAsync(
      command,
      (completed) {
        if (!completer.isCompleted) completer.complete(completed);
      },
      (log) {},
    );
    _activeProbeSession = session;
    if (_cancelled) session.cancel().ignore();
    final completed = await completer.future;
    _activeProbeSession = null;
    if (_cancelled) throw const MediaCutterCancelledException();
    return completed;
  }

  Future<MediaInformationSession> _runMediaInfo(String path) async {
    if (_cancelled) throw const MediaCutterCancelledException();
    final completer = Completer<MediaInformationSession>();
    final session = await FFprobeKit.getMediaInformationAsync(
      path,
      (completed) {
        if (!completer.isCompleted) completer.complete(completed);
      },
    );
    _activeMediaInfoSession = session;
    if (_cancelled) session.cancel().ignore();
    final completed = await completer.future;
    _activeMediaInfoSession = null;
    if (_cancelled) throw const MediaCutterCancelledException();
    return completed;
  }

  SmartCutResult _logAndReturnFallback(
    SmartCutFallbackReason reason,
    String details,
  ) {
    AppLogger().w('SmartCut fallback (${reason.name}): $details');
    return SmartCutResult.fallback(reason, details);
  }

  SmartCutSplitResult _logAndReturnSplitFallback(
    SmartCutFallbackReason reason,
    String details,
  ) {
    AppLogger().w('SmartCut split fallback (${reason.name}): $details');
    return SmartCutSplitResult.fallback(reason, details);
  }

  static String? _readStringProp(StreamInformation? stream, String key) {
    if (stream == null) return null;
    final raw = stream.getProperty(key);
    if (raw == null) return null;
    final str = raw.toString().trim();
    return str.isEmpty ? null : str;
  }

  static int? _readIntProp(StreamInformation? stream, String key) {
    if (stream == null) return null;
    final raw = stream.getProperty(key);
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  static double? _parsePositiveDouble(String? raw) {
    if (raw == null) return null;
    final parsed = double.tryParse(raw.trim());
    if (parsed == null || !parsed.isFinite || parsed <= 0.0) return null;
    return parsed;
  }

  static double? _parseSignedDouble(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.toUpperCase() == 'N/A') return null;
    final parsed = double.tryParse(trimmed);
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }

  static String _fmt6(double seconds) => seconds.toStringAsFixed(6);

  static String _q(String path) => '"${path.replaceAll('\\', '/')}"';

  static void _deleteFileQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      AppLogger().e('SmartCut cleanup failed for file $path', e);
    }
  }

  static void _deleteFilesQuietly(List<String> paths) {
    for (final path in paths) {
      _deleteFileQuietly(path);
    }
  }

  static void _deleteDirQuietly(Directory? dir) {
    if (dir == null) return;
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (e) {
      AppLogger().e('SmartCut cleanup failed for dir ${dir.path}', e);
    }
  }
}
