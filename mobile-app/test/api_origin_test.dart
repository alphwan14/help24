import 'package:flutter_test/flutter_test.dart';
import 'package:help24/config/api_config.dart';
import 'package:help24/config/app_urls.dart';

/// Guards the origin every API call in the app is built from.
///
/// WHY THIS SUITE EXISTS
/// ---------------------
/// `ApiConfig.baseUrl` has been wrong in production before, in the worst
/// possible way: it was pinned to a developer's LAN address, so every shipped
/// APK sent payments, payouts, chat notifications and routing to a machine no
/// user could reach. Nothing failed at build time and nothing said so at run
/// time — the app simply stopped being able to move money.
///
/// A hostname is exactly the kind of value that regresses quietly: it is one
/// string, it is edited during debugging, and a wrong value still compiles,
/// still type-checks and still looks plausible in review. So it gets a test.
///
/// These assertions are deliberately about SHAPE and OWNERSHIP, not about
/// reachability. A unit test must not depend on the network; whether the host
/// answers is proven separately by the deployment checks.
void main() {
  group('production API origin', () {
    test('is Help24\'s own domain, over TLS', () {
      expect(ApiConfig.productionOrigin, 'https://api.help24.co.ke');
    });

    test('a build with no dart-define ships the production origin', () {
      // This is the shipped case. `flutter test` supplies no
      // HELP24_API_BASE_URL, so baseUrl resolves to the same default a release
      // build gets when nobody passes a flag.
      expect(ApiConfig.baseUrl, ApiConfig.productionOrigin);
      expect(
        ApiConfig.isOverridden,
        isFalse,
        reason:
            'isOverridden must be false for a default build. If this fails, '
            'baseUrl and productionOrigin have drifted and the "pointed at a '
            'laptop" warning would fire on every release.',
      );
    });

    test('carries no hosting-vendor hostname', () {
      // The vendor origin still works and is not a secret — but it must not be
      // what the app dials, because it leaks the stack into the binary and it
      // cannot be repointed without a Play Store release.
      const vendorMarkers = ['onrender.com', 'vercel.app', 'firebaseapp.com'];
      for (final marker in vendorMarkers) {
        expect(
          ApiConfig.baseUrl.contains(marker),
          isFalse,
          reason: 'baseUrl must not contain "$marker"',
        );
      }
    });
  });

  group('every endpoint is derived from the one origin', () {
    // Named so a failure says WHICH endpoint drifted, rather than just "a
    // string did not match".
    const endpoints = <String, String>{
      'clientConfig': ApiConfig.clientConfig,
      'initiatePayment': ApiConfig.initiatePayment,
      'paymentStatus': ApiConfig.paymentStatus,
      'releasePayout': ApiConfig.releasePayout,
      'chatNotify': ApiConfig.chatNotify,
      'routesCompute': ApiConfig.routesCompute,
    };

    test('all sit under baseUrl', () {
      endpoints.forEach((name, url) {
        expect(
          url.startsWith('${ApiConfig.baseUrl}/'),
          isTrue,
          reason: '$name ($url) is not built from ApiConfig.baseUrl',
        );
      });
    });

    test('none hardcodes a vendor host', () {
      endpoints.forEach((name, url) {
        expect(url.contains('onrender.com'), isFalse, reason: name);
      });
    });

    test('all are https', () {
      endpoints.forEach((name, url) {
        expect(url.startsWith('https://'), isTrue, reason: name);
      });
    });
  });

  group('brand domains stay in one family', () {
    // The API origin and the user-visible site must remain the same
    // registrable domain. If they ever diverge, an auth email pointing at
    // help24.co.ke and an app calling something else is the first symptom.
    test('API origin is a help24.co.ke host', () {
      final api = Uri.parse(ApiConfig.productionOrigin);
      expect(api.host.endsWith('help24.co.ke'), isTrue);
      expect(api.scheme, 'https');
    });

    test('website and API share the registrable domain', () {
      final site = Uri.parse(AppUrls.website);
      final api = Uri.parse(ApiConfig.productionOrigin);
      expect(site.host, 'help24.co.ke');
      expect(api.host.endsWith(site.host), isTrue);
    });
  });
}
