/// Help24 shows no em dashes anywhere in its interface (owner decision,
/// 2026-11-08). The app's own strings are written without them, and a test
/// (`test/plain_copy_test.dart`) keeps it that way.
///
/// Text written by the SERVER can still contain them: notification titles
/// and bodies, error messages, moderation reasons. The backend is frozen, so
/// the app rewrites that text as it displays it. A dash between two clauses
/// becomes a sentence break ("Job completed — payment released" reads
/// "Job completed. Payment released"), and a dash with nothing after it is
/// dropped.
///
/// Never apply this to text a MEMBER wrote (posts, chats, bios, reviews,
/// dispute messages). That is their wording, not ours.
String plainCopy(String text) {
  if (!text.contains('—')) return text;
  final out = text
      .replaceAllMapped(
        RegExp(r'\s*—\s*(\S)'),
        (m) => '. ${m.group(1)!.toUpperCase()}',
      )
      .replaceAll('—', '')
      .replaceAll(RegExp(r'\.\s*\.'), '.')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  return out;
}
