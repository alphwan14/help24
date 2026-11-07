/**
 * Provider vetting (migration 135) — the vocabulary the backend, the admin
 * dashboard and the app share. The database is the authority for every rule;
 * this file only names things and words them for people.
 */

export const VERIFICATION_BUCKET = 'provider-verifications';

export type VerificationKind = 'id' | 'care';
export type VerificationStatus = 'pending' | 'approved' | 'rejected';
export type VerificationDocumentType = 'national_id' | 'passport' | 'alien_id' | 'certificate' | 'receipt';
export type ReviewDecision = 'approve' | 'reject';

export const DOCUMENT_LABELS: Readonly<Record<VerificationDocumentType, string>> = {
  national_id: 'National ID',
  passport: 'Passport',
  alien_id: 'Alien ID',
  certificate: 'Certificate of Good Conduct',
  receipt: 'eCitizen application receipt',
};

/** What each file in a submission is, in upload order (submit_provider_verification). */
export const FILE_ROLES: Readonly<Record<VerificationDocumentType, readonly string[]>> = {
  national_id: ['Front', 'Back', 'Selfie holding the ID'],
  alien_id: ['Front', 'Back', 'Selfie holding the ID'],
  passport: ['Photo page', 'Selfie holding the passport'],
  certificate: ['Certificate', 'Page 2', 'Page 3', 'Page 4'],
  receipt: ['Receipt', 'Page 2', 'Page 3', 'Page 4'],
};

/**
 * The reasons a reviewer picks from. Each is written to the provider, so it
 * says what to do next. A reviewer may also type their own.
 */
export const REJECTION_REASONS: readonly string[] = [
  'The photo is blurred or too dark to read. Please retake it in good light.',
  'Part of the document is cut off. Please show the whole card or page.',
  'The selfie does not clearly show your face together with the document.',
  'The name on the document does not match the name on your Help24 profile.',
  'The document has expired. Please send a valid one.',
  'This is not the document we asked for.',
  'We could not confirm the certificate is genuine. Please send the PDF from eCitizen.',
  'The receipt does not show a Certificate of Good Conduct application.',
];

/** Signed links for the reviewer live just long enough to look. */
export const SIGNED_URL_TTL_SECONDS = 5 * 60;

/** Documents are deleted this long after the decision (Data Protection Act 2019). */
export const FILE_RETENTION_DAYS = 30;

/** The review promise made to providers. */
export const REVIEW_TARGET_HOURS = 24;

/** The push and in-app notification for a decision. */
export function decisionNotice(row: {
  kind: VerificationKind;
  document_type: VerificationDocumentType;
  status: VerificationStatus;
  rejection_reason?: string | null;
  expires_at?: string | null;
}): { type: 'verification_approved' | 'verification_rejected'; title: string; body: string } {
  if (row.status === 'rejected') {
    const what = row.kind === 'id' ? 'ID' : DOCUMENT_LABELS[row.document_type];
    return {
      type: 'verification_rejected',
      title: `We could not verify your ${what}`,
      body: `${row.rejection_reason ?? 'Please send it again.'} Open Help24 to send it again.`,
    };
  }
  if (row.kind === 'id') {
    return {
      type: 'verification_approved',
      title: 'Your ID is verified',
      body: 'Your profile now shows "ID verified". You can offer and apply for work that needs an ID check.',
    };
  }
  if (row.document_type === 'receipt') {
    const until = row.expires_at ? kenyaDate(row.expires_at) : 'within 30 days';
    return {
      type: 'verification_approved',
      title: 'Receipt accepted — certificate pending',
      body: `Your care listings can go live, marked "Certificate pending". Upload your Certificate of Good Conduct by ${until} to apply for care jobs and be hired.`,
    };
  }
  return {
    type: 'verification_approved',
    title: 'Care check complete',
    body: 'Your profile now shows "Care checked". You can offer, apply for and be hired for care work.',
  };
}

export function kenyaDate(iso: string): string {
  return new Date(iso).toLocaleDateString('en-KE', {
    day: 'numeric', month: 'long', year: 'numeric', timeZone: 'Africa/Nairobi',
  });
}
