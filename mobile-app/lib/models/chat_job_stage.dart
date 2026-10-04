import 'package:flutter/foundation.dart';

import '../utils/format_utils.dart';
import 'job_lifecycle.dart';

// =============================================================================
// THE PINNED JOB BAR'S STAGE — derived, never stored.
//
// Every stage is read off fields the app already has: the post (title, price,
// author, selected provider, applications) and the participant-scoped
// lifecycle aggregate (`GET /jobs/:postId/lifecycle`), whose `settlement.state`
// is the server's one money-truth. Arrival is the only stage that comes from
// the thread itself — the journey that ended "Arrived", or the arrival notice.
//
// Two places where the approved copy and the backend disagree, resolved toward
// the backend (a button that cannot succeed is worse than a quieter one):
//   • "Pay with M-Pesa or Airtel Money": the app and server only take M-Pesa,
//     so the bar says "Pay with M-Pesa".
//   • The customer's "Mark complete" is the server's APPROVE, which requires
//     the provider to have marked the job done first (`jobs.service approve`
//     → getPendingCompletion). Until then the customer's button is Details.
//
// A stage that cannot be derived — the lifecycle has not loaded, the person in
// this chat is not the one selected, the server reports something unexpected
// — falls back to the title, the price and View. Nothing is guessed.
// =============================================================================

enum ChatJobStage {
  offerIn,
  priceAgreed,
  held,
  arrived,
  completionPending,
  payoutProcessing,
  released,
  refunded,
  disputed,
  attention,
  unknown,
}

/// What the trailing button does. The screen maps each to its route.
enum ChatJobAction { review, pay, details, imArrived, markComplete, approve, rate, view }

/// The leading tile's icon and tint family.
enum ChatJobTile { job, money, lock, tool, check, alert }

/// The status line's colour role.
enum ChatJobTone { neutral, success, danger }

/// One of the four progress segments: Agreed, Held, In progress, Released.
enum ChatJobSegment { done, current, track, danger }

/// One application on the post, as the bar needs it.
@immutable
class ChatJobOffer {
  const ChatJobOffer({required this.applicantId, required this.price, required this.at, this.message = ''});

  final String applicantId;
  final double price;
  final DateTime at;
  final String message;
}

@immutable
class ChatJobInputs {
  const ChatJobInputs({
    required this.viewerId,
    required this.partnerId,
    required this.partnerName,
    required this.title,
    required this.price,
    required this.authorId,
    required this.selectedProviderId,
    this.offers = const [],
    this.lifecycle,
    this.arrivedAt,
    this.arrivalClock,
  });

  final String viewerId;
  final String partnerId;
  final String partnerName;
  final String title;
  final double price;
  final String authorId;
  final String? selectedProviderId;
  final List<ChatJobOffer> offers;

  /// Null until loaded, or when the viewer may not read it.
  final JobLifecycle? lifecycle;

  /// When the provider arrived, from the thread.
  final DateTime? arrivedAt;

  /// [arrivedAt] as the device shows a clock ("11:27 AM").
  final String? arrivalClock;
}

@immutable
class ChatJobBarState {
  const ChatJobBarState({
    required this.stage,
    required this.title,
    required this.status,
    required this.tone,
    required this.tile,
    required this.action,
    required this.actionLabel,
    required this.primary,
    required this.segments,
    required this.stageLabel,
  });

  final ChatJobStage stage;

  /// The job's title — always the first line.
  final String title;

  /// The stage, in one line.
  final String status;
  final ChatJobTone tone;
  final ChatJobTile tile;
  final ChatJobAction action;
  final String actionLabel;

  /// Accent-filled (the next step) rather than a quiet surface button.
  final bool primary;
  final List<ChatJobSegment> segments;

  /// For assistive tech: "Stage 2 of 4: held by Help24".
  final String stageLabel;
}


List<ChatJobSegment> _progress(int doneCount, {int? current, int? danger}) => [
      for (var i = 0; i < 4; i++)
        if (i == danger)
          ChatJobSegment.danger
        else if (i < doneCount)
          ChatJobSegment.done
        else if (i == current)
          ChatJobSegment.current
        else
          ChatJobSegment.track,
    ];


ChatJobBarState _state({
  required ChatJobStage stage,
  required ChatJobInputs i,
  required String status,
  required ChatJobTile tile,
  required ChatJobAction action,
  required String actionLabel,
  required bool primary,
  required List<ChatJobSegment> segments,
  required String stageLabel,
  ChatJobTone tone = ChatJobTone.neutral,
}) =>
    ChatJobBarState(
      stage: stage,
      title: i.title.trim(),
      status: status,
      tone: tone,
      tile: tile,
      action: action,
      actionLabel: actionLabel,
      primary: primary,
      segments: segments,
      stageLabel: stageLabel,
    );

ChatJobBarState _fallback(ChatJobInputs i) => _state(
      stage: ChatJobStage.unknown,
      i: i,
      status: i.price > 0 ? formatPriceDisplay(i.price) : 'Job details',
      tile: ChatJobTile.job,
      action: ChatJobAction.view,
      actionLabel: 'View',
      primary: false,
      segments: _progress(0),
      stageLabel: 'No job agreed yet',
    );

/// THE BAR FOR THIS VIEWER, NOW.
ChatJobBarState deriveChatJobBar(ChatJobInputs i) {
  final partner = i.partnerName.trim().isEmpty ? 'They' : i.partnerName.trim();
  final isClient = i.viewerId.isNotEmpty && i.viewerId == i.authorId;
  final selected = (i.selectedProviderId ?? '').trim();

  // ── Nobody selected yet: an offer may be on the table ──────────────────
  if (selected.isEmpty) {
    final mine = isClient ? i.partnerId : i.viewerId;
    final offers = i.offers.where((o) => o.applicantId == mine).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (offers.isEmpty) return _fallback(i);
    final offer = offers.last;
    final amount = formatPriceDisplay(offer.price > 0 ? offer.price : i.price);
    return _state(
      stage: ChatJobStage.offerIn,
      i: i,
      status: isClient ? '$partner offered $amount' : 'You offered $amount',
      tile: ChatJobTile.money,
      action: isClient ? ChatJobAction.review : ChatJobAction.view,
      actionLabel: isClient ? 'Review' : 'View',
      primary: isClient,
      segments: _progress(0, current: 0),
      stageLabel: 'Offer made, price not agreed yet',
    );
  }

  // ── Someone is selected: is it the person in THIS chat? ─────────────────
  final isProvider = i.viewerId == selected;
  final pairIsTheJob = (isClient && i.partnerId == selected) || (isProvider && i.partnerId == i.authorId);
  if (!pairIsTheJob) return _fallback(i);

  final lc = i.lifecycle;
  if (lc == null) return _fallback(i);

  final paid = lc.payment?.amount;
  final money = formatPriceDisplay(paid != null && paid > 0 ? paid : i.price);
  final state = lc.settlement?.state ?? 'no_payment';

  switch (state) {
    case 'no_payment':
    case 'awaiting_payment':
      return _state(
        stage: ChatJobStage.priceAgreed,
        i: i,
        status: isClient ? '$money · Pay with M-Pesa' : 'Waiting for $partner to pay $money',
        tile: ChatJobTile.money,
        action: isClient ? ChatJobAction.pay : ChatJobAction.details,
        actionLabel: isClient ? 'Pay' : 'Details',
        primary: isClient,
        segments: _progress(1, current: 1),
        stageLabel: 'Stage 1 of 4: price agreed, payment due',
      );

    case 'in_escrow':
      if (lc.completion?.status == 'pending_approval') {
        return _state(
          stage: ChatJobStage.completionPending,
          i: i,
          status: isClient ? '$partner marked it complete' : 'Waiting for $partner to confirm',
          tile: ChatJobTile.tool,
          action: isClient ? ChatJobAction.approve : ChatJobAction.details,
          actionLabel: isClient ? 'Mark complete' : 'Details',
          primary: isClient,
          segments: _progress(2, current: 2),
          stageLabel: 'Stage 3 of 4: in progress, waiting for approval',
        );
      }
      if (i.arrivedAt != null) {
        final at = i.arrivalClock == null ? '' : ' at ${i.arrivalClock}';
        return _state(
          stage: ChatJobStage.arrived,
          i: i,
          status: isClient ? '$partner arrived$at' : 'You arrived$at',
          tile: ChatJobTile.tool,
          action: isClient ? ChatJobAction.details : ChatJobAction.markComplete,
          actionLabel: isClient ? 'Details' : 'Mark complete',
          primary: !isClient,
          segments: _progress(2, current: 2),
          stageLabel: 'Stage 3 of 4: in progress',
        );
      }
      return _state(
        stage: ChatJobStage.held,
        i: i,
        status: '$money held by Help24',
        tone: ChatJobTone.success,
        tile: ChatJobTile.lock,
        action: isClient ? ChatJobAction.details : ChatJobAction.imArrived,
        actionLabel: isClient ? 'Details' : "I've arrived",
        primary: !isClient,
        segments: _progress(2),
        stageLabel: 'Stage 2 of 4: payment held by Help24',
      );

    case 'payout_processing':
      // Dispatched, not confirmed. Never "released" until the server says so.
      return _state(
        stage: ChatJobStage.payoutProcessing,
        i: i,
        status: isClient ? 'Releasing $money to $partner' : '$money on its way to you',
        tile: ChatJobTile.check,
        action: ChatJobAction.details,
        actionLabel: 'Details',
        primary: false,
        segments: _progress(3, current: 3),
        stageLabel: 'Stage 4 of 4: payment being released',
      );

    case 'released':
    case 'split_settled':
      final split = state == 'split_settled';
      return _state(
        stage: ChatJobStage.released,
        i: i,
        status: split
            ? (lc.settlement?.label.isNotEmpty == true ? lc.settlement!.label : 'Settled by Help24')
            : (isClient ? '$money released to $partner' : '$money released to you'),
        tone: ChatJobTone.success,
        tile: ChatJobTile.check,
        action: isClient ? ChatJobAction.rate : ChatJobAction.details,
        actionLabel: isClient ? 'Rate' : 'Details',
        primary: false,
        segments: _progress(4),
        stageLabel: 'Stage 4 of 4: payment released',
      );

    case 'refunded':
      return _state(
        stage: ChatJobStage.refunded,
        i: i,
        status: isClient ? '$money refunded to you' : '$money refunded to $partner',
        tile: ChatJobTile.money,
        action: ChatJobAction.details,
        actionLabel: 'Details',
        primary: false,
        segments: _progress(2),
        stageLabel: 'Payment refunded',
      );

    case 'disputed':
      return _state(
        stage: ChatJobStage.disputed,
        i: i,
        status: 'Payment on hold: dispute open',
        tone: ChatJobTone.danger,
        tile: ChatJobTile.alert,
        action: ChatJobAction.view,
        actionLabel: 'View',
        primary: false,
        segments: _progress(2, danger: 2),
        stageLabel: 'Payment on hold while a dispute is open',
      );

    case 'settlement_failed':
    case 'inconsistent':
      final label = lc.settlement?.label ?? '';
      return _state(
        stage: ChatJobStage.attention,
        i: i,
        status: label.isNotEmpty ? label : 'Payment needs attention',
        tone: ChatJobTone.danger,
        tile: ChatJobTile.alert,
        action: ChatJobAction.details,
        actionLabel: 'Details',
        primary: false,
        segments: _progress(2, current: 2),
        stageLabel: 'Payment needs attention',
      );

    default:
      return _fallback(i);
  }
}
