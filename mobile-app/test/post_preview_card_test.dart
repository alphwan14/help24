import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/theme/app_icons.dart';
import 'package:help24/theme/tokens.dart';
import 'package:help24/widgets/post_preview_card.dart';

/// "PREVIEW YOUR POST" — EVERYTHING STAYS INSIDE THE CARD.
///
/// The card carried the capsule radius, and a tall card drawn with it is an
/// oval: on a Galaxy S20+ the category icon sat on the curve and the
/// "Flexible" chip hung half outside the card. These tests assert containment
/// against the card's REAL rounded outline — every corner of every piece of
/// content must lie inside the rounded rectangle, not merely inside its
/// bounding box — for the realistic spread of what a post can hold.

const _phones = <String, Size>{
  // Logical sizes: Galaxy S20+ at its 1080×2400 setting, Galaxy A21s, and a
  // narrow 320 dp device as the worst case.
  'S20+': Size(384, 853),
  'A21s': Size(360, 800),
  'narrow': Size(320, 640),
};

const _longTitle =
    'I need a plumber to replace my bathroom fittings, fix the leaking kitchen '
    'sink and check the water pressure across the whole house before Friday';
const _longDescription =
    'Professional home and office cleaning services — deep cleaning, carpet '
    'shampooing, window washing and post-construction clean-up. We bring our '
    'own equipment and eco-friendly products, and we work weekends. Twelve '
    'years of experience across Mombasa, Kilifi and Kwale.';

PostPreviewCard _card({
  String title = 'Plumber needed',
  String description = '',
  String? category = 'Plumbing',
  List<PreviewTag> tags = const [],
  List<String> attributes = const [],
  bool media = false,
  String typeLabel = 'Request',
}) =>
    PostPreviewCard(
      media: media
          ? const SizedBox(
              height: 160,
              width: double.infinity,
              child: ColoredBox(color: Colors.teal),
            )
          : null,
      icon: AppIcons.category,
      typeLabel: typeLabel,
      typeColor: Colors.blue,
      categoryName: category,
      title: title,
      description: description,
      tags: tags,
      attributes: attributes,
    );

const _flexible = PreviewTag(text: 'Flexible', accent: Colors.green);
const _openBudget = PreviewTag(icon: AppIcons.price, text: 'Budget · Open to offers');
const _mombasa = PreviewTag(icon: AppIcons.location, text: 'Mombasa');

/// Every variation the posting flow can produce, from minimal to maximal.
final Map<String, PostPreviewCard> _variations = {
  'A short title': _card(tags: const [_openBudget, _flexible]),
  'B very long title': _card(title: _longTitle, tags: const [_mombasa, _openBudget, _flexible]),
  'C short description': _card(description: 'Kitchen sink leaks.', tags: const [_mombasa, _flexible]),
  'D long multi-line description': _card(description: _longDescription, tags: const [_mombasa]),
  'E request with price': _card(
      tags: const [_mombasa, PreviewTag(icon: AppIcons.price, text: 'Budget · KES 1,200'), _flexible]),
  'F request, open to offers': _card(tags: const [_mombasa, _openBudget, _flexible]),
  'G request with location': _card(
      tags: const [PreviewTag(icon: AppIcons.location, text: 'Nyali, Mombasa'), _openBudget, _flexible]),
  'H request without location': _card(tags: const [_openBudget, _flexible]),
  'I other category, offer': _card(
      typeLabel: 'Offer',
      category: 'House Cleaning',
      description: _longDescription,
      tags: const [
        _mombasa,
        PreviewTag(icon: AppIcons.price, text: 'From KES 500 · Per task'),
        PreviewTag(icon: AppIcons.pending, text: 'By appointment'),
      ]),
  'I long custom category': _card(
      category: 'Commercial kitchen extraction hood and duct deep-cleaning specialists',
      tags: const [_flexible]),
  'J minimal post data': _card(title: 'Help', category: null),
  'K maximum realistic data': _card(
      media: true,
      title: _longTitle,
      description: _longDescription,
      category: 'Plumbing',
      tags: const [
        PreviewTag(
            icon: AppIcons.location,
            text: 'Mtwapa Gardens Estate, off Mombasa–Malindi Road, Kilifi County, Coast'),
        PreviewTag(icon: AppIcons.price, text: 'Budget · KES 1,250,000'),
        PreviewTag(text: 'Emergency — needed right now', accent: Colors.red),
      ],
      attributes: const [
        'Fixtures: toilet, shower, basin',
        'Water source: county supply and borehole',
        'Access: third floor, no lift',
      ]),
};

Future<void> _pump(WidgetTester tester, Size size, Widget card) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: card,
      ),
    ),
  ));
}

/// The corners of every visible leaf — text, icons, and each tag capsule.
List<(String, Rect)> _contentRects(WidgetTester tester) {
  final card = find.byType(PostPreviewCard);
  final rects = <(String, Rect)>[];
  for (final e in find.descendant(of: card, matching: find.byType(Text)).evaluate()) {
    rects.add(('text "${(e.widget as Text).data}"', tester.getRect(find.byWidget(e.widget))));
  }
  for (final e in find.descendant(of: card, matching: find.byType(Icon)).evaluate()) {
    rects.add(('icon', tester.getRect(find.byWidget(e.widget))));
  }
  // The tag capsules themselves, not just their text: a capsule half outside
  // the card was the reported defect.
  for (final e in find
      .descendant(of: card, matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TagChip'))
      .evaluate()) {
    rects.add(('tag', tester.getRect(find.byWidget(e.widget))));
  }
  return rects;
}

/// Content that does not fit inside [outline], as readable failures.
List<String> _escapes(RRect outline, List<(String, Rect)> content) => [
      for (final (label, r) in content)
        for (final corner in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight])
          // Half-pixel tolerance: an edge sitting exactly on the outline is in.
          if (!outline.inflate(0.5).contains(corner)) '$label at $corner',
    ];

void main() {
  for (final phone in _phones.entries) {
    group('on ${phone.key} (${phone.value.width.toInt()} dp wide)', () {
      for (final v in _variations.entries) {
        testWidgets('${v.key}: lays out and keeps every element inside the card',
            (tester) async {
          await _pump(tester, phone.value, v.value);

          // A RenderFlex overflow (the old category row) surfaces here.
          expect(tester.takeException(), isNull, reason: 'layout overflowed');

          final card = tester.getRect(find.byType(PostPreviewCard));
          final outline = RRect.fromRectAndRadius(card, const Radius.circular(AppRadius.lg));
          final content = _contentRects(tester);
          expect(content, isNotEmpty);
          expect(_escapes(outline, content), isEmpty,
              reason: 'content escaped the card outline');
          expect(card.right, lessThanOrEqualTo(phone.value.width - 24 + 0.5),
              reason: 'card wider than the screen');
        });
      }
    });
  }

  testWidgets('the containment check has teeth: the old oval fails it', (tester) async {
    // The same content inside the outline the card USED to draw — the
    // capsule radius, which Flutter scales to half the shorter side.
    await _pump(tester, _phones['S20+']!, _variations['F request, open to offers']!);
    final card = tester.getRect(find.byType(PostPreviewCard));
    final oval = RRect.fromRectAndRadius(card, Radius.circular(card.shortestSide / 2));
    expect(_escapes(oval, _contentRects(tester)), isNotEmpty,
        reason: 'if the old geometry passed, this test would prove nothing');
  });

  testWidgets('the card is a card: card radius, and it clips its content', (tester) async {
    await _pump(tester, _phones['S20+']!, _variations['K maximum realistic data']!);
    final container = tester.widget<Container>(find
        .descendant(of: find.byType(PostPreviewCard), matching: find.byType(Container))
        .first);
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, AppRadius.lgAll);
    expect(decoration.borderRadius, isNot(AppRadius.pillAll));
    expect(container.clipBehavior, isNot(Clip.none),
        reason: 'a photo header must follow the card corners');
    expect((container.foregroundDecoration! as BoxDecoration).border, isNotNull,
        reason: 'the hairline is painted over the content so a photo cannot hide it');
  });

  testWidgets('tags never wrap onto a second line', (tester) async {
    await _pump(tester, _phones['narrow']!, _variations['K maximum realistic data']!);
    final tagTexts = find.descendant(
      of: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TagChip'),
      matching: find.byType(Text),
    );
    expect(tagTexts, findsWidgets);
    for (final e in tagTexts.evaluate()) {
      expect((e.widget as Text).maxLines, 1);
      final height = tester.getSize(find.byWidget(e.widget)).height;
      expect(height, lessThan(20), reason: 'a two-line capsule is a small oval');
    }
  });

  testWidgets('optional parts take no space when absent', (tester) async {
    await _pump(tester, _phones['S20+']!, _variations['J minimal post data']!);
    // No description line, no category label, no tag row.
    expect(find.text('Help'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TagChip'), findsNothing);
    final texts = find.descendant(of: find.byType(PostPreviewCard), matching: find.byType(Text));
    expect(texts, findsNWidgets(2), reason: 'the type badge and the title, nothing blank');
  });

  test('the post screen uses the shared card, never the capsule radius', () {
    final src = File('lib/screens/post_screen.dart').readAsStringSync();
    expect(src.contains('PostPreviewCard('), isTrue);
    final widget = File('lib/widgets/post_preview_card.dart').readAsStringSync();
    expect(widget.contains('static const BorderRadius radius = AppRadius.lgAll;'), isTrue);
  });
}
