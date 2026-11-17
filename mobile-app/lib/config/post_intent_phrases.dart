// THE PHRASES THAT SAY WHICH KIND OF POST SOMETHING IS.
//
// The composer reads a title and description and, when the words sound like
// the OTHER kind of post, offers a one-tap switch: "This sounds like you're
// offering a service. Post as an offer?". It never blocks posting.
//
// The example that started it: "Edger here anyone in need of plumber" went
// up as a Request. "anyone in need of" is how a provider advertises.
//
// ── Two strengths ────────────────────────────────────────────────────────
// A PHRASE says what the person is doing ("we offer", "natafuta") and counts
// 2. A HINT is a word both kinds use, that only leans one way ("fundi wa" is
// in "Mimi ni fundi wa stima" and in "Natafuta fundi wa stima") and counts 1.
// So "Natafuta fundi wa fridge" is a request (2 against 1), while "Fundi wa
// stima, niko na experience" is an offer (two hints, nothing against).
//
// ── Editing these lists ──────────────────────────────────────────────────
// * Write phrases in lower case, the way people type them. Punctuation and
//   apostrophes are ignored on both sides, so "i'm a" also matches "Im a"
//   and "I'm a,".
// * A phrase matches whole words only: "natafuta" does not match inside
//   "tunatafuta" (that one is listed separately).
// * The LONGER phrase wins where two overlap. That is how "natafuta kazi"
//   (looking for work: a provider) beats "natafuta" (looking for: a client),
//   and "anyone in need of" beats "in need of". When a short word means the
//   opposite inside a longer phrase, add the longer phrase to the other list.
// * A post is nudged only when the other side scores strictly more. A tie
//   says nothing, so a stray "available" in a request is harmless.
// * Not sure which strength? Make it a hint.
// * Tests: test/post_intent_test.dart. Add a line there for every phrase
//   that fixes a real post.

/// Someone advertising their own work. Counts 2.
const List<String> kOfferPhrases = [
  // English
  'i am a',
  'i am an',
  "i'm a",
  "i'm an",
  'am a',
  'anyone in need of',
  'anyone who needs',
  'anyone looking for',
  'if you need',
  'do you need',
  'we offer',
  'i offer',
  'we provide',
  'i provide',
  'we repair',
  'i repair',
  'we fix',
  'i fix',
  'call me',
  'call us',
  'contact me',
  'contact us',
  'hire me',
  'book me',
  'dm me',
  'inbox me',
  'at your service',
  'looking for work',
  'looking for a job',
  'looking for jobs',
  'looking for clients',
  'looking for customers',
  'seeking work',
  'seeking clients',
  'need work',
  'i need work',
  'need a job',
  'i need a job',
  // Kiswahili and Sheng
  'mimi ni fundi',
  'tunatoa',
  'natoa',
  'tunafanya',
  'nafanya',
  'tunauza',
  'nauza',
  'napatikana',
  'tunapatikana',
  'nipigie',
  'tupigie',
  'kama unahitaji',
  'kama uko na',
  'uko na shida',
  'una shida ya',
  'natafuta kazi',
  'tunatafuta kazi',
  'natafuta wateja',
  'tunatafuta wateja',
  'nahitaji kazi',
  'natafuta job',
];

/// Leans towards an offer, but requests use it too. Counts 1.
const List<String> kOfferHints = [
  'available',
  'now available',
  'services available',
  'offering',
  'years of experience',
  'affordable rates',
  'fundi wa',
  'ni fundi',
  'niko na',
  'tuko na',
  'huduma za',
];

/// Someone asking for help. Counts 2.
const List<String> kRequestPhrases = [
  // English
  'looking for',
  'i am looking for',
  "i'm looking for",
  'need someone',
  'i need',
  'we need',
  'who can',
  'anyone who can',
  'can someone',
  'can anyone',
  'is there anyone',
  'i want',
  'we want',
  'searching for',
  'seeking',
  'wanted',
  'needed',
  'where can i get',
  'where can i find',
  // Kiswahili and Sheng
  'natafuta',
  'ninatafuta',
  'tunatafuta',
  'nahitaji',
  'ninahitaji',
  'tunahitaji',
  'nataka',
  'tunataka',
  'nisaidie',
  'nisaidieni',
  'kuna fundi',
  'kuna mtu',
  'nani anaweza',
  'naeza pata',
  'naweza pata',
  'nitapata wapi',
  'anahitajika',
  'inahitajika',
  'wanahitajika',
];

/// Leans towards a request, but offers use it too. Counts 1.
const List<String> kRequestHints = [
  'need a',
  'need an',
  'in need of',
  'help me',
  'required',
  'recommend a',
  'naomba',
  'imeharibika',
  'imeharibikiwa',
];
