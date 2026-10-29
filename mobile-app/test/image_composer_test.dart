import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/screens/image_composer_screen.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  // Found on device 2026-10-29: uiautomator reported the composer's send
  // button as a nameless Button (NAF) — TalkBack said only "Button" on the one
  // control this screen exists for.
  testWidgets('the send button is named for a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    final dir = Directory.systemTemp.createTempSync('composer_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final photo = File('${dir.path}/a.png')..writeAsBytesSync(const [0x89, 0x50, 0x4e, 0x47]);

    await tester.pumpWidget(MaterialApp(
      home: ImageComposerScreen(initialFiles: [XFile(photo.path)], partnerName: 'Joseph'),
    ));
    await tester.pump();

    expect(find.bySemanticsLabel('Send'), findsOneWidget);
    handle.dispose();
  });
}
