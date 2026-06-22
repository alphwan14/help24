// Parsed response of GET /disputes/:id/thread — the participant-scoped dispute
// conversation (metadata + messages + signed evidence + decisions). The backend
// is the source of truth; the app never stores dispute state, only renders it.

class DisputeThread {
  final String id;
  final String status;
  final String? priority;
  final String? reason;
  final String? createdAt;
  final String? firstResponseAt;
  final String? resolvedAt;
  final String? escalatedAt;
  final String postId;
  final String postTitle;
  final String viewerRole; // 'client' | 'provider'
  final String? assignedAdminName;
  final String? assignedAdminRole;
  final List<ThreadMessage> messages;
  final List<ThreadEvidence> evidence;
  final List<ThreadDecision> decisions;

  const DisputeThread({
    required this.id,
    required this.status,
    required this.priority,
    required this.reason,
    required this.createdAt,
    required this.firstResponseAt,
    required this.resolvedAt,
    required this.escalatedAt,
    required this.postId,
    required this.postTitle,
    required this.viewerRole,
    required this.assignedAdminName,
    required this.assignedAdminRole,
    required this.messages,
    required this.evidence,
    required this.decisions,
  });

  bool get isClient => viewerRole == 'client';
  bool get isProvider => viewerRole == 'provider';

  /// Terminal cases lock the composer.
  bool get isClosed =>
      status == 'resolved' ||
      status == 'escalated' ||
      status == 'merged' ||
      status == 'resolved_release' ||
      status == 'resolved_refund' ||
      status == 'resolved_partial';

  /// True when the admin is waiting on THIS viewer for evidence.
  bool get awaitingMyEvidence =>
      (status == 'awaiting_client_evidence' && isClient) ||
      (status == 'awaiting_provider_evidence' && isProvider);

  factory DisputeThread.fromJson(Map<String, dynamic> j) {
    final post = (j['post'] as Map<String, dynamic>?) ?? const {};
    final admin = j['assigned_admin'] as Map<String, dynamic>?;
    return DisputeThread(
      id: j['id'] as String? ?? '',
      status: j['status'] as String? ?? 'open',
      priority: j['priority'] as String?,
      reason: j['reason'] as String?,
      createdAt: j['created_at'] as String?,
      firstResponseAt: j['first_response_at'] as String?,
      resolvedAt: j['resolved_at'] as String?,
      escalatedAt: j['escalated_at'] as String?,
      postId: post['id'] as String? ?? '',
      postTitle: post['title'] as String? ?? 'Dispute',
      viewerRole: j['viewer_role'] as String? ?? 'client',
      assignedAdminName: admin?['name'] as String?,
      assignedAdminRole: admin?['role'] as String?,
      messages: ((j['messages'] as List<dynamic>?) ?? [])
          .map((e) => ThreadMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      evidence: ((j['evidence'] as List<dynamic>?) ?? [])
          .map((e) => ThreadEvidence.fromJson(e as Map<String, dynamic>))
          .toList(),
      decisions: ((j['decisions'] as List<dynamic>?) ?? [])
          .map((e) => ThreadDecision.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ThreadMessage {
  final String id;
  final String senderType; // client | provider | admin | system
  final String? senderId;
  final String message;
  final String kind; // text | evidence_request | evidence_submitted | system | resolution
  final String createdAt;

  const ThreadMessage({
    required this.id,
    required this.senderType,
    required this.senderId,
    required this.message,
    required this.kind,
    required this.createdAt,
  });

  bool get isSystem => senderType == 'system';
  bool get isAdmin => senderType == 'admin';
  bool get isEvidenceRequest => kind == 'evidence_request';

  factory ThreadMessage.fromJson(Map<String, dynamic> j) => ThreadMessage(
        id: j['id'] as String? ?? '',
        senderType: j['sender_type'] as String? ?? 'system',
        senderId: j['sender_id'] as String?,
        message: j['message'] as String? ?? '',
        kind: j['kind'] as String? ?? 'text',
        createdAt: j['created_at'] as String? ?? '',
      );
}

class ThreadEvidence {
  final String id;
  final String type; // image | document | text | system_chat | video
  final String uploaderType; // client | provider | admin | system
  final String? fileUrl; // short-TTL signed URL
  final String? content;
  final String? fileName;
  final String? mimeType;
  final int? sizeBytes;
  final String? reviewedAt;
  final String createdAt;

  const ThreadEvidence({
    required this.id,
    required this.type,
    required this.uploaderType,
    required this.fileUrl,
    required this.content,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.reviewedAt,
    required this.createdAt,
  });

  bool get isImage => type == 'image' && fileUrl != null;
  bool get isFile => (type == 'image' || type == 'document' || type == 'video') && fileUrl != null;
  bool get reviewed => reviewedAt != null;

  factory ThreadEvidence.fromJson(Map<String, dynamic> j) => ThreadEvidence(
        id: j['id'] as String? ?? '',
        type: j['type'] as String? ?? 'text',
        uploaderType: j['uploader_type'] as String? ?? 'system',
        fileUrl: j['file_url'] as String?,
        content: j['content'] as String?,
        fileName: j['file_name'] as String?,
        mimeType: j['mime_type'] as String?,
        sizeBytes: (j['size_bytes'] as num?)?.toInt(),
        reviewedAt: j['reviewed_at'] as String?,
        createdAt: j['created_at'] as String? ?? '',
      );
}

class ThreadDecision {
  final String decisionType;
  final String? reasoning;
  final String createdAt;

  const ThreadDecision({
    required this.decisionType,
    required this.reasoning,
    required this.createdAt,
  });

  factory ThreadDecision.fromJson(Map<String, dynamic> j) => ThreadDecision(
        decisionType: j['decision_type'] as String? ?? '',
        reasoning: j['reasoning'] as String?,
        createdAt: j['created_at'] as String? ?? '',
      );
}
