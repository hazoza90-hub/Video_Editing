# Source inventory / فهرس المصدر

Generated from the current local source by `python tools/review_inventory.py`.
This is navigation metadata, not proof that every branch has been runtime-tested.

138 Dart files in lib/ and test/. Generated/build caches excluded.

| Group | Files |
|---|---:|
| audio_enhancement | 4 |
| audio_processing | 4 |
| export | 1 |
| lib/app.dart | 1 |
| lib/core | 21 |
| lib/main.dart | 1 |
| lib/shared | 4 |
| media_cutter | 4 |
| preview | 1 |
| shorts_generator | 14 |
| silence_detector | 13 |
| splash | 1 |
| test/audio_enhancement_test.dart | 1 |
| test/audio_preview_command_test.dart | 1 |
| test/media_cutter_command_test.dart | 1 |
| test/professional_audio_editor_service_test.dart | 1 |
| test/video_download_service_test.dart | 1 |
| test/video_enhancement_command_test.dart | 1 |
| test/video_import_metadata_test.dart | 1 |
| test/widget_test.dart | 1 |
| video_adjustment | 27 |
| video_enhancement | 19 |
| video_import | 8 |
| video_processing | 7 |

| File | Lines | Types / Providers |
|---|---:|---|
| [lib/app.dart](../lib/app.dart) | 21 | SilenceRemoverApp |
| [lib/core/constants/adjustment_defaults.dart](../lib/core/constants/adjustment_defaults.dart) | 98 | AdjustmentDefaults |
| [lib/core/constants/app_constants.dart](../lib/core/constants/app_constants.dart) | 34 | AppConstants |
| [lib/core/constants/ffmpeg_filters.dart](../lib/core/constants/ffmpeg_filters.dart) | 42 | FfmpegFilterConstants |
| [lib/core/enums/export_quality.dart](../lib/core/enums/export_quality.dart) | 5 | ExportQuality |
| [lib/core/enums/processing_state.dart](../lib/core/enums/processing_state.dart) | 9 | ProcessingState |
| [lib/core/errors/failures.dart](../lib/core/errors/failures.dart) | 52 | Failure, VideoImportFailure, AudioExtractionFailure, SilenceDetectionFailure, VideoProcessingFailure, ExportFailure, PermissionFailure, StorageFailure, CorruptedFileFailure, NoAudioTrackFailure, EnhancementFailure |
| [lib/core/extensions/num_extensions.dart](../lib/core/extensions/num_extensions.dart) | 15 | DoubleExtensions, IntExtensions |
| [lib/core/router/app_router.dart](../lib/core/router/app_router.dart) | 116 | AppRouter |
| [lib/core/services/draft_service.dart](../lib/core/services/draft_service.dart) | 196 | DraftData, DraftService |
| [lib/core/services/face_detection_service.dart](../lib/core/services/face_detection_service.dart) | 283 | _FaceTrack, FaceDetectionService |
| [lib/core/services/video_download_service.dart](../lib/core/services/video_download_service.dart) | 549 | CancelToken, DownloadProgress, _SpeedTracker, YoutubeQualityOption, VideoDownloadService, CancelledDownloadException |
| [lib/core/theme/app_colors.dart](../lib/core/theme/app_colors.dart) | 35 | AppColors |
| [lib/core/theme/app_theme.dart](../lib/core/theme/app_theme.dart) | 158 | AppTheme |
| [lib/core/utils/duration_utils.dart](../lib/core/utils/duration_utils.dart) | 28 | DurationUtils |
| [lib/core/utils/exports.dart](../lib/core/utils/exports.dart) | 4 | — |
| [lib/core/utils/file_utils.dart](../lib/core/utils/file_utils.dart) | 93 | FileUtils |
| [lib/core/utils/filter_chain_builder.dart](../lib/core/utils/filter_chain_builder.dart) | 260 | FilterChainBuilder |
| [lib/core/utils/frame_extractor.dart](../lib/core/utils/frame_extractor.dart) | 49 | FrameExtractor |
| [lib/core/utils/logger.dart](../lib/core/utils/logger.dart) | 30 | LogLevel, AppLogger |
| [lib/core/utils/media_scanner.dart](../lib/core/utils/media_scanner.dart) | 18 | MediaScanner |
| [lib/core/utils/result.dart](../lib/core/utils/result.dart) | 15 | Result, Success, AppError |
| [lib/features/audio_enhancement/data/services/audio_enhancement_filter_builder.dart](../lib/features/audio_enhancement/data/services/audio_enhancement_filter_builder.dart) | 63 | AudioEnhancementFilterBuilder |
| [lib/features/audio_enhancement/data/services/audio_preview_command_builder.dart](../lib/features/audio_enhancement/data/services/audio_preview_command_builder.dart) | 32 | AudioPreviewCommandBuilder |
| [lib/features/audio_enhancement/data/services/auto_noise_detector.dart](../lib/features/audio_enhancement/data/services/auto_noise_detector.dart) | 53 | AutoNoiseDetector |
| [lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart](../lib/features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart) | 1095 | AudioEnhancePreset, _PresetValues, AudioEnhancementScreen, _AudioEnhancementScreenState |
| [lib/features/audio_processing/data/repositories/audio_processor_repository_impl.dart](../lib/features/audio_processing/data/repositories/audio_processor_repository_impl.dart) | 160 | AudioProcessorRepositoryImpl |
| [lib/features/audio_processing/domain/entities/waveform_data.dart](../lib/features/audio_processing/domain/entities/waveform_data.dart) | 45 | WaveformData |
| [lib/features/audio_processing/domain/providers/waveform_provider.dart](../lib/features/audio_processing/domain/providers/waveform_provider.dart) | 32 | WaveformNotifier, audioProcessorRepositoryProvider, waveformProvider |
| [lib/features/audio_processing/domain/repositories/audio_processor_repository.dart](../lib/features/audio_processing/domain/repositories/audio_processor_repository.dart) | 7 | AudioProcessorRepository |
| [lib/features/export/presentation/export_screen.dart](../lib/features/export/presentation/export_screen.dart) | 410 | ExportScreen, _ExportScreenState |
| [lib/features/media_cutter/data/services/ffmpeg_media_cutter_service.dart](../lib/features/media_cutter/data/services/ffmpeg_media_cutter_service.dart) | 1326 | CutterMediaType, CutterMode, MediaCutterCancelledException, MediaCutCommand, RemoveRange, FfmpegMediaCutterService |
| [lib/features/media_cutter/data/services/professional_audio_editor_service.dart](../lib/features/media_cutter/data/services/professional_audio_editor_service.dart) | 291 | AudioSilenceRegion, ProfessionalAudioEditorService |
| [lib/features/media_cutter/presentation/screens/audio_editor_screen.dart](../lib/features/media_cutter/presentation/screens/audio_editor_screen.dart) | 977 | AudioEditorScreen, _AudioEditorScreenState, _DragTarget, _AudioEditSnapshot, _AudioOverlayPainter |
| [lib/features/media_cutter/presentation/screens/media_cutter_screen.dart](../lib/features/media_cutter/presentation/screens/media_cutter_screen.dart) | 1870 | MediaCutterScreen, _MediaCutterScreenState, _TimelineDragMode, _WaveformRangeEditor, _WaveformRangeEditorState, _WaveformRangePainter, _WaveformSplitEditor, _WaveformSplitPainter |
| [lib/features/preview/presentation/preview_screen.dart](../lib/features/preview/presentation/preview_screen.dart) | 302 | PreviewScreen, _PreviewScreenState |
| [lib/features/shorts_generator/data/datasources/ffmpeg_analysis_datasource.dart](../lib/features/shorts_generator/data/datasources/ffmpeg_analysis_datasource.dart) | 101 | FfmpegAnalysisDatasource |
| [lib/features/shorts_generator/data/datasources/ffmpeg_export_datasource.dart](../lib/features/shorts_generator/data/datasources/ffmpeg_export_datasource.dart) | 192 | FfmpegExportDatasource |
| [lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart](../lib/features/shorts_generator/data/repositories/shorts_repository_impl.dart) | 435 | ShortsRepositoryImpl |
| [lib/features/shorts_generator/domain/entities/clip_suggestion.dart](../lib/features/shorts_generator/domain/entities/clip_suggestion.dart) | 22 | ClipSuggestion |
| [lib/features/shorts_generator/domain/entities/export_settings.dart](../lib/features/shorts_generator/domain/entities/export_settings.dart) | 125 | PlatformTarget, ClipDuration, CuttingMode, ExportQuality, ExportQualityLabel, ExportSettings |
| [lib/features/shorts_generator/domain/entities/reframe_settings.dart](../lib/features/shorts_generator/domain/entities/reframe_settings.dart) | 65 | ReframeMode, ReframeModeLabel, ReframeSettings |
| [lib/features/shorts_generator/domain/entities/scene_info.dart](../lib/features/shorts_generator/domain/entities/scene_info.dart) | 15 | SceneInfo |
| [lib/features/shorts_generator/domain/entities/shorts_project.dart](../lib/features/shorts_generator/domain/entities/shorts_project.dart) | 19 | ShortsProject |
| [lib/features/shorts_generator/domain/entities/video_segment.dart](../lib/features/shorts_generator/domain/entities/video_segment.dart) | 15 | VideoSegment |
| [lib/features/shorts_generator/domain/repositories/shorts_repository.dart](../lib/features/shorts_generator/domain/repositories/shorts_repository.dart) | 18 | ShortsRepository |
| [lib/features/shorts_generator/presentation/providers/shorts_provider.dart](../lib/features/shorts_generator/presentation/providers/shorts_provider.dart) | 137 | ExportSettingsNotifier, ShortsUiState, ShortsUiNotifier, exportSettingsProvider, shortsUiProvider |
| [lib/features/shorts_generator/presentation/screens/export_screen.dart](../lib/features/shorts_generator/presentation/screens/export_screen.dart) | 125 | ShortsExportScreen |
| [lib/features/shorts_generator/presentation/screens/import_mode_screen.dart](../lib/features/shorts_generator/presentation/screens/import_mode_screen.dart) | 464 | ImportModeScreen, _ImportModeScreenState |
| [lib/features/shorts_generator/presentation/screens/suggestions_screen.dart](../lib/features/shorts_generator/presentation/screens/suggestions_screen.dart) | 765 | SuggestionsScreen, _ClipCard, _TemplateBadge, _EditClipDialogRoute, _EditClipScreen, _EditClipScreenState, _PreviewRoute, _PreviewScreen, _PreviewScreenState |
| [lib/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart](../lib/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart) | 140 | FfmpegSilenceDatasource |
| [lib/features/silence_detector/data/repositories/silence_detector_repository_impl.dart](../lib/features/silence_detector/data/repositories/silence_detector_repository_impl.dart) | 112 | SilenceDetectorRepositoryImpl |
| [lib/features/silence_detector/data/services/adaptive_threshold_service.dart](../lib/features/silence_detector/data/services/adaptive_threshold_service.dart) | 71 | AdaptiveThresholdService |
| [lib/features/silence_detector/data/services/breathing_protection_service.dart](../lib/features/silence_detector/data/services/breathing_protection_service.dart) | 43 | BreathingProtectionService |
| [lib/features/silence_detector/data/services/vad_service.dart](../lib/features/silence_detector/data/services/vad_service.dart) | 100 | VadService |
| [lib/features/silence_detector/domain/entities/detection_params.dart](../lib/features/silence_detector/domain/entities/detection_params.dart) | 90 | SmartZoomConfig, DetectionParams |
| [lib/features/silence_detector/domain/entities/silence_segment.dart](../lib/features/silence_detector/domain/entities/silence_segment.dart) | 26 | SilenceSegment |
| [lib/features/silence_detector/domain/providers/silence_detection_provider.dart](../lib/features/silence_detector/domain/providers/silence_detection_provider.dart) | 118 | DetectionParamsNotifier, SilenceSegmentsNotifier, detectionParamsProvider, silenceSegmentsProvider, hasSilenceSegmentsProvider, totalSilenceDurationProvider |
| [lib/features/silence_detector/domain/repositories/silence_detector_repository.dart](../lib/features/silence_detector/domain/repositories/silence_detector_repository.dart) | 23 | SilenceDetectorRepository |
| [lib/features/silence_detector/presentation/editor_screen.dart](../lib/features/silence_detector/presentation/editor_screen.dart) | 535 | EditorScreen, _EditorScreenState |
| [lib/features/silence_detector/presentation/widgets/detection_settings_panel.dart](../lib/features/silence_detector/presentation/widgets/detection_settings_panel.dart) | 303 | DetectionSettingsPanel, _ThresholdSlider, _MinDurationSlider, _PaddingSlider |
| [lib/features/silence_detector/presentation/widgets/silence_timeline.dart](../lib/features/silence_detector/presentation/widgets/silence_timeline.dart) | 140 | SilenceTimeline, _SegmentItem |
| [lib/features/silence_detector/presentation/widgets/waveform_viewer.dart](../lib/features/silence_detector/presentation/widgets/waveform_viewer.dart) | 200 | WaveformViewer, _WaveformPainter |
| [lib/features/splash/presentation/splash_screen.dart](../lib/features/splash/presentation/splash_screen.dart) | 68 | SplashScreen, _SplashScreenState |
| [lib/features/video_adjustment/data/datasources/ffmpeg_adjustment_datasource.dart](../lib/features/video_adjustment/data/datasources/ffmpeg_adjustment_datasource.dart) | 189 | FfmpegAdjustmentDatasource |
| [lib/features/video_adjustment/data/repositories/adjustment_repository_impl.dart](../lib/features/video_adjustment/data/repositories/adjustment_repository_impl.dart) | 99 | AdjustmentRepositoryImpl |
| [lib/features/video_adjustment/domain/entities/adjustment_preset.dart](../lib/features/video_adjustment/domain/entities/adjustment_preset.dart) | 118 | AdjustmentPreset |
| [lib/features/video_adjustment/domain/entities/adjustment_settings.dart](../lib/features/video_adjustment/domain/entities/adjustment_settings.dart) | 114 | AdjustmentSettings |
| [lib/features/video_adjustment/domain/entities/audio_adjustment.dart](../lib/features/video_adjustment/domain/entities/audio_adjustment.dart) | 67 | AudioAdjustment |
| [lib/features/video_adjustment/domain/entities/color_adjustment.dart](../lib/features/video_adjustment/domain/entities/color_adjustment.dart) | 52 | ColorAdjustment |
| [lib/features/video_adjustment/domain/entities/tone_adjustment.dart](../lib/features/video_adjustment/domain/entities/tone_adjustment.dart) | 42 | ToneAdjustment |
| [lib/features/video_adjustment/domain/entities/video_adjustment.dart](../lib/features/video_adjustment/domain/entities/video_adjustment.dart) | 80 | VideoAdjustment |
| [lib/features/video_adjustment/domain/repositories/adjustment_repository.dart](../lib/features/video_adjustment/domain/repositories/adjustment_repository.dart) | 24 | AdjustmentRepository |
| [lib/features/video_adjustment/domain/usecases/apply_adjustments_usecase.dart](../lib/features/video_adjustment/domain/usecases/apply_adjustments_usecase.dart) | 72 | ApplyAdjustmentsUseCase, PreviewFrameUseCase, ExportAdjustedVideoUseCase, ApplyPresetUseCase, ApplyLutUseCase |
| [lib/features/video_adjustment/presentation/providers/adjustment_provider.dart](../lib/features/video_adjustment/presentation/providers/adjustment_provider.dart) | 327 | AdjustmentNotifier, adjustmentDatasourceProvider, adjustmentRepositoryProvider, adjustmentProvider |
| [lib/features/video_adjustment/presentation/providers/export_provider.dart](../lib/features/video_adjustment/presentation/providers/export_provider.dart) | 90 | ExportNotifier, ExportState, exportProvider |
| [lib/features/video_adjustment/presentation/providers/preview_provider.dart](../lib/features/video_adjustment/presentation/providers/preview_provider.dart) | 80 | PreviewNotifier, PreviewState, previewProvider |
| [lib/features/video_adjustment/presentation/providers/undo_redo_provider.dart](../lib/features/video_adjustment/presentation/providers/undo_redo_provider.dart) | 86 | UndoRedoNotifier, UndoRedoState, undoRedoProvider |
| [lib/features/video_adjustment/presentation/screens/adjustment_screen.dart](../lib/features/video_adjustment/presentation/screens/adjustment_screen.dart) | 358 | AdjustmentScreen, _AdjustmentScreenState, ExportQualitySelector, _ExportQualitySelectorState |
| [lib/features/video_adjustment/presentation/widgets/adjustment_slider.dart](../lib/features/video_adjustment/presentation/widgets/adjustment_slider.dart) | 115 | AdjustmentSlider |
| [lib/features/video_adjustment/presentation/widgets/audio_adjustments_panel.dart](../lib/features/video_adjustment/presentation/widgets/audio_adjustments_panel.dart) | 39 | AudioAdjustmentsPanel |
| [lib/features/video_adjustment/presentation/widgets/basic_adjustments_panel.dart](../lib/features/video_adjustment/presentation/widgets/basic_adjustments_panel.dart) | 98 | BasicAdjustmentsPanel |
| [lib/features/video_adjustment/presentation/widgets/before_after_toggle.dart](../lib/features/video_adjustment/presentation/widgets/before_after_toggle.dart) | 63 | BeforeAfterToggle |
| [lib/features/video_adjustment/presentation/widgets/color_adjustments_panel.dart](../lib/features/video_adjustment/presentation/widgets/color_adjustments_panel.dart) | 34 | ColorAdjustmentsPanel |
| [lib/features/video_adjustment/presentation/widgets/effects_panel.dart](../lib/features/video_adjustment/presentation/widgets/effects_panel.dart) | 32 | EffectsPanel |
| [lib/features/video_adjustment/presentation/widgets/lut_panel.dart](../lib/features/video_adjustment/presentation/widgets/lut_panel.dart) | 130 | LutPanel, _LutInfo, _LutTile |
| [lib/features/video_adjustment/presentation/widgets/presets_row.dart](../lib/features/video_adjustment/presentation/widgets/presets_row.dart) | 96 | PresetsRow |
| [lib/features/video_adjustment/presentation/widgets/tone_adjustments_panel.dart](../lib/features/video_adjustment/presentation/widgets/tone_adjustments_panel.dart) | 32 | ToneAdjustmentsPanel |
| [lib/features/video_adjustment/presentation/widgets/undo_redo_bar.dart](../lib/features/video_adjustment/presentation/widgets/undo_redo_bar.dart) | 60 | UndoRedoBar |
| [lib/features/video_adjustment/presentation/widgets/video_adjustments_panel.dart](../lib/features/video_adjustment/presentation/widgets/video_adjustments_panel.dart) | 86 | VideoAdjustmentsPanel |
| [lib/features/video_adjustment/presentation/widgets/video_preview_widget.dart](../lib/features/video_adjustment/presentation/widgets/video_preview_widget.dart) | 121 | VideoPreviewWidget |
| [lib/features/video_enhancement/data/datasources/ffmpeg_enhancement_datasource.dart](../lib/features/video_enhancement/data/datasources/ffmpeg_enhancement_datasource.dart) | 197 | FfmpegEnhancementDatasource |
| [lib/features/video_enhancement/data/datasources/preview_generator_datasource.dart](../lib/features/video_enhancement/data/datasources/preview_generator_datasource.dart) | 144 | PreviewGeneratorDatasource |
| [lib/features/video_enhancement/data/datasources/professional_enhancement_command_builder.dart](../lib/features/video_enhancement/data/datasources/professional_enhancement_command_builder.dart) | 236 | ProfessionalEnhancementCommandBuilder |
| [lib/features/video_enhancement/data/datasources/video_analyzer_datasource.dart](../lib/features/video_enhancement/data/datasources/video_analyzer_datasource.dart) | 201 | VideoAnalyzerDatasource |
| [lib/features/video_enhancement/data/repositories/enhancement_repository_impl.dart](../lib/features/video_enhancement/data/repositories/enhancement_repository_impl.dart) | 108 | EnhancementRepositoryImpl |
| [lib/features/video_enhancement/domain/entities/enhancement_plan.dart](../lib/features/video_enhancement/domain/entities/enhancement_plan.dart) | 162 | EnhancementLevel, EnhancementAction, EnhancementPlan |
| [lib/features/video_enhancement/domain/entities/enhancement_result.dart](../lib/features/video_enhancement/domain/entities/enhancement_result.dart) | 109 | EnhancementResult, EnhancementStageResult, PreviewFrame |
| [lib/features/video_enhancement/domain/entities/enhancement_settings.dart](../lib/features/video_enhancement/domain/entities/enhancement_settings.dart) | 97 | EnhancementSettings |
| [lib/features/video_enhancement/domain/entities/video_analysis_result.dart](../lib/features/video_enhancement/domain/entities/video_analysis_result.dart) | 139 | VideoQualityIssue, VideoMetadata, VideoQualityAnalysis, VideoAnalysisResult |
| [lib/features/video_enhancement/domain/repositories/enhancement_repository.dart](../lib/features/video_enhancement/domain/repositories/enhancement_repository.dart) | 45 | EnhancementRepository, EnhancementProgress |
| [lib/features/video_enhancement/presentation/providers/enhancement_provider.dart](../lib/features/video_enhancement/presentation/providers/enhancement_provider.dart) | 301 | EnhancementScreen, EnhancementState, EnhancementNotifier, EnhancementPlanCopyWith, enhancementProvider |
| [lib/features/video_enhancement/presentation/screens/analysis_screen.dart](../lib/features/video_enhancement/presentation/screens/analysis_screen.dart) | 115 | AnalysisScreen |
| [lib/features/video_enhancement/presentation/screens/enhancement_home_screen.dart](../lib/features/video_enhancement/presentation/screens/enhancement_home_screen.dart) | 83 | EnhancementHomeScreen, _EnhancementHomeScreenState |
| [lib/features/video_enhancement/presentation/screens/import_screen.dart](../lib/features/video_enhancement/presentation/screens/import_screen.dart) | 81 | ImportScreen |
| [lib/features/video_enhancement/presentation/screens/plan_screen.dart](../lib/features/video_enhancement/presentation/screens/plan_screen.dart) | 314 | PlanScreen |
| [lib/features/video_enhancement/presentation/screens/preview_screen.dart](../lib/features/video_enhancement/presentation/screens/preview_screen.dart) | 162 | PreviewScreen |
| [lib/features/video_enhancement/presentation/screens/processing_screen.dart](../lib/features/video_enhancement/presentation/screens/processing_screen.dart) | 122 | ProcessingScreen |
| [lib/features/video_enhancement/presentation/screens/result_screen.dart](../lib/features/video_enhancement/presentation/screens/result_screen.dart) | 228 | ResultScreen, _ResultScreenState |
| [lib/features/video_enhancement/presentation/widgets/split_comparison_widget.dart](../lib/features/video_enhancement/presentation/widgets/split_comparison_widget.dart) | 148 | SplitComparisonWidget, _SplitComparisonWidgetState, _SliderClipper |
| [lib/features/video_import/data/repositories/video_import_repository_impl.dart](../lib/features/video_import/data/repositories/video_import_repository_impl.dart) | 107 | VideoImportRepositoryImpl |
| [lib/features/video_import/domain/entities/video_file.dart](../lib/features/video_import/domain/entities/video_file.dart) | 43 | VideoFile |
| [lib/features/video_import/domain/providers/video_import_provider.dart](../lib/features/video_import/domain/providers/video_import_provider.dart) | 17 | videoImportRepositoryProvider, videoImportProvider |
| [lib/features/video_import/domain/repositories/video_import_repository.dart](../lib/features/video_import/domain/repositories/video_import_repository.dart) | 7 | VideoImportRepository |
| [lib/features/video_import/presentation/home_screen.dart](../lib/features/video_import/presentation/home_screen.dart) | 818 | HomeScreen, _HomeScreenState |
| [lib/features/video_import/presentation/widgets/feature_card.dart](../lib/features/video_import/presentation/widgets/feature_card.dart) | 122 | FeatureCard |
| [lib/features/video_import/presentation/widgets/import_button.dart](../lib/features/video_import/presentation/widgets/import_button.dart) | 40 | ImportButton |
| [lib/features/video_import/presentation/widgets/video_info_card.dart](../lib/features/video_import/presentation/widgets/video_info_card.dart) | 100 | VideoInfoCard |
| [lib/features/video_processing/data/repositories/video_processor_repository_impl.dart](../lib/features/video_processing/data/repositories/video_processor_repository_impl.dart) | 129 | VideoProcessorRepositoryImpl |
| [lib/features/video_processing/data/services/ffmpeg_cutting_service.dart](../lib/features/video_processing/data/services/ffmpeg_cutting_service.dart) | 322 | FfmpegCuttingService |
| [lib/features/video_processing/data/services/ffmpeg_smart_zoom_service.dart](../lib/features/video_processing/data/services/ffmpeg_smart_zoom_service.dart) | 20 | FfmpegSmartZoomService |
| [lib/features/video_processing/domain/entities/export_params.dart](../lib/features/video_processing/domain/entities/export_params.dart) | 19 | ExportParams |
| [lib/features/video_processing/domain/providers/processing_provider.dart](../lib/features/video_processing/domain/providers/processing_provider.dart) | 108 | ProcessingStateModel, ProcessingNotifier, videoProcessorRepositoryProvider, processingStateProvider |
| [lib/features/video_processing/domain/repositories/video_processor_repository.dart](../lib/features/video_processing/domain/repositories/video_processor_repository.dart) | 27 | VideoProcessorRepository |
| [lib/features/video_processing/presentation/processing_screen.dart](../lib/features/video_processing/presentation/processing_screen.dart) | 159 | ProcessingScreen |
| [lib/main.dart](../lib/main.dart) | 21 | — |
| [lib/shared/widgets/app_scaffold.dart](../lib/shared/widgets/app_scaffold.dart) | 42 | AppScaffold |
| [lib/shared/widgets/error_dialog.dart](../lib/shared/widgets/error_dialog.dart) | 62 | ErrorDialog |
| [lib/shared/widgets/loading_overlay.dart](../lib/shared/widgets/loading_overlay.dart) | 41 | LoadingOverlay |
| [lib/shared/widgets/permission_handler_widget.dart](../lib/shared/widgets/permission_handler_widget.dart) | 66 | PermissionHandlerWidget |
| [test/audio_enhancement_test.dart](../test/audio_enhancement_test.dart) | 61 | — |
| [test/audio_preview_command_test.dart](../test/audio_preview_command_test.dart) | 41 | — |
| [test/media_cutter_command_test.dart](../test/media_cutter_command_test.dart) | 1000 | — |
| [test/professional_audio_editor_service_test.dart](../test/professional_audio_editor_service_test.dart) | 75 | — |
| [test/video_download_service_test.dart](../test/video_download_service_test.dart) | 110 | — |
| [test/video_enhancement_command_test.dart](../test/video_enhancement_command_test.dart) | 36 | — |
| [test/video_import_metadata_test.dart](../test/video_import_metadata_test.dart) | 15 | — |
| [test/widget_test.dart](../test/widget_test.dart) | 11 | — |
