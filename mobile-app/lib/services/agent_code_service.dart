import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_auth_bridge.dart';

/// How an agent code reached the app — recorded with the credit, because
/// agents are paid per member and marketing is measured per channel.
enum AgentCodeMethod { code, link, qr }

class AgentClaimResult {
  final bool ok;
  /// 'credited' (first agent), 'changed' (moved inside the 3-day window) or
  /// 'unchanged' (the same code again).
  final String? status;
  final String? agentName;
  final String? error;

  const AgentClaimResult._({required this.ok, this.status, this.agentName, this.error});
  const AgentClaimResult.success(String status, String? agentName)
      : this._(ok: true, status: status, agentName: agentName);
  const AgentClaimResult.failure(String error) : this._(ok: false, error: error);
}

class AgentCredit {
  final String? agentName;
  final String? code;
  final bool canChange;
  final DateTime? windowEndsAt;

  const AgentCredit({this.agentName, this.code, required this.canChange, this.windowEndsAt});

  bool get credited => agentName != null;
}

/// The one place the app touches agent codes (migration 127,
/// docs/partner-portal-plan.md).
///
/// A code arrives three ways — typed, or carried by an agent's link
/// (`https://help24.co.ke/a/H24-7K3Q`) or QR code (the same link with
/// `?src=qr`). A link can arrive BEFORE anyone is signed in (it is how many
/// people install the app), so it is kept as a PENDING code on disk and
/// claimed by [claimPending] once a session exists. The server decides
/// everything else — whether the code is real, whether it is the agent's
/// own, whether the 3-day window is still open.
class AgentCodeService {
  AgentCodeService._();

  static const MethodChannel _links = MethodChannel('com.help24.help24/links');
  static const _pendingCodeKey = 'help24_agent_code_pending_v1';
  static const _pendingMethodKey = 'help24_agent_code_method_v1';
  static const _promptDismissedKey = 'help24_agent_prompt_dismissed_v1';

  /// Fires when a link delivers a code while the app is running.
  static final StreamController<String> _arrived = StreamController<String>.broadcast();
  static Stream<String> get arrivals => _arrived.stream;

  static bool _listening = false;

  /// Start listening for agent links. Safe to call more than once.
  static Future<void> init() async {
    if (_listening) return;
    _listening = true;
    _links.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) await _receive(call.arguments as String);
    });
    try {
      final initial = await _links.invokeMethod<String>('initialLink');
      if (initial != null) await _receive(initial);
    } catch (e) {
      debugPrint('[AGENT] initial link unavailable: ${e.runtimeType}');
    }
  }

  /// `/a/<CODE>` on help24.co.ke → (code, method), or null for any other link.
  @visibleForTesting
  static ({String code, AgentCodeMethod method})? parseLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https') return null;
    if (uri.host != 'help24.co.ke' && uri.host != 'www.help24.co.ke') return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments[0] != 'a') return null;
    final code = normalize(segments[1]);
    if (code == null) return null;
    final qr = uri.queryParameters['src'] == 'qr';
    return (code: code, method: qr ? AgentCodeMethod.qr : AgentCodeMethod.link);
  }

  /// "h24 7k3q", "H24-7K3Q", "7k3q" → "H24-7K3Q"; null when it cannot be a code.
  static String? normalize(String input) {
    var raw = input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (raw.startsWith('H24')) raw = raw.substring(3);
    if (!RegExp(r'^[A-HJ-NP-Z2-9]{4,6}$').hasMatch(raw)) return null;
    return 'H24-$raw';
  }

  static Future<void> _receive(String link) async {
    final parsed = parseLink(link);
    if (parsed == null) return;
    debugPrint('[AGENT] link received method=${parsed.method.name}');
    await setPending(parsed.code, parsed.method);
    _arrived.add(parsed.code);
  }

  static Future<void> setPending(String code, AgentCodeMethod method) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingCodeKey, code);
      await prefs.setString(_pendingMethodKey, method.name);
    } catch (e) {
      debugPrint('[AGENT] could not keep the pending code: ${e.runtimeType}');
    }
  }

  static Future<({String code, AgentCodeMethod method})?> pending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_pendingCodeKey);
      if (code == null) return null;
      final method = AgentCodeMethod.values.firstWhere(
        (m) => m.name == prefs.getString(_pendingMethodKey),
        orElse: () => AgentCodeMethod.code,
      );
      return (code: code, method: method);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _clearPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingCodeKey);
      await prefs.remove(_pendingMethodKey);
    } catch (_) {}
  }

  /// Claim a pending code, if there is one. A refusal that cannot change by
  /// trying again (unknown code, own code, window closed) also clears it, so
  /// it is not retried — and reported — on every launch.
  static Future<AgentClaimResult?> claimPending() async {
    final p = await pending();
    if (p == null) return null;
    final result = await claim(p.code, p.method);
    if (result.ok || (result.error != _offline && result.error != _notYet)) await _clearPending();
    return result;
  }

  static const _offline = "We couldn't reach Help24 just now. We'll try again shortly.";
  static const _notYet = "Agent codes aren't available yet. Please try again later.";

  /// Credit [code] to the signed-in member.
  static Future<AgentClaimResult> claim(String code, AgentCodeMethod method) async {
    final normalized = normalize(code);
    if (normalized == null) {
      return const AgentClaimResult.failure('Agent codes look like H24-7K3Q. Check the code and try again.');
    }
    final signedIn = await SupabaseAuthBridge.ensureSessionForWriteAsync();
    if (!signedIn) return const AgentClaimResult.failure(_offline);
    try {
      final res = await Supabase.instance.client
          .rpc('claim_agent_code', params: {'p_code': normalized, 'p_method': method.name});
      final map = (res as Map).cast<String, dynamic>();
      debugPrint('[AGENT] claim status=${map['status']} method=${method.name}');
      return AgentClaimResult.success(map['status'] as String? ?? 'credited', map['agent_name'] as String?);
    } on PostgrestException catch (e) {
      debugPrint('[AGENT] claim refused code=${e.code}');
      return AgentClaimResult.failure(messageFor(e.code, e.message));
    } catch (e) {
      debugPrint('[AGENT] claim failed: ${e.runtimeType}');
      return const AgentClaimResult.failure(_offline);
    }
  }

  /// The member's own credit, or null when it cannot be read just now.
  static Future<AgentCredit?> myCredit() async {
    final signedIn = await SupabaseAuthBridge.ensureSessionForWriteAsync();
    if (!signedIn) return null;
    try {
      final res = await Supabase.instance.client.rpc('my_agent_credit');
      final map = (res as Map).cast<String, dynamic>();
      return AgentCredit(
        agentName: map['agent_name'] as String?,
        code: map['code'] as String?,
        canChange: map['can_change'] == true,
        windowEndsAt: DateTime.tryParse(map['window_ends_at']?.toString() ?? ''),
      );
    } catch (e) {
      debugPrint('[AGENT] credit unavailable: ${e.runtimeType}');
      return null;
    }
  }

  /// The words a member sees for a refusal. The server's HELP24_AGENT_*
  /// messages are already written for people; everything else is generic —
  /// the error mapper convention: never show a raw failure value.
  @visibleForTesting
  static String messageFor(String? code, String message) {
    if (code == 'PGRST202') return _notYet;
    final m = RegExp(r'HELP24_AGENT_[A-Z_]+:\s*(.+)$').firstMatch(message);
    if (m != null) {
      final text = m.group(1)!.trim();
      final sentence = text[0].toUpperCase() + text.substring(1);
      return sentence.endsWith('.') ? sentence : '$sentence.';
    }
    return "That code couldn't be added just now. Please try again.";
  }

  /// The one-time "Did someone help you join?" prompt — once per account.
  static Future<bool> promptDismissed(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_promptDismissedKey)?.contains(uid) ?? false;
    } catch (_) {
      return true; // when in doubt, do not interrupt
    }
  }

  static Future<void> dismissPrompt(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_promptDismissedKey) ?? <String>[];
      if (!list.contains(uid)) await prefs.setStringList(_promptDismissedKey, [...list, uid]);
    } catch (_) {}
  }
}
