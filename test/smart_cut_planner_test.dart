import 'package:ai_video_editing/features/media_cutter/data/services/smart_cut_planner.dart';
import 'package:flutter_test/flutter_test.dart';

List<SmartCutPacket> _buildCfrPackets({
  required double durationSeconds,
  required double fps,
  required int gopSize,
  bool withClosedBFrames = false,
}) {
  final totalFrames = (durationSeconds * fps).round();
  final frameDur = 1.0 / fps;
  final displayPackets = <SmartCutPacket>[
    for (var i = 0; i < totalFrames; i++)
      SmartCutPacket(
        pts: i * frameDur,
        dts: i * frameDur,
        isKeyFrame: i % gopSize == 0,
      ),
  ];
  if (!withClosedBFrames) return displayPackets;

  // Emulate closed-GOP decode order (I P B B within each GOP, never crossing
  // a keyframe boundary).
  final decodePackets = <SmartCutPacket>[];
  var dtsIndex = -1;
  for (var gopStart = 0; gopStart < totalFrames; gopStart += gopSize) {
    final gopEnd = (gopStart + gopSize).clamp(0, totalFrames);
    final key = displayPackets[gopStart];
    decodePackets.add(
      SmartCutPacket(
        pts: key.pts,
        dts: dtsIndex * frameDur,
        isKeyFrame: true,
      ),
    );
    dtsIndex++;

    var cursor = gopStart + 1;
    while (cursor < gopEnd) {
      final pIndex = (cursor + 2).clamp(cursor, gopEnd - 1);
      if (pIndex > cursor) {
        decodePackets.add(
          SmartCutPacket(pts: displayPackets[pIndex].pts, dts: dtsIndex * frameDur),
        );
        dtsIndex++;
      }
      for (var b = cursor; b < pIndex; b++) {
        decodePackets.add(
          SmartCutPacket(pts: displayPackets[b].pts, dts: dtsIndex * frameDur),
        );
        dtsIndex++;
      }
      if (pIndex == cursor) {
        decodePackets.add(
          SmartCutPacket(
            pts: displayPackets[cursor].pts,
            dts: dtsIndex * frameDur,
          ),
        );
        dtsIndex++;
      }
      cursor = pIndex + 1;
    }
  }
  return decodePackets;
}

SmartCutVideoParams _validParams({
  String codecName = 'h264',
  String? profile = 'High',
  String? level = '41',
  String? pixFmt = 'yuv420p',
  int width = 1920,
  int height = 1080,
  double fps = 30.0,
  String? timeBase = '1/90000',
  int hasBFrames = 2,
  String? colorSpace = 'bt709',
  String? colorPrimaries = 'bt709',
  String? colorTransfer = 'bt709',
  String? colorRange = 'tv',
  bool isVfr = false,
}) {
  return SmartCutVideoParams(
    codecName: codecName,
    profile: profile,
    level: level,
    pixFmt: pixFmt,
    width: width,
    height: height,
    fps: fps,
    timeBase: timeBase,
    hasBFrames: hasBFrames,
    colorSpace: colorSpace,
    colorPrimaries: colorPrimaries,
    colorTransfer: colorTransfer,
    colorRange: colorRange,
    isVfr: isVfr,
  );
}

void main() {
  group('SmartCutPlanner.planSegment', () {
    test('exact keyframe boundaries yield pure copy plan', () {
      final packets = _buildCfrPackets(
        durationSeconds: 10.0,
        fps: 30.0,
        gopSize: 60, // keyframes at 0, 2, 4, 6, 8s
      );

      final plan = SmartCutPlanner.planSegment(
        packets,
        2.0,
        6.0,
        10.0,
        fps: 30.0,
      );

      expect(plan.canSmartCut, isTrue);
      expect(plan.isPureCopy, isTrue);
      expect(plan.parts, hasLength(1));
      final copy = plan.parts.single;
      expect(copy.kind, SmartCutPartKind.copy);
      expect(copy.start, closeTo(2.0, 1e-6));
      expect(copy.end, closeTo(6.0, 1e-6));
      expect(copy.frameCount, 120);
      expect(copy.keyDts, isNotNull);
      expect(copy.endDts, isNotNull);
    });

    test('mid-GOP start and end split into head reencode + copy + tail reencode', () {
      final packets = _buildCfrPackets(
        durationSeconds: 10.0,
        fps: 30.0,
        gopSize: 60,
      );

      final plan = SmartCutPlanner.planSegment(
        packets,
        2.5,
        6.5,
        10.0,
        fps: 30.0,
      );

      expect(plan.canSmartCut, isTrue);
      expect(plan.hasCopyParts, isTrue);
      expect(plan.isPureCopy, isFalse);
      expect(plan.parts, hasLength(3));

      expect(plan.parts[0].kind, SmartCutPartKind.reencode);
      expect(plan.parts[0].start, closeTo(2.5, 1e-6));
      expect(plan.parts[0].end, closeTo(4.0, 1e-6));
      expect(plan.parts[0].frameCount, 45);

      expect(plan.parts[1].kind, SmartCutPartKind.copy);
      expect(plan.parts[1].start, closeTo(4.0, 1e-6));
      expect(plan.parts[1].end, closeTo(6.0, 1e-6));
      expect(plan.parts[1].frameCount, 60);
      expect(plan.parts[1].keyDts, closeTo(4.0, 1e-6));
      expect(plan.parts[1].endDts, closeTo(6.0, 1e-6));

      expect(plan.parts[2].kind, SmartCutPartKind.reencode);
      expect(plan.parts[2].start, closeTo(6.0, 1e-6));
      expect(plan.parts[2].end, closeTo(6.5, 1e-6));
      expect(plan.parts[2].frameCount, 15);
    });

    test('short segment without internal keyframe plans a single reencode part', () {
      final packets = _buildCfrPackets(
        durationSeconds: 10.0,
        fps: 30.0,
        gopSize: 60,
      );

      final plan = SmartCutPlanner.planSegment(
        packets,
        2.2,
        3.5,
        10.0,
        fps: 30.0,
      );

      expect(plan.canSmartCut, isTrue);
      expect(plan.hasCopyParts, isFalse);
      expect(plan.parts, hasLength(1));
      expect(plan.parts.single.kind, SmartCutPartKind.reencode);
      expect(plan.parts.single.frameCount, 39);
      expect(plan.expectedDuration, closeTo(1.3, 1e-4));
    });

    test('single internal keyframe ending mid-GOP reencodes cleanly', () {
      final packets = _buildCfrPackets(
        durationSeconds: 10.0,
        fps: 30.0,
        gopSize: 60,
      );

      final plan = SmartCutPlanner.planSegment(
        packets,
        2.5,
        5.5,
        10.0,
        fps: 30.0,
      );

      expect(plan.canSmartCut, isTrue);
      expect(plan.hasCopyParts, isFalse);
      expect(plan.parts, hasLength(1));
      expect(plan.parts.single.kind, SmartCutPartKind.reencode);
      expect(plan.parts.single.frameCount, 90);
    });

    test('segment extending to EOF copies through end without tail reencode', () {
      final packets = _buildCfrPackets(
        durationSeconds: 10.0,
        fps: 30.0,
        gopSize: 60,
      );

      final plan = SmartCutPlanner.planSegment(
        packets,
        2.5,
        10.0,
        10.0,
        fps: 30.0,
      );

      expect(plan.canSmartCut, isTrue);
      expect(plan.parts, hasLength(2));

      expect(plan.parts[0].kind, SmartCutPartKind.reencode);
      expect(plan.parts[0].start, closeTo(2.5, 1e-6));
      expect(plan.parts[0].end, closeTo(4.0, 1e-6));
      expect(plan.parts[0].frameCount, 45);

      expect(plan.parts[1].kind, SmartCutPartKind.copy);
      expect(plan.parts[1].start, closeTo(4.0, 1e-6));
      expect(plan.parts[1].end, closeTo(10.0, 1e-6));
      expect(plan.parts[1].frameCount, 180);
      expect(plan.parts[1].endDts, isNull);
    });

    test('full duration from 0 to EOF starting on keyframe is pure copy', () {
      final packets = _buildCfrPackets(
        durationSeconds: 10.0,
        fps: 30.0,
        gopSize: 60,
      );

      final plan = SmartCutPlanner.planSegment(
        packets,
        0.0,
        10.0,
        10.0,
        fps: 30.0,
      );

      expect(plan.canSmartCut, isTrue);
      expect(plan.isPureCopy, isTrue);
      expect(plan.parts.single.frameCount, 300);
      expect(plan.parts.single.endDts, isNull);
    });
  });

  group('Open-GOP detection', () {
    test('closed GOP with B-frames is accepted', () {
      final packets = _buildCfrPackets(
        durationSeconds: 10.0,
        fps: 30.0,
        gopSize: 60,
        withClosedBFrames: true,
      );

      final secondKeyIndex = packets.indexWhere(
        (p) => p.isKeyFrame && p.pts > 1.0,
      );
      expect(SmartCutPlanner.isOpenGop(packets, secondKeyIndex), isFalse);

      final plan = SmartCutPlanner.planSegment(
        packets,
        2.5,
        6.5,
        10.0,
        fps: 30.0,
      );
      expect(plan.canSmartCut, isTrue);
      expect(plan.parts, hasLength(3));
    });

    test('detects Open-GOP when post-keyframe packet has PTS < keyframe PTS', () {
      final packets = <SmartCutPacket>[
        const SmartCutPacket(pts: 0.0, dts: -0.1, isKeyFrame: true),
        const SmartCutPacket(pts: 1.0, dts: 0.9),
        // Second GOP keyframe at pts=2.0 followed in decode order by B-frame
        // displaying at pts=1.96 (prior to keyframe).
        const SmartCutPacket(pts: 2.0, dts: 1.9, isKeyFrame: true),
        const SmartCutPacket(pts: 1.96, dts: 1.93),
        const SmartCutPacket(pts: 2.5, dts: 2.4),
        const SmartCutPacket(pts: 4.0, dts: 3.9, isKeyFrame: true),
        const SmartCutPacket(pts: 4.5, dts: 4.4),
      ];

      expect(SmartCutPlanner.isOpenGop(packets, 0), isFalse);
      expect(SmartCutPlanner.isOpenGop(packets, 2), isTrue);

      final plan = SmartCutPlanner.planSegment(
        packets,
        0.5,
        4.5,
        6.0,
        fps: 30.0,
      );
      expect(plan.canSmartCut, isFalse);
      expect(plan.fallbackReason, SmartCutFallbackReason.openGop);
    });

    test('triggers openGop fallback when trailing copy boundary keyframe is open', () {
      final packets = <SmartCutPacket>[
        const SmartCutPacket(pts: 0.0, dts: 0.0, isKeyFrame: true),
        const SmartCutPacket(pts: 0.5, dts: 0.5),
        // Closed keyframe k1 at 2.0
        const SmartCutPacket(pts: 2.0, dts: 2.0, isKeyFrame: true),
        const SmartCutPacket(pts: 2.5, dts: 2.5),
        // Open keyframe k2 at 4.0 (followed by pts=3.95)
        const SmartCutPacket(pts: 4.0, dts: 3.9, isKeyFrame: true),
        const SmartCutPacket(pts: 3.95, dts: 3.93),
        const SmartCutPacket(pts: 4.5, dts: 4.5),
      ];

      final plan = SmartCutPlanner.planSegment(
        packets,
        0.5,
        4.5,
        6.0,
        fps: 30.0,
      );
      expect(plan.canSmartCut, isFalse);
      expect(plan.fallbackReason, SmartCutFallbackReason.openGop);
    });
  });

  group('Compatibility & VFR detection', () {
    test('canAttemptSmartCut accepts valid H.264 CFR source', () {
      final params = _validParams();
      expect(SmartCutPlanner.canAttemptSmartCut(params), isTrue);
      expect(SmartCutPlanner.checkCompatibility(params), isNull);
    });

    test('rejects unsupported codecs, 10-bit pixFmt, invalid fps, and VFR', () {
      expect(
        SmartCutPlanner.checkCompatibility(_validParams(codecName: 'hevc')),
        SmartCutFallbackReason.unsupportedCodec,
      );
      expect(
        SmartCutPlanner.checkCompatibility(_validParams(codecName: 'vp9')),
        SmartCutFallbackReason.unsupportedCodec,
      );
      expect(
        SmartCutPlanner.checkCompatibility(_validParams(isVfr: true)),
        SmartCutFallbackReason.vfrSource,
      );
      expect(
        SmartCutPlanner.canAttemptSmartCut(_validParams(isVfr: true)),
        isFalse,
      );
      expect(
        SmartCutPlanner.checkCompatibility(_validParams(fps: 0.0)),
        SmartCutFallbackReason.unsupportedCodec,
      );
      expect(
        SmartCutPlanner.checkCompatibility(_validParams(pixFmt: 'yuv420p10le')),
        SmartCutFallbackReason.unsupportedCodec,
      );
      expect(
        SmartCutPlanner.checkCompatibility(_validParams(pixFmt: 'unknown')),
        SmartCutFallbackReason.unsupportedCodec,
      );
      expect(
        SmartCutPlanner.checkCompatibility(_validParams(width: 0)),
        SmartCutFallbackReason.unsupportedCodec,
      );
    });

    test('parseFrameRate and detectVfr handle rational and CFR/VFR rates', () {
      expect(SmartCutPlanner.parseFrameRate('30000/1001'), closeTo(29.97, 0.01));
      expect(SmartCutPlanner.parseFrameRate('60/1'), 60.0);
      expect(SmartCutPlanner.parseFrameRate('0/0'), 0.0);
      expect(SmartCutPlanner.parseFrameRate('N/A'), 0.0);

      expect(
        SmartCutPlanner.detectVfr(
          avgFrameRate: '30000/1001',
          rFrameRate: '30000/1001',
        ),
        isFalse,
      );
      expect(
        SmartCutPlanner.detectVfr(
          avgFrameRate: '27500/1000',
          rFrameRate: '30000/1000',
        ),
        isTrue,
      );
      expect(
        SmartCutPlanner.detectVfr(
          avgFrameRate: '30/1',
          rFrameRate: '1000/1',
        ),
        isTrue,
      );
    });
  });

  group('buildMatchedX264Flags', () {
    test('emits matched profile, integer/dotted level, pix_fmt, closed GOP, and valid color tags', () {
      final flags = SmartCutPlanner.buildMatchedX264Flags(_validParams());

      expect(flags, contains('-c:v libx264'));
      expect(flags, contains('-profile:v high'));
      expect(flags, contains('-level:v 4.1'));
      expect(flags, contains('-pix_fmt yuv420p'));
      expect(flags, contains('-x264-params "bf=2:open-gop=0"'));
      expect(flags, contains('-colorspace bt709'));
      expect(flags, contains('-color_primaries bt709'));
      expect(flags, contains('-color_trc bt709'));
      expect(flags, contains('-color_range tv'));
    });

    test('ignores unknown/unspecified tags and forces bf=0 on baseline profile', () {
      final flags = SmartCutPlanner.buildMatchedX264Flags(
        _validParams(
          profile: 'Constrained Baseline',
          level: '3.1',
          hasBFrames: 2,
          colorSpace: 'unknown',
          colorPrimaries: 'unspecified',
          colorTransfer: null,
          colorRange: 'N/A',
        ),
      );

      expect(flags, contains('-profile:v baseline'));
      expect(flags, contains('-level:v 3.1'));
      expect(flags, contains('-x264-params "bf=0:open-gop=0"'));
      expect(flags, isNot(contains('-colorspace')));
      expect(flags, isNot(contains('-color_primaries')));
      expect(flags, isNot(contains('-color_trc')));
      expect(flags, isNot(contains('-color_range')));
    });
  });

  group('buildAudioDeclickFilter', () {
    test('single kept segment uses aresample + apad without afade', () {
      final filter = SmartCutPlanner.buildAudioDeclickFilter(
        segments: const [(1.5, 5.5)],
      );

      expect(filter, contains('[1:a]atrim=start=1.500000:end=5.500000'));
      expect(filter, contains('asetpts=PTS-STARTPTS'));
      expect(filter, contains('aresample=async=1:first_pts=0'));
      expect(filter, contains('apad=whole_dur=4.000000[outa]'));
      expect(filter, isNot(contains('afade=')));
      expect(filter, isNot(contains('concat=')));
    });

    test('two kept segments fade only on internal splice boundary', () {
      final filter = SmartCutPlanner.buildAudioDeclickFilter(
        segments: const [(0.0, 2.0), (4.0, 7.0)],
      );

      expect(
        filter,
        contains(
          '[1:a]atrim=start=0.000000:end=2.000000,'
          'asetpts=PTS-STARTPTS,aresample=async=1:first_pts=0,'
          'afade=t=out:st=1.995000:d=0.005,apad=whole_dur=2.000000[a0];',
        ),
      );
      expect(
        filter,
        contains(
          '[1:a]atrim=start=4.000000:end=7.000000,'
          'asetpts=PTS-STARTPTS,aresample=async=1:first_pts=0,'
          'afade=t=in:st=0:d=0.005,apad=whole_dur=3.000000[a1];',
        ),
      );
      expect(filter, endsWith('[a0][a1]concat=n=2:v=0:a=1[outa]'));
    });

    test('three kept segments put both fade-in and fade-out on middle segment', () {
      final filter = SmartCutPlanner.buildAudioDeclickFilter(
        segments: const [(0.0, 1.0), (2.0, 4.0), (5.0, 8.0)],
      );

      expect(
        filter,
        contains(
          '[1:a]atrim=start=2.000000:end=4.000000,'
          'asetpts=PTS-STARTPTS,aresample=async=1:first_pts=0,'
          'afade=t=in:st=0:d=0.005,afade=t=out:st=1.995000:d=0.005,'
          'apad=whole_dur=2.000000[a1];',
        ),
      );
      expect(filter, endsWith('[a0][a1][a2]concat=n=3:v=0:a=1[outa]'));
    });
  });

  group('validateOutputProbe', () {
    test('passes for valid video+audio within tolerance', () {
      final res = SmartCutPlanner.validateOutputProbe(
        hasVideoStream: true,
        hasAudioStream: true,
        expectAudio: true,
        actualDurationSeconds: 4.12,
        expectedDurationSeconds: 4.0,
        fps: 30.0,
        fileSizeBytes: 102400,
      );
      expect(res.isValid, isTrue);
    });

    test('passes for video-only output when audio is not expected', () {
      final res = SmartCutPlanner.validateOutputProbe(
        hasVideoStream: true,
        hasAudioStream: false,
        expectAudio: false,
        actualDurationSeconds: 4.0,
        expectedDurationSeconds: 4.0,
        fps: 30.0,
        fileSizeBytes: 51200,
      );
      expect(res.isValid, isTrue);
    });

    test('fails on empty size, missing video, missing expected audio, or drift', () {
      expect(
        SmartCutPlanner.validateOutputProbe(
          hasVideoStream: true,
          hasAudioStream: true,
          expectAudio: true,
          actualDurationSeconds: 4.0,
          expectedDurationSeconds: 4.0,
          fps: 30.0,
          fileSizeBytes: 0,
        ).isValid,
        isFalse,
      );
      expect(
        SmartCutPlanner.validateOutputProbe(
          hasVideoStream: false,
          hasAudioStream: true,
          expectAudio: true,
          actualDurationSeconds: 4.0,
          expectedDurationSeconds: 4.0,
          fps: 30.0,
          fileSizeBytes: 1024,
        ).isValid,
        isFalse,
      );
      expect(
        SmartCutPlanner.validateOutputProbe(
          hasVideoStream: true,
          hasAudioStream: false,
          expectAudio: true,
          actualDurationSeconds: 4.0,
          expectedDurationSeconds: 4.0,
          fps: 30.0,
          fileSizeBytes: 1024,
        ).isValid,
        isFalse,
      );
      expect(
        SmartCutPlanner.validateOutputProbe(
          hasVideoStream: true,
          hasAudioStream: true,
          expectAudio: true,
          actualDurationSeconds: 4.6,
          expectedDurationSeconds: 4.0,
          fps: 30.0,
          fileSizeBytes: 1024,
        ).isValid,
        isFalse,
      );
    });

    test('uses max(0.5s, 3 frames) tolerance for low-fps streams', () {
      // At 2 fps, 3 frames = 1.5s > 0.5s, so 1.2s drift is allowed and 1.6s fails.
      expect(
        SmartCutPlanner.validateOutputProbe(
          hasVideoStream: true,
          hasAudioStream: true,
          expectAudio: true,
          actualDurationSeconds: 5.2,
          expectedDurationSeconds: 4.0,
          fps: 2.0,
          fileSizeBytes: 1024,
        ).isValid,
        isTrue,
      );
      expect(
        SmartCutPlanner.validateOutputProbe(
          hasVideoStream: true,
          hasAudioStream: true,
          expectAudio: true,
          actualDurationSeconds: 5.6,
          expectedDurationSeconds: 4.0,
          fps: 2.0,
          fileSizeBytes: 1024,
        ).isValid,
        isFalse,
      );
    });
  });

  group('CSV parsing & command builders', () {
    test('parsePacketsCsv preserves decode order and handles N/A fallback', () {
      const csv = '''
0.000000,-0.066667,K_
0.066667,-0.033333,__
0.033333,N/A,__
packet,2.000000,1.933333,K__
''';
      final packets = SmartCutPlanner.parsePacketsCsv(csv);
      expect(packets, hasLength(4));
      expect(packets[0].isKeyFrame, isTrue);
      expect(packets[1].pts, closeTo(0.066667, 1e-6));
      expect(packets[2].pts, closeTo(0.033333, 1e-6));
      expect(packets[2].dts, closeTo(0.033333, 1e-6));
      expect(packets[3].isKeyFrame, isTrue);
    });

    test('part, concat, and merge command builders format properly', () {
      final params = _validParams();
      const reencodePart = SmartCutPart(
        kind: SmartCutPartKind.reencode,
        start: 2.5,
        end: 4.0,
        frameCount: 45,
      );
      const copyPart = SmartCutPart(
        kind: SmartCutPartKind.copy,
        start: 4.0,
        end: 6.0,
        frameCount: 60,
        keyDts: 4.0,
        endDts: 6.0,
      );

      final reCmd = SmartCutPlanner.buildReencodePartCommand(
        inputPath: 'C:/clips/src.mp4',
        outputPath: 'C:/tmp/part0.mp4',
        part: reencodePart,
        params: params,
      );
      expect(reCmd, contains('-ss 2.499000'));
      expect(reCmd, contains('-frames:v 45'));
      expect(reCmd, contains('-video_track_timescale 90000'));
      expect(reCmd, contains('-an'));

      final cpCmd = SmartCutPlanner.buildCopyPartCommand(
        inputPath: 'C:/clips/src.mp4',
        outputPath: 'C:/tmp/part1.mp4',
        part: copyPart,
        params: params,
      );
      expect(cpCmd, contains('-ss 4.001000'));
      expect(cpCmd, contains('-c:v copy'));
      expect(cpCmd, contains('-frames:v 60'));

      final concat = SmartCutPlanner.buildConcatListContent([
        (path: 'C:/tmp/part0.mp4', duration: 1.5),
        (path: 'C:/tmp/part1.mp4', duration: 2.0),
      ]);
      expect(concat, startsWith('ffconcat version 1.0'));
      expect(concat, contains("file 'C:/tmp/part0.mp4'"));
      expect(concat, contains('duration 1.500000'));

      final merge = SmartCutPlanner.buildMergeCommand(
        concatListPath: 'C:/tmp/concat.txt',
        sourceInputPath: 'C:/clips/src.mp4',
        outputPath: 'C:/clips/out.mp4',
        keptSegments: const [(2.5, 6.0)],
        hasAudio: true,
      );
      expect(merge, contains('-c:v copy'));
      expect(merge, contains('-c:a aac -b:a 192k'));
      expect(merge, contains('-movflags +faststart'));
      expect(merge, contains('-map 0:v:0 -map "[outa]"'));

      final kept = SmartCutPlanner.computeKeptSegments(
        const [(2.0, 4.0), (7.0, 8.0)],
        10.0,
      );
      expect(kept, [(0.0, 2.0), (4.0, 7.0), (8.0, 10.0)]);
    });
  });
}
