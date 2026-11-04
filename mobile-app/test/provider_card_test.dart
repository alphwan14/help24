import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/provider_reputation.dart';
import 'package:help24/screens/provider/provider_card_screen.dart';
import 'package:help24/services/agent_code_service.dart';
import 'package:help24/services/provider_card_link.dart';

ProviderReputation _rep({String tier = 'new_provider', int reviews = 0, double rating = 0, int jobs = 0}) =>
    ProviderReputation.fromJson({
      'provider_id': 'abc',
      'average_rating': rating,
      'bayesian_rating': rating,
      'total_reviews': reviews,
      'completed_jobs': jobs,
      'tier': tier,
    });

void main() {
  const uid = 'Xb3k9QmT2vLp8sR4nY6wZ1aC5dE7';

  group('ProviderCardLink', () {
    test('the card link and its QR form round-trip to the uid', () {
      expect(ProviderCardLink.url(uid), 'https://help24.co.ke/p/$uid');
      expect(ProviderCardLink.parse(ProviderCardLink.url(uid)), uid);
      expect(ProviderCardLink.parse(ProviderCardLink.qrUrl(uid)), uid);
      expect(ProviderCardLink.parse('https://www.help24.co.ke/p/$uid'), uid);
    });

    test('anything that is not a card link is refused', () {
      expect(ProviderCardLink.parse('http://help24.co.ke/p/$uid'), isNull);
      expect(ProviderCardLink.parse('https://evil.example/p/$uid'), isNull);
      expect(ProviderCardLink.parse('https://help24.co.ke/a/H24-7K3Q'), isNull);
      expect(ProviderCardLink.parse('https://help24.co.ke/p/'), isNull);
      expect(ProviderCardLink.parse('https://help24.co.ke/p/short'), isNull);
      expect(ProviderCardLink.parse('https://help24.co.ke/p/$uid/extra'), isNull);
      expect(ProviderCardLink.parse('https://help24.co.ke/p/abc%27%3Bdrop'), isNull);
    });

    test('agent links and card links never claim each other', () {
      expect(AgentCodeService.parseLink(ProviderCardLink.qrUrl(uid)), isNull);
      expect(ProviderCardLink.parse('https://help24.co.ke/a/H24-7K3Q?src=qr'), isNull);
    });
  });

  group('the record line says only what the profile says', () {
    test('no record read → no line, never a guess', () {
      expect(ProviderCard.recordLine(null), isNull);
    });

    test('a provider with no history is new, not zero', () {
      expect(ProviderCard.recordLine(_rep()), 'New on Help24');
    });

    test('reviews and jobs, in the public profile terms', () {
      expect(ProviderCard.recordLine(_rep(tier: 'top_rated', reviews: 12, rating: 4.84, jobs: 9)),
          '★ 4.8 (12) · 9 jobs done on Help24');
      expect(ProviderCard.recordLine(_rep(tier: 'rising_provider', jobs: 1)), '1 job done on Help24');
    });
  });

  testWidgets('the card paints a scannable code and promises nothing about money', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: ProviderCard(
            name: 'Amina Wanjiru',
            profession: 'Electrician',
            photoUrl: '',
            record: 'New on Help24',
            link: ProviderCardLink.qrUrl(uid),
          ),
        ),
      ),
    ));

    expect(find.text('Amina Wanjiru'), findsOneWidget);
    expect(find.text('Electrician'), findsOneWidget);
    expect(find.text('AW'), findsOneWidget);
    expect(find.text('Find me on Help24'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is QrPainter), findsOneWidget);

    // Phase A: payment protection is not live, so the card must not claim it.
    final words = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => (t.data ?? '').toLowerCase())
        .join(' ');
    for (final claim in ['pay', 'protect', 'escrow', 'secure', 'guarantee', 'safe']) {
      expect(words.contains(claim), isFalse, reason: 'the card says "$claim"');
    }
  });
}
