import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_video_editing/app.dart';
import 'package:ai_video_editing/core/constants/app_constants.dart';

void main() {
  testWidgets('App renders without error', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: SilenceRemoverApp()));
    expect(find.byType(MaterialApp), findsOneWidget);
    await tester.pump(AppConstants.splashDuration);
    await tester.pump();
  });
}
