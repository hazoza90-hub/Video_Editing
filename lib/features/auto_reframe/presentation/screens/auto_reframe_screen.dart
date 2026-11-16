import 'dart:io';
import 'dart:math';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/services/face_detection_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/logger.dart';
import '../../data/services/ffmpeg_auto_reframe_service.dart';
import '../../domain/entities/reframe_config.dart';

/// Standalone Auto Reframe studio: real ML Kit speaker tracking, a live crop
/// overlay, and an FFmpeg render for any target aspect ratio.
class AutoReframeScreen extends StatefulWidget {
  final String videoPath;

  const AutoReframeScreen({super.key, required this.videoPath});

  /// Pure clamp math (unit-tested): keeps the crop window fully inside the
  /// source frame for the given effective output aspect.
  static (double, double) clampCenterForAspect(
    double normX,
    double normY,
    double previewW,
    double previewH,
    double effectiveAspect,
  ) {
    if (previewW <= 0 || previewH <= 0) return (normX, normY);
    final sourceAspect = previewW / previewH;
    double cropW;
    double cropH;
    if (sourceAspect > effectiveAspect) {
      cropH = 1.0;
      cropW = effectiveAspect / sourceAspect;
    } else {
      cropW = 1.0;
      cropH = sourceAspect / effectiveAspect;
    }
    return (
      normX.clamp(cropW / 2, 1 - cropW / 2),
      normY.clamp(cropH / 2, 1 - cropH / 2),
    );
  }

  /// Pure drag-step math (unit-tested): `onPanUpdate` delivers PER-FRAME
  /// incremental pixel deltas, so each step must be applied to the CURRENT
  /// drag position (the caller advances the origin with the returned,
  /// clamped center). Applying deltas to the fixed `onPanStart` origin would
  /// move the box by only one frame's delta (~2px) for the whole gesture.
  static (double, double) dragStepCenter({
    required (double, double) origin,
    required double deltaXPx,
    required double deltaYPx,
    required double previewW,
    required double previewH,
    required double effectiveAspect,
  }) {
    if (previewW <= 0 || previewH <= 0) return origin;
    return clampCenterForAspect(
      origin.$1 + deltaXPx / previewW,
      origin.$2 + deltaYPx / previewH,
      previewW,
      previewH,
      effectiveAspect,
    );
  }

  @override
  State<AutoReframeScreen> createState() => _AutoReframeScreenState();
}

class _AutoReframeScreenState extends State<AutoReframeScreen> {
  final _reframeService = FfmpegAutoReframeService();

  VideoPlayerController? _controller;
  bool _playerReady = false;
  Duration _duration = Duration.zero;
  String? _error;

  FaceTrackResult? _track;

  /// The trajectory actually rendered/previewed: auto active-speaker path, or
  /// the locked person's path when `selectedSpeakerId` is set. Recomputed only
  /// when the analysis, motion preset or speaker selection changes.
  FaceTrackResult? _effectiveTrack;

  /// AI-generated keyframes (normalized for editing) — the "Reset AI" base.
  List<FaceTrackPoint> _aiKeyframes = const [];

  /// User-editable keyframe list driving preview + render. Re-initialized
  /// whenever [_recomputeEffectiveTrack] runs.
  List<FaceTrackPoint> _workingKeyframes = const [];

  /// Pixel radius within which the magnetic timeline snaps the playhead to
  /// a keyframe marker (CapCut-style magnetic scrubbing).
  static const double magneticSnapPx = 12.0;

  /// Last keyframe the magnetic timeline snapped to during the current
  /// gesture (haptic feedback fires once per newly-snapped keyframe).
  double? _lastSnappedKfSec;

  /// Crop-box drag origin (normalized), kept across a pan gesture.
  (double, double)? _dragOrigin;

  bool _analyzing = false;
  double _analysisProgress = 0;
  String _analysisStatus = '';

  List<SceneShot> _shots = const [];
  final Map<int, ShotTrackingOverride> _shotOverrides = {};
  bool _cameraViewMode = true;
  bool _showTapBoxes = true;

  ReframeConfig _config = const ReframeConfig();
  bool _rendering = false;

  late final TextEditingController _customWidthController;
  late final TextEditingController _customHeightController;

  @override
  void initState() {
    super.initState();
    _customWidthController = TextEditingController(
      text: _config.customWidthRatio.toStringAsFixed(0),
    );
    _customHeightController = TextEditingController(
      text: _config.customHeightRatio.toStringAsFixed(0),
    );
    _initialize();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onPlayerTick);
    _controller?.dispose();
    _customWidthController.dispose();
    _customHeightController.dispose();
    super.dispose();
  }

  void _onPlayerTick() {
    if (mounted) setState(() {});
  }

  double get _durationSeconds => _duration.inMilliseconds / 1000;

  double get _positionSeconds {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return 0;
    return controller.value.position.inMilliseconds / 1000;
  }

  Future<void> _initialize() async {
    await _probeDuration();
    try {
      final controller = VideoPlayerController.file(File(widget.videoPath));
      _controller = controller;
      await controller.initialize();
      controller.addListener(_onPlayerTick);
      if (_duration == Duration.zero) {
        _duration = controller.value.duration;
      }
      if (mounted) setState(() => _playerReady = true);
    } catch (e, stack) {
      AppLogger().e('AutoReframe: player init failed', e, stack);
      if (mounted) {
        setState(() => _error = 'Could not open this video: $e');
      }
    }
    await _analyzeFaces();
  }

  /// FFprobe first, player duration as fallback (Release builds can lose the
  /// FFprobe JNI bridge, which must never block the feature).
  Future<void> _probeDuration() async {
    try {
      final session = await FFprobeKit.getMediaInformation(widget.videoPath);
      final info = session.getMediaInformation();
      final seconds = double.tryParse(info?.getDuration() ?? '') ?? 0;
      if (seconds > 0 && mounted) {
        setState(
          () => _duration = Duration(milliseconds: (seconds * 1000).round()),
        );
      }
    } catch (e) {
      AppLogger().e('AutoReframe: probe failed', e);
    }
  }

  Future<void> _analyzeFaces() async {
    if (_analyzing) return;
    setState(() {
      _analyzing = true;
      _analysisProgress = 0;
      _analysisStatus = 'Preparing face analysis...';
    });
    final result = await FaceDetectionService.analyzeVideoFaceTrack(
      widget.videoPath,
      durationSec: _durationSeconds > 0 ? _durationSeconds : null,
      deadZone: _config.motion.deadZone,
      smoothness: _config.motion.smoothness,
      onProgress: (progress, status) {
        if (!mounted) return;
        setState(() {
          _analysisProgress = progress;
          _analysisStatus = status;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _shotOverrides.clear();
      if (result == null) {
        _track = null;
        final dur = _durationSeconds;
        _shots = dur > 0
            ? [SceneShot(id: 0, startSec: 0, endSec: dur)]
            : const [];
        _analyzing = false;
        _analysisStatus = 'No face found — center crop will be used';
      } else {
        _track = result;
        final dur = max(
          _durationSeconds,
          result.rawPoints.isNotEmpty ? result.rawPoints.last.timeSec : 1.0,
        );
        _shots = result.shots.isNotEmpty
            ? List<SceneShot>.of(result.shots)
            : (dur > 0
                ? [SceneShot(id: 0, startSec: 0, endSec: dur)]
                : const []);
        _analyzing = false;
      }
      _recomputeEffectiveTrack();
    });
  }

  /// Resolves the path used by preview + render: the auto active-speaker
  /// trajectory, per-shot locks, or the locked person's trajectory, then
  /// (re)initializes the manual keyframe editor from those keyframes.
  void _recomputeEffectiveTrack() {
    final track = _track;
    if (track == null) {
      _effectiveTrack = null;
      _aiKeyframes = const [];
      _workingKeyframes = const [];
      return;
    }

    final id = _config.selectedSpeakerId;
    DetectedSpeakerProfile? lockedProfile;
    if (id != null) {
      for (final candidate in track.speakers) {
        if (candidate.id == id) {
          lockedProfile = candidate;
          break;
        }
      }
    }

    final List<FaceTrackPoint> keyframes;
    if (_shots.isNotEmpty && (_shotOverrides.isNotEmpty || id != null)) {
      keyframes = FaceDetectionService.buildKeyframesWithShotOverrides(
        track,
        _shots,
        _shotOverrides,
        id,
        deadZone: _config.motion.deadZone,
        smoothness: _config.motion.smoothness,
      );
    } else if (id == null) {
      keyframes = FaceDetectionService.buildKeyframes(
        track.rawPoints,
        deadZone: _config.motion.deadZone,
        smoothness: _config.motion.smoothness,
      );
    } else if (lockedProfile != null) {
      keyframes = FaceDetectionService.buildKeyframes(
        lockedProfile.rawPoints,
        deadZone: _config.motion.deadZone,
        smoothness: _config.motion.smoothness,
      );
    } else {
      keyframes = track.keyframes;
    }

    final useLockedProfileOnly = lockedProfile != null && _shotOverrides.isEmpty;
    final resolved = FaceTrackResult(
      rawPoints: useLockedProfileOnly ? lockedProfile.rawPoints : track.rawPoints,
      keyframes: keyframes,
      avgNormX: useLockedProfileOnly ? lockedProfile.avgNormX : track.avgNormX,
      avgNormY: useLockedProfileOnly ? lockedProfile.avgNormY : track.avgNormY,
      facesDetectedCount: track.facesDetectedCount,
      speakers: track.speakers,
      shots: List<SceneShot>.unmodifiable(_shots),
      sourceWidth: track.sourceWidth,
      sourceHeight: track.sourceHeight,
    );
    _effectiveTrack = resolved;

    // Clean, editable keyframes: fold synthetic 1ms helpers into single
    // cut keyframes and flag every >= 0.135 jump as an instant cut.
    _aiKeyframes = FaceDetectionService.normalizeKeyframesForEditing(
      resolved.keyframes,
    );
    _workingKeyframes = List<FaceTrackPoint>.of(_aiKeyframes);
  }

  // ---------------------------------------------------------------------------
  // Manual keyframe editor
  // ---------------------------------------------------------------------------

  /// Working-keyframe position at [timeSec], honoring `isCut` holds/snaps.
  (double, double) _currentSampledPosition(double timeSec) {
    final keyframes = _workingKeyframes;
    if (keyframes.isEmpty) {
      return _effectiveTrack?.sampleAt(timeSec) ?? (0.5, 0.42);
    }
    return FaceTrackResult.sampleKeyframes(keyframes, timeSec);
  }

  /// Index of the keyframe nearest to [timeSec] (`-1` when there is none).
  int _nearestKfIndex(double timeSec) {
    final keyframes = _workingKeyframes;
    if (keyframes.isEmpty) return -1;
    var best = 0;
    var bestDelta = double.infinity;
    for (var i = 0; i < keyframes.length; i++) {
      final delta = (keyframes[i].timeSec - timeSec).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = i;
      }
    }
    return best;
  }

  /// Insert-or-update a manual keyframe at [timeSec] (or lock current shot
  /// to a static position when its override mode is [ShotLockMode.staticPosition]).
  void _upsertManualKeyframeAt(double timeSec, double normX, double normY) {
    final currentShot = _currentShotAt(timeSec);
    if (currentShot != null &&
        _shotOverrides[currentShot.id]?.mode == ShotLockMode.staticPosition) {
      _setShotModeStaticPosition(currentShot, normX, normY);
      return;
    }
    setState(() {
      _workingKeyframes = FaceDetectionService.upsertManualKeyframe(
        _workingKeyframes,
        timeSec: timeSec,
        normX: normX,
        normY: normY,
      );
    });
  }

  void _setShotModeStaticPosition(SceneShot shot, double normX, double normY) {
    setState(() {
      _shotOverrides[shot.id] = ShotTrackingOverride(
        mode: ShotLockMode.staticPosition,
        staticX: normX,
        staticY: normY,
      );
      _recomputeEffectiveTrack();
    });
  }

  void _setShotModePerson(SceneShot shot, int speakerId) {
    setState(() {
      _shotOverrides[shot.id] = ShotTrackingOverride(
        mode: ShotLockMode.specificPerson,
        targetSpeakerId: speakerId,
      );
      _recomputeEffectiveTrack();
    });
  }

  void _setShotModeAutoSpeaker(SceneShot shot) {
    setState(() {
      _shotOverrides[shot.id] = const ShotTrackingOverride(
        mode: ShotLockMode.autoSpeaker,
      );
      _recomputeEffectiveTrack();
    });
  }

  int _currentShotIndexAt(double timeSec) {
    if (_shots.isEmpty) return -1;
    for (var i = 0; i < _shots.length; i++) {
      final s = _shots[i];
      if (timeSec >= s.startSec - 0.001 && timeSec <= s.endSec + 0.001) {
        return i;
      }
    }
    if (timeSec <= _shots.first.startSec) return 0;
    return _shots.length - 1;
  }

  SceneShot? _currentShotAt(double timeSec) {
    final idx = _currentShotIndexAt(timeSec);
    if (idx < 0 || idx >= _shots.length) return null;
    return _shots[idx];
  }

  void _jumpShot(int direction) {
    if (_shots.isEmpty) return;
    final idx = _currentShotIndexAt(_positionSeconds);
    if (idx < 0) return;
    if (direction < 0) {
      if (_positionSeconds - _shots[idx].startSec <= 0.4) {
        final target = idx > 0 ? _shots[idx - 1].startSec + 0.02 : 0.0;
        _seekToTime(target);
      } else {
        _seekToTime(_shots[idx].startSec + 0.02);
      }
    } else if (idx + 1 < _shots.length) {
      _seekToTime(_shots[idx + 1].startSec + 0.02);
    }
  }

  void _mergeCurrentShot() {
    if (_shots.length < 2) return;
    final idx = _currentShotIndexAt(_positionSeconds);
    if (idx < 0) return;
    setState(() {
      final list = List<SceneShot>.of(_shots);
      if (idx <= 0) {
        list[0] = list[0].copyWith(endSec: list[1].endSec);
        _shotOverrides.remove(list[1].id);
        list.removeAt(1);
      } else {
        list[idx - 1] = list[idx - 1].copyWith(endSec: list[idx].endSec);
        _shotOverrides.remove(list[idx].id);
        list.removeAt(idx);
      }
      _shots = list;
      _recomputeEffectiveTrack();
    });
  }

  void _splitShotAtPlayhead() {
    if (_shots.isEmpty) {
      if (_durationSeconds <= 0.6) return;
      setState(() {
        _shots = [SceneShot(id: 0, startSec: 0, endSec: _durationSeconds)];
      });
    }
    final t = _positionSeconds;
    final idx = _currentShotIndexAt(t);
    if (idx < 0) return;
    final shot = _shots[idx];
    if (t - shot.startSec < 0.3 || shot.endSec - t < 0.3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'حرك المؤشر داخل اللقطة (بفارق 0.3 ثانية على الأقل عن البداية/النهاية) لتقسيمها',
          ),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final nextId = _shots.fold<int>(0, (mx, s) => max(mx, s.id)) + 1;
    setState(() {
      final list = List<SceneShot>.of(_shots);
      list[idx] = SceneShot(id: shot.id, startSec: shot.startSec, endSec: t);
      list.insert(
        idx + 1,
        SceneShot(id: nextId, startSec: t, endSec: shot.endSec),
      );
      if (_shotOverrides.containsKey(shot.id)) {
        _shotOverrides[nextId] = _shotOverrides[shot.id]!;
      }
      _shots = list;
      _recomputeEffectiveTrack();
    });
    HapticFeedback.mediumImpact();
  }

  void _seekToTime(double timeSec) {
    final controller = _controller;
    if (controller == null || _durationSeconds <= 0) return;
    final clamped = timeSec.clamp(0.0, _durationSeconds);
    controller.seekTo(Duration(milliseconds: (clamped * 1000).round()));
    setState(() {});
  }

  /// Index of a keyframe the playhead currently sits on (±0.25s), or -1.
  int _keyframeAtPlayheadIndex() {
    final keyframes = _workingKeyframes;
    if (keyframes.isEmpty) return -1;
    var best = -1;
    var bestDelta = FaceDetectionService.manualKeyframeToleranceSec;
    for (var i = 0; i < keyframes.length; i++) {
      final delta = (keyframes[i].timeSec - _positionSeconds).abs();
      if (delta <= bestDelta) {
        bestDelta = delta;
        best = i;
      }
    }
    return best;
  }

  /// The single smart `◆+ Add KF` / `◆- Delete KF` button: drops a keyframe
  /// at the playhead, or removes the one the playhead sits on.
  void _smartKeyframeToggle() {
    final index = _keyframeAtPlayheadIndex();
    if (index >= 0) {
      _deleteKeyframeAt(index);
      return;
    }
    final (x, y) = _currentSampledPosition(_positionSeconds);
    _upsertManualKeyframeAt(_positionSeconds, x, y);
  }

  void _deleteKeyframeAt(int index) {
    setState(() {
      _workingKeyframes = FaceDetectionService.deleteKeyframe(
        _workingKeyframes,
        index,
      );
    });
  }

  /// `Center ⌖`: parks the current keyframe at the frame center (0.5, 0.45).
  void _centerCurrentKeyframe() {
    final onIdx = _keyframeAtPlayheadIndex();
    final index =
        onIdx >= 0 ? onIdx : _nearestKfIndex(_positionSeconds);
    if (index < 0) return;
    setState(() {
      final updated = List<FaceTrackPoint>.of(_workingKeyframes);
      updated[index] = updated[index].copyWith(
        normX: 0.5,
        normY: 0.45,
        isManual: true,
      );
      _workingKeyframes = updated;
    });
  }

  /// `Clear All 🗑️`: drops every AI keyframe and leaves one centered keyframe
  /// at 0:00 so the whole video can be keyframed manually from scratch.
  void _clearAllKeyframes() {
    setState(() {
      _workingKeyframes = [
        const FaceTrackPoint(
          timeSec: 0,
          normX: 0.5,
          normY: 0.45,
          isManual: true,
        ),
      ];
    });
  }

  /// Toggles the transition of the current keyframe. Marked `isManual` so the
  /// automatic cut heuristics never override the user's choice.
  void _toggleCutForCurrentKeyframe() {
    final onIdx = _keyframeAtPlayheadIndex();
    final index =
        onIdx >= 0 ? onIdx : _nearestKfIndex(_positionSeconds);
    if (index < 0) return;
    setState(() {
      final updated = List<FaceTrackPoint>.of(_workingKeyframes);
      final point = updated[index];
      updated[index] = point.copyWith(isCut: !point.isCut, isManual: true);
      _workingKeyframes = updated;
    });
  }

  void _resetKeyframes() {
    setState(() => _workingKeyframes = List<FaceTrackPoint>.of(_aiKeyframes));
  }

  /// -1 = previous keyframe before the playhead, +1 = next one after it.
  void _jumpKeyframe(int direction) {
    final position = _positionSeconds;
    double? target;
    if (direction < 0) {
      for (final point in _workingKeyframes) {
        if (point.timeSec < position - 0.05) target = point.timeSec;
      }
    } else {
      for (final point in _workingKeyframes) {
        if (point.timeSec > position + 0.05) {
          target = point.timeSec;
          break;
        }
      }
    }
    if (target != null) _seekToTime(target);
  }

  /// Output crop aspect after `frameFill` (mirrors the FFmpeg inner box).
  double _effectiveCropAspect() {
    final (outW, outH) = _config.outputSize;
    final box = FfmpegAutoReframeService.innerBoxForFill(
      outW: outW,
      outH: outH,
      frameFill: _config.frameFillClamped,
    );
    return box.boxW / box.boxH;
  }

  /// Keeps the crop window fully inside the source frame while dragging.
  (double, double) _clampCropCenter(
    double normX,
    double normY,
    double previewW,
    double previewH,
  ) {
    return AutoReframeScreen.clampCenterForAspect(
      normX,
      normY,
      previewW,
      previewH,
      _effectiveCropAspect(),
    );
  }

  // --- Direct crop-box dragging ---------------------------------------------

  void _onCropPanStart() {
    final controller = _controller;
    if (controller != null && controller.value.isPlaying) controller.pause();
    _dragOrigin = _currentSampledPosition(_positionSeconds);
  }

  void _onCropPanUpdate(
    double deltaXPx,
    double deltaYPx,
    double previewW,
    double previewH,
  ) {
    if (previewW <= 0 || previewH <= 0) return;
    final origin = _dragOrigin ?? _currentSampledPosition(_positionSeconds);
    final (clampedX, clampedY) = _clampCropCenter(
      origin.$1 + deltaXPx / previewW,
      origin.$2 + deltaYPx / previewH,
      previewW,
      previewH,
    );
    // Advance the origin with the CLAMPED result so the next frame's delta
    // accumulates from where the box actually is — without this, dragging
    // only nudges the box by one frame's delta.
    _dragOrigin = (clampedX, clampedY);
    _upsertManualKeyframeAt(_positionSeconds, clampedX, clampedY);
  }

  void _onCropPanEnd() => _dragOrigin = null;

  void _selectSpeaker(int? speakerId) {
    setState(() {
      _config = _config.copyWith(selectedSpeakerId: speakerId);
      _recomputeEffectiveTrack();
    });
  }

  static FaceTrackPoint _sampleProfileAt(
    DetectedSpeakerProfile profile,
    double timeSec,
  ) {
    if (profile.rawPoints.isEmpty) {
      return FaceTrackPoint(
        timeSec: timeSec,
        normX: profile.avgNormX,
        normY: profile.avgNormY,
        faceWidth: profile.avgFaceWidth,
        faceHeight: profile.avgFaceHeight,
      );
    }
    var best = profile.rawPoints.first;
    var bestDelta = (best.timeSec - timeSec).abs();
    for (var i = 1; i < profile.rawPoints.length; i++) {
      final p = profile.rawPoints[i];
      final d = (p.timeSec - timeSec).abs();
      if (d < bestDelta) {
        bestDelta = d;
        best = p;
      }
    }
    return best;
  }

  void _toggleTapLockOnPerson(DetectedSpeakerProfile profile) {
    HapticFeedback.selectionClick();
    final shot = _currentShotAt(_positionSeconds);
    if (shot == null) {
      _selectSpeaker(profile.id);
      return;
    }
    final ov = _shotOverrides[shot.id];
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (ov?.mode == ShotLockMode.specificPerson &&
        ov?.targetSpeakerId == profile.id) {
      _setShotModeAutoSpeaker(shot);
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            '🎤 تم إلغاء القفل والعودة لتتبع المتكلم تلقائياً في هذه اللقطة',
          ),
          duration: Duration(milliseconds: 1300),
        ),
      );
    } else {
      _setShotModePerson(shot, profile.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text('🔒 تم تثبيت اللقطة الحالية على ${profile.label}'),
          duration: const Duration(milliseconds: 1300),
        ),
      );
    }
  }

  /// Tap-to-lock: selects/toggles the detected person whose face/shoulder box
  /// or proximity contains the tap. Returns false when no marker matches
  /// (the caller then moves the crop box to the tapped spot).
  bool _selectSpeakerNearTap(double normX, double normY) {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return false;

    DetectedSpeakerProfile? nearest;
    var bestScore = double.infinity;
    for (final profile in track.speakers) {
      final pt = _sampleProfileAt(profile, _positionSeconds);
      final halfW = max(0.08, pt.faceWidth * 0.85);
      final boxH = max(0.12, pt.faceHeight * 1.15);
      final inBox = (normX - pt.normX).abs() <= halfW &&
          normY >= pt.normY - boxH * 0.65 &&
          normY <= pt.normY + boxH * 1.35;
      final dx = normX - pt.normX;
      final dy = normY - pt.normY;
      final distSq = dx * dx + dy * dy;
      if (!inBox && distSq >= 0.0196) continue;
      final score = inBox ? distSq * 0.25 : distSq;
      if (score < bestScore) {
        bestScore = score;
        nearest = profile;
      }
    }
    if (nearest == null) return false;
    _toggleTapLockOnPerson(nearest);
    return true;
  }

  /// One marker per detected person near [timeSec]; per-shot and active
  /// speaking status are flagged for overlays and tap boxes.
  List<ReframeFaceMarker> _faceMarkersAt(double timeSec) {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return const [];

    final shot = _currentShotAt(timeSec);
    final ov = shot != null ? _shotOverrides[shot.id] : null;
    final int? lockedSpeakerId;
    if (ov != null && ov.mode == ShotLockMode.specificPerson) {
      lockedSpeakerId = ov.targetSpeakerId;
    } else if (ov != null && ov.mode == ShotLockMode.staticPosition) {
      lockedSpeakerId = null;
    } else {
      lockedSpeakerId = _config.selectedSpeakerId;
    }

    final (sx, sy) = (_effectiveTrack ?? track).sampleAt(timeSec);
    int? activeSpeakingId;
    var bestActiveDist = 0.09;
    for (final profile in track.speakers) {
      final pt = _sampleProfileAt(profile, timeSec);
      if ((pt.timeSec - timeSec).abs() > 1.8) continue;
      final dx = pt.normX - sx;
      final dy = pt.normY - sy;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist < bestActiveDist) {
        bestActiveDist = dist;
        activeSpeakingId = profile.id;
      }
    }

    final markers = <ReframeFaceMarker>[];
    for (final profile in track.speakers) {
      final pt = _sampleProfileAt(profile, timeSec);
      final locked = profile.id == lockedSpeakerId;
      if ((pt.timeSec - timeSec).abs() > 2.2 && !locked) continue;
      markers.add(
        ReframeFaceMarker(
          id: profile.id,
          normX: pt.normX,
          normY: pt.normY,
          widthNorm: pt.faceWidth > 0 ? pt.faceWidth : profile.avgFaceWidth,
          heightNorm: pt.faceHeight > 0 ? pt.faceHeight : profile.avgFaceHeight,
          label: profile.label,
          locked: locked,
          isSpeaking: profile.id == activeSpeakingId || pt.isSpeaking,
        ),
      );
    }
    return markers;
  }

  /// Re-smooths the already measured trajectory. No FFmpeg, no ML Kit: the
  /// motion preset is a pure post-processing choice.
  void _applyMotionPreset(CameraMotionPreset preset) {
    setState(() {
      _config = _config.copyWith(motion: preset);
      final track = _track;
      if (track != null) {
        _track = FaceTrackResult(
          rawPoints: track.rawPoints,
          keyframes: FaceDetectionService.buildKeyframes(
            track.rawPoints,
            deadZone: preset.deadZone,
            smoothness: preset.smoothness,
          ),
          avgNormX: track.avgNormX,
          avgNormY: track.avgNormY,
          facesDetectedCount: track.facesDetectedCount,
          speakers: track.speakers,
          shots: track.shots,
          sourceWidth: track.sourceWidth,
          sourceHeight: track.sourceHeight,
        );
      }
      _recomputeEffectiveTrack();
    });
  }

  void _selectPreset(AspectRatioPreset preset) {
    setState(() => _config = _config.copyWith(preset: preset));
  }

  void _updateCustomRatio() {
    final width = double.tryParse(_customWidthController.text.trim());
    final height = double.tryParse(_customHeightController.text.trim());
    if (width == null || height == null || width <= 0 || height <= 0) return;
    setState(
      () => _config = _config.copyWith(
        customWidthRatio: width,
        customHeightRatio: height,
      ),
    );
  }

  Future<void> _render() async {
    if (_rendering) return;
    final tempDir = await getTemporaryDirectory();
    final outputPath =
        '${tempDir.path}/reframe_${DateTime.now().millisecondsSinceEpoch}.mp4';

    final progress = ValueNotifier<double>(0);
    final status = ValueNotifier<String>('Starting FFmpeg...');
    if (!mounted) {
      progress.dispose();
      status.dispose();
      return;
    }
    setState(() => _rendering = true);
    var dialogOpen = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Rendering Auto Reframe'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, value, _) => LinearProgressIndicator(value: value),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, value, _) =>
                    Text('${(value * 100).toStringAsFixed(0)}%'),
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (_, value, _) => Text(
                  value,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Working keyframes are the source of truth after manual edits; expand
    // effective cuts into 1ms steps (idempotent) so FFmpeg snaps exactly.
    final base = _effectiveTrack;
    final working = _workingKeyframes;
    final renderTrack = working.isEmpty
        ? base
        : FaceTrackResult(
            rawPoints: base?.rawPoints ?? working,
            keyframes: FaceDetectionService.materializeKeyframesForFfmpeg(
              working,
            ),
            avgNormX: base?.avgNormX ?? 0.5,
            avgNormY: base?.avgNormY ?? 0.42,
            facesDetectedCount: base?.facesDetectedCount ?? 0,
            speakers: base?.speakers ?? const [],
            shots: base?.shots ?? _shots,
            sourceWidth: base?.sourceWidth ?? 0,
            sourceHeight: base?.sourceHeight ?? 0,
          );

    final result = await _reframeService.reframe(
      videoPath: widget.videoPath,
      outputPath: outputPath,
      config: _config,
      track: renderTrack,
      durationMs: _duration.inMilliseconds,
      onProgress: (value, message) {
        progress.value = value;
        status.value = message;
      },
    );

    if (!mounted) {
      progress.dispose();
      status.dispose();
      return;
    }
    if (dialogOpen) {
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
    setState(() => _rendering = false);
    progress.dispose();
    status.dispose();

    if (result == null) {
      final log = _reframeService.lastErrorLog;
      final detail = log == null
          ? 'Unknown FFmpeg error'
          : (log.length > 400 ? log.substring(log.length - 400) : log);
      setState(() => _error = detail);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reframe failed: $detail')),
      );
      return;
    }

    setState(() => _error = null);
    await Navigator.of(context).pushNamed(
      AppRouter.preview,
      arguments: {
        'originalPath': widget.videoPath,
        'processedPath': result,
        'originalDuration': _duration,
        'removedDuration': Duration.zero,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Auto Reframe'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip:
                'إظهار/إخفاء مربعات اللمس على الفيديو (Tap-to-Track)',
            onPressed: () => setState(() => _showTapBoxes = !_showTapBoxes),
            icon: Icon(
              _showTapBoxes ? Icons.touch_app : Icons.touch_app_outlined,
              color: _showTapBoxes ? const Color(0xFF00E676) : null,
            ),
          ),
          IconButton(
            tooltip: 'Re-Analyze Face & Voice',
            onPressed: _analyzing ? null : _analyzeFaces,
            icon: const Icon(Icons.face_retouching_natural),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPreview(),
            const SizedBox(height: 12),
            if (_analyzing) _buildAnalysisBanner(),
            if (!_analyzing && _track != null) ...[
              _buildShotLockCard(),
              const SizedBox(height: 12),
            ],
            _buildKeyframeEditor(),
            if (_track != null) _buildTrackSummary(),
            if (_track != null && _track!.speakers.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildSpeakerSelector(),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ),
            const SizedBox(height: 16),
            _buildRatioSelector(),
            if (_config.preset == AspectRatioPreset.custom)
              _buildCustomRatioInputs(),
            const SizedBox(height: 16),
            _buildStyleSelector(),
            const SizedBox(height: 16),
            _buildMotionSelector(),
            if (_config.style != AutoReframeStyle.blurBackgroundFrame) ...[
              const SizedBox(height: 16),
              _buildFrameFillControl(),
            ],
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _rendering ? null : _render,
              icon: const Icon(Icons.movie_creation_outlined),
              label: Text(_rendering ? 'Rendering...' : 'Render & Preview'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9C27B0),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final controller = _controller;
    if (!_playerReady || controller == null) {
      return Container(
        height: 260,
        decoration: BoxDecoration(
          color: AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final size = controller.value.size;
    final aspect = size.width > 0 && size.height > 0
        ? size.width / size.height
        : 16 / 9;
    final effective = _effectiveTrack;
    final (normX, normY) = _currentSampledPosition(_positionSeconds);
    final faces = _faceMarkersAt(_positionSeconds);
    final cropAspect = _effectiveCropAspect();
    final isPlaying = controller.value.isPlaying;
    final duration = _durationSeconds > 0 ? _durationSeconds : 0.0;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(
                    value: true,
                    icon: Icon(Icons.videocam, size: 15),
                    label: Text('Camera 9:16'),
                  ),
                  ButtonSegment<bool>(
                    value: false,
                    icon: Icon(Icons.crop_free, size: 15),
                    label: Text('Full Frame'),
                  ),
                ],
                selected: {_cameraViewMode},
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                onSelectionChanged: (sel) {
                  setState(() => _cameraViewMode = sel.first);
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: isPlaying
                    ? const Color(0xFFFFAB40)
                    : const Color(0xFF00E676),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              onPressed: () {
                setState(() {
                  isPlaying ? controller.pause() : controller.play();
                });
              },
              icon: Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: 18,
              ),
              label: Text(
                isPlaying ? 'إيقاف' : 'تشغيل',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_cameraViewMode) ...[
          Container(
            height: 310,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFE040FB).withValues(alpha: 0.7),
                width: 1.5,
              ),
            ),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: _config.aspectRatio,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final viewW = constraints.maxWidth;
                      final viewH = constraints.maxHeight;
                      if (viewW <= 0 || viewH <= 0) {
                        return const SizedBox.shrink();
                      }
                      final faceTracking =
                          _config.style == AutoReframeStyle.smartFaceCrop;
                      final winWnorm = aspect > cropAspect
                          ? (cropAspect / aspect).clamp(0.05, 1.0)
                          : 1.0;
                      final winHnorm = aspect < cropAspect
                          ? (aspect / cropAspect).clamp(0.05, 1.0)
                          : 1.0;
                      final halfW = winWnorm / 2;
                      final halfH = winHnorm / 2;
                      final targetX = faceTracking ? normX : 0.5;
                      final targetY = faceTracking ? normY : 0.5;
                      final cx = targetX.clamp(halfW, 1.0 - halfW);
                      final cy = targetY.clamp(halfH, 1.0 - halfH);
                      final vidW = viewW / winWnorm;
                      final vidH = viewH / winHnorm;
                      final offsetX = -(cx - halfW) * vidW;
                      final offsetY = -(cy - halfH) * vidH;

                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) => _onCropPanStart(),
                        onPanUpdate: (details) => _onCropPanUpdate(
                          details.delta.dx,
                          details.delta.dy,
                          vidW,
                          vidH,
                        ),
                        onPanEnd: (_) => _onCropPanEnd(),
                        onTapUp: (details) {
                          if (vidW <= 0 || vidH <= 0) return;
                          final tapNormX =
                              ((details.localPosition.dx - offsetX) / vidW)
                                  .clamp(0.0, 1.0);
                          final tapNormY =
                              ((details.localPosition.dy - offsetY) / vidH)
                                  .clamp(0.0, 1.0);
                          if (_selectSpeakerNearTap(tapNormX, tapNormY)) {
                            return;
                          }
                          final (clampedX, clampedY) = _clampCropCenter(
                            tapNormX,
                            tapNormY,
                            vidW,
                            vidH,
                          );
                          _upsertManualKeyframeAt(
                            _positionSeconds,
                            clampedX,
                            clampedY,
                          );
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          clipBehavior: Clip.hardEdge,
                          children: [
                            Positioned(
                              left: offsetX,
                              top: offsetY,
                              width: vidW,
                              height: vidH,
                              child: VideoPlayer(controller),
                            ),
                            if (_showTapBoxes && faces.isNotEmpty)
                              ..._buildCameraViewTapBoxes(
                                faces: faces,
                                vidW: vidW,
                                vidH: vidH,
                                viewW: viewW,
                                viewH: viewH,
                                offsetX: offsetX,
                                offsetY: offsetY,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildCameraStripMiniMap(
            faces: faces,
            cropAspect: cropAspect,
            srcAspect: aspect,
            cx: normX,
          ),
        ] else
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: aspect,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final previewW = constraints.maxWidth;
                  final previewH = constraints.maxHeight;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Always-on CapCut-style direct manipulation: one-finger
                    // drag moves the crop box (no mode toggle needed), and
                    // playback pauses automatically while dragging.
                    onPanStart: (_) => _onCropPanStart(),
                    onPanUpdate: (details) => _onCropPanUpdate(
                      details.delta.dx,
                      details.delta.dy,
                      previewW,
                      previewH,
                    ),
                    onPanEnd: (_) => _onCropPanEnd(),
                    onTapUp: (details) {
                      if (previewW <= 0 || previewH <= 0) return;
                      final tapX =
                          (details.localPosition.dx / previewW).clamp(0.0, 1.0);
                      final tapY = (details.localPosition.dy / previewH)
                          .clamp(0.0, 1.0);
                      if (_selectSpeakerNearTap(tapX, tapY)) return;
                      final (cx, cy) = _clampCropCenter(
                        tapX,
                        tapY,
                        previewW,
                        previewH,
                      );
                      _upsertManualKeyframeAt(_positionSeconds, cx, cy);
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        VideoPlayer(controller),
                        CustomPaint(
                          painter: ReframeOverlayPainter(
                            targetAspect: _config.aspectRatio,
                            outW: _config.outputSize.$1,
                            outH: _config.outputSize.$2,
                            frameFill: _config.frameFillClamped,
                            normX: normX,
                            normY: normY,
                            style: _config.style,
                            speakerLocked: effective != null,
                            faces: _showTapBoxes ? faces : const [],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        const SizedBox(height: 8),
        _buildPlaybackTransportBar(duration),
      ],
    );
  }

  List<Widget> _buildCameraViewTapBoxes({
    required List<ReframeFaceMarker> faces,
    required double vidW,
    required double vidH,
    required double viewW,
    required double viewH,
    required double offsetX,
    required double offsetY,
  }) {
    final track = _track;
    if (track == null || faces.isEmpty) return const [];
    final maxW = viewW * 0.55;
    final maxH = viewH * 0.55;
    final widgets = <Widget>[];
    for (final face in faces) {
      final centerX = face.normX * vidW + offsetX;
      final centerY = face.normY * vidH + offsetY;
      final boxW =
          (face.widthNorm * vidW * 1.25).clamp(40.0, max<double>(40.0, maxW));
      final boxH = (face.heightNorm * vidH * 1.45)
          .clamp(48.0, max<double>(48.0, maxH));
      final rawLeft = centerX - boxW * 0.5;
      final rawTop = centerY - boxH * 0.38;
      if (rawLeft + boxW < 0 ||
          rawLeft > viewW ||
          rawTop + boxH < 0 ||
          rawTop > viewH) {
        continue;
      }
      final left = rawLeft.clamp(2.0, max<double>(2.0, viewW - boxW - 2.0));
      final top = rawTop.clamp(2.0, max<double>(2.0, viewH - boxH - 2.0));

      final Color color;
      final String iconEmoji;
      if (face.locked) {
        color = const Color(0xFFE040FB);
        iconEmoji = '🔒';
      } else if (face.isSpeaking) {
        color = const Color(0xFF00E676);
        iconEmoji = '🎤';
      } else {
        color = const Color(0xFF00E5FF);
        iconEmoji = '👆';
      }

      DetectedSpeakerProfile? matchedProfile;
      for (final p in track.speakers) {
        if (p.id == face.id) {
          matchedProfile = p;
          break;
        }
      }

      widgets.add(
        Positioned(
          left: left,
          top: top,
          width: boxW,
          height: boxH,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: matchedProfile == null
                ? null
                : () => _toggleTapLockOnPerson(matchedProfile!),
            child: Container(
              alignment: Alignment.topLeft,
              decoration: BoxDecoration(
                color: color.withValues(
                  alpha: (face.locked || face.isSpeaking) ? 0.14 : 0.06,
                ),
                border: Border.all(color: color, width: 2.0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '$iconEmoji #${face.id}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: face.locked ? Colors.white : Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildPlaybackTransportBar(double duration) {
    final controller = _controller;
    final isPlaying = controller?.value.isPlaying ?? false;
    final dur = duration > 0 ? duration : 0.0;
    final pos = dur > 0 ? _positionSeconds.clamp(0.0, dur) : 0.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'رجوع 2 ثانية',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.replay_5, size: 20),
                onPressed: dur > 0 ? () => _seekToTime(_positionSeconds - 2.0) : null,
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: isPlaying
                      ? const Color(0xFFFFAB40)
                      : const Color(0xFFE040FB),
                  foregroundColor: isPlaying ? Colors.black : Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                ),
                onPressed: controller == null || dur <= 0
                    ? null
                    : () {
                        setState(() {
                          isPlaying ? controller.pause() : controller.play();
                        });
                      },
                icon: Icon(
                  isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 20,
                ),
                label: Text(
                  isPlaying ? 'إيقاف مؤقت' : 'تشغيل الفيديو',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'تقديم 2 ثانية',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.forward_5, size: 20),
                onPressed: dur > 0 ? () => _seekToTime(_positionSeconds + 2.0) : null,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_formatTimeTenths(pos)} / ${_formatTimeTenths(dur)}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textSecondary,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: _showTapBoxes
                    ? 'إخفاء مربعات التحديد فوق الفيديو'
                    : 'إظهار مربعات التحديد فوق الفيديو',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _showTapBoxes = !_showTapBoxes),
                icon: Icon(
                  _showTapBoxes ? Icons.visibility : Icons.visibility_off,
                  size: 18,
                  color: _showTapBoxes
                      ? const Color(0xFF00E676)
                      : Colors.white54,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCameraStripMiniMap({
    required List<ReframeFaceMarker> faces,
    required double cropAspect,
    required double srcAspect,
    required double cx,
  }) {
    final track = _track;
    final winWnorm =
        srcAspect > cropAspect ? (cropAspect / srcAspect).clamp(0.08, 1.0) : 1.0;
    final halfW = winWnorm / 2;
    final clampedCx = cx.clamp(halfW, 1.0 - halfW);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final stripW = constraints.maxWidth;
            final winW = stripW * winWnorm;
            final winLeft = ((clampedCx - halfW) * stripW)
                .clamp(0.0, max<double>(0.0, stripW - winW));
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _onCropPanStart(),
              onPanUpdate: (details) {
                if (stripW <= 0) return;
                final dx = details.delta.dx / stripW;
                final (_, curY) = _currentSampledPosition(_positionSeconds);
                final nextX = (cx + dx).clamp(halfW, 1.0 - halfW);
                _upsertManualKeyframeAt(_positionSeconds, nextX, curY);
              },
              onPanEnd: (_) => _onCropPanEnd(),
              onTapUp: (details) {
                if (stripW <= 0) return;
                final tapX = (details.localPosition.dx / stripW)
                    .clamp(halfW, 1.0 - halfW);
                final (_, curY) = _currentSampledPosition(_positionSeconds);
                _upsertManualKeyframeAt(_positionSeconds, tapX, curY);
              },
              child: Container(
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                  ),
                ),
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: winLeft,
                      top: 2,
                      width: winW,
                      height: 30,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE040FB).withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFFE040FB),
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.open_with,
                          size: 13,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    for (final face in faces)
                      Positioned(
                        left: (face.normX * stripW - 6)
                            .clamp(2.0, max<double>(2.0, stripW - 14.0)),
                        top: 11,
                        width: 12,
                        height: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: face.locked
                                ? const Color(0xFFE040FB)
                                : face.isSpeaking
                                    ? const Color(0xFF00E676)
                                    : const Color(0xFF00E5FF),
                            border: Border.all(color: Colors.black, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        if (track != null && track.speakers.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final face in faces)
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: face.locked
                      ? const Color(0xFFE040FB).withValues(alpha: 0.25)
                      : face.isSpeaking
                          ? const Color(0xFF00E676).withValues(alpha: 0.25)
                          : AppColors.surfaceLight,
                  side: BorderSide(
                    color: face.locked
                        ? const Color(0xFFE040FB)
                        : face.isSpeaking
                            ? const Color(0xFF00E676)
                            : Colors.white.withValues(alpha: 0.24),
                  ),
                  label: Text(
                    '${face.locked ? '🔒 مثبت: ' : face.isSpeaking ? '🎤 يتحدث: ' : '👆 تثبيت: '}${face.label}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () {
                    for (final p in track.speakers) {
                      if (p.id == face.id) {
                        _toggleTapLockOnPerson(p);
                        break;
                      }
                    }
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Interactive keyframe editor
  // ---------------------------------------------------------------------------

  Widget _buildKeyframeEditor() {
    final keyframes = _workingKeyframes;
    final duration = _durationSeconds > 0 ? _durationSeconds : 0.0;
    final position = _positionSeconds.clamp(0.0, duration > 0 ? duration : 0.0);
    final currentIdx = _nearestKfIndex(position);
    final onKfIdx = _keyframeAtPlayheadIndex();
    final onKf = onKfIdx >= 0;
    final selected = onKf
        ? keyframes[onKfIdx]
        : (currentIdx >= 0 ? keyframes[currentIdx] : null);
    final hasPrev = keyframes.any((k) => k.timeSec < position - 0.05);
    final hasNext = keyframes.any((k) => k.timeSec > position + 0.05);
    final (posX, posY) = _currentSampledPosition(position);
    final cropAspect = _effectiveCropAspect();
    final vidSize = _controller?.value.size;
    final srcAspect =
        (vidSize != null && vidSize.width > 0 && vidSize.height > 0)
            ? vidSize.width / vidSize.height
            : 16 / 9;
    final halfW = srcAspect > cropAspect
        ? (cropAspect / srcAspect).clamp(0.05, 1.0) / 2.0
        : 0.5;
    final minX = halfW.clamp(0.0, 0.49);
    final maxX = (1.0 - halfW).clamp(0.51, 1.0);
    final sliderX = posX.clamp(minX, maxX);

    return Card(
      color: AppColors.surfaceLight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Keyframes · ${keyframes.length}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${_formatTimeTenths(position)} / '
                  '${_formatTimeTenths(duration)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  Icons.swap_horiz,
                  size: 16,
                  color: Color(0xFFE040FB),
                ),
                const SizedBox(width: 6),
                const Text(
                  'تحريك الكاميرا:',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                Expanded(
                  child: Slider(
                    value: sliderX,
                    min: minX,
                    max: maxX,
                    onChangeStart: (_) {
                      if (_controller?.value.isPlaying ?? false) {
                        _controller?.pause();
                      }
                    },
                    onChanged: (v) =>
                        _upsertManualKeyframeAt(_positionSeconds, v, posY),
                  ),
                ),
                Text(
                  '${(posX * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),

            // --- Scrubbable magnetic keyframe timeline --------------------
            _buildMagneticTimeline(
              keyframes: keyframes,
              duration: duration,
              position: position,
              currentIdx: currentIdx,
            ),
            const SizedBox(height: 8),

            // --- Quick keyframe actions ------------------------------------
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _editorButton(
                  icon: Icons.skip_previous,
                  label: '‹ Prev',
                  onPressed: hasPrev ? () => _jumpKeyframe(-1) : null,
                ),
                _editorButton(
                  icon: onKf ? Icons.bookmark_remove : Icons.add_circle,
                  label: onKf ? '◆- Delete KF' : '◆+ Add KF',
                  highlighted: !onKf && duration > 0,
                  onPressed: duration > 0 ? _smartKeyframeToggle : null,
                ),
                _editorButton(
                  icon: Icons.skip_next,
                  label: 'Next ›',
                  onPressed: hasNext ? () => _jumpKeyframe(1) : null,
                ),
                _editorButton(
                  icon: selected != null && !selected.isCut
                      ? Icons.waves
                      : Icons.flash_on,
                  label: selected == null
                      ? 'Cut / Smooth'
                      : (selected.isCut ? 'Cut ⚡' : 'Smooth 〰️'),
                  highlighted: selected?.isCut ?? false,
                  onPressed:
                      selected != null ? _toggleCutForCurrentKeyframe : null,
                ),
                _editorButton(
                  icon: Icons.center_focus_strong,
                  label: 'Center ⌖',
                  onPressed: keyframes.isNotEmpty
                      ? _centerCurrentKeyframe
                      : null,
                ),
                _editorButton(
                  icon: Icons.delete_sweep,
                  label: 'Clear All 🗑️',
                  onPressed: _clearAllKeyframes,
                ),
                _editorButton(
                  icon: Icons.restart_alt,
                  label: 'Reset AI ↺',
                  onPressed: _aiKeyframes.isNotEmpty ? _resetKeyframes : null,
                ),
              ],
            ),
            const SizedBox(height: 8),

            // --- Keyframe chips: tap seeks, × deletes instantly -----------
            if (keyframes.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: keyframes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) {
                    final kf = keyframes[i];
                    final marker =
                        '${kf.isManual ? '✋' : ''}${kf.isCut ? '⚡' : '〰️'}';
                    return InputChip(
                      label: Text(
                        '#${i + 1} ${_formatTimeTenths(kf.timeSec)} $marker',
                        style: const TextStyle(fontSize: 12),
                      ),
                      selected: i == currentIdx,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => _seekToTime(kf.timeSec),
                      onDeleted: () => _deleteKeyframeAt(i),
                      deleteIcon: const Icon(Icons.cancel, size: 16),
                    );
                  },
                ),
              )
            else
              const Text(
                'No keyframes yet — drag the camera or press "◆+ Add KF".',
                style:
                    TextStyle(fontSize: 11, color: AppColors.textTertiary),
              ),
          ],
        ),
      ),
    );
  }

  /// Magnetic timeline strip: tap or finger-scrub to seek, snapping to the
  /// nearest keyframe marker within 12 pixels with a haptic tick.
  Widget _buildMagneticTimeline({
    required List<FaceTrackPoint> keyframes,
    required double duration,
    required double position,
    required int currentIdx,
  }) {
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          double? scrubTime(double dx) {
            if (duration <= 0 || width <= 0) return null;
            final t = (dx.clamp(0.0, width) / width) * duration;
            final timeTolerance = magneticSnapPx / width * duration;
            var snapped = t;
            var bestDelta = timeTolerance;
            for (final kf in keyframes) {
              final delta = (kf.timeSec - t).abs();
              if (delta <= bestDelta) {
                bestDelta = delta;
                snapped = kf.timeSec;
              }
            }
            // One haptic tick per newly-snapped marker, not per drag frame.
            if ((snapped - t).abs() > 1e-9 && snapped != _lastSnappedKfSec) {
              _lastSnappedKfSec = snapped;
              HapticFeedback.selectionClick();
            }
            return snapped;
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (details) {
              _lastSnappedKfSec = null;
              final t = scrubTime(details.localPosition.dx);
              if (t != null) _seekToTime(t);
            },
            onHorizontalDragUpdate: (details) {
              final t = scrubTime(details.localPosition.dx);
              if (t != null) _seekToTime(t);
            },
            onHorizontalDragEnd: (_) => _lastSnappedKfSec = null,
            onHorizontalDragCancel: () => _lastSnappedKfSec = null,
            onTapDown: (details) {
              _lastSnappedKfSec = null;
              final t = scrubTime(details.localPosition.dx);
              if (t != null) _seekToTime(t);
            },
            child: CustomPaint(
              size: Size(width, 54),
              painter: KeyframeTimelinePainter(
                keyframes: keyframes,
                duration: duration,
                position: position,
                selectedIndex: currentIdx,
              ),
            ),
          );
        },
      ),
    );
  }

  /// `m:ss.t` (tenths) so exact keyframe timing is readable at a glance.
  String _formatTimeTenths(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '0:00.0';
    final whole = seconds.floor();
    final tenths = ((seconds - whole) * 10).floor();
    return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}.'
        '$tenths';
  }

  Widget _editorButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool highlighted = false,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        foregroundColor:
            highlighted ? const Color(0xFFE040FB) : null,
      ),
    );
  }

  Widget _buildAnalysisBanner() {
    return Card(
      color: AppColors.surfaceLight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            LinearProgressIndicator(value: _analysisProgress),
            const SizedBox(height: 8),
            Text(
              _analysisStatus,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackSummary() {
    final track = _track!;
    final voiceLockedCount =
        track.speakers.where((s) => s.speakingRatio != null).length;
    return Card(
      color: AppColors.surfaceLight,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.record_voice_over, color: Color(0xFFE040FB)),
        title: Text(
          '3-Layer AI · ${track.speakers.length} people '
          '($voiceLockedCount voice-locked) · '
          '${_workingKeyframes.length} keyframes · ${_shots.length} shots',
          style: const TextStyle(fontSize: 12.5),
        ),
        subtitle: Text(
          '${track.facesDetectedCount} face detections · '
          'Tap any person on video to lock/unlock',
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  Widget _buildShotLockCard() {
    final track = _track;
    if (track == null || _shots.isEmpty) return const SizedBox.shrink();
    final idx = _currentShotIndexAt(_positionSeconds);
    if (idx < 0 || idx >= _shots.length) return const SizedBox.shrink();
    final shot = _shots[idx];
    final ov = _shotOverrides[shot.id];
    final mode = ov?.mode ?? ShotLockMode.autoSpeaker;
    final hasCustom = _shotOverrides.containsKey(shot.id) &&
        mode != ShotLockMode.autoSpeaker;
    final canSplitHere = (_positionSeconds - shot.startSec) >= 0.3 &&
        (shot.endSec - _positionSeconds) >= 0.3;
    final canJumpPrev = idx > 0 || (_positionSeconds - shot.startSec) > 0.4;

    return Card(
      color: AppColors.surfaceLight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '🎯 تثبيت الهدف في اللقطة #${idx + 1}/${_shots.length} '
                    '(${_formatTimeTenths(shot.startSec)} - '
                    '${_formatTimeTenths(shot.endSec)})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (hasCustom)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE040FB).withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'مُخصّص',
                      style: TextStyle(
                        color: Color(0xFFE040FB),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _editorButton(
                  icon: Icons.skip_previous,
                  label: '‹ اللقطة السابقة',
                  onPressed: canJumpPrev ? () => _jumpShot(-1) : null,
                ),
                _editorButton(
                  icon: Icons.content_cut,
                  label: '✂️ تقسيم لقطة هنا',
                  highlighted: canSplitHere,
                  onPressed: _splitShotAtPlayhead,
                ),
                _editorButton(
                  icon: Icons.merge_type,
                  label: 'دمج اللقطة',
                  onPressed: _shots.length >= 2 ? _mergeCurrentShot : null,
                ),
                _editorButton(
                  icon: Icons.skip_next,
                  label: 'اللقطة التالية ›',
                  onPressed:
                      idx + 1 < _shots.length ? () => _jumpShot(1) : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'اختر لمن تثبت الكاميرا أثناء هذه اللقطة (أو المس الشخص مباشرة داخل الفيديو):',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  avatar: const Icon(Icons.record_voice_over, size: 16),
                  label: const Text(
                    'المتكلم تلقائياً (صوت + شفاه)',
                    style: TextStyle(fontSize: 12),
                  ),
                  selected: mode == ShotLockMode.autoSpeaker,
                  onSelected: (_) => _setShotModeAutoSpeaker(shot),
                ),
                for (final p in track.speakers)
                  ChoiceChip(
                    avatar: const Icon(Icons.person_pin_circle, size: 16),
                    label: Text(
                      'تثبيت: ${p.label} 🔊',
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: mode == ShotLockMode.specificPerson &&
                        ov?.targetSpeakerId == p.id,
                    onSelected: (_) => _setShotModePerson(shot, p.id),
                  ),
                ChoiceChip(
                  avatar: const Icon(Icons.lock_outline, size: 16),
                  label: const Text(
                    'تثبيت الكاميرا هنا طوال اللقطة',
                    style: TextStyle(fontSize: 12),
                  ),
                  selected: mode == ShotLockMode.staticPosition,
                  onSelected: (_) {
                    final (cx, cy) = _currentSampledPosition(_positionSeconds);
                    _setShotModeStaticPosition(shot, cx, cy);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '💡 ميزة Tap-to-Track: المس أي شخص مباشرة على شاشة الفيديو لقفل الكاميرا عليه في هذه اللقطة، والمسه مرة أخرى للعودة للتتبع التلقائي.',
              style: TextStyle(fontSize: 10.5, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRatioSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Aspect Ratio', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in AspectRatioPreset.values)
              ChoiceChip(
                avatar: Icon(preset.icon, size: 18),
                label: Text(preset.shortLabel),
                selected: _config.preset == preset,
                onSelected: (_) => _selectPreset(preset),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_config.outputSize.$1} x ${_config.outputSize.$2}',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildCustomRatioInputs() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _customWidthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Width ratio',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _updateCustomRatio(),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(':'),
          ),
          Expanded(
            child: TextField(
              controller: _customHeightController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Height ratio',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _updateCustomRatio(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStyleSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Framing Mode', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final style in AutoReframeStyle.values)
              ChoiceChip(
                label: Text(style.label),
                selected: _config.style == style,
                onSelected: (_) =>
                    setState(() => _config = _config.copyWith(style: style)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _config.style.description,
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  Widget _buildMotionSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Camera Motion', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final motion in CameraMotionPreset.values)
              ChoiceChip(
                label: Text(motion.label),
                selected: _config.motion == motion,
                onSelected: (_) => _applyMotionPreset(motion),
              ),
          ],
        ),
      ],
    );
  }

  /// `45% .. 100%` video-fill slider with quick presets. Lower fill widens the
  /// crop (more scene visible) and adds proportional black bars.
  Widget _buildFrameFillControl() {
    final fill = _config.frameFillClamped;
    final (outW, outH) = _config.outputSize;
    final box = FfmpegAutoReframeService.innerBoxForFill(
      outW: outW,
      outH: outH,
      frameFill: fill,
    );
    final barText = outH >= outW
        ? 'Black bars: '
            '${(((outH - box.boxH) / 2) / outH * 100).toStringAsFixed(0)}% '
            'top + bottom'
        : 'Black bars: '
            '${(((outW - box.boxW) / 2) / outW * 100).toStringAsFixed(0)}% '
            'left + right';

    const presets = <(double, String)>[
      (1.0, '100% Full'),
      (0.8, '80%'),
      (0.65, '65%'),
      (0.5, '50%'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Video Fill / Black Space',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              '${(fill * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE040FB),
              ),
            ),
          ],
        ),
        Slider(
          value: fill,
          min: 0.45,
          max: 1.0,
          divisions: 106,
          label: '${(fill * 100).toStringAsFixed(0)}%',
          onChanged: (value) =>
              setState(() => _config = _config.copyWith(frameFill: value)),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (value, label) in presets)
              ChoiceChip(
                label: Text(label),
                selected: (fill - value).abs() < 0.005,
                onSelected: (_) =>
                    setState(() => _config = _config.copyWith(frameFill: value)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Lower fill shows more of the scene around the speaker · $barText',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }

  /// `Auto Active Speaker` + one chip per detected person; tapping a face on
  /// the preview selects the same person.
  Widget _buildSpeakerSelector() {
    final track = _track;
    if (track == null || track.speakers.isEmpty) return const SizedBox.shrink();
    final selectedId = _config.selectedSpeakerId;
    String? selectedLabel;
    for (final profile in track.speakers) {
      if (profile.id == selectedId) selectedLabel = profile.label;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'وضع التتبع العام للفيديو بالكامل (Target Face / Speaker)',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              avatar: Icon(
                Icons.record_voice_over,
                size: 18,
                color: selectedId == null
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              label: const Text('Auto Active Speaker (المتكلم تلقائياً)'),
              selected: selectedId == null,
              onSelected: (_) => _selectSpeaker(null),
            ),
            for (final profile in track.speakers)
              ChoiceChip(
                avatar: Icon(
                  Icons.person,
                  size: 18,
                  color: selectedId == profile.id
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                label: Text('${profile.label} 🔊'),
                selected: selectedId == profile.id,
                onSelected: (_) => _selectSpeaker(profile.id),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          selectedId == null
              ? 'الوضع العام: الكاميرا تتبع الشخص المتكلم تلقائياً (بصمة الصوت + حركة الشفاه الداخلية + الجسد العلوي).'
              : 'الوضع العام: الكاميرا مثبتة على $selectedLabel طوال الفيديو.',
          style: const TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
      ],
    );
  }
}

/// One detected person drawn on the preview (face/shoulder bounding box & state).
class ReframeFaceMarker {
  final int id;
  final double normX;
  final double normY;
  final double widthNorm;
  final double heightNorm;
  final String label;
  final bool locked;
  final bool isSpeaking;

  const ReframeFaceMarker({
    this.id = 0,
    required this.normX,
    required this.normY,
    this.widthNorm = 0.12,
    this.heightNorm = 0.24,
    required this.label,
    this.locked = false,
    this.isSpeaking = false,
  });
}

/// Live overlay: dimmed area outside the crop window, all detected faces with
/// the selected speaker highlighted, black-bar bands for `frameFill`, and a
/// "Speaker Locked" marker.
class ReframeOverlayPainter extends CustomPainter {
  final double targetAspect;
  final int outW;
  final int outH;
  final double frameFill;
  final double normX;
  final double normY;
  final AutoReframeStyle style;
  final bool speakerLocked;
  final List<ReframeFaceMarker> faces;

  const ReframeOverlayPainter({
    required this.targetAspect,
    required this.outW,
    required this.outH,
    required this.frameFill,
    required this.normX,
    required this.normY,
    required this.style,
    required this.speakerLocked,
    this.faces = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Mirror the FFmpeg geometry exactly: effective aspect of the inner box
    // after `frameFill`, then the source crop window, then the black bars.
    final fill = frameFill.clamp(0.45, 1.0);
    var boxW = outW;
    var boxH = outH;
    if (fill < 0.99) {
      final box = FfmpegAutoReframeService.innerBoxForFill(
        outW: outW,
        outH: outH,
        frameFill: fill,
      );
      boxW = box.boxW;
      boxH = box.boxH;
    }
    final effectiveAspect = boxW / boxH > 0 ? boxW / boxH : 1.0;

    double cropW;
    double cropH;
    if (size.width / size.height > effectiveAspect) {
      cropH = size.height;
      cropW = cropH * effectiveAspect;
    } else {
      cropW = size.width;
      cropH = cropW / effectiveAspect;
    }

    final faceTracking = style == AutoReframeStyle.smartFaceCrop;
    final centerX = faceTracking ? normX * size.width : size.width / 2;
    final centerY = faceTracking ? normY * size.height : size.height / 2;

    final left = (centerX - cropW / 2).clamp(0.0, size.width - cropW);
    final top = (centerY - cropH / 2).clamp(0.0, size.height - cropH);
    final cropRect = Rect.fromLTWH(left, top, cropW, cropH);

    if (style != AutoReframeStyle.blurBackgroundFrame) {
      final dimPath = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(cropRect);
      canvas.drawPath(dimPath, Paint()..color = Colors.black.withValues(alpha: 0.55));
    }

    final glow = Paint()
      ..color = const Color(0xFFE040FB)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 6);
    canvas.drawRect(cropRect, glow);
    canvas.drawRect(
      cropRect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // Black bars added by `pad=...:black`, drawn at the exact final proportion
    // inside the crop window (portrait → top/bottom, landscape → left/right).
    // The preview must NOT hide the speaker's face with opaque bars: use a
    // translucent letterbox band + dashed guide lines instead, so the full
    // cropped area stays visible while dragging the box.
    final portrait = outH >= outW;
    final barFraction = (1 - (portrait ? boxH / outH : boxW / outW)) / 2;
    if (barFraction > 0.004) {
      final barPaint = Paint()..color = Colors.black26;
      final guidePaint = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1.2;
      if (portrait) {
        final barH = cropRect.height * barFraction;
        canvas.drawRect(
          Rect.fromLTWH(cropRect.left, cropRect.top, cropRect.width, barH),
          barPaint,
        );
        canvas.drawRect(
          Rect.fromLTWH(
            cropRect.left,
            cropRect.bottom - barH,
            cropRect.width,
            barH,
          ),
          barPaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.left, cropRect.top + barH),
          Offset(cropRect.right, cropRect.top + barH),
          guidePaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.left, cropRect.bottom - barH),
          Offset(cropRect.right, cropRect.bottom - barH),
          guidePaint,
        );
      } else {
        final barW = cropRect.width * barFraction;
        canvas.drawRect(
          Rect.fromLTWH(cropRect.left, cropRect.top, barW, cropRect.height),
          barPaint,
        );
        canvas.drawRect(
          Rect.fromLTWH(
            cropRect.right - barW,
            cropRect.top,
            barW,
            cropRect.height,
          ),
          barPaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.left + barW, cropRect.top),
          Offset(cropRect.left + barW, cropRect.bottom),
          guidePaint,
        );
        _drawDashedLine(
          canvas,
          Offset(cropRect.right - barW, cropRect.top),
          Offset(cropRect.right - barW, cropRect.bottom),
          guidePaint,
        );
      }
    }

    // Every detected person: face/shoulder tap-to-track box + state pill.
    for (final face in faces) {
      final maxW = size.width * 0.4;
      final maxH = size.height * 0.58;
      final boxW = (face.widthNorm * size.width * 1.15)
          .clamp(36.0, max<double>(36.0, maxW));
      final boxH = (face.heightNorm * size.height * 1.35)
          .clamp(44.0, max<double>(44.0, maxH));
      final left = (face.normX * size.width - boxW * 0.5)
          .clamp(2.0, max<double>(2.0, size.width - boxW - 2.0));
      final top = (face.normY * size.height - boxH * 0.38)
          .clamp(2.0, max<double>(2.0, size.height - boxH - 2.0));
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, boxW, boxH),
        const Radius.circular(8),
      );
      final Color color;
      final String tag;
      final Color pillBg;
      final Color pillFg;
      if (face.locked) {
        color = const Color(0xFFE040FB);
        tag = '🔒 مثبت';
        pillBg = const Color(0xDD9C27B0);
        pillFg = Colors.white;
      } else if (face.isSpeaking) {
        color = const Color(0xFF00E676);
        tag = '🎤 يتحدث';
        pillBg = const Color(0xDD00E676);
        pillFg = Colors.black;
      } else {
        color = const Color(0xFF00E5FF);
        tag = '👆 تثبيت';
        pillBg = const Color(0xCC006064);
        pillFg = Colors.white;
      }

      final active = face.locked || face.isSpeaking;
      canvas.drawRRect(
        rrect,
        Paint()..color = color.withValues(alpha: active ? 0.16 : 0.08),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 2.4 : 1.5,
      );

      final label = TextPainter(
        text: TextSpan(
          text: ' #${face.id} $tag ',
          style: TextStyle(
            color: pillFg,
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            backgroundColor: pillBg,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(
          left.clamp(0.0, max<double>(0.0, size.width - label.width)),
          (top - label.height - 2)
              .clamp(0.0, max<double>(0.0, size.height - label.height)),
        ),
      );
    }

    // Crosshair at the actual tracked face center (the crop center).
    final faceCenter = Offset(centerX, centerY);
    final cross = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 1.6;
    canvas.drawLine(
      faceCenter - const Offset(12, 0),
      faceCenter + const Offset(12, 0),
      cross,
    );
    canvas.drawLine(
      faceCenter - const Offset(0, 12),
      faceCenter + const Offset(0, 12),
      cross,
    );
    canvas.drawCircle(faceCenter, 5, cross..style = PaintingStyle.stroke);

    if (speakerLocked && faceTracking) {
      final badge = TextPainter(
        text: const TextSpan(
          text: ' 3-Layer AI Speaker Lock ',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            backgroundColor: Color(0xAA9C27B0),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badgeOffset = Offset(
        (cropRect.left + 8)
            .clamp(0.0, max<double>(0.0, size.width - badge.width - 8)),
        (cropRect.top + 8)
            .clamp(0.0, max<double>(0.0, size.height - badge.height - 8)),
      );
      badge.paint(canvas, badgeOffset);
    }
  }

  /// Dashed helper line for the letterbox guide in the preview.
  static void _drawDashedLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    double dash = 8,
    double gap = 6,
  }) {
    final total = (to - from).distance;
    if (total <= 0) return;
    final unit = (to - from) / total;
    var traveled = 0.0;
    while (traveled < total) {
      final dashEnd = min(traveled + dash, total);
      canvas.drawLine(
        from + unit * traveled,
        from + unit * dashEnd,
        paint,
      );
      traveled = dashEnd + gap;
    }
  }

  @override
  bool shouldRepaint(covariant ReframeOverlayPainter oldDelegate) {
    return oldDelegate.normX != normX ||
        oldDelegate.normY != normY ||
        oldDelegate.targetAspect != targetAspect ||
        oldDelegate.outW != outW ||
        oldDelegate.outH != outH ||
        oldDelegate.frameFill != frameFill ||
        oldDelegate.style != style ||
        oldDelegate.speakerLocked != speakerLocked ||
        oldDelegate.faces != faces;
  }
}

/// Timeline strip painting diamond keyframe markers.
///
/// * AI keyframes: cyan `#00E5FF`
/// * manual/edited keyframes: amber `#FFD54F`
/// * nearest/active keyframe: magenta `#E040FB` (drawn larger)
/// * `isCut` keyframes are **filled** diamonds, smooth ones are **hollow**
class KeyframeTimelinePainter extends CustomPainter {
  final List<FaceTrackPoint> keyframes;
  final double duration;
  final double position;
  final int selectedIndex;

  const KeyframeTimelinePainter({
    required this.keyframes,
    required this.duration,
    required this.position,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final midY = size.height / 2;

    canvas.drawLine(
      Offset(0, midY),
      Offset(size.width, midY),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 2,
    );

    // Playhead marker.
    if (duration > 0) {
      final playX = (position / duration).clamp(0.0, 1.0) * size.width;
      canvas.drawLine(
        Offset(playX, 3),
        Offset(playX, size.height - 3),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.4,
      );
    }

    if (duration <= 0) return;
    for (var i = 0; i < keyframes.length; i++) {
      final kf = keyframes[i];
      final x = (kf.timeSec / duration).clamp(0.0, 1.0) * size.width;
      final selected = i == selectedIndex;
      final color = selected
          ? const Color(0xFFE040FB)
          : (kf.isManual
              ? const Color(0xFFFFD54F)
              : const Color(0xFF00E5FF));
      final radius = selected ? 8.0 : 5.5;
      final diamond = Path()
        ..moveTo(x, midY - radius)
        ..lineTo(x + radius, midY)
        ..lineTo(x, midY + radius)
        ..lineTo(x - radius, midY)
        ..close();

      if (kf.isCut) {
        // Instant cut: filled diamond.
        canvas.drawPath(diamond, Paint()..color = color);
        if (selected) {
          canvas.drawPath(
            diamond,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4,
          );
        }
      } else {
        // Smooth pan: hollow diamond.
        canvas.drawPath(
          diamond,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant KeyframeTimelinePainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.duration != duration ||
        oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.keyframes.length != keyframes.length ||
        !_sameKeyframes(oldDelegate.keyframes, keyframes);
  }

  static bool _sameKeyframes(
    List<FaceTrackPoint> a,
    List<FaceTrackPoint> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].timeSec != b[i].timeSec ||
          a[i].normX != b[i].normX ||
          a[i].normY != b[i].normY ||
          a[i].isCut != b[i].isCut ||
          a[i].isManual != b[i].isManual) {
        return false;
      }
    }
    return true;
  }
}
