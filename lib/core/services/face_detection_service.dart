import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/logger.dart';

/// How camera tracking behaves within a single [SceneShot].
enum ShotLockMode {
  autoSpeaker,
  specificPerson,
  staticPosition,
}

/// Per-shot camera lock override applied in the Auto-Reframe editor.
class ShotTrackingOverride {
  final ShotLockMode mode;
  final int? targetSpeakerId;
  final double? staticX;
  final double? staticY;

  const ShotTrackingOverride({
    this.mode = ShotLockMode.autoSpeaker,
    this.targetSpeakerId,
    this.staticX,
    this.staticY,
  });

  ShotTrackingOverride copyWith({
    ShotLockMode? mode,
    int? targetSpeakerId,
    bool clearTargetSpeaker = false,
    double? staticX,
    double? staticY,
  }) {
    return ShotTrackingOverride(
      mode: mode ?? this.mode,
      targetSpeakerId:
          clearTargetSpeaker ? null : (targetSpeakerId ?? this.targetSpeakerId),
      staticX: staticX ?? this.staticX,
      staticY: staticY ?? this.staticY,
    );
  }
}

/// Continuous scene segment between detected hard cuts.
class SceneShot {
  final int id;
  final double startSec;
  final double endSec;

  const SceneShot({
    required this.id,
    required this.startSec,
    required this.endSec,
  });

  SceneShot copyWith({
    int? id,
    double? startSec,
    double? endSec,
  }) {
    return SceneShot(
      id: id ?? this.id,
      startSec: startSec ?? this.startSec,
      endSec: endSec ?? this.endSec,
    );
  }
}

/// A single timestamped subject anchor point in normalized [0..1] video space.
class FaceTrackPoint {
  final double timeSec;
  final double normX;
  final double normY;
  final double faceWidth;
  final double faceHeight;
  final bool isSpeaking;
  final int? speakerId;
  final bool isCut;
  final bool isManual;
  final bool isSmoothPan;

  const FaceTrackPoint({
    required this.timeSec,
    required this.normX,
    required this.normY,
    this.faceWidth = 0.14,
    this.faceHeight = 0.22,
    this.isSpeaking = false,
    this.speakerId,
    this.isCut = false,
    this.isManual = false,
    this.isSmoothPan = false,
  });

  FaceTrackPoint copyWith({
    double? timeSec,
    double? normX,
    double? normY,
    double? faceWidth,
    double? faceHeight,
    bool? isSpeaking,
    int? speakerId,
    bool? isCut,
    bool? isManual,
    bool? isSmoothPan,
  }) {
    return FaceTrackPoint(
      timeSec: timeSec ?? this.timeSec,
      normX: normX ?? this.normX,
      normY: normY ?? this.normY,
      faceWidth: faceWidth ?? this.faceWidth,
      faceHeight: faceHeight ?? this.faceHeight,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      speakerId: speakerId ?? this.speakerId,
      isCut: isCut ?? this.isCut,
      isManual: isManual ?? this.isManual,
      isSmoothPan: isSmoothPan ?? this.isSmoothPan,
    );
  }

  @override
  String toString() =>
      'FaceTrackPoint(t=${timeSec.toStringAsFixed(3)}, '
      'x=${normX.toStringAsFixed(3)}, y=${normY.toStringAsFixed(3)}, '
      'spk=$speakerId, cut=$isCut, manual=$isManual, pan=$isSmoothPan)';
}

/// Summary of a tracked speaker/subject identity discovered during analysis.
class DetectedSpeakerProfile {
  /// Index inside [FaceTrackResult.speakers], left-to-right by average X.
  final int id;
  final String label;
  final double avgNormX;
  final double avgNormY;
  final double avgFaceWidth;
  final double avgFaceHeight;
  final int sampleCount;
  final List<FaceTrackPoint> rawPoints;
  final double? speakingRatio;

  const DetectedSpeakerProfile({
    required this.id,
    required this.label,
    required this.avgNormX,
    required this.avgNormY,
    this.avgFaceWidth = 0.12,
    this.avgFaceHeight = 0.24,
    required this.sampleCount,
    required this.rawPoints,
    this.speakingRatio,
  });
}

/// Acoustic features extracted for a video-aligned analysis frame.
class AudioFrameFeatures {
  final double energy;
  final double speech;
  final double pitchHz;
  final double pitchClarity;
  final double bandLow;
  final double bandMid;
  final double bandHigh;
  final bool isSpeech;
  final int voiceClusterId;

  const AudioFrameFeatures({
    this.energy = 0.5,
    this.speech = 0.5,
    this.pitchHz = 0.0,
    this.pitchClarity = 0.0,
    this.bandLow = 0.33,
    this.bandMid = 0.34,
    this.bandHigh = 0.33,
    this.isSpeech = true,
    this.voiceClusterId = -1,
  });
}

class _VoiceCluster {
  final int id;
  double pitchHz;
  double bandLow;
  double bandMid;
  double bandHigh;
  int count = 1;

  _VoiceCluster({
    required this.id,
    required this.pitchHz,
    required this.bandLow,
    required this.bandMid,
    required this.bandHigh,
  });

  void update(AudioFrameFeatures f) {
    final alpha = (1.0 / min(18, count + 1)).clamp(0.05, 0.35);
    if (f.pitchHz > 65.0) {
      pitchHz = pitchHz > 65.0
          ? (1.0 - alpha) * pitchHz + alpha * f.pitchHz
          : f.pitchHz;
    }
    bandLow = (1.0 - alpha) * bandLow + alpha * f.bandLow;
    bandMid = (1.0 - alpha) * bandMid + alpha * f.bandMid;
    bandHigh = (1.0 - alpha) * bandHigh + alpha * f.bandHigh;
    count++;
  }

  double distanceTo(AudioFrameFeatures f) {
    final pitchDist = (f.pitchHz > 65.0 && pitchHz > 65.0)
        ? (log(f.pitchHz / pitchHz) / ln2).abs() * 1.55
        : 0.22;
    final dLow = (f.bandLow - bandLow).abs() * 1.2;
    final dMid = (f.bandMid - bandMid).abs();
    final dHigh = (f.bandHigh - bandHigh).abs() * 0.9;
    final specDist = (dLow + dMid + dHigh) * 0.55;
    return pitchDist * 0.75 + specDist * 0.25;
  }
}

/// Output of face + silhouette + active-speaker tracking across a clip.
class FaceTrackResult {
  final List<FaceTrackPoint> rawPoints;
  final List<FaceTrackPoint> keyframes;
  final double avgNormX;
  final double avgNormY;
  final int facesDetectedCount;
  final List<DetectedSpeakerProfile> speakers;
  final List<SceneShot> shots;
  final int sourceWidth;
  final int sourceHeight;

  const FaceTrackResult({
    required this.rawPoints,
    required this.keyframes,
    required this.avgNormX,
    required this.avgNormY,
    required this.facesDetectedCount,
    this.speakers = const [],
    this.shots = const [],
    this.sourceWidth = 0,
    this.sourceHeight = 0,
  });

  /// Samples the camera center at [timeSec], honoring hard-cut boundaries.
  (double normX, double normY) sampleAt(double timeSec) {
    return sampleKeyframes(keyframes, timeSec);
  }

  /// Linearly interpolates [keyframes] at [timeSec], snapping on cuts.
  static (double normX, double normY) sampleKeyframes(
    List<FaceTrackPoint> keyframes,
    double timeSec,
  ) {
    if (keyframes.isEmpty) return (0.5, 0.42);
    if (keyframes.length == 1) {
      return (keyframes.first.normX, keyframes.first.normY);
    }
    if (timeSec <= keyframes.first.timeSec) {
      return (keyframes.first.normX, keyframes.first.normY);
    }
    if (timeSec >= keyframes.last.timeSec) {
      return (keyframes.last.normX, keyframes.last.normY);
    }

    var lo = 0;
    var hi = keyframes.length - 1;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >> 1;
      if (keyframes[mid].timeSec <= timeSec) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final a = keyframes[lo];
    final b = keyframes[hi];
    if (FaceDetectionService.isEffectiveCut(a, b)) {
      if (timeSec < b.timeSec) {
        return (a.normX, a.normY);
      }
      return (b.normX, b.normY);
    }
    final span = b.timeSec - a.timeSec;
    if (span <= 0.0001) return (b.normX, b.normY);
    final t = ((timeSec - a.timeSec) / span).clamp(0.0, 1.0);
    return (
      a.normX + (b.normX - a.normX) * t,
      a.normY + (b.normY - a.normY) * t,
    );
  }
}

class _FrameCandidateObs {
  final _SpeakerTrack track;
  final double lipActivity;
  final double combinedScore;
  final double normX;
  final double normY;
  final double normW;
  final double normH;

  const _FrameCandidateObs({
    required this.track,
    required this.lipActivity,
    required this.combinedScore,
    required this.normX,
    required this.normY,
    required this.normW,
    required this.normH,
  });
}

class _FrameObservation {
  final int frameIndex;
  final double timeSec;
  final bool isSceneCut;
  final AudioFrameFeatures audio;
  final List<_FrameCandidateObs> candidates;

  const _FrameObservation({
    required this.frameIndex,
    required this.timeSec,
    required this.isSceneCut,
    required this.audio,
    required this.candidates,
  });
}

class _SpeakerTrack {
  final int id;
  int hits = 0;
  double lastSeenSec = -1.0;
  double normX = 0.5;
  double normY = 0.42;
  double normW = 0.14;
  double normH = 0.22;

  // Box edges and normalized appearance statistics in [0..1].
  double lastX0 = 0.4;
  double lastY0 = 0.25;
  double lastX1 = 0.6;
  double lastY1 = 0.55;
  double torsoX0 = 0.35;
  double torsoY0 = 0.55;
  double torsoX1 = 0.65;
  double torsoY1 = 0.90;
  double lastYawDeg = 0.0;

  double? prevAperture;
  double? prevInnerAperture;
  double? prevWidthRatio;
  double? prevContrast;
  double? prevRegionDelta;
  double lastLipRawDelta = 0.0;
  double lastMoveDelta = 0.0;
  double silhouetteActivity = 0.0;
  double areaWeight = 1.0;

  Uint8List? prevFaceCropRgba;
  bool isSilhouette = false;

  final List<double> recentLips = <double>[];
  final List<double> recentAudioEnergies = <double>[];
  final List<double> recentLipDeltas = <double>[];
  final List<double> recentSpeechScores = <double>[];

  double audioSyncScore = 0.5;
  final Map<int, double> voiceClusterWeights = <int, double>{};
  int? dominantVoiceCluster;
  int silentStreak = 0;
  bool wasSpeaking = false;

  List<double>? appearanceSig;
  List<double>? torsoSig;

  final List<FaceTrackPoint> points = <FaceTrackPoint>[];

  _SpeakerTrack(this.id);

  double voiceAffinityForCluster(int clusterId) {
    if (clusterId < 0) return 0.0;
    final hits = voiceClusterWeights[clusterId] ?? 0.0;
    if (hits < 1.15) return 0.0;
    var total = 0.0;
    for (final v in voiceClusterWeights.values) {
      total += v;
    }
    final share = total > 0 ? hits / total : 1.0;
    return (min(hits, 6.0) / 6.0) * (share * 0.7 + 0.3);
  }

  (double combinedScore, bool isSpeakingFrame) recordSpeechSample({
    required double lipActivity,
    required double mouthOpenness,
    required double yawDeg,
    required AudioFrameFeatures audio,
  }) {
    const window = 8;
    recentLips.add(lipActivity);
    if (recentLips.length > window) recentLips.removeAt(0);
    recentAudioEnergies.add(audio.energy);
    if (recentAudioEnergies.length > window) recentAudioEnergies.removeAt(0);
    recentLipDeltas.add((lipActivity - mouthOpenness).abs());
    if (recentLipDeltas.length > window) recentLipDeltas.removeAt(0);

    audioSyncScore = FaceDetectionService.computeAudioVisualSyncScore(
      recentLips,
      recentAudioEnergies,
    );

    final yawFactor = yawDeg.abs() >= 38.0
        ? 0.68
        : (1.0 - (yawDeg.abs() / 120.0)).clamp(0.75, 1.0);
    final avBoost = 0.72 + audioSyncScore * 0.4;

    double combined;
    if (audio.isSpeech) {
      final audioBlend =
          (0.55 * audio.energy + 0.45 * audio.speech).clamp(0.0, 1.0);
      combined = lipActivity * yawFactor * avBoost * (0.45 + 0.85 * audioBlend);
      if (mouthOpenness >= 0.015 && lipActivity >= 0.008) {
        combined = max(combined, lipActivity * 0.9);
      }
    } else {
      combined = lipActivity * 0.15;
    }

    recentSpeechScores.add(combined);
    if (recentSpeechScores.length > window) recentSpeechScores.removeAt(0);

    final speaking = audio.isSpeech && combined >= 0.012;
    if (speaking) {
      silentStreak = 0;
      wasSpeaking = true;
    } else {
      silentStreak++;
    }
    return (combined, speaking);
  }
}

/// Geometric bounds & confidence of a fallback dark-silhouette subject.
typedef SilhouetteSubject = ({
  double normX,
  double normY,
  double normW,
  double normH,
  double mass,
  bool sceneChanged,
});

/// Multimodal AI tracking service (faces, silhouettes, audio VAD & diarization)
/// powering podcast Auto-Reframe and Shorts face centering.
class FaceDetectionService {
  FaceDetectionService._();

  static const double defaultDeadZone = 0.045;
  static const double defaultSmoothness = 0.28;
  static const int maxKeyframes = 96;

  /// Spatial delta threshold (in normalized width) considered a speaker cut.
  static const double speakerJumpThreshold = 0.135;

  static const double associationDistance = 0.17;
  static const double minFaceOverlap = 0.1;
  static const double speakerLockSeconds = 0.5;
  static const int lipWindow = 4;

  static const int silhouetteGridWidth = 80;
  static const int silhouetteGridHeight = 45;
  static const double silhouetteSceneChangeThreshold = 16.0;
  static const double silhouetteRegionX0 = 0.0;
  static const double silhouetteRegionX1 = 1.0;
  static const double silhouetteRegionY0 = 0.12;
  static const double silhouetteRegionY1 = 0.92;
  static const int silhouetteMaxLuma = 24;
  static const int silhouetteNeighborhoodLuma = 28;
  static const int silhouetteMaxChannelSpread = 14;
  static const double silhouetteMinBackgroundLuma = 38;
  static const double silhouetteMinClusterFraction = 0.014;
  static const double silhouetteMaxClusterFraction = 0.48;
  static const double silhouetteMinBottomFraction = 0.52;
  static const double silhouetteMaxTopFraction = 0.65;
  static const double silhouetteMinHeightFraction = 0.15;
  static const double silhouetteMinWidthFraction = 0.055;
  static const double silhouetteMaxWidthFraction = 0.48;

  static const double emptyFrameCenterResetSec = 1.5;

  /// Shots with total spread within 4% collapse to a single locked camera point.
  static const double shotSteadyTolerance = 0.04;

  /// Manual edit matching window in seconds.
  static const double manualKeyframeToleranceSec = 0.12;

  static final RegExp _scdetRegex =
      RegExp(r'lavfi\.scd\.time:\s*([0-9]+(?:\.[0-9]+)?)');

  /// Runs the full multimodal speaker/subject tracking pipeline over a clip.
  static Future<FaceTrackResult?> analyzeVideoFaceTrack(
    String videoPath, {
    double startSec = 0,
    double? endSec,
    double? durationSec,
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    void Function(double progress, String status)? onProgress,
  }) async {
    final source = await _probeSource(videoPath);
    final resolvedReqDuration = durationSec ??
        (endSec != null && endSec > startSec ? endSec - startSec : null);
    final clipDuration = _resolveClipDuration(
      probedDurationSec: source.durationSec,
      startSec: startSec,
      requestedDurationSec: resolvedReqDuration,
    );
    if (clipDuration == null || clipDuration <= 0) {
      AppLogger().e('FaceTrack: unknown clip duration for $videoPath');
      return null;
    }

    final sampleFps = clipDuration <= 150.0
        ? 5.0
        : (clipDuration <= 300.0 ? 4.0 : max(2.5, 600.0 / clipDuration));
    final expectedFrames = max(2, (clipDuration * sampleFps).ceil());

    final tmpBase = await getTemporaryDirectory();
    final framesDir = Directory(
      '${tmpBase.path}/reframe_frames_${DateTime.now().millisecondsSinceEpoch}',
    );
    await framesDir.create(recursive: true);

    final landmarkDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableClassification: true,
        enableTracking: true,
        minFaceSize: 0.04,
      ),
    );
    final contourDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableContours: true,
        enableLandmarks: true,
        minFaceSize: 0.1,
      ),
    );

    try {
      onProgress?.call(0.05, 'جاري تحليل الصوت واستخراج الإطارات...');

      final audioFuture = _extractAndAnalyzeAudio(
        videoPath: videoPath,
        startSec: startSec,
        durationSec: clipDuration,
        workDir: framesDir,
        targetFrames: expectedFrames,
      );

      final scdetCmd =
          '-ss ${startSec.toStringAsFixed(3)} '
          '-t ${clipDuration.toStringAsFixed(3)} '
          '-i "$videoPath" '
          '-vf "scale=960:-2:flags=fast_bilinear,scdet=t=18,fps=$sampleFps:round=up" '
          '-q:v 3 -y "${framesDir.path}/frame_%04d.jpg"';

      var session = await FFmpegKit.execute(scdetCmd);
      var rc = await session.getReturnCode();
      final detectedCuts = <double>[];

      if (ReturnCode.isSuccess(rc)) {
        final logs = await session.getAllLogsAsString() ?? '';
        for (final match in _scdetRegex.allMatches(logs)) {
          final ts = double.tryParse(match.group(1) ?? '');
          if (ts == null) continue;
          if (detectedCuts.isEmpty || ts - detectedCuts.last >= 0.25) {
            detectedCuts.add(ts);
          }
        }
      } else {
        final fallbackCmd =
            '-ss ${startSec.toStringAsFixed(3)} '
            '-t ${clipDuration.toStringAsFixed(3)} '
            '-i "$videoPath" '
            '-vf "fps=$sampleFps:round=up,scale=960:-2" '
            '-q:v 3 -y "${framesDir.path}/frame_%04d.jpg"';
        session = await FFmpegKit.execute(fallbackCmd);
        rc = await session.getReturnCode();
        if (!ReturnCode.isSuccess(rc)) {
          await audioFuture;
          return null;
        }
      }

      final audioFrames = await audioFuture;
      final frameFiles = framesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      if (frameFiles.isEmpty) {
        return FaceTrackResult(
          rawPoints: const <FaceTrackPoint>[],
          keyframes: const <FaceTrackPoint>[],
          avgNormX: 0.5,
          avgNormY: 0.42,
          facesDetectedCount: 0,
          shots: _buildShotsFromBoundaries(clipDuration, detectedCuts),
          sourceWidth: source.width,
          sourceHeight: source.height,
        );
      }

      final tracks = <int, _SpeakerTrack>{};
      var nextTrackId = 0;
      Uint8List? prevSilGrid;
      Uint8List? prevMouthGrid;
      var cutCursor = 0;

      final frameObsList = <_FrameObservation>[];
      var lastX = 0.5;
      var lastY = 0.42;

      for (var i = 0; i < frameFiles.length; i++) {
        final file = frameFiles[i];
        final timeSec = min(clipDuration, i / sampleFps);

        var isCut = false;
        while (cutCursor < detectedCuts.length &&
            detectedCuts[cutCursor] <= timeSec + (0.5 / sampleFps)) {
          if ((detectedCuts[cutCursor] - timeSec).abs() <= (1.0 / sampleFps) ||
              detectedCuts[cutCursor] <= timeSec) {
            isCut = true;
          }
          cutCursor++;
        }

        final decoded = await _decodeAnalysisGrids(file);
        if (decoded == null) continue;
        final imgW = decoded.width;
        final imgH = decoded.height;
        final silGrid = decoded.silhouetteGrid;
        final mouthGrid = decoded.mouthGrid;
        final fullRgba = decoded.fullRgba;

        final sceneChangedByLuma = isSceneChange(
          prevSilGrid,
          silGrid,
          silhouetteGridWidth,
          silhouetteGridHeight,
        );
        final effectiveCut = i > 0 && (isCut || sceneChangedByLuma);

        final inputImage = InputImage.fromFilePath(file.path);
        var faces = await landmarkDetector.processImage(inputImage);

        final missingContours = faces.any((f) {
          final up = f.contours[FaceContourType.upperLipBottom]?.points;
          final lo = f.contours[FaceContourType.lowerLipTop]?.points;
          return up == null || up.length < 3 || lo == null || lo.length < 3;
        });

        List<Face> contourFaces = const <Face>[];
        if (faces.isNotEmpty && (faces.length >= 2 || missingContours)) {
          if (faces.length == 1) {
            contourFaces = await contourDetector.processImage(inputImage);
          }
        }

        final audio = i < audioFrames.length
            ? audioFrames[i]
            : const AudioFrameFeatures();

        final visibleTracks = <_SpeakerTrack>[];
        final candidates = <_FrameCandidateObs>[];
        final excludeRects = <({double x0, double y0, double x1, double y1})>[];

        for (var fi = 0; fi < faces.length; fi++) {
          final face = faces[fi];
          final box = face.boundingBox;
          final cx = (box.center.dx / imgW).clamp(0.0, 1.0);
          final cy = (box.center.dy / imgH).clamp(0.0, 1.0);
          final fw = (box.width / imgW).clamp(0.04, 0.9);
          final fh = (box.height / imgH).clamp(0.06, 0.95);
          final x0 = (box.left / imgW).clamp(0.0, 1.0);
          final y0 = (box.top / imgH).clamp(0.0, 1.0);
          final x1 = (box.right / imgW).clamp(0.0, 1.0);
          final y1 = (box.bottom / imgH).clamp(0.0, 1.0);

          excludeRects.add((x0: x0, y0: y0, x1: x1, y1: y1));

          final tx0 = (cx - fw * 1.05).clamp(0.0, 1.0);
          final tx1 = (cx + fw * 1.05).clamp(0.0, 1.0);
          final ty0 = (y1 + fh * 0.05).clamp(0.0, 0.96);
          final ty1 = min(1.0, max(ty0 + 0.03, y1 + fh * 1.4));

          final appSig = _extractRegionSignature(
            silGrid,
            silhouetteGridWidth,
            silhouetteGridHeight,
            x0,
            y0,
            x1,
            y1,
          );
          final torsoSig = _extractRegionSignature(
            silGrid,
            silhouetteGridWidth,
            silhouetteGridHeight,
            tx0,
            ty0,
            tx1,
            ty1,
          );

          var track = _associateFace(
            tracks.values,
            cx: cx,
            cy: cy,
            x0: x0,
            y0: y0,
            x1: x1,
            y1: y1,
            nowSec: timeSec,
            allowCrossCut: !effectiveCut,
            appSig: appSig,
            torsoSig: torsoSig,
          );
          if (track == null) {
            track = _SpeakerTrack(nextTrackId++);
            tracks[track.id] = track;
          }

          Face contourSource = face;
          final hasUp =
              (face.contours[FaceContourType.upperLipBottom]?.points.length ??
                      0) >=
                  3;
          final hasLo =
              (face.contours[FaceContourType.lowerLipTop]?.points.length ??
                      0) >=
                  3;
          if (!hasUp || !hasLo) {
            Face? matchedContour;
            if (contourFaces.isNotEmpty) {
              var bestOvl = 0.0;
              for (final cf in contourFaces) {
                final cb = cf.boundingBox;
                final ovl = _boxOverlap(
                  x0,
                  y0,
                  x1,
                  y1,
                  (cb.left / imgW).clamp(0.0, 1.0),
                  (cb.top / imgH).clamp(0.0, 1.0),
                  (cb.right / imgW).clamp(0.0, 1.0),
                  (cb.bottom / imgH).clamp(0.0, 1.0),
                );
                if (ovl > bestOvl) {
                  bestOvl = ovl;
                  matchedContour = cf;
                }
              }
            }
            matchedContour ??= await _detectContoursOnFaceCrop(
              detector: contourDetector,
              fullRgba: fullRgba,
              imageWidth: imgW,
              imageHeight: imgH,
              faceBox: box,
              workDir: framesDir,
              frameIndex: i,
              faceIndex: fi,
            );
            if (matchedContour != null) {
              contourSource = matchedContour;
            }
          }

          final lipDelta = _updateLipActivity(
            track: track,
            face: face,
            contourFace: contourSource,
            imageWidth: imgW,
            imageHeight: imgH,
            mouthGrid: mouthGrid,
            prevMouthGrid: prevMouthGrid,
            mouthGridWidth: 240,
            mouthGridHeight: 135,
            nx0: x0,
            ny0: y0,
            nx1: x1,
            ny1: y1,
            isCut: effectiveCut,
          );

          _updateTrack(
            track,
            timeSec: timeSec,
            cx: cx,
            cy: cy,
            w: fw,
            h: fh,
            x0: x0,
            y0: y0,
            x1: x1,
            y1: y1,
            tx0: tx0,
            ty0: ty0,
            tx1: tx1,
            ty1: ty1,
            yawDeg: face.headEulerAngleY ?? 0.0,
            appSig: appSig,
            torsoSig: torsoSig,
          );

          final speechEval = track.recordSpeechSample(
            lipActivity: lipDelta.activity,
            mouthOpenness: lipDelta.aperture,
            yawDeg: face.headEulerAngleY ?? 0.0,
            audio: audio,
          );

          visibleTracks.add(track);
          candidates.add(
            _FrameCandidateObs(
              track: track,
              lipActivity: lipDelta.activity,
              combinedScore: speechEval.$1,
              normX: cx,
              normY: cy,
              normW: fw,
              normH: fh,
            ),
          );
        }

        // Fallback silhouette detection when screen is empty or asymmetric single face.
        double silMinX = silhouetteRegionX0;
        double silMaxX = silhouetteRegionX1;
        var shouldCheckSil = visibleTracks.isEmpty;
        if (!shouldCheckSil && visibleTracks.length == 1) {
          final vx = visibleTracks.first.normX;
          if (vx < 0.32) {
            shouldCheckSil = true;
            silMinX = 0.52;
            silMaxX = 1.0;
          } else if (vx > 0.68) {
            shouldCheckSil = true;
            silMinX = 0.0;
            silMaxX = 0.48;
          }
        }

        if (shouldCheckSil) {
          final silSub = detectSilhouetteOrMotionSubject(
            silGrid,
            silhouetteGridWidth,
            silhouetteGridHeight,
            effectiveCut ? null : prevSilGrid,
            minX: silMinX,
            maxX: silMaxX,
            excludeRects: excludeRects,
          );
          if (silSub != null) {
            final motion = effectiveCut || prevSilGrid == null
                ? 0.0
                : _silhouetteMotionActivity(
                    prevSilGrid,
                    silGrid,
                    silhouetteGridWidth,
                    silhouetteGridHeight,
                    cx: silSub.normX,
                    cy: silSub.normY,
                    w: silSub.normW,
                    h: silSub.normH,
                  );
            if (motion < 0.055 || visibleTracks.isEmpty) {
              var silTrack = _associateSilhouette(
                tracks.values,
                normX: silSub.normX,
                normY: silSub.normY,
                timeSec: timeSec,
              );
              if (silTrack == null) {
                silTrack = _SpeakerTrack(nextTrackId++)..isSilhouette = true;
                tracks[silTrack.id] = silTrack;
              }
              silTrack.hits++;
              silTrack.lastSeenSec = timeSec;
              silTrack.normX = silSub.normX;
              silTrack.normY = silSub.normY;
              silTrack.normW = silSub.normW;
              silTrack.normH = silSub.normH;
              silTrack.silhouetteActivity = motion;
              final score = (audio.isSpeech ? 0.025 : 0.008) + motion * 0.4;
              silTrack.recordSpeechSample(
                lipActivity: motion * 0.25,
                mouthOpenness: motion * 0.2,
                yawDeg: 0.0,
                audio: audio,
              );
              candidates.add(
                _FrameCandidateObs(
                  track: silTrack,
                  lipActivity: motion * 0.25,
                  combinedScore: score,
                  normX: silSub.normX,
                  normY: silSub.normY,
                  normW: silSub.normW,
                  normH: silSub.normH,
                ),
              );
              visibleTracks.add(silTrack);
            }
          }
        }

        // Brief torso coasting for temporarily turned/occluded tracks.
        if (!effectiveCut) {
          for (final t in tracks.values) {
            if (t.isSilhouette || visibleTracks.contains(t) || t.hits < 2) {
              continue;
            }
            final dt = timeSec - t.lastSeenSec;
            if (dt <= 0 || dt > 2.2) continue;
            final coast = _coastUnseenTrackViaTorso(
              t,
              silGrid,
              silhouetteGridWidth,
              silhouetteGridHeight,
            );
            if (coast != null) {
              t.lastSeenSec = timeSec;
              t.normX = coast.cx;
              t.normY = coast.cy;
              final decayScore =
                  (t.recentSpeechScores.isNotEmpty ? t.recentSpeechScores.last : 0.0) *
                      0.55;
              final decayLip =
                  (t.recentLips.isNotEmpty ? t.recentLips.last : 0.0) * 0.55;
              candidates.add(
                _FrameCandidateObs(
                  track: t,
                  lipActivity: decayLip,
                  combinedScore: decayScore,
                  normX: coast.cx,
                  normY: coast.cy,
                  normW: t.normW,
                  normH: t.normH,
                ),
              );
            }
          }
        }

        if (candidates.isNotEmpty) {
          lastX = candidates.first.normX;
          lastY = candidates.first.normY;
        }

        frameObsList.add(
          _FrameObservation(
            frameIndex: i,
            timeSec: timeSec,
            isSceneCut: effectiveCut,
            audio: audio,
            candidates: candidates,
          ),
        );

        prevSilGrid = silGrid;
        prevMouthGrid = mouthGrid;

        if (onProgress != null && (i % 5 == 0 || i == frameFiles.length - 1)) {
          onProgress(
            0.15 + 0.72 * ((i + 1) / frameFiles.length),
            'جاري تتبع الوجوه والمشهد (${i + 1}/${frameFiles.length})...',
          );
        }
      }

      _enrollGlobalVoiceAndAppearance(tracks, frameObsList);

      final rawPoints = _resolveTwoPassDeterministicTrajectory(
        frameObsList,
        tracks,
        clipDuration: clipDuration,
        defaultX: lastX,
        defaultY: lastY,
      );

      final shots = _buildShotsFromBoundaries(clipDuration, detectedCuts);
      final profiles = _buildProfiles(tracks, rawPoints);
      final keyframes = buildKeyframes(
        rawPoints,
        deadZone: deadZone,
        smoothness: smoothness,
        maxKeyframes: maxKeyframes,
      );

      onProgress?.call(1.0, '✅ اكتمل تتبع المتكلم والبصمة الصوتية');
      AppLogger().i(
        'FaceTrack: ${frameObsList.length} frames, ${profiles.length} people, '
        '${shots.length} shots, ${tracks.length} faces, ${keyframes.length} keyframes',
      );

      return FaceTrackResult(
        rawPoints: rawPoints,
        keyframes: keyframes,
        avgNormX: lastX,
        avgNormY: lastY,
        facesDetectedCount: frameObsList.length,
        speakers: profiles,
        shots: shots,
        sourceWidth: source.width,
        sourceHeight: source.height,
      );
    } catch (e, st) {
      AppLogger().e('FaceTrack failed: $e\n$st');
      return null;
    } finally {
      await landmarkDetector.close();
      await contourDetector.close();
      if (await framesDir.exists()) {
        await framesDir.delete(recursive: true);
      }
    }
  }

  /// Splits [durationSec] into contiguous [SceneShot] intervals from cut times.
  static List<SceneShot> _buildShotsFromBoundaries(
    double durationSec,
    List<double> cutTimestamps,
  ) {
    final sorted = cutTimestamps
        .where((t) => t > 0.1 && t < durationSec - 0.1)
        .toList()
      ..sort();

    final shots = <SceneShot>[];
    var cursor = 0.0;
    for (final cut in sorted) {
      if (cut - cursor < 0.1) continue;
      shots.add(SceneShot(id: shots.length, startSec: cursor, endSec: cut));
      cursor = cut;
    }
    shots.add(
      SceneShot(
        id: shots.length,
        startSec: cursor,
        endSec: max(cursor + 0.1, durationSec),
      ),
    );
    return List<SceneShot>.unmodifiable(List<SceneShot>.from(shots));
  }

  static List<DetectedSpeakerProfile> _buildProfiles(
    Map<int, _SpeakerTrack> tracks,
    List<FaceTrackPoint> rawPoints,
  ) {
    final validTracks = tracks.values
        .where((t) => t.points.isNotEmpty || t.hits >= 2)
        .toList()
      ..sort((a, b) => a.normX.compareTo(b.normX));

    if (validTracks.isEmpty) return const <DetectedSpeakerProfile>[];

    // Group temporally disjoint tracks that represent the same person.
    final groups = <List<_SpeakerTrack>>[];
    for (final track in validTracks) {
      List<_SpeakerTrack>? target;
      for (final g in groups) {
        final rep = g.first;
        if (rep.isSilhouette != track.isSilhouette) continue;
        if (_tracksOverlapInTime(rep, track)) continue;
        final dx = (rep.normX - track.normX).abs();
        final appSim = _signatureSimilarity(rep.appearanceSig, track.appearanceSig);
        if ((dx < 0.17 && (appSim >= 0.78 || track.isSilhouette)) ||
            appSim >= 0.88) {
          target = g;
          break;
        }
      }
      if (target != null) {
        target.add(track);
      } else {
        groups.add(<_SpeakerTrack>[track]);
      }
    }

    groups.sort((a, b) {
      final ax = a.map((t) => t.normX).reduce((x, y) => x + y) / a.length;
      final bx = b.map((t) => t.normX).reduce((x, y) => x + y) / b.length;
      return ax.compareTo(bx);
    });

    final profiles = <DetectedSpeakerProfile>[];
    final total = min(maxProfiles, groups.length);
    for (var i = 0; i < total; i++) {
      final g = groups[i];
      final mergedPoints = <FaceTrackPoint>[];
      var trackedFrames = 0;
      var speakingFrames = 0;
      var sumX = 0.0;
      var sumY = 0.0;

      for (final t in g) {
        for (final p in t.points) {
          mergedPoints.add(p.copyWith(speakerId: i));
        }
        trackedFrames += t.points.length;
        speakingFrames += t.points.where((p) => p.isSpeaking).length;
        sumX += t.normX;
        sumY += t.normY;
      }
      mergedPoints.sort((a, b) => a.timeSec.compareTo(b.timeSec));

      final avgX = mergedPoints.isNotEmpty
          ? mergedPoints.map((p) => p.normX).reduce((a, b) => a + b) /
              mergedPoints.length
          : sumX / g.length;
      final avgY = mergedPoints.isNotEmpty
          ? mergedPoints.map((p) => p.normY).reduce((a, b) => a + b) /
              mergedPoints.length
          : sumY / g.length;
      final avgW = mergedPoints.isNotEmpty
          ? mergedPoints.map((p) => p.faceWidth).reduce((a, b) => a + b) /
              mergedPoints.length
          : 0.12;
      final avgH = mergedPoints.isNotEmpty
          ? mergedPoints.map((p) => p.faceHeight).reduce((a, b) => a + b) /
              mergedPoints.length
          : 0.24;

      final speakingRatio = trackedFrames > 0
          ? (speakingFrames / trackedFrames).clamp(0.0, 1.0)
          : null;

      profiles.add(
        DetectedSpeakerProfile(
          id: i,
          label: _speakerLabel(i, total),
          avgNormX: avgX,
          avgNormY: avgY,
          avgFaceWidth: avgW,
          avgFaceHeight: avgH,
          sampleCount: mergedPoints.length,
          rawPoints: List<FaceTrackPoint>.unmodifiable(mergedPoints),
          speakingRatio: speakingRatio,
        ),
      );
    }
    return List<DetectedSpeakerProfile>.unmodifiable(profiles);
  }

  static const int maxProfiles = 4;
  static const double profileMergeDistance = 0.18;

  static String _speakerLabel(int index, int total) {
    if (total <= 1) return 'الشخص 1';
    if (total == 2) return index == 0 ? 'المتكلم الأيسر' : 'المتكلم الأيمن';
    return 'المتكلم ${index + 1}';
  }

  static double _signatureSimilarity(List<double>? a, List<double>? b) {
    if (a == null || b == null || a.length != b.length || a.isEmpty) {
      return 0.5;
    }
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    final denom = sqrt(normA * normB);
    if (denom <= 1e-8) return 0.5;
    return (dot / denom).clamp(0.0, 1.0);
  }

  static bool _tracksOverlapInTime(_SpeakerTrack a, _SpeakerTrack b) {
    if (a.points.isEmpty || b.points.isEmpty) return false;
    final aStart = a.points.first.timeSec;
    final aEnd = a.points.last.timeSec;
    final bStart = b.points.first.timeSec;
    final bEnd = b.points.last.timeSec;
    return aStart <= bEnd && bStart <= aEnd;
  }

  static void _enrollGlobalVoiceAndAppearance(
    Map<int, _SpeakerTrack> tracks,
    List<_FrameObservation> frames,
  ) {
    final validTracks = tracks.values
        .where((t) => !t.isSilhouette && t.points.isNotEmpty)
        .toList();
    if (validTracks.isEmpty) return;

    final trackToGroup = <int, int>{};
    final groups = <List<_SpeakerTrack>>[];

    for (final track in validTracks) {
      var bestGroupIdx = -1;
      var bestSim = 0.0;
      for (var gi = 0; gi < groups.length; gi++) {
        final rep = groups[gi].first;
        final overlap = _tracksOverlapInTime(rep, track);
        final sim = 0.62 * _signatureSimilarity(rep.appearanceSig, track.appearanceSig) +
            0.38 * _signatureSimilarity(rep.torsoSig, track.torsoSig);
        final minSim = overlap ? 0.88 : 0.80;
        if (sim >= minSim && sim > bestSim) {
          bestSim = sim;
          bestGroupIdx = gi;
        }
      }
      if (bestGroupIdx >= 0) {
        groups[bestGroupIdx].add(track);
        trackToGroup[track.id] = bestGroupIdx;
      } else {
        trackToGroup[track.id] = groups.length;
        groups.add(<_SpeakerTrack>[track]);
      }
    }

    final groupHist = <int, Map<int, double>>{
      for (var gi = 0; gi < groups.length; gi++) gi: <int, double>{},
    };
    final groupHits = <int, int>{for (var gi = 0; gi < groups.length; gi++) gi: 0};

    for (final frame in frames) {
      if (!frame.audio.isSpeech || frame.audio.voiceClusterId < 0) continue;
      final clusterId = frame.audio.voiceClusterId;
      final obs = frame.candidates
          .where((c) => !c.track.isSilhouette)
          .toList();
      if (obs.isEmpty) continue;

      if (obs.length == 1) {
        final c = obs.first;
        final gid = trackToGroup[c.track.id];
        if (gid == null) continue;
        final open = c.track.prevAperture ?? 0.0;
        if (c.lipActivity >= 0.0085 || open >= 0.0095 || frame.audio.speech >= 0.26) {
          final hist = groupHist[gid]!;
          hist[clusterId] = min(14.0, (hist[clusterId] ?? 0.0) + 1.05);
          groupHits[gid] = (groupHits[gid] ?? 0) + 1;
        }
        continue;
      }

      _FrameCandidateObs? best;
      var bestScore = 0.0;
      var runnerUp = 0.0;
      for (final c in obs) {
        final s = c.lipActivity * (0.65 * frame.audio.speech + 0.35);
        if (s > bestScore) {
          runnerUp = bestScore;
          bestScore = s;
          best = c;
        } else if (s > runnerUp) {
          runnerUp = s;
        }
      }

      if (best != null &&
          bestScore >= 0.011 &&
          frame.audio.speech >= 0.38 &&
          bestScore >= runnerUp * 1.35 + 0.0025) {
        final gid = trackToGroup[best.track.id];
        if (gid != null) {
          final hist = groupHist[gid]!;
          hist[clusterId] = min(14.0, (hist[clusterId] ?? 0.0) + 0.9);
          groupHits[gid] = (groupHits[gid] ?? 0) + 1;
        }
        for (final other in obs) {
          if (other.track.id == best.track.id) continue;
          final ogid = trackToGroup[other.track.id];
          if (ogid == null) continue;
          final oHist = groupHist[ogid]!;
          final cur = oHist[clusterId] ?? 0.0;
          if (cur > 0.0) {
            oHist[clusterId] = max(0.0, cur - 0.22);
          }
        }
      } else if (obs.every((c) => c.lipActivity < 0.0105 && (c.track.prevAperture ?? 0.0) < 0.011)) {
        // Unvoiced/silent visemes in multi-person frame do not teach clusters.
        continue;
      }
    }

    for (var gi = 0; gi < groups.length; gi++) {
      final hist = groupHist[gi]!;
      var bestCluster = -1;
      var bestVal = 0.7;
      for (final entry in hist.entries) {
        if (entry.value > bestVal) {
          bestVal = entry.value;
          bestCluster = entry.key;
        }
      }
      for (final track in groups[gi]) {
        track.voiceClusterWeights
          ..clear()
          ..addAll(hist);
        if (bestCluster >= 0) {
          track.dominantVoiceCluster = bestCluster;
        }
      }
    }
  }

  static List<FaceTrackPoint> _resolveTwoPassDeterministicTrajectory(
    List<_FrameObservation> frames,
    Map<int, _SpeakerTrack> tracks, {
    required double clipDuration,
    required double defaultX,
    required double defaultY,
  }) {
    if (frames.isEmpty) return const <FaceTrackPoint>[];

    // Partition into continuous camera shots at scene boundaries.
    final shotSlices = <List<_FrameObservation>>[];
    var curSlice = <_FrameObservation>[];
    for (final f in frames) {
      if (f.isSceneCut && curSlice.isNotEmpty) {
        shotSlices.add(curSlice);
        curSlice = <_FrameObservation>[];
      }
      curSlice.add(f);
    }
    if (curSlice.isNotEmpty) shotSlices.add(curSlice);

    final out = <FaceTrackPoint>[];
    var smoothX = defaultX;
    var smoothY = defaultY;
    _SpeakerTrack? prevShotTrack;

    for (var shotIdx = 0; shotIdx < shotSlices.length; shotIdx++) {
      final shot = shotSlices[shotIdx];
      final n = shot.length;
      if (n == 0) continue;

      final shotTracks = <_SpeakerTrack>[];
      final trackIdx = <int, int>{};
      for (final f in shot) {
        for (final c in f.candidates) {
          if (!trackIdx.containsKey(c.track.id)) {
            trackIdx[c.track.id] = shotTracks.length;
            shotTracks.add(c.track);
          }
        }
      }

      if (shotTracks.isEmpty) {
        for (var f = 0; f < n; f++) {
          final obs = shot[f];
          out.add(
            FaceTrackPoint(
              timeSec: obs.timeSec,
              normX: smoothX,
              normY: smoothY,
              isCut: shotIdx > 0 && f == 0,
            ),
          );
        }
        prevShotTrack = null;
        continue;
      }

      final tCount = shotTracks.length;
      final lipGrid = List<List<double>>.generate(
        tCount,
        (_) => List<double>.filled(n, 0.0),
      );
      final rawScores = List<List<double>>.generate(
        tCount,
        (_) => List<double>.filled(n, 0.0),
      );
      final present = List<List<bool>>.generate(
        tCount,
        (_) => List<bool>.filled(n, false),
      );
      final xGrid = List<List<double>>.generate(
        tCount,
        (ti) => List<double>.filled(n, shotTracks[ti].normX),
      );
      final yGrid = List<List<double>>.generate(
        tCount,
        (ti) => List<double>.filled(n, shotTracks[ti].normY),
      );
      final wGrid = List<List<double>>.generate(
        tCount,
        (ti) => List<double>.filled(n, shotTracks[ti].normW),
      );
      final hGrid = List<List<double>>.generate(
        tCount,
        (ti) => List<double>.filled(n, shotTracks[ti].normH),
      );

      for (var f = 0; f < n; f++) {
        final frame = shot[f];
        final cid = frame.audio.voiceClusterId;
        for (final c in frame.candidates) {
          final ti = trackIdx[c.track.id]!;
          present[ti][f] = true;
          lipGrid[ti][f] = c.lipActivity;
          xGrid[ti][f] = c.normX;
          yGrid[ti][f] = c.normY;
          wGrid[ti][f] = c.normW;
          hGrid[ti][f] = c.normH;

          var s = c.combinedScore;
          if (!c.track.isSilhouette && cid >= 0) {
            final aff = c.track.voiceAffinityForCluster(cid);
            if (aff > 0) {
              s *= (0.45 * aff + 0.72 + min(0.18, c.track.audioSyncScore * 2.5));
            } else if (c.track.dominantVoiceCluster != null &&
                c.track.dominantVoiceCluster != cid) {
              s *= (0.42 * (1.0 - aff) + 0.58);
            }
          }
          rawScores[ti][f] = s;
        }
      }

      // Detect panel boundaries (2-panel or 3-panel split layouts).
      final shotMeanX = List<double>.filled(tCount, 0.5);
      for (var ti = 0; ti < tCount; ti++) {
        var sx = 0.0;
        var cnt = 0;
        for (var f = 0; f < n; f++) {
          if (present[ti][f]) {
            sx += xGrid[ti][f];
            cnt++;
          }
        }
        shotMeanX[ti] = cnt > 0 ? sx / cnt : shotTracks[ti].normX;
      }

      final sortedByX = List<int>.generate(tCount, (i) => i)
        ..sort((a, b) => shotMeanX[a].compareTo(shotMeanX[b]));
      final isTwoPanel = tCount == 2 &&
          shotMeanX[sortedByX[0]] < 0.42 &&
          shotMeanX[sortedByX[1]] > 0.58;
      final isThreePanel = tCount == 3 &&
          shotMeanX[sortedByX[0]] < 0.36 &&
          shotMeanX[sortedByX[1]] >= 0.33 &&
          shotMeanX[sortedByX[1]] <= 0.67 &&
          shotMeanX[sortedByX[2]] > 0.64;

      double clampPanelSafeX(int ti, double rawX) {
        if (isTwoPanel) {
          final rank = sortedByX.indexOf(ti);
          if (rank == 0) return rawX.clamp(0.08, 0.49);
          return rawX.clamp(0.51, 0.92);
        }
        if (isThreePanel) {
          final rank = sortedByX.indexOf(ti);
          if (rank == 0) return rawX.clamp(0.08, 0.36);
          if (rank == 1) return rawX.clamp(0.32, 0.68);
          return rawX.clamp(0.64, 0.92);
        }
        return rawX.clamp(0.05, 0.95);
      }

      // Compute smooth scores and speech modulation bonus across 5-frame windows.
      final smoothScores = List<List<double>>.generate(
        tCount,
        (_) => List<double>.filled(n, 0.0),
      );
      final lookaheadScores = List<List<double>>.generate(
        tCount,
        (_) => List<double>.filled(n, 0.0),
      );

      for (var ti = 0; ti < tCount; ti++) {
        for (var f = 0; f < n; f++) {
          var sum = 0.0;
          var cnt = 0;
          final deltas = <double>[];
          for (var k = max(0, f - 2); k <= min(n - 1, f + 2); k++) {
            if (!shot[k].audio.isSpeech) continue;
            sum += rawScores[ti][k];
            cnt++;
            if (present[ti][k]) deltas.add(lipGrid[ti][k]);
          }
          var avg = cnt > 0 ? sum / cnt : rawScores[ti][f];
          if (!shotTracks[ti].isSilhouette && deltas.length >= 3) {
            final meanD = deltas.reduce((a, b) => a + b) / deltas.length;
            if (meanD >= 0.04) {
              var vSum = 0.0;
              for (final d in deltas) {
                vSum += (d - meanD) * (d - meanD);
              }
              final stdD = sqrt(vSum / deltas.length);
              final modBonus = (meanD / 0.22).clamp(0.0, 1.0) *
                  (stdD / 0.02).clamp(0.0, 0.22);
              avg += modBonus;
            }
          }
          smoothScores[ti][f] = avg;

          var fwSum = 0.0;
          var fwW = 0.0;
          for (var k = f; k <= min(n - 1, f + 2); k++) {
            if (!shot[k].audio.isSpeech && k > f) break;
            final w = k == f ? 1.25 : 1.0;
            fwSum += rawScores[ti][k] * w;
            fwW += w;
          }
          lookaheadScores[ti][f] = fwW > 0 ? fwSum / fwW : avg;
        }
      }

      // Initial active track from early speaking frames (up to 6 frames).
      var initTrack = 0;
      var bestInit = -1.0;
      for (var ti = 0; ti < tCount; ti++) {
        var total = 0.0;
        var seen = 0;
        for (var f = 0; f < min(n, 7); f++) {
          if (shot[f].audio.isSpeech && seen < 6) {
            total += smoothScores[ti][f];
            seen++;
          }
        }
        if (total == 0.0) {
          for (var f = 0; f < min(n, 4); f++) {
            total += smoothScores[ti][f];
          }
        }
        if (total > bestInit) {
          bestInit = total;
          initTrack = ti;
        }
      }

      // Pass 1: causal hysteresis state machine with lip-silence onset lookahead.
      final pass1 = List<int>.filled(n, initTrack);
      var cur = initTrack;
      var holdCount = 1;
      var streak = 0;
      const speechLookahead = 3;

      bool isCurrentSilentAt(int f, int tIdx) {
        if (!present[tIdx][f]) return true;
        return lipGrid[tIdx][f] < 0.011;
      }

      for (var f = 1; f < n; f++) {
        var best = cur;
        var bestSc = -1.0;
        for (var ti = 0; ti < tCount; ti++) {
          if (lookaheadScores[ti][f] > bestSc) {
            bestSc = lookaheadScores[ti][f];
            best = ti;
          }
        }

        if (best != cur && shot[f].audio.isSpeech) {
          final curSilent = isCurrentSilentAt(f, cur);
          final candOnset = lipGrid[best][f] >= 0.014;
          final minWins = (speechLookahead - 1).clamp(curSilent && candOnset ? 1 : 2, curSilent && candOnset ? 2 : 3);
          final minHold = curSilent && candOnset ? 4 : 6;
          final minStreak = curSilent && candOnset ? 2 : 4;

          var winCount = 0;
          for (var k = f; k < min(n, f + speechLookahead); k++) {
            if (lookaheadScores[best][k] > lookaheadScores[cur][k] * 1.1 + 0.03) {
              winCount++;
            }
          }

          final curScore = lookaheadScores[cur][f];
          final candScore = lookaheadScores[best][f];
          final bigMargin = candScore >= 0.18 && candScore > curScore * 1.1 + 0.03;

          if (bigMargin && winCount >= minWins) {
            streak++;
          } else {
            streak = 0;
          }

          if ((holdCount >= minHold || !present[cur][f]) && streak >= minStreak) {
            if (f >= 3 && holdCount >= 3 && isCurrentSilentAt(f - 1, cur)) {
              pass1[f - 1] = best;
            }
            cur = best;
            holdCount = 1;
            streak = 0;
          } else {
            holdCount++;
          }
        } else {
          streak = 0;
          holdCount++;
        }
        pass1[f] = cur;
      }

      // Post-Pass-1 initial blip suppression (runs of length 1..4).
      var firstRun = 1;
      while (firstRun < n && firstRun <= 4 && pass1[firstRun] == pass1[0]) {
        firstRun++;
      }
      if (firstRun < n && firstRun <= 4 && pass1[firstRun] != pass1[0]) {
        for (var k = 0; k < firstRun; k++) {
          pass1[k] = pass1[firstRun];
        }
      }

      for (var f = 0; f < n; f++) {
        final ti = pass1[f];
        final tr = shotTracks[ti];
        final obs = shot[f];
        final rawX = clampPanelSafeX(ti, xGrid[ti][f]);
        final rawY = yGrid[ti][f].clamp(0.08, 0.92);
        final didTrackChange = prevShotTrack != null && prevShotTrack.id != tr.id;

        if (f == 0 || didTrackChange) {
          smoothX = rawX;
          smoothY = rawY;
        } else {
          smoothX = 0.42 * rawX + 0.58 * smoothX;
          smoothY = 0.38 * rawY + 0.62 * smoothY;
        }

        final pt = FaceTrackPoint(
          timeSec: obs.timeSec,
          normX: smoothX,
          normY: smoothY,
          faceWidth: wGrid[ti][f],
          faceHeight: hGrid[ti][f],
          isSpeaking: obs.audio.isSpeech && lipGrid[ti][f] >= 0.011,
          speakerId: tr.id,
          isCut: shotIdx > 0 && f == 0,
          isSmoothPan: didTrackChange && out.isNotEmpty,
        );
        out.add(pt);
        tr.points.add(pt);
        prevShotTrack = tr;
      }
    }

    return List<FaceTrackPoint>.unmodifiable(out);
  }

  /// Correlates a rolling visual lip series with audio RMS energy.
  static double computeAudioVisualSyncScore(
    List<double> lipSeries,
    List<double> energySeries,
  ) {
    final n = min(lipSeries.length, energySeries.length);
    if (n < 2) return 0.5;

    final lipStart = lipSeries.length - n;
    final enStart = energySeries.length - n;
    var sumLip = 0.0;
    var sumEn = 0.0;
    for (var i = 0; i < n; i++) {
      sumLip += lipSeries[lipStart + i];
      sumEn += energySeries[enStart + i];
    }
    final meanLip = sumLip / n;
    final meanEn = sumEn / n;

    var num = 0.0;
    var denA = 1e-7;
    var denB = 1e-7;
    var coActive = 0.0;
    var silentMismatch = 0.0;

    for (var i = 0; i < n; i++) {
      final l = lipSeries[lipStart + i];
      final e = energySeries[enStart + i];
      final dl = l - meanLip;
      final de = e - meanEn;
      num += dl * de;
      denA += dl * dl;
      denB += de * de;

      if (e >= 0.18 && l >= 0.011) {
        coActive += min(1.0, (l / 0.025) * (e / 0.4));
      } else if (e < 0.12 && l >= 0.015) {
        silentMismatch += 0.35;
      }
    }

    final corr = (num / sqrt(denA * denB)).clamp(-1.0, 1.0);
    final corr01 = ((corr + 1.0) * 0.5).clamp(0.0, 1.0);
    final denomCo = max(1.0, n * 0.55);
    final coScore = (coActive / denomCo).clamp(0.0, 1.0);

    var lipStd = 0.0;
    if (lipSeries.length >= 3) {
      var lSum = 0.0;
      for (final v in lipSeries) {
        lSum += v;
      }
      final lMean = lSum / lipSeries.length;
      var lVar = 0.0;
      for (final v in lipSeries) {
        lVar += (v - lMean) * (v - lMean);
      }
      lipStd = sqrt(lVar / lipSeries.length);
    }
    final modBonus = (lipStd / 0.022).clamp(0.0, 0.25);

    return (coScore * 0.48 + corr01 * 0.37 + modBonus - (silentMismatch / n))
        .clamp(0.05, 1.0);
  }

  /// Extracts mono 16 kHz PCM via FFmpeg and computes per-frame audio features.
  static Future<List<AudioFrameFeatures>> _extractAndAnalyzeAudio({
    required String videoPath,
    required double startSec,
    required double durationSec,
    required Directory workDir,
    required int targetFrames,
  }) async {
    final wavPath = '${workDir.path}/audio_16k.wav';
    final cmd =
        '-ss ${startSec.toStringAsFixed(3)} '
        '-t ${durationSec.toStringAsFixed(3)} '
        '-i "$videoPath" -vn -ac 1 -ar 16000 -acodec pcm_s16le -y "$wavPath"';
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    if (!ReturnCode.isSuccess(rc)) return const <AudioFrameFeatures>[];
    final wavFile = File(wavPath);
    if (!await wavFile.exists()) return const <AudioFrameFeatures>[];
    final bytes = await wavFile.readAsBytes();
    return analyzeWavBytes(bytes, targetFrames);
  }

  /// Analyzes 16 kHz mono PCM WAV bytes into frame-aligned [AudioFrameFeatures].
  static List<AudioFrameFeatures> analyzeWavBytes(
    Uint8List wavBytes,
    int targetFrames,
  ) {
    if (targetFrames <= 0) return const <AudioFrameFeatures>[];

    // Scan up to first 256 bytes for 'data' chunk header.
    var dataOffset = 44;
    final scanEnd = min(256, wavBytes.length - 8);
    for (var i = 12; i < scanEnd; i++) {
      if (wavBytes[i] == 0x64 &&
          wavBytes[i + 1] == 0x61 &&
          wavBytes[i + 2] == 0x74 &&
          wavBytes[i + 3] == 0x61) {
        dataOffset = i + 8;
        break;
      }
    }

    if (wavBytes.length <= dataOffset + 32) {
      return List<AudioFrameFeatures>.filled(
        targetFrames,
        const AudioFrameFeatures(),
      );
    }

    final totalSamples = (wavBytes.length - dataOffset) ~/ 2;
    final pcm = Float32List(totalSamples);
    final bd = ByteData.sublistView(wavBytes, dataOffset);
    for (var i = 0; i < totalSamples; i++) {
      pcm[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final hop = max(64, (totalSamples / targetFrames).round());
    final energyRaw = List<double>.filled(targetFrames, 0.0);
    final speechModRaw = List<double>.filled(targetFrames, 0.0);
    final pitchHzRaw = List<double>.filled(targetFrames, 0.0);
    final pitchClarityRaw = List<double>.filled(targetFrames, 0.0);
    final bandLowRaw = List<double>.filled(targetFrames, 0.33);
    final bandMidRaw = List<double>.filled(targetFrames, 0.34);
    final bandHighRaw = List<double>.filled(targetFrames, 0.33);

    final minLag = (8000.0 / 300.0).round();
    final maxLag = (8000.0 / 72.0).round();

    for (var fi = 0; fi < targetFrames; fi++) {
      final s0 = fi * hop;
      final s1 = min(totalSamples, s0 + hop);
      final frameLen = s1 - s0;
      if (frameLen < 64) continue;

      // 4 sub-frames with 0.95 pre-emphasis RMS -> mean energy & modulation.
      final subLen = max(16, frameLen ~/ 4);
      final subRms = List<double>.filled(4, 0.0);
      var prevSample = pcm[s0];
      for (var c = 0; c < 4; c++) {
        final a = s0 + c * subLen;
        final b = c == 3 ? s1 : min(s1, a + subLen);
        if (b <= a) continue;
        var sq = 0.0;
        for (var j = a; j < b; j++) {
          final cur = pcm[j];
          final emp = cur - prevSample * 0.95;
          sq += emp * emp;
          prevSample = cur;
        }
        subRms[c] = sqrt(sq / (b - a));
      }
      final meanRms =
          (subRms[0] + subRms[1] + subRms[2] + subRms[3]) * 0.25;
      var minR = subRms[0];
      var maxR = subRms[0];
      for (var c = 1; c < 4; c++) {
        if (subRms[c] > maxR) maxR = subRms[c];
        if (subRms[c] < minR) minR = subRms[c];
      }
      energyRaw[fi] = meanRms;
      speechModRaw[fi] = maxR - minR;

      // Moving-average 3-band spectral split (16-tap low, 4-tap mid, residual high).
      if (frameLen >= 32) {
        var win16 = 0.0;
        for (var k = 0; k < 16; k++) {
          win16 += pcm[s0 + k];
        }
        var win4 = 0.0;
        for (var k = 0; k < 4; k++) {
          win4 += pcm[s0 + k];
        }
        var lowE = 0.0;
        var midE = 0.0;
        var highE = 0.0;
        for (var j = s0 + 16; j < s1; j++) {
          final cur = pcm[j];
          win16 += cur - pcm[j - 16];
          win4 += cur - pcm[j - 4];
          final low = win16 * 0.0625;
          final lowMid = win4 * 0.25;
          final mid = lowMid - low;
          final high = cur - lowMid;
          lowE += low * low;
          midE += mid * mid;
          highE += high * high;
        }
        final totalSpec = lowE + midE + highE + 1e-9;
        bandLowRaw[fi] = lowE / totalSpec;
        bandMidRaw[fi] = midE / totalSpec;
        bandHighRaw[fi] = highE / totalSpec;
      }

      // 8 kHz downsampled normalized autocorrelation pitch tracking.
      final dsLen = min(900, frameLen ~/ 2);
      if (dsLen >= 160) {
        final offset = s0 + max<int>(0, (frameLen - dsLen * 2) ~/ 2);
        var mean = 0.0;
        for (var j = 0; j < dsLen; j++) {
          mean += pcm[offset + j * 2];
        }
        mean /= dsLen;

        final ds = Float32List(dsLen);
        var zeroLagEnergy = 1e-9;
        for (var j = 0; j < dsLen; j++) {
          final v = pcm[offset + j * 2] - mean;
          ds[j] = v;
          zeroLagEnergy += v * v;
        }

        var bestLag = minLag;
        var bestCorr = 0.0;
        final hiLag = min(maxLag, dsLen ~/ 2);
        for (var lag = minLag; lag <= hiLag; lag++) {
          var ac = 0.0;
          final lim = dsLen - lag;
          for (var j = 0; j < lim; j += 2) {
            ac += ds[j] * ds[j + lag];
          }
          final normAc = (ac * 2.0) / zeroLagEnergy;
          if (normAc > bestCorr) {
            bestCorr = normAc;
            bestLag = lag;
          }
        }

        final clarity = bestCorr.clamp(0.0, 1.0);
        pitchClarityRaw[fi] = clarity;
        if (clarity >= 0.23 && bestLag > 0) {
          pitchHzRaw[fi] = 8000.0 / bestLag;
        }
      }
    }

    // 15th..90th percentile normalization & VAD thresholding.
    final sortedE = List<double>.of(energyRaw)..sort();
    final sortedS = List<double>.of(speechModRaw)..sort();
    final floorE = sortedE[(targetFrames * 0.15).toInt()];
    final ceilE = max(floorE + 1e-4, sortedE[(targetFrames * 0.9).toInt()]);
    final spanE = ceilE - floorE;

    final floorS = sortedS[(targetFrames * 0.15).toInt()];
    final ceilS = max(floorS + 1e-4, sortedS[(targetFrames * 0.9).toInt()]);
    final spanS = ceilS - floorS;

    final normE = List<double>.filled(targetFrames, 0.0);
    final normS = List<double>.filled(targetFrames, 0.0);
    final isVoiced = List<bool>.filled(targetFrames, false);

    for (var fi = 0; fi < targetFrames; fi++) {
      final ne = ((energyRaw[fi] - floorE) / spanE).clamp(0.0, 1.0);
      final ns = ((speechModRaw[fi] - floorS) / spanS).clamp(0.0, 1.0);
      normE[fi] = ne;
      normS[fi] = ns;
      isVoiced[fi] = (ne >= 0.16 && ns >= 0.10) ||
          ne >= 0.28 ||
          (ne >= 0.12 && pitchClarityRaw[fi] >= 0.30);
    }

    // Smooth spectral bands and pitch across adjacent voiced neighbors.
    final smLow = List<double>.filled(targetFrames, 0.33);
    final smMid = List<double>.filled(targetFrames, 0.34);
    final smHigh = List<double>.filled(targetFrames, 0.33);
    final smPitch = List<double>.filled(targetFrames, 0.0);

    for (var fi = 0; fi < targetFrames; fi++) {
      final pitches = <double>[];
      var wSum = 0.0;
      var lSum = 0.0;
      var mSum = 0.0;
      var hSum = 0.0;
      for (var k = max(0, fi - 1); k <= min(targetFrames - 1, fi + 1); k++) {
        if (!isVoiced[k] && k != fi) continue;
        final w = k == fi ? 1.0 : 0.25;
        wSum += w;
        lSum += bandLowRaw[k] * w;
        mSum += bandMidRaw[k] * w;
        hSum += bandHighRaw[k] * w;
        if (pitchHzRaw[k] > 65.0) pitches.add(pitchHzRaw[k]);
      }
      if (wSum > 0) {
        smLow[fi] = lSum / wSum;
        smMid[fi] = mSum / wSum;
        smHigh[fi] = hSum / wSum;
      }
      if (pitches.isNotEmpty) {
        pitches.sort();
        smPitch[fi] = pitches[pitches.length ~/ 2];
      }
    }

    // Online speaker voice clustering (_VoiceCluster).
    final clusters = <_VoiceCluster>[];
    final out = <AudioFrameFeatures>[];
    var prevCid = -1;
    var sameRun = 0;

    for (var fi = 0; fi < targetFrames; fi++) {
      final feat = AudioFrameFeatures(
        energy: normE[fi],
        speech: normS[fi],
        pitchHz: smPitch[fi],
        pitchClarity: pitchClarityRaw[fi],
        bandLow: smLow[fi],
        bandMid: smMid[fi],
        bandHigh: smHigh[fi],
        isSpeech: isVoiced[fi],
      );

      var assignedCid = -1;
      if (feat.isSpeech && (feat.pitchHz > 65.0 || feat.energy >= 0.25)) {
        if (clusters.isEmpty) {
          assignedCid = 0;
          clusters.add(
            _VoiceCluster(
              id: 0,
              pitchHz: feat.pitchHz > 65.0 ? feat.pitchHz : 145.0,
              bandLow: feat.bandLow,
              bandMid: feat.bandMid,
              bandHigh: feat.bandHigh,
            ),
          );
          prevCid = 0;
          sameRun = 1;
        } else {
          _VoiceCluster? bestC;
          var bestDist = double.infinity;
          for (final c in clusters) {
            var d = c.distanceTo(feat);
            if (c.id == prevCid) d *= 0.85;
            if (d < bestDist) {
              bestDist = d;
              bestC = c;
            }
          }

          if (bestC != null && (bestDist <= 0.28 || clusters.length >= 4)) {
            if (prevCid >= 0 &&
                bestC.id != prevCid &&
                sameRun < 2 &&
                bestDist <= 0.182) {
              bestC = clusters[prevCid];
            }
            bestC.update(feat);
            assignedCid = bestC.id;
            sameRun = (assignedCid == prevCid) ? sameRun + 1 : 1;
            prevCid = assignedCid;
          } else {
            assignedCid = clusters.length;
            clusters.add(
              _VoiceCluster(
                id: assignedCid,
                pitchHz: feat.pitchHz > 65.0 ? feat.pitchHz : 150.0,
                bandLow: feat.bandLow,
                bandMid: feat.bandMid,
                bandHigh: feat.bandHigh,
              ),
            );
            prevCid = assignedCid;
            sameRun = 1;
          }
        }
      } else {
        prevCid = -1;
        sameRun = 0;
      }

      out.add(
        AudioFrameFeatures(
          energy: feat.energy,
          speech: feat.speech,
          pitchHz: feat.pitchHz > 65.0 ? feat.pitchHz : smPitch[fi],
          pitchClarity: feat.pitchClarity,
          bandLow: feat.bandLow,
          bandMid: feat.bandMid,
          bandHigh: feat.bandHigh,
          isSpeech: feat.isSpeech,
          voiceClusterId: assignedCid,
        ),
      );
    }

    return out;
  }

  /// Detects a high-contrast dark silhouette subject or motion cluster when ML Kit
  /// returns no face for a panel or frame.
  static SilhouetteSubject? detectSilhouetteOrMotionSubject(
    Uint8List rgbaBytes,
    int width,
    int height,
    Uint8List? previousRgbaBytes, {
    double minX = silhouetteRegionX0,
    double maxX = silhouetteRegionX1,
    List<({double x0, double y0, double x1, double y1})>? excludeRects,
  }) {
    final count = width * height;
    if (count == 0 || rgbaBytes.length < count * 4) return null;

    final luma = Float32List(count);
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      luma[i] =
          (77 * rgbaBytes[o] + 150 * rgbaBytes[o + 1] + 29 * rgbaBytes[o + 2]) /
              256.0;
    }

    var diffSum = 0.0;
    if (previousRgbaBytes != null && previousRgbaBytes.length >= count * 4) {
      for (var i = 0; i < count; i++) {
        final o = i * 4;
        final pl = (77 * previousRgbaBytes[o] +
                150 * previousRgbaBytes[o + 1] +
                29 * previousRgbaBytes[o + 2]) /
            256.0;
        diffSum += (luma[i] - pl).abs();
      }
    }
    final sceneChanged =
        previousRgbaBytes != null && (diffSum / count) >= silhouetteSceneChangeThreshold;

    final x0 = (minX * width).floor().clamp(0, width - 1);
    final x1 = (maxX * width).ceil().clamp(x0 + 1, width - 1);
    final y0 = (silhouetteRegionY0 * height).floor().clamp(0, height - 1);
    final y1 = (silhouetteRegionY1 * height).ceil().clamp(y0 + 1, height - 1);

    // Build neutral dark-pixel mask inside search ROI.
    final mask = Uint8List(count);
    var sumLuma = 0.0;
    var roiCells = 0;
    for (var gy = y0; gy <= y1; gy++) {
      for (var gx = x0; gx <= x1; gx++) {
        final i = gy * width + gx;
        final o = i * 4;
        final r = rgbaBytes[o];
        final g = rgbaBytes[o + 1];
        final b = rgbaBytes[o + 2];
        final hi = max(r, max(g, b));
        final lo = min(r, min(g, b));
        final l = luma[i];
        sumLuma += l;
        roiCells++;
        if (l <= silhouetteMaxLuma && (hi - lo) <= silhouetteMaxChannelSpread) {
          mask[i] = 1;
        }
      }
    }
    if (roiCells == 0 || (sumLuma / roiCells) < silhouetteMinBackgroundLuma) {
      return null;
    }

    // Remove vertical dark wall pillars connected from the top ceiling border.
    final pillarPrev = List<bool>.filled(width, false);
    final ceilRows = min(3, height - 1);
    for (var gx = 0; gx < width; gx++) {
      var darkCount = 0;
      for (var gy = 0; gy <= ceilRows; gy++) {
        final i = gy * width + gx;
        final o = i * 4;
        final hi = max(rgbaBytes[o], max(rgbaBytes[o + 1], rgbaBytes[o + 2]));
        final lo = min(rgbaBytes[o], min(rgbaBytes[o + 1], rgbaBytes[o + 2]));
        if (luma[i] <= silhouetteNeighborhoodLuma &&
            hi - lo <= silhouetteMaxChannelSpread + 2) {
          darkCount++;
        }
      }
      if (darkCount >= 2) {
        for (var k = gx - 1; k <= gx + 1; k++) {
          if (k >= 0 && k < width) pillarPrev[k] = true;
        }
      }
    }
    final ceilLimit = min(y1, (height * 0.72).floor());
    for (var gy = y0; gy <= ceilLimit; gy++) {
      final pillarCurr = List<bool>.filled(width, false);
      var gx = x0;
      while (gx <= x1) {
        if (mask[gy * width + gx] != 1) {
          gx++;
          continue;
        }
        final r0 = gx;
        while (gx <= x1 && mask[gy * width + gx] == 1) {
          gx++;
        }
        final r1 = gx - 1;
        final runWidth = r1 - r0 + 1;
        var touchesPillar = false;
        for (var k = max(0, r0 - 1); k <= min(width - 1, r1 + 1); k++) {
          if (pillarPrev[k]) {
            touchesPillar = true;
            break;
          }
        }
        if (runWidth <= 7 && touchesPillar) {
          for (var k = r0; k <= r1; k++) {
            mask[gy * width + k] = 0;
            pillarCurr[k] = true;
          }
        }
        for (var k = r0; k <= r1; k++) {
          if (pillarPrev[k] && luma[gy * width + k] <= silhouetteNeighborhoodLuma) {
            pillarCurr[k] = true;
          }
        }
      }
      for (var k = 0; k < width; k++) {
        if (pillarPrev[k] &&
            luma[gy * width + k] <= silhouetteNeighborhoodLuma &&
            mask[gy * width + k] == 0) {
          pillarCurr[k] = true;
        }
      }
      for (var k = 0; k < width; k++) {
        pillarPrev[k] = pillarCurr[k];
      }
    }

    // Strip thin horizontal runs (< 3 cells).
    for (var gy = y0; gy <= y1; gy++) {
      var runStart = -1;
      for (var gx = x0; gx <= x1 + 1; gx++) {
        final isMask = gx <= x1 && mask[gy * width + gx] == 1;
        if (isMask) {
          if (runStart < 0) runStart = gx;
        } else if (runStart >= 0) {
          if (gx - runStart < 3) {
            for (var k = runStart; k < gx; k++) {
              mask[gy * width + k] = 0;
            }
          }
          runStart = -1;
        }
      }
    }

    // Exclude detected face bounding boxes.
    if (excludeRects != null) {
      for (final r in excludeRects) {
        final fx0 = (r.x0 * width).floor().clamp(0, width);
        final fx1 = (r.x1 * width).ceil().clamp(0, width);
        final fy0 = (r.y0 * height).floor().clamp(0, height);
        final fy1 = (r.y1 * height).ceil().clamp(0, height);
        for (var gy = fy0; gy < fy1; gy++) {
          for (var gx = fx0; gx < fx1; gx++) {
            if (gx >= x0 && gx <= x1 && gy >= y0 && gy <= y1) {
              mask[gy * width + gx] = 0;
            }
          }
        }
      }
    }

    // Largest 4-connected cluster matching human silhouette geometry.
    final visited = Uint8List(count);
    var bestCells = 0;
    var bestTop = 0;
    var bestBottom = 0;
    var bestLeft = 0;
    var bestRight = 0;
    var bestWeightedSumX = 0.0;
    var bestWeightTotal = 0.0;
    final stack = <int>[];

    for (var gy = y0; gy <= y1; gy++) {
      for (var gx = x0; gx <= x1; gx++) {
        final start = gy * width + gx;
        if (visited[start] != 0 || mask[start] == 0) continue;

        var cells = 0;
        var top = gy;
        var bottom = gy;
        var left = gx;
        var right = gx;
        var weightedSumX = 0.0;
        var weightTotal = 0.0;
        stack.add(start);
        visited[start] = 1;

        while (stack.isNotEmpty) {
          final idx = stack.removeLast();
          final cy = idx ~/ width;
          final cx = idx % width;
          cells++;
          if (cy < top) top = cy;
          if (cy > bottom) bottom = cy;
          if (cx < left) left = cx;
          if (cx > right) right = cx;

          final w = cy <= y0 + (y1 - y0) * 0.45 ? 1.5 : 0.7;
          weightedSumX += cx * w;
          weightTotal += w;

          final neighbors = <int>[
            if (cx > x0) idx - 1,
            if (cx < x1) idx + 1,
            if (cy > y0) idx - width,
            if (cy < y1) idx + width,
          ];
          for (final nb in neighbors) {
            if (visited[nb] == 0 && mask[nb] == 1) {
              visited[nb] = 1;
              stack.add(nb);
            }
          }
        }

        final frac = cells / count;
        final normBottom = (bottom + 1) / height;
        final normTop = top / height;
        final normH = (bottom - top + 1) / height;
        final normW = (right - left + 1) / width;
        final bboxFill = cells / ((bottom - top + 1) * (right - left + 1));

        if (frac < silhouetteMinClusterFraction ||
            frac > silhouetteMaxClusterFraction ||
            bboxFill < 0.32 ||
            normBottom < silhouetteMinBottomFraction ||
            normTop > silhouetteMaxTopFraction ||
            normH < silhouetteMinHeightFraction ||
            normW < silhouetteMinWidthFraction ||
            normW > silhouetteMaxWidthFraction) {
          continue;
        }

        // Border contrast check against immediate bright background.
        var bgSum = 0.0;
        var bgCount = 0;
        for (var by = max(0, top - 1); by <= min(height - 1, bottom + 1); by++) {
          for (var bx = max(0, left - 1); bx <= min(width - 1, right + 1); bx++) {
            final idx = by * width + bx;
            if (mask[idx] == 0) {
              bgSum += luma[idx];
              bgCount++;
            }
          }
        }
        if (bgCount >= 8 && (bgSum / bgCount) < silhouetteMinBackgroundLuma) {
          continue;
        }

        if (cells > bestCells) {
          bestCells = cells;
          bestTop = top;
          bestBottom = bottom;
          bestLeft = left;
          bestRight = right;
          bestWeightedSumX = weightedSumX;
          bestWeightTotal = weightTotal;
        }
      }
    }

    if (bestCells == 0 || bestWeightTotal <= 0) return null;
    final normX = ((bestWeightedSumX / bestWeightTotal) + 0.5) / width;
    final normY = ((bestTop + (bestBottom - bestTop) * 0.35) + 0.5) / height;
    final normW = (bestRight - bestLeft + 1) / width;
    final normH = (bestBottom - bestTop + 1) / height;

    return (
      normX: normX.clamp(0.05, 0.95),
      normY: normY.clamp(0.10, 0.88),
      normW: normW,
      normH: normH,
      mass: (bestCells / count).clamp(0.0, 1.0),
      sceneChanged: sceneChanged,
    );
  }

  /// Checks whether two thumbnail RGBA grids represent a hard visual cut.
  static bool isSceneChange(
    Uint8List? prevRgba,
    Uint8List? currRgba,
    int width,
    int height,
  ) {
    if (prevRgba == null || currRgba == null) return false;
    final count = width * height;
    if (count == 0 ||
        prevRgba.length < count * 4 ||
        currRgba.length < count * 4) {
      return false;
    }
    var diffSum = 0.0;
    for (var i = 0; i < count; i++) {
      final o = i * 4;
      final lp =
          (77 * prevRgba[o] + 150 * prevRgba[o + 1] + 29 * prevRgba[o + 2]) >> 8;
      final lc =
          (77 * currRgba[o] + 150 * currRgba[o + 1] + 29 * currRgba[o + 2]) >> 8;
      diffSum += (lp - lc).abs();
    }
    return (diffSum / count) >= silhouetteSceneChangeThreshold;
  }

  static _SpeakerTrack? _associateSilhouette(
    Iterable<_SpeakerTrack> tracks, {
    required double normX,
    required double normY,
    required double timeSec,
  }) {
    _SpeakerTrack? best;
    var bestDist = 0.22;
    for (final t in tracks) {
      if (!t.isSilhouette || t.lastSeenSec == timeSec) continue;
      if (timeSec - t.lastSeenSec > 2.5) continue;
      final dist = sqrt(pow(t.normX - normX, 2) + pow(t.normY - normY, 2));
      if (dist < bestDist) {
        bestDist = dist;
        best = t;
      }
    }
    return best;
  }

  static double _silhouetteMotionActivity(
    Uint8List prevRgba,
    Uint8List currRgba,
    int width,
    int height, {
    required double cx,
    required double cy,
    required double w,
    required double h,
  }) {
    final x0 = ((cx - w * 0.65) * width).floor().clamp(0, width - 1);
    final x1 = ((cx + w * 0.65) * width).ceil().clamp(x0 + 1, width - 1);
    final y0 = ((cy - h * 0.45) * height).floor().clamp(0, height - 1);
    final y1 = ((cy + h * 0.55) * height).ceil().clamp(y0 + 1, height - 1);
    var sum = 0.0;
    var cnt = 0;
    for (var gy = y0; gy <= y1; gy++) {
      for (var gx = x0; gx <= x1; gx++) {
        final o = (gy * width + gx) * 4;
        final lp = (77 * prevRgba[o] +
                150 * prevRgba[o + 1] +
                29 * prevRgba[o + 2]) >>
            8;
        final lc = (77 * currRgba[o] +
                150 * currRgba[o + 1] +
                29 * currRgba[o + 2]) >>
            8;
        sum += (lp - lc).abs();
        cnt++;
      }
    }
    if (cnt == 0) return 0.0;
    return (sum / cnt) / 255.0;
  }

  static ({double activity, double aperture}) _updateLipActivity({
    required _SpeakerTrack track,
    required Face face,
    required Face contourFace,
    required int imageWidth,
    required int imageHeight,
    required Uint8List? mouthGrid,
    required Uint8List? prevMouthGrid,
    required int mouthGridWidth,
    required int mouthGridHeight,
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    required bool isCut,
  }) {
    final yawDeg = (face.headEulerAngleY ?? 0.0).abs();
    final yawWeight = yawDeg >= 45.0 ? 0.5 : 1.0;

    final innerMar = _extractInnerLipContourMar(contourFace);
    final fallbackMetrics = _lipMetrics(contourFace, face.boundingBox);

    final aperture = innerMar ?? fallbackMetrics.$1;
    final widthRatio = fallbackMetrics.$2;

    var baseDelta = 0.0;
    if (aperture != null) {
      if (!isCut && track.prevAperture != null) {
        final d = (aperture - track.prevAperture!).abs();
        baseDelta += max(0.0, d - 0.022) * 1.9 * yawWeight;
      }
      track.prevAperture = aperture;
    }

    if (widthRatio != null) {
      if (!isCut && track.prevWidthRatio != null) {
        final d = (widthRatio - track.prevWidthRatio!).abs();
        baseDelta += max(0.0, d - 0.024) * 1.1 * yawWeight;
      }
      track.prevWidthRatio = widthRatio;
    }

    final validGrid = mouthGrid != null &&
        mouthGrid.length >= mouthGridWidth * mouthGridHeight * 4;

    if (validGrid) {
      final contrast = _mouthToCheekContrast(
        mouthGrid,
        mouthGridWidth,
        mouthGridHeight,
        nx0: nx0,
        ny0: ny0,
        nx1: nx1,
        ny1: ny1,
        yawDeg: face.headEulerAngleY ?? 0.0,
      );
      final innerLipAp = computeInnerLipAperture(
        mouthGrid,
        mouthGridWidth,
        mouthGridHeight,
        nx0: nx0,
        ny0: ny0,
        nx1: nx1,
        ny1: ny1,
        yawDeg: face.headEulerAngleY ?? 0.0,
      );

      final regDelta = !isCut && prevMouthGrid != null
          ? computeMouthRegionDelta(
              prevMouthGrid,
              mouthGrid,
              mouthGridWidth,
              mouthGridHeight,
              nx0: nx0,
              ny0: ny0,
              nx1: nx1,
              ny1: ny1,
              prevNx0: track.lastX0,
              prevNy0: track.lastY0,
              prevNx1: track.lastX1,
              prevNy1: track.lastY1,
            )
          : 0.0;

      var dContrast = 0.0;
      if (!isCut && track.prevContrast != null) {
        dContrast = max(0.0, (contrast - track.prevContrast!).abs() - 0.01);
      }
      var dInner = 0.0;
      if (!isCut && track.prevInnerAperture != null) {
        dInner = max(
          0.0,
          (innerLipAp - track.prevInnerAperture!).abs() - 0.0085,
        );
      }
      var dReg = max(0.0, regDelta - 0.0085);

      track.prevContrast = contrast;
      track.prevInnerAperture = innerLipAp;

      final visualMotion =
          (dContrast * 3.8 + dInner * 1.8 + dReg * 2.6) * yawWeight;
      baseDelta += visualMotion;

      if (baseDelta < 0.003) {
        final subtle = min(0.002, (innerLipAp + contrast) * 0.2);
        baseDelta += subtle;
      }
    }

    track.lastLipRawDelta = baseDelta;
    return (
      activity: baseDelta,
      aperture: aperture ?? (track.prevInnerAperture ?? 0.0),
    );
  }

  /// Measures mouth-region luma motion normalized by forehead lighting stability
  /// across a 3x3 alignment search grid.
  static double computeMouthRegionDelta(
    Uint8List? prevRgba,
    Uint8List? currRgba,
    int width,
    int height, {
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    required double prevNx0,
    required double prevNy0,
    required double prevNx1,
    required double prevNy1,
  }) {
    if (prevRgba == null || currRgba == null) return 0.0;
    final minLen = width * height * 4;
    if (minLen == 0 || prevRgba.length < minLen || currRgba.length < minLen) {
      return 0.0;
    }

    final currW = max(0.0, nx1 - nx0);
    final currH = max(0.0, ny1 - ny0);
    final prevW = max(0.0, prevNx1 - prevNx0);
    final prevH = max(0.0, prevNy1 - prevNy0);
    if (currW <= 0 || currH <= 0 || prevW <= 0 || prevH <= 0) return 0.0;

    double patchMae(
      double u0,
      double u1,
      double v0,
      double v1,
      double du,
      double dv,
    ) {
      var sum = 0.0;
      for (var iy = 0; iy < 4; iy++) {
        final fy = v0 + (v1 - v0) * ((iy + 0.5) / 4.0);
        final cy = ((ny0 + currH * fy) * height);
        final py = ((prevNy0 + prevH * (fy + dv)) * height);
        for (var ix = 0; ix < 6; ix++) {
          final fx = u0 + (u1 - u0) * ((ix + 0.5) / 6.0);
          final cx = ((nx0 + currW * fx) * width);
          final px = ((prevNx0 + prevW * (fx + du)) * width);
          final lc = _sampleLumaBilinear(currRgba, width, height, cx, cy);
          final lp = _sampleLumaBilinear(prevRgba, width, height, px, py);
          sum += (lc - lp).abs();
        }
      }
      return sum / 24.0;
    }

    var bestMouth = double.infinity;
    var bestRef = double.infinity;
    const shifts = <double>[-0.02, 0.0, 0.02];
    for (final du in shifts) {
      for (final dv in shifts) {
        final m = patchMae(0.26, 0.74, 0.62, 0.78, du, dv);
        final r = patchMae(0.26, 0.74, 0.16, 0.44, du, dv);
        if (m < bestMouth) bestMouth = m;
        if (r < bestRef) bestRef = r;
      }
    }

    var refLuma = 0.0;
    for (var iy = 0; iy < 4; iy++) {
      final fy = 0.16 + 0.28 * ((iy + 0.5) / 4.0);
      final cy = (ny0 + currH * fy) * height;
      for (var ix = 0; ix < 6; ix++) {
        final fx = 0.26 + 0.48 * ((ix + 0.5) / 6.0);
        final cx = (nx0 + currW * fx) * width;
        refLuma += _sampleLumaBilinear(currRgba, width, height, cx, cy);
      }
    }
    refLuma /= 24.0;

    final brightnessScale = (0.4 / max(0.12, refLuma)).clamp(0.8, 2.5);
    final raw = max(0.0, (bestMouth - bestRef * 1.05) * brightnessScale);
    return max(0.0, raw - 0.0068);
  }

  static double _sampleLumaBilinear(
    Uint8List rgba,
    int width,
    int height,
    double px,
    double py,
  ) {
    final x = px.clamp(0.0, (width - 1).toDouble());
    final y = py.clamp(0.0, (height - 1).toDouble());
    final x0 = x.floor();
    final y0 = y.floor();
    final x1 = min(width - 1, x0 + 1);
    final y1 = min(height - 1, y0 + 1);
    final fx = x - x0;
    final fy = y - y0;

    double lumaAt(int ix, int iy) {
      final o = (iy * width + ix) * 4;
      return (0.299 * rgba[o] + 0.587 * rgba[o + 1] + 0.114 * rgba[o + 2]) /
          255.0;
    }

    final v00 = lumaAt(x0, y0);
    final v10 = lumaAt(x1, y0);
    final v01 = lumaAt(x0, y1);
    final v11 = lumaAt(x1, y1);
    final top = v00 + (v10 - v00) * fx;
    final bot = v01 + (v11 - v01) * fx;
    return top + (bot - top) * fy;
  }

  /// Estimates normalized dark inner-mouth opening relative to surrounding skin.
  static double computeInnerLipAperture(
    Uint8List rgba,
    int width,
    int height, {
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    double yawDeg = 0.0,
  }) {
    final bw = nx1 - nx0;
    final bh = ny1 - ny0;
    if (bw <= 0 || bh <= 0) return 0.0;

    final yawShift = (-yawDeg / 60.0).clamp(-0.18, 0.18);
    final u0 = (nx0 + bw * (0.32 + yawShift)).clamp(0.0, 1.0);
    final u1 = (nx0 + bw * (0.68 + yawShift)).clamp(u0 + 0.01, 1.0);
    final v0 = (ny0 + bh * 0.62).clamp(0.0, 1.0);
    final v1 = (ny0 + bh * 0.80).clamp(v0 + 0.01, 1.0);

    var skinSum = 0.0;
    var skinCnt = 0;
    var darkCount = 0;
    var totalSamples = 0;

    for (var iy = 0; iy < 5; iy++) {
      final y = (ny0 + bh * (0.48 + 0.10 * ((iy + 0.5) / 5.0))) * height;
      for (var ix = 0; ix < 6; ix++) {
        final x = (u0 + (u1 - u0) * ((ix + 0.5) / 6.0)) * width;
        skinSum += _sampleLumaBilinear(rgba, width, height, x, y);
        skinCnt++;
      }
    }
    final skinLuma = skinCnt > 0 ? skinSum / skinCnt : 0.4;

    var minLuma = 1.0;
    var meanMouth = 0.0;
    for (var iy = 0; iy < 5; iy++) {
      final y = (v0 + (v1 - v0) * ((iy + 0.5) / 5.0)) * height;
      for (var ix = 0; ix < 6; ix++) {
        final x = (u0 + (u1 - u0) * ((ix + 0.5) / 6.0)) * width;
        final l = _sampleLumaBilinear(rgba, width, height, x, y);
        meanMouth += l;
        if (l < minLuma) minLuma = l;
        if (l < skinLuma * 0.62) darkCount++;
        totalSamples++;
      }
    }
    if (totalSamples == 0) return 0.0;
    meanMouth /= totalSamples;
    final darkFrac = darkCount / totalSamples;
    final depth = ((skinLuma - minLuma) / max(0.15, skinLuma)).clamp(0.0, 1.0);
    return ((darkFrac * 0.6 + depth * 0.4) *
            ((skinLuma - meanMouth) * 2.2 + 0.4))
        .clamp(0.0, 1.0);
  }

  static double _mouthToCheekContrast(
    Uint8List rgba,
    int width,
    int height, {
    required double nx0,
    required double ny0,
    required double nx1,
    required double ny1,
    double yawDeg = 0.0,
  }) {
    final bw = nx1 - nx0;
    final bh = ny1 - ny0;
    if (bw <= 0 || bh <= 0) return 0.0;
    final yawShift = (-yawDeg / 60.0).clamp(-0.15, 0.15);
    final midOffset = yawShift * 0.5;

    var cheekSum = 0.0;
    var mouthSum = 0.0;
    for (var ix = 0; ix < 4; ix++) {
      final fx = (ix + 0.5) / 4.0;
      final cx =
          ((nx0 + bw * (0.28 + 0.44 * fx + midOffset)).clamp(0.0, 1.0)) * width;
      for (var iy = 0; iy < 4; iy++) {
        final fy = (iy + 0.5) / 4.0;
        final cyCheek = (ny0 + bh * (0.24 + 0.20 * fy)) * height;
        final cyMouth = (ny0 + bh * (0.63 + 0.15 * fy)) * height;
        cheekSum += _sampleLumaBilinear(rgba, width, height, cx, cyCheek);
        mouthSum += _sampleLumaBilinear(rgba, width, height, cx, cyMouth);
      }
    }
    return ((cheekSum - mouthSum) / 16.0).abs().clamp(0.0, 1.0);
  }

  static (double?, double?) _lipMetrics(Face face, ui.Rect box) {
    final rectH = box.height > 0 ? box.height : 1.0;
    final rectW = box.width > 0 ? box.width : 1.0;

    final upperPts = face.contours[FaceContourType.upperLipBottom]?.points;
    final lowerPts = face.contours[FaceContourType.lowerLipTop]?.points;

    double? contourOpen;
    if (upperPts != null &&
        upperPts.isNotEmpty &&
        lowerPts != null &&
        lowerPts.isNotEmpty) {
      final upMean =
          upperPts.fold<double>(0.0, (s, p) => s + p.y) / upperPts.length;
      final loMean =
          lowerPts.fold<double>(0.0, (s, p) => s + p.y) / lowerPts.length;
      contourOpen = (loMean - upMean).abs() / rectH;
    }

    final leftMouth = face.landmarks[FaceLandmarkType.leftMouth]?.position;
    final rightMouth = face.landmarks[FaceLandmarkType.rightMouth]?.position;
    final bottomMouth = face.landmarks[FaceLandmarkType.bottomMouth]?.position;
    final noseBase = face.landmarks[FaceLandmarkType.noseBase]?.position;
    final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
    final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;

    double? widthRatio;
    if (leftMouth != null && rightMouth != null) {
      widthRatio = (leftMouth.x - rightMouth.x).abs() / rectW;
    }

    if (contourOpen != null) {
      return (contourOpen, widthRatio);
    }

    if (bottomMouth != null && leftMouth != null && rightMouth != null) {
      final cornerMidY = (leftMouth.y + rightMouth.y) * 0.5;
      final refSpan = max(rectH * 0.18, (leftMouth.x - rightMouth.x).abs());
      final openRatio = (bottomMouth.y - cornerMidY).abs() / refSpan;

      if (leftEye != null && rightEye != null && noseBase != null) {
        final eyeMidY = (leftEye.y + rightEye.y) * 0.5;
        final midFace = max(rectH * 0.18, (noseBase.y - eyeMidY).abs());
        final lowerFace = (bottomMouth.y - noseBase.y).abs() / midFace;
        return (openRatio * 0.45 + lowerFace * 0.25, widthRatio);
      }
      return (openRatio * 0.55, widthRatio);
    }

    return (null, widthRatio);
  }

  static double? _extractInnerLipContourMar(Face face) {
    final upper = face.contours[FaceContourType.upperLipBottom]?.points;
    final lower = face.contours[FaceContourType.lowerLipTop]?.points;
    if (upper == null || upper.length < 3 || lower == null || lower.length < 3) {
      return null;
    }

    final lipSpanX = (upper.last.x - upper.first.x).abs().toDouble();
    final width = max(1.0, max(lipSpanX, face.boundingBox.width * 0.25));

    final upStart = upper.length ~/ 4;
    final upEnd = max(upStart + 1, upper.length - upStart);
    var upY = 0.0;
    for (var i = upStart; i < upEnd; i++) {
      upY += upper[i].y;
    }
    upY /= (upEnd - upStart);

    final loStart = lower.length ~/ 4;
    final loEnd = max(loStart + 1, lower.length - loStart);
    var loY = 0.0;
    for (var i = loStart; i < loEnd; i++) {
      loY += lower[i].y;
    }
    loY /= (loEnd - loStart);

    return ((loY - upY).abs() / width).clamp(0.0, 0.85);
  }

  static _SpeakerTrack? _associateFace(
    Iterable<_SpeakerTrack> tracks, {
    required double cx,
    required double cy,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
    required double nowSec,
    required bool allowCrossCut,
    List<double>? appSig,
    List<double>? torsoSig,
  }) {
    // Pass 1: spatial box overlap + appearance similarity.
    _SpeakerTrack? bestIouTrack;
    var bestIouScore = 0.1;
    for (final t in tracks) {
      if (t.isSilhouette || t.lastSeenSec == nowSec) continue;
      if (nowSec - t.lastSeenSec > 2.8) continue;
      final iou = _boxOverlap(t.lastX0, t.lastY0, t.lastX1, t.lastY1, x0, y0, x1, y1);
      if (iou <= 0) continue;
      final appSim = _signatureSimilarity(t.appearanceSig, appSig);
      final score = iou + (appSim > 0.75 ? appSim * 0.12 : 0.0);
      if (score > bestIouScore) {
        bestIouScore = score;
        bestIouTrack = t;
      }
    }
    if (bestIouTrack != null) return bestIouTrack;

    // Pass 2: centroid distance + appearance/torso re-identification across brief gaps/cuts.
    _SpeakerTrack? bestDistTrack;
    var bestEffDist = 0.17;
    for (final t in tracks) {
      if (t.isSilhouette || t.lastSeenSec == nowSec) continue;
      final dt = nowSec - t.lastSeenSec;
      if (dt > 6.5) continue;

      final dist = sqrt(pow(t.normX - cx, 2) + pow(t.normY - cy, 2));
      final appSim = _signatureSimilarity(t.appearanceSig, appSig);
      final torsoSim = _signatureSimilarity(t.torsoSig, torsoSig);
      final combinedSim = 0.65 * appSim + 0.35 * torsoSim;

      final effDist = combinedSim >= 0.85
          ? dist * 0.68
          : ((dt > 2.5 || !allowCrossCut) ? 99.0 : dist);
      if (effDist < bestEffDist) {
        bestEffDist = effDist;
        bestDistTrack = t;
      }
    }
    return bestDistTrack;
  }

  static Future<Face?> _detectContoursOnFaceCrop({
    required FaceDetector detector,
    required Uint8List? fullRgba,
    required int imageWidth,
    required int imageHeight,
    required ui.Rect faceBox,
    required Directory workDir,
    required int frameIndex,
    required int faceIndex,
  }) async {
    if (fullRgba == null || imageWidth <= 0 || imageHeight <= 0) return null;
    final padX = faceBox.width * 0.22;
    final padY = faceBox.height * 0.22;
    final x0 = (faceBox.left - padX).floor().clamp(0, imageWidth - 1);
    final y0 = (faceBox.top - padY).floor().clamp(0, imageHeight - 1);
    final x1 = (faceBox.right + padX).ceil().clamp(x0 + 1, imageWidth);
    final y1 = (faceBox.bottom + padY).ceil().clamp(y0 + 1, imageHeight);

    final bmp = _encodeRgbaCropToBmp(
      fullRgba,
      imageWidth,
      imageHeight,
      x0,
      y0,
      x1,
      y1,
    );
    final cropFile = File(
      '${workDir.path}/crop_${frameIndex}_$faceIndex.bmp',
    );
    await cropFile.writeAsBytes(bmp);
    try {
      final detected = await detector.processImage(
        InputImage.fromFilePath(cropFile.path),
      );
      if (detected.isEmpty) return null;
      if (detected.length == 1) return detected.first;
      detected.sort((a, b) {
        final areaA = a.boundingBox.width * a.boundingBox.height;
        final areaB = b.boundingBox.width * b.boundingBox.height;
        return areaB.compareTo(areaA);
      });
      return detected.first;
    } catch (_) {
      return null;
    } finally {
      if (await cropFile.exists()) {
        await cropFile.delete();
      }
    }
  }

  static Uint8List _encodeRgbaCropToBmp(
    Uint8List rgba,
    int imgW,
    int imgH,
    int x0,
    int y0,
    int x1,
    int y1,
  ) {
    final cw = max(1, x1 - x0);
    final ch = max(1, y1 - y0);
    final rowStride = (cw * 3 + 3) & ~3;
    final pixelBytes = rowStride * ch;
    final totalBytes = 54 + pixelBytes;
    final out = Uint8List(totalBytes);
    final bd = ByteData.view(out.buffer);

    out[0] = 0x42; // 'B'
    out[1] = 0x4D; // 'M'
    bd.setUint32(2, totalBytes, Endian.little);
    bd.setUint32(10, 54, Endian.little);
    bd.setUint32(14, 40, Endian.little);
    bd.setInt32(18, cw, Endian.little);
    bd.setInt32(22, ch, Endian.little);
    bd.setUint16(26, 1, Endian.little);
    bd.setUint16(28, 24, Endian.little);
    bd.setUint32(34, pixelBytes, Endian.little);

    for (var y = 0; y < ch; y++) {
      final srcY = (y0 + (ch - 1 - y)).clamp(0, imgH - 1);
      final dstRow = 54 + y * rowStride;
      for (var x = 0; x < cw; x++) {
        final srcX = (x0 + x).clamp(0, imgW - 1);
        final so = (srcY * imgW + srcX) * 4;
        final doff = dstRow + x * 3;
        out[doff] = rgba[so + 2];
        out[doff + 1] = rgba[so + 1];
        out[doff + 2] = rgba[so];
      }
    }
    return out;
  }

  static List<double> _extractRegionSignature(
    Uint8List rgba,
    int w,
    int h,
    double nx0,
    double ny0,
    double nx1,
    double ny1,
  ) {
    final x0 = (nx0 * w).floor().clamp(0, w - 1);
    final x1 = (nx1 * w).ceil().clamp(x0 + 1, w);
    final y0 = (ny0 * h).floor().clamp(0, h - 1);
    final y1 = (ny1 * h).ceil().clamp(y0 + 1, h);

    // 3 vertical stripes * 4 channels (r, g, b, luma) = 12 features.
    final sig = List<double>.filled(12, 0.0);
    final counts = List<int>.filled(3, 0);
    final spanY = max(1, y1 - y0);

    for (var gy = y0; gy < y1; gy++) {
      final stripe = (((gy - y0) * 3) ~/ spanY).clamp(0, 2);
      final base = stripe * 4;
      for (var gx = x0; gx < x1; gx++) {
        final o = (gy * w + gx) * 4;
        final r = rgba[o] / 255.0;
        final g = rgba[o + 1] / 255.0;
        final b = rgba[o + 2] / 255.0;
        sig[base] += r;
        sig[base + 1] += g;
        sig[base + 2] += b;
        sig[base + 3] += 0.299 * r + 0.587 * g + 0.114 * b;
        counts[stripe]++;
      }
    }
    for (var s = 0; s < 3; s++) {
      final c = counts[s];
      if (c > 0) {
        final base = s * 4;
        sig[base] /= c;
        sig[base + 1] /= c;
        sig[base + 2] /= c;
        sig[base + 3] /= c;
      }
    }
    return sig;
  }

  static List<double>? _blendSignatures(
    List<double>? oldSig,
    List<double>? newSig, {
    double alpha = 0.25,
  }) {
    if (newSig == null) return oldSig;
    if (oldSig == null || oldSig.length != newSig.length) {
      return List<double>.of(newSig);
    }
    final out = List<double>.filled(oldSig.length, 0.0);
    for (var i = 0; i < oldSig.length; i++) {
      out[i] = oldSig[i] * (1.0 - alpha) + newSig[i] * alpha;
    }
    return out;
  }

  static void _updateTrack(
    _SpeakerTrack track, {
    required double timeSec,
    required double cx,
    required double cy,
    required double w,
    required double h,
    required double x0,
    required double y0,
    required double x1,
    required double y1,
    required double tx0,
    required double ty0,
    required double tx1,
    required double ty1,
    required double yawDeg,
    List<double>? appSig,
    List<double>? torsoSig,
  }) {
    track.lastMoveDelta = sqrt(pow(track.normX - cx, 2) + pow(track.normY - cy, 2));
    track.hits++;
    track.lastSeenSec = timeSec;
    track.normX = cx;
    track.normY = cy;
    track.normW = w;
    track.normH = h;
    track.lastX0 = x0;
    track.lastY0 = y0;
    track.lastX1 = x1;
    track.lastY1 = y1;
    track.torsoX0 = tx0;
    track.torsoY0 = ty0;
    track.torsoX1 = tx1;
    track.torsoY1 = ty1;
    track.lastYawDeg = yawDeg;
    track.areaWeight = (1.0 + (w * h) * 8.0).clamp(1.0, 2.5);
    track.appearanceSig = _blendSignatures(track.appearanceSig, appSig);
    track.torsoSig = _blendSignatures(track.torsoSig, torsoSig);
  }

  static ({double cx, double cy})? _coastUnseenTrackViaTorso(
    _SpeakerTrack track,
    Uint8List silGrid,
    int w,
    int h,
  ) {
    if (track.torsoSig == null) return null;
    final tw = (track.torsoX1 - track.torsoX0).clamp(0.05, 0.4);
    final ty0 = track.torsoY0;
    final ty1 = track.torsoY1;
    final baseCx = (track.torsoX0 + track.torsoX1) * 0.5;

    var bestShift = 0.0;
    var bestSim = 0.72;
    for (var dx = -0.06; dx <= 0.0601; dx += 0.03) {
      final sx0 = (baseCx + dx - tw * 0.5).clamp(0.0, 1.0 - tw);
      final sx1 = sx0 + tw;
      final sig = _extractRegionSignature(silGrid, w, h, sx0, ty0, sx1, ty1);
      final sim = _signatureSimilarity(track.torsoSig, sig);
      if (sim > bestSim) {
        bestSim = sim;
        bestShift = dx;
      }
    }
    return (
      cx: (track.normX + bestShift).clamp(0.05, 0.95),
      cy: track.normY,
    );
  }

  static double _boxOverlap(
    double ax0,
    double ay0,
    double ax1,
    double ay1,
    double bx0,
    double by0,
    double bx1,
    double by1,
  ) {
    final ix0 = max(ax0, bx0);
    final iy0 = max(ay0, by0);
    final ix1 = min(ax1, bx1);
    final iy1 = min(ay1, by1);
    if (ix1 <= ix0 || iy1 <= iy0) return 0.0;
    final inter = (ix1 - ix0) * (iy1 - iy0);
    final union =
        max(1e-6, (ax1 - ax0) * (ay1 - ay0) + (bx1 - bx0) * (by1 - by0) - inter);
    return inter / union;
  }

  static Future<
      ({
        int width,
        int height,
        Uint8List silhouetteGrid,
        Uint8List mouthGrid,
        Uint8List? fullRgba,
      })?> _decodeAnalysisGrids(File file) async {
    try {
      final image = await _decodeImage(file);
      final w = image.width;
      final h = image.height;
      final bd = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (bd == null) return null;
      final full = bd.buffer.asUint8List();
      final sil = _boxDownsampleRgba(
        full,
        w,
        h,
        silhouetteGridWidth,
        silhouetteGridHeight,
      );
      final mouth = _boxDownsampleRgba(full, w, h, 240, 135);
      return (
        width: w,
        height: h,
        silhouetteGrid: sil,
        mouthGrid: mouth,
        fullRgba: full,
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _boxDownsampleRgba(
    Uint8List src,
    int srcW,
    int srcH,
    int dstW,
    int dstH,
  ) {
    final out = Uint8List(dstW * dstH * 4);
    for (var dy = 0; dy < dstH; dy++) {
      final sy0 = (dy * srcH) ~/ dstH;
      final sy1 = max(sy0 + 1, ((dy + 1) * srcH) ~/ dstH);
      for (var dx = 0; dx < dstW; dx++) {
        final sx0 = (dx * srcW) ~/ dstW;
        final sx1 = max(sx0 + 1, ((dx + 1) * srcW) ~/ dstW);
        var r = 0;
        var g = 0;
        var b = 0;
        var cnt = 0;
        for (var sy = sy0; sy < sy1; sy++) {
          for (var sx = sx0; sx < sx1; sx++) {
            final o = (sy * srcW + sx) * 4;
            r += src[o];
            g += src[o + 1];
            b += src[o + 2];
            cnt++;
          }
        }
        final doff = (dy * dstW + dx) * 4;
        if (cnt > 0) {
          out[doff] = r ~/ cnt;
          out[doff + 1] = g ~/ cnt;
          out[doff + 2] = b ~/ cnt;
        }
        out[doff + 3] = 255;
      }
    }
    return out;
  }

  static Future<ui.Image> _decodeImage(File file) async {
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static double? _resolveClipDuration({
    required double? probedDurationSec,
    required double startSec,
    required double? requestedDurationSec,
  }) {
    if (requestedDurationSec != null && requestedDurationSec > 0) {
      return requestedDurationSec;
    }
    if (probedDurationSec == null) return null;
    return max(0.0, probedDurationSec - startSec);
  }

  static Future<({double? durationSec, int width, int height})> _probeSource(
    String videoPath,
  ) async {
    final session = await FFprobeKit.getMediaInformation(videoPath);
    final info = session.getMediaInformation();
    if (info == null) return (durationSec: null, width: 0, height: 0);
    final dur = double.tryParse(info.getDuration() ?? '');
    var w = 0;
    var h = 0;
    for (final stream in info.getStreams()) {
      if (stream.getType() == 'video') {
        w = stream.getWidth() ?? 0;
        h = stream.getHeight() ?? 0;
        break;
      }
    }
    return (durationSec: dur, width: w, height: h);
  }

  /// Builds shot-aware, stabilized keyframes bounded by [maxKeyframes].
  static List<FaceTrackPoint> buildKeyframes(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    int maxKeyframes = FaceDetectionService.maxKeyframes,
  }) {
    if (rawPoints.isEmpty) return const <FaceTrackPoint>[];

    final ranges = _splitSegments(rawPoints, speakerJumpThreshold);
    final stabilized = <FaceTrackPoint>[];
    final availBudget = max(ranges.length, 96 - (ranges.length - 1) * 2);
    var remainingRaw = rawPoints.length;

    for (var i = 0; i < ranges.length; i++) {
      final (start, end) = ranges[i];
      final seg = rawPoints.sublist(start, end);
      if (seg.isEmpty) continue;

      final dead = min(deadZone * 0.35, 0.014);
      final sm = _stabilizeSegment(seg, dead, smoothness);
      if (sm.isEmpty) continue;

      final firstSm = sm.first;
      final canSmooth = i > 0 && firstSm.isSmoothPan && !firstSm.isCut;
      final isCut = !canSmooth;

      final med = _medianOf(sm);
      var maxDevX = 0.0;
      var maxDevY = 0.0;
      for (final p in sm) {
        maxDevX = max(maxDevX, (p.normX - med.$1).abs());
        maxDevY = max(maxDevY, (p.normY - med.$2).abs());
      }

      if (canSmooth && stabilized.isNotEmpty) {
        final prev = stabilized.last;
        final rampTime = firstSm.timeSec - 0.26;
        if (rampTime >= prev.timeSec + 0.02) {
          stabilized.add(
            FaceTrackPoint(
              timeSec: rampTime,
              normX: prev.normX,
              normY: prev.normY,
              faceWidth: prev.faceWidth,
              faceHeight: prev.faceHeight,
              isSpeaking: prev.isSpeaking,
              speakerId: prev.speakerId,
              isCut: false,
              isSmoothPan: true,
            ),
          );
        }
      }

      if (maxDevX <= shotSteadyTolerance && maxDevY <= shotSteadyTolerance) {
        stabilized.add(
          FaceTrackPoint(
            timeSec: firstSm.timeSec,
            normX: med.$1,
            normY: med.$2,
            faceWidth: firstSm.faceWidth,
            faceHeight: firstSm.faceHeight,
            isSpeaking: firstSm.isSpeaking,
            speakerId: firstSm.speakerId,
            isCut: isCut,
            isSmoothPan: canSmooth,
          ),
        );
      } else {
        final segBudget = remainingRaw > 0
            ? max(2, ((availBudget * seg.length) ~/ remainingRaw))
            : 2;
        final segOut = _simplifySegment(sm, segBudget);
        if (segOut.isNotEmpty) {
          segOut[0] = FaceTrackPoint(
            timeSec: segOut[0].timeSec,
            normX: segOut[0].normX,
            normY: segOut[0].normY,
            faceWidth: segOut[0].faceWidth,
            faceHeight: segOut[0].faceHeight,
            isSpeaking: segOut[0].isSpeaking,
            speakerId: segOut[0].speakerId,
            isCut: isCut,
            isManual: segOut[0].isManual,
            isSmoothPan: canSmooth,
          );
        }
        stabilized.addAll(segOut);
      }
      remainingRaw -= seg.length;
    }

    final budgeted = _enforceBudget(stabilized, maxKeyframes);
    return List<FaceTrackPoint>.unmodifiable(
      List<FaceTrackPoint>.from(budgeted),
    );
  }

  /// Applies per-shot tracking overrides ([ShotTrackingOverride]) and optional
  /// global person lock across [shots], returning updated keyframes.
  static List<FaceTrackPoint> buildKeyframesWithShotOverrides(
    FaceTrackResult track,
    List<SceneShot> shots,
    Map<int, ShotTrackingOverride> overrides,
    int? globalLockedSpeakerId, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    int maxKeyframes = FaceDetectionService.maxKeyframes,
  }) {
    if (shots.isEmpty) {
      if (globalLockedSpeakerId != null) {
        final prof = _findProfile(track.speakers, globalLockedSpeakerId);
        if (prof != null && prof.rawPoints.isNotEmpty) {
          return buildKeyframes(
            prof.rawPoints,
            deadZone: deadZone,
            smoothness: smoothness,
            maxKeyframes: maxKeyframes,
          );
        }
      }
      return buildKeyframes(
        track.rawPoints,
        deadZone: deadZone,
        smoothness: smoothness,
        maxKeyframes: maxKeyframes,
      );
    }

    final combined = <FaceTrackPoint>[];
    for (var si = 0; si < shots.length; si++) {
      final shot = shots[si];
      final ov = overrides[shot.id];
      final effectiveMode = ov?.mode ??
          (globalLockedSpeakerId != null
              ? ShotLockMode.specificPerson
              : ShotLockMode.autoSpeaker);
      final targetSpeaker = effectiveMode == ShotLockMode.specificPerson
          ? (ov?.targetSpeakerId ?? globalLockedSpeakerId)
          : null;

      if (effectiveMode == ShotLockMode.staticPosition) {
        final sx = (ov?.staticX ?? track.avgNormX).clamp(0.0, 1.0);
        final sy = (ov?.staticY ?? track.avgNormY).clamp(0.0, 1.0);
        combined.add(
          FaceTrackPoint(
            timeSec: shot.startSec,
            normX: sx,
            normY: sy,
            isCut: si > 0,
            isManual: true,
          ),
        );
        continue;
      }

      List<FaceTrackPoint> segPoints;
      if (effectiveMode == ShotLockMode.specificPerson &&
          targetSpeaker != null) {
        final prof = _findProfile(track.speakers, targetSpeaker);
        segPoints = _extractShotPointsForPerson(
          track.rawPoints,
          prof,
          shot.startSec,
          shot.endSec,
        );
      } else {
        segPoints = track.rawPoints
            .where((p) =>
                p.timeSec >= shot.startSec - 0.001 &&
                p.timeSec <= shot.endSec + 0.001)
            .toList();
      }

      if (segPoints.isEmpty) {
        final mid = (shot.startSec + shot.endSec) * 0.5;
        final sampled = FaceTrackResult.sampleKeyframes(track.keyframes, mid);
        segPoints = <FaceTrackPoint>[
          FaceTrackPoint(
            timeSec: shot.startSec,
            normX: sampled.$1,
            normY: sampled.$2,
            isCut: si > 0,
          ),
        ];
      }

      final segKeyframes = buildKeyframes(
        segPoints,
        deadZone: deadZone,
        smoothness: smoothness,
        maxKeyframes: maxKeyframes,
      );

      for (var ki = 0; ki < segKeyframes.length; ki++) {
        final kp = segKeyframes[ki];
        final forceCut = si > 0 && ki == 0 ? true : kp.isCut;
        if (combined.isNotEmpty &&
            (kp.timeSec - combined.last.timeSec).abs() <= 0.002) {
          combined[combined.length - 1] = kp.copyWith(isCut: kp.isCut || forceCut);
        } else {
          combined.add(kp.copyWith(isCut: kp.isCut || (si > 0 && ki == 0)));
        }
      }
    }

    final budgeted = _enforceBudget(combined, maxKeyframes);
    return List<FaceTrackPoint>.unmodifiable(
      List<FaceTrackPoint>.from(budgeted),
    );
  }

  static List<FaceTrackPoint> _extractShotPointsForPerson(
    List<FaceTrackPoint> rawPoints,
    DetectedSpeakerProfile? profile,
    double startSec,
    double endSec,
  ) {
    if (profile != null && profile.rawPoints.isNotEmpty) {
      final filtered = profile.rawPoints
          .where((p) => p.timeSec >= startSec - 0.001 && p.timeSec <= endSec + 0.001)
          .toList();
      if (filtered.isNotEmpty) {
        final out = <FaceTrackPoint>[];
        if (filtered.first.timeSec > startSec + 0.15) {
          final first = filtered.first;
          out.add(
            FaceTrackPoint(
              timeSec: startSec,
              normX: first.normX,
              normY: first.normY,
              faceWidth: first.faceWidth,
              faceHeight: first.faceHeight,
            ),
          );
        }
        out.addAll(filtered);
        return out;
      }
    }
    return rawPoints
        .where((p) => p.timeSec >= startSec - 0.001 && p.timeSec <= endSec + 0.001)
        .toList();
  }

  static DetectedSpeakerProfile? _findProfile(
    List<DetectedSpeakerProfile> profiles,
    int speakerId,
  ) {
    for (final p in profiles) {
      if (p.id == speakerId) return p;
    }
    return null;
  }

  static (double, double) _medianOf(List<FaceTrackPoint> points) {
    final xs = points.map((p) => p.normX).toList()..sort();
    final ys = points.map((p) => p.normY).toList()..sort();
    final mid = points.length ~/ 2;
    return (xs[mid], ys[mid]);
  }

  /// True if the transition between [a] and [b] is a hard cut rather than a pan.
  static bool isEffectiveCut(FaceTrackPoint a, FaceTrackPoint b) {
    if (b.isCut) return true;
    if (b.isManual || b.isSmoothPan) return false;
    if (b.timeSec - a.timeSec <= 0.05) return true;
    return (b.normX - a.normX).abs() >= speakerJumpThreshold;
  }

  /// Inserts 1 ms hold anchors before effective cuts for crisp FFmpeg expressions.
  static List<FaceTrackPoint> materializeKeyframesForFfmpeg(
    List<FaceTrackPoint> keyframes,
  ) {
    if (keyframes.length < 2) return List<FaceTrackPoint>.of(keyframes);
    final out = <FaceTrackPoint>[keyframes.first];
    for (var i = 1; i < keyframes.length; i++) {
      final prev = out.last;
      final cur = keyframes[i];
      if (isEffectiveCut(prev, cur)) {
        final holdTime = max(prev.timeSec + 0.001, cur.timeSec - 0.001);
        if (holdTime < cur.timeSec) {
          out.add(
            FaceTrackPoint(
              timeSec: holdTime,
              normX: prev.normX,
              normY: prev.normY,
              faceWidth: prev.faceWidth,
              faceHeight: prev.faceHeight,
              speakerId: prev.speakerId,
            ),
          );
        }
      }
      out.add(cur);
    }
    return List<FaceTrackPoint>.unmodifiable(List<FaceTrackPoint>.from(out));
  }

  /// Sorts keyframes chronologically and collapses near-duplicate timestamps (<= 2 ms).
  static List<FaceTrackPoint> normalizeKeyframesForEditing(
    List<FaceTrackPoint> keyframes,
  ) {
    if (keyframes.isEmpty) return const <FaceTrackPoint>[];
    final sorted = List<FaceTrackPoint>.of(keyframes)
      ..sort((a, b) => a.timeSec.compareTo(b.timeSec));

    final out = <FaceTrackPoint>[sorted.first];
    for (var i = 1; i < sorted.length; i++) {
      final cur = sorted[i];
      if (cur.timeSec - out.last.timeSec <= 0.002) {
        out[out.length - 1] = FaceTrackPoint(
          timeSec: cur.timeSec,
          normX: cur.normX,
          normY: cur.normY,
          faceWidth: cur.faceWidth,
          faceHeight: cur.faceHeight,
          isSpeaking: cur.isSpeaking,
          speakerId: cur.speakerId,
          isCut: cur.isCut,
          isManual: cur.isManual,
          isSmoothPan: cur.isSmoothPan,
        );
      } else {
        out.add(cur);
      }
    }
    return List<FaceTrackPoint>.unmodifiable(List<FaceTrackPoint>.from(out));
  }

  /// Inserts or updates a manual keyframe and prunes conflicting AI keyframes.
  static List<FaceTrackPoint> upsertManualKeyframe(
    List<FaceTrackPoint> keyframes, {
    required double timeSec,
    required double normX,
    required double normY,
    bool isCut = false,
    double tolerance = manualKeyframeToleranceSec,
  }) {
    final normalized = List<FaceTrackPoint>.of(
      normalizeKeyframesForEditing(keyframes),
    );

    var bestIdx = -1;
    var bestDt = double.infinity;
    for (var i = 0; i < normalized.length; i++) {
      final dt = (normalized[i].timeSec - timeSec).abs();
      if (dt <= tolerance && dt < bestDt) {
        bestDt = dt;
        bestIdx = i;
      }
    }

    final clampedX = normX.clamp(0.0, 1.0);
    final clampedY = normY.clamp(0.0, 1.0);

    if (bestIdx >= 0) {
      normalized[bestIdx] = normalized[bestIdx].copyWith(
        normX: clampedX,
        normY: clampedY,
        isCut: isCut,
        isManual: true,
      );
      _pruneConflictingAiKeyframes(normalized, bestIdx);
    } else {
      final point = FaceTrackPoint(
        timeSec: timeSec,
        normX: clampedX,
        normY: clampedY,
        isCut: isCut,
        isManual: true,
      );
      normalized.add(point);
      normalized.sort((a, b) => a.timeSec.compareTo(b.timeSec));
      final insertedIdx = normalized.indexWhere(
        (p) => p.isManual && (p.timeSec - point.timeSec).abs() <= 0.0005,
      );
      if (insertedIdx >= 0) {
        _pruneConflictingAiKeyframes(normalized, insertedIdx);
      }
    }
    return List<FaceTrackPoint>.unmodifiable(List<FaceTrackPoint>.from(normalized));
  }

  static void _pruneConflictingAiKeyframes(
    List<FaceTrackPoint> out,
    int insertedIdx,
  ) {
    final anchor = out[insertedIdx];
    final userTime = anchor.timeSec;

    var prevManualIdx = -1;
    for (var i = insertedIdx - 1; i >= 0; i--) {
      if (out[i].isManual && userTime - out[i].timeSec <= 12.0) {
        prevManualIdx = i;
        break;
      }
    }
    var nextManualIdx = -1;
    for (var i = insertedIdx + 1; i < out.length; i++) {
      if (out[i].isManual && out[i].timeSec - userTime <= 12.0) {
        nextManualIdx = i;
        break;
      }
    }

    final kept = <FaceTrackPoint>[];
    for (var i = 0; i < out.length; i++) {
      final p = out[i];
      if (i == insertedIdx || p.isManual) {
        kept.add(p);
        continue;
      }
      if (prevManualIdx >= 0 && i > prevManualIdx && i < insertedIdx) {
        continue;
      }
      if (nextManualIdx >= 0 && i > insertedIdx && i < nextManualIdx) {
        continue;
      }
      final dtSigned = p.timeSec - userTime;
      if (dtSigned.abs() <= 0.45) {
        continue;
      }
      if (nextManualIdx < 0 &&
          dtSigned > 0 &&
          dtSigned <= 4.0 &&
          (!p.isCut || dtSigned <= 1.5)) {
        continue;
      }
      kept.add(p);
    }

    // Clear hard-cut flag when smoothly leaving a manual keyframe onto an AI cut.
    for (var i = 1; i < kept.length; i++) {
      if (kept[i - 1].isManual && !kept[i].isManual && kept[i].isCut) {
        kept[i] = kept[i].copyWith(isCut: false);
      }
    }

    out
      ..clear()
      ..addAll(kept);
  }

  /// Removes keyframe at [index] when more than one keyframe remains.
  static List<FaceTrackPoint> deleteKeyframe(
    List<FaceTrackPoint> keyframes,
    int index,
  ) {
    if (keyframes.length <= 1 || index < 0 || index >= keyframes.length) {
      return List<FaceTrackPoint>.of(keyframes);
    }
    final out = List<FaceTrackPoint>.of(keyframes)..removeAt(index);
    return List<FaceTrackPoint>.unmodifiable(List<FaceTrackPoint>.from(out));
  }

  /// Stabilizes [rawPoints] segment-by-segment preserving hard speaker cuts.
  static List<FaceTrackPoint> stabilizeTrack(
    List<FaceTrackPoint> rawPoints, {
    double deadZone = defaultDeadZone,
    double smoothness = defaultSmoothness,
    double jumpThreshold = speakerJumpThreshold,
  }) {
    if (rawPoints.isEmpty) return const <FaceTrackPoint>[];
    final ranges = _splitSegments(rawPoints, jumpThreshold);
    final out = <FaceTrackPoint>[];
    for (final (start, end) in ranges) {
      final seg = rawPoints.sublist(start, end);
      if (seg.isEmpty) continue;
      final stabilized = _stabilizeSegment(seg, deadZone, smoothness);
      if (start > 0 && stabilized.isNotEmpty) {
        stabilized[0] = stabilized[0].copyWith(isCut: true);
      }
      out.addAll(stabilized);
    }
    return List<FaceTrackPoint>.unmodifiable(List<FaceTrackPoint>.from(out));
  }

  static List<(int, int)> _splitSegments(
    List<FaceTrackPoint> rawPoints,
    double threshold,
  ) {
    final ranges = <(int, int)>[];
    var segStart = 0;
    for (var i = 1; i < rawPoints.length; i++) {
      final prev = rawPoints[i - 1];
      final cur = rawPoints[i];
      final dx = (cur.normX - prev.normX).abs();
      final dy = (cur.normY - prev.normY).abs();
      final gap = cur.timeSec - prev.timeSec;
      if (cur.isCut ||
          cur.isSmoothPan ||
          dx >= threshold ||
          dy >= threshold ||
          gap > 1.5) {
        ranges.add((segStart, i));
        segStart = i;
      }
    }
    ranges.add((segStart, rawPoints.length));
    return ranges;
  }

  static List<FaceTrackPoint> _stabilizeSegment(
    List<FaceTrackPoint> points,
    double deadZone,
    double smoothness,
  ) {
    if (points.length <= 1) return List<FaceTrackPoint>.of(points);

    final anchored = <FaceTrackPoint>[];
    var anchorX = points.first.normX;
    var anchorY = points.first.normY;
    for (final p in points) {
      final dx = (p.normX - anchorX).abs();
      final dy = (p.normY - anchorY).abs();
      if (dx > deadZone) anchorX = p.normX;
      if (dy > deadZone) anchorY = p.normY;
      anchored.add(
        FaceTrackPoint(
          timeSec: p.timeSec,
          normX: anchorX,
          normY: anchorY,
          faceWidth: p.faceWidth,
          faceHeight: p.faceHeight,
          isSpeaking: p.isSpeaking,
          speakerId: p.speakerId,
          isCut: p.isCut,
          isManual: p.isManual,
          isSmoothPan: p.isSmoothPan,
        ),
      );
    }

    final alpha = smoothness.clamp(0.01, 1.0);
    final forward = List<FaceTrackPoint>.of(anchored);
    for (var i = 1; i < forward.length; i++) {
      final prev = forward[i - 1];
      final cur = forward[i];
      forward[i] = cur.copyWith(
        normX: alpha * cur.normX + (1.0 - alpha) * prev.normX,
        normY: alpha * cur.normY + (1.0 - alpha) * prev.normY,
      );
    }

    final backward = List<FaceTrackPoint>.of(forward);
    for (var i = backward.length - 2; i >= 0; i--) {
      final next = backward[i + 1];
      final cur = backward[i];
      backward[i] = cur.copyWith(
        normX: alpha * cur.normX + (1.0 - alpha) * next.normX,
        normY: alpha * cur.normY + (1.0 - alpha) * next.normY,
      );
    }
    return backward;
  }

  static List<FaceTrackPoint> _simplifySegment(
    List<FaceTrackPoint> points, [
    int targetMax = maxKeyframes,
  ]) {
    if (points.length <= targetMax) return List<FaceTrackPoint>.of(points);
    var tol = 0.002;
    for (var step = 0; step < 30; step++) {
      final simplified = _rdp(points, epsilon: tol);
      if (simplified.length <= targetMax) return simplified;
      tol *= 1.6;
    }
    final stride = (points.length - 1) / max(1, targetMax - 1);
    final sampled = <FaceTrackPoint>[];
    for (var i = 0; i < targetMax; i++) {
      final idx = (i * stride).round().clamp(0, points.length - 1);
      sampled.add(points[idx]);
    }
    return sampled;
  }

  static List<FaceTrackPoint> _enforceBudget(
    List<FaceTrackPoint> points,
    int maxKeyframes,
  ) {
    if (points.length <= maxKeyframes) return points;
    var result = List<FaceTrackPoint>.of(points);
    var epsilon = 0.012;
    while (result.length > maxKeyframes && epsilon < 0.25) {
      result = _rdp(result, epsilon: epsilon);
      epsilon *= 1.5;
    }
    if (result.length > maxKeyframes) {
      final step = (result.length - 1) / (maxKeyframes - 1);
      final sampled = <FaceTrackPoint>[];
      for (var i = 0; i < maxKeyframes; i++) {
        sampled.add(result[min(result.length - 1, (i * step).round())]);
      }
      return sampled;
    }
    return result;
  }

  /// Simplifies [points] with Ramer-Douglas-Peucker while preserving cuts/manual anchors.
  static List<FaceTrackPoint> simplifyKeyframes(
    List<FaceTrackPoint> points, {
    int maxKeyframes = FaceDetectionService.maxKeyframes,
  }) {
    if (points.length <= 2 || points.length <= maxKeyframes) {
      return List<FaceTrackPoint>.unmodifiable(List<FaceTrackPoint>.from(points));
    }
    return List<FaceTrackPoint>.unmodifiable(
      List<FaceTrackPoint>.from(_enforceBudget(points, maxKeyframes)),
    );
  }

  static List<FaceTrackPoint> _rdp(
    List<FaceTrackPoint> points, {
    double epsilon = 0.01,
  }) {
    if (points.length <= 2) return List<FaceTrackPoint>.of(points);
    final startT = points.first.timeSec;
    final endT = points.last.timeSec;
    final timeSpan = max(1e-6, endT - startT);
    const timeScale = 0.05;

    double px(FaceTrackPoint p) => ((p.timeSec - startT) / timeSpan) * timeScale;

    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;

    for (var i = 1; i < points.length - 1; i++) {
      if (points[i].isCut || points[i].isManual) keep[i] = true;
    }

    void recurse(int lo, int hi) {
      if (hi <= lo + 1) return;
      final a = points[lo];
      final b = points[hi];
      var maxDist = 0.0;
      var maxIdx = -1;
      final ax = px(a);
      final bx = px(b);
      for (var i = lo + 1; i < hi; i++) {
        final d = _perpendicularDistance(
          px(points[i]),
          points[i].normX,
          points[i].normY,
          ax,
          a.normX,
          a.normY,
          bx,
          b.normX,
          b.normY,
        );
        if (d > maxDist) {
          maxDist = d;
          maxIdx = i;
        }
      }
      if (maxDist > epsilon && maxIdx >= 0) {
        keep[maxIdx] = true;
        recurse(lo, maxIdx);
        recurse(maxIdx, hi);
      }
    }

    recurse(0, points.length - 1);
    final out = <FaceTrackPoint>[];
    for (var i = 0; i < points.length; i++) {
      if (keep[i]) out.add(points[i]);
    }
    return out;
  }

  static double _perpendicularDistance(
    double pt,
    double px,
    double py,
    double at,
    double ax,
    double ay,
    double bt,
    double bx,
    double by,
  ) {
    final dt = bt - at;
    final dx = bx - ax;
    final dy = by - ay;
    final lenSq = dt * dt + dx * dx + dy * dy;
    if (lenSq <= 1e-12) {
      return sqrt(pow(px - ax, 2) + pow(py - ay, 2));
    }
    final u = (((pt - at) * dt + (px - ax) * dx + (py - ay) * dy) / lenSq)
        .clamp(0.0, 1.0);
    final cx = ax + u * dx;
    final cy = ay + u * dy;
    return sqrt(pow(px - cx, 2) + pow(py - cy, 2));
  }

  /// Shorts generator helper: returns the horizontal pixel center of the face.
  static Future<double?> detectFaceCenterX(
    String videoPath,
    double startSec,
    double endSec,
  ) async {
    final res = await analyzeVideoFaceTrack(
      videoPath,
      startSec: startSec,
      endSec: endSec,
    );
    if (res == null) return null;
    final width = res.sourceWidth > 0 ? res.sourceWidth : 1080;
    return res.avgNormX * width;
  }

  /// Shorts generator helper: returns evenly spaced horizontal pixel X samples.
  static Future<List<double>?> detectFacePath(
    String videoPath,
    double startSec,
    double endSec,
  ) async {
    final dur = endSec - startSec;
    if (dur < 1.0) return null;
    final res = await analyzeVideoFaceTrack(
      videoPath,
      startSec: startSec,
      endSec: endSec,
    );
    if (res == null) return null;
    final count = dur.round().clamp(6, 240);
    final width = res.sourceWidth > 0 ? res.sourceWidth : 1080;
    return List<double>.generate(count, (i) {
      final t = startSec + dur * (i / max(1, count - 1));
      return (res.sampleAt(t).$1 * width).clamp(0.0, width.toDouble());
    });
  }
}
