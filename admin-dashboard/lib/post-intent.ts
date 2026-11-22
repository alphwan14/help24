// Does a listing's own text read as a request or as an offer?
//
// The SAME check the app's composer runs before posting
// (mobile-app/lib/utils/post_intent.dart), here so the console can list the
// live listings whose words say the other kind ("Edger here anyone in need of
// plumber", posted as a Request) for an admin to reclassify.
//
// The phrase lists are a COPY of mobile-app/lib/config/post_intent_phrases.dart,
// in the same order. Edit that file first, then this one: lib/post-intent.test.mjs
// reads the Dart file and fails if the two lists differ.
//
// How it reads: anywhere in the title and description together, any case,
// punctuation ignored, by WHOLE WORDS ("am a" must not fire inside "Kama").
// A phrase counts 2, a hint 1; where two overlap the longer one claims the
// words; the other kind must score strictly more, so a tie says nothing.

export type IntentKind = "request" | "offer";

/** Someone advertising their own work. Counts 2. */
export const OFFER_PHRASES = [
  "i am a",
  "i am an",
  "i'm a",
  "i'm an",
  "am a",
  "am an",
  "iam a",
  "iam an",
  "anyone in need of",
  "anyone who needs",
  "anyone looking for",
  "if you need",
  "do you need",
  "we offer",
  "i offer",
  "we provide",
  "i provide",
  "we repair",
  "i repair",
  "we fix",
  "i fix",
  "call me",
  "call us",
  "contact me",
  "contact us",
  "hire me",
  "book me",
  "dm me",
  "inbox me",
  "at your service",
  "looking for work",
  "looking for a job",
  "looking for jobs",
  "looking for clients",
  "looking for customers",
  "seeking work",
  "seeking clients",
  "need work",
  "i need work",
  "need a job",
  "i need a job",
  "mimi ni fundi",
  "tunatoa",
  "natoa",
  "tunafanya",
  "nafanya",
  "tunauza",
  "nauza",
  "napatikana",
  "tunapatikana",
  "nipigie",
  "tupigie",
  "kama unahitaji",
  "kama uko na",
  "uko na shida",
  "una shida ya",
  "natafuta kazi",
  "tunatafuta kazi",
  "natafuta wateja",
  "tunatafuta wateja",
  "nahitaji kazi",
  "natafuta job",
] as const;

/** Leans towards an offer, but requests use it too. Counts 1. */
export const OFFER_HINTS = [
  "available",
  "now available",
  "services available",
  "offering",
  "years of experience",
  "affordable rates",
  "fundi wa",
  "ni fundi",
  "niko na",
  "tuko na",
  "huduma za",
] as const;

/** Someone asking for help. Counts 2. */
export const REQUEST_PHRASES = [
  "looking for",
  "i am looking for",
  "i'm looking for",
  "need someone",
  "i need",
  "we need",
  "who can",
  "anyone who can",
  "can someone",
  "can anyone",
  "is there anyone",
  "i want",
  "we want",
  "searching for",
  "seeking",
  "wanted",
  "needed",
  "where can i get",
  "where can i find",
  "natafuta",
  "ninatafuta",
  "tunatafuta",
  "nahitaji",
  "ninahitaji",
  "tunahitaji",
  "nataka",
  "tunataka",
  "nisaidie",
  "nisaidieni",
  "kuna fundi",
  "kuna mtu",
  "nani anaweza",
  "naeza pata",
  "naweza pata",
  "nitapata wapi",
  "anahitajika",
  "inahitajika",
  "wanahitajika",
] as const;

/** Leans towards a request, but offers use it too. Counts 1. */
export const REQUEST_HINTS = [
  "need a",
  "need an",
  "in need of",
  "help me",
  "required",
  "recommend a",
  "naomba",
  "imeharibika",
  "imeharibikiwa",
] as const;

export type IntentReading = {
  /** The offer phrases and hints found, in the order they appear. */
  offerPhrases: string[];
  /** The request phrases and hints found, in the order they appear. */
  requestPhrases: string[];
  offerScore: number;
  requestScore: number;
  /** The kind the words lean towards, or null when they do not lean. */
  leaning: IntentKind | null;
};

type Phrase = { tokens: string[]; kind: IntentKind; source: string; weight: number; order: number };

/** Lower case, apostrophes removed, everything not a letter or digit a word break. */
function tokens(text: string): string[] {
  const cleaned = text
    .toLowerCase()
    .replace(/['’‘`]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
  return cleaned === "" ? [] : cleaned.split(" ");
}

let compiled: Phrase[] | null = null;

/** Every list, tokenised once. Longest first; at equal length a phrase before a hint; then list order. */
function phrases(): Phrase[] {
  if (compiled) return compiled;
  let order = 0;
  const all: Phrase[] = [];
  const add = (list: readonly string[], kind: IntentKind, weight: number) => {
    for (const p of list) {
      const t = tokens(p);
      if (t.length > 0) all.push({ tokens: t, kind, source: p, weight, order: order++ });
    }
  };
  add(OFFER_PHRASES, "offer", 2);
  add(REQUEST_PHRASES, "request", 2);
  add(OFFER_HINTS, "offer", 1);
  add(REQUEST_HINTS, "request", 1);
  all.sort((a, b) => b.tokens.length - a.tokens.length || b.weight - a.weight || a.order - b.order);
  compiled = all;
  return all;
}

/** Read [text]. Every word is claimed by at most one phrase, the longest one that fits there. */
export function readPostIntent(text: string): IntentReading {
  const words = tokens(text);
  const claimed = new Array<boolean>(words.length).fill(false);
  const found: { start: number; phrase: Phrase }[] = [];
  for (const phrase of phrases()) {
    for (let start = 0; start + phrase.tokens.length <= words.length; start++) {
      if (!phrase.tokens.every((t, i) => words[start + i] === t)) continue;
      const end = start + phrase.tokens.length;
      let free = true;
      for (let i = start; i < end; i++) if (claimed[i]) free = false;
      if (!free) continue;
      for (let i = start; i < end; i++) claimed[i] = true;
      found.push({ start, phrase });
    }
  }
  found.sort((a, b) => a.start - b.start);
  const score = (kind: IntentKind) => found.filter((m) => m.phrase.kind === kind).reduce((s, m) => s + m.phrase.weight, 0);
  const offerScore = score("offer");
  const requestScore = score("request");
  return {
    offerPhrases: found.filter((m) => m.phrase.kind === "offer").map((m) => m.phrase.source),
    requestPhrases: found.filter((m) => m.phrase.kind === "request").map((m) => m.phrase.source),
    offerScore,
    requestScore,
    leaning: offerScore > requestScore ? "offer" : requestScore > offerScore ? "request" : null,
  };
}

export type IntentSuggestion = {
  /** The kind the words read as. */
  type: IntentKind;
  /** The phrases and hints that read that way, as written in the lists. */
  evidence: string[];
  /**
   * At least one PHRASE says it ("anyone in need of"), not only hints. Two
   * hints are enough to be listed, but hints are words both kinds use, so a
   * hint-only listing is marked weak.
   */
  strong: boolean;
};

/**
 * The least evidence before anything is suggested: one phrase (2) or two
 * hints (1 + 1). The app's kNudgeMinimumScore; a single weak word ("Fundi wa
 * fridge") says nothing, in the app or here.
 */
export const NUDGE_MINIMUM_SCORE = 2;

/**
 * What a listing posted as [chosen] reads as instead, or null when its words
 * agree with it, do not lean, or lean too weakly. Only a request and an offer
 * are compared: a job has its own form and is never suggested.
 */
export function suggestPostType(input: { chosen: string; title: string; description?: string | null }): IntentSuggestion | null {
  if (input.chosen !== "request" && input.chosen !== "offer") return null;
  const reading = readPostIntent(`${input.title}\n${input.description ?? ""}`);
  if (!reading.leaning || reading.leaning === input.chosen) return null;
  const score = reading.leaning === "offer" ? reading.offerScore : reading.requestScore;
  if (score < NUDGE_MINIMUM_SCORE) return null;
  const evidence = [...new Set(reading.leaning === "offer" ? reading.offerPhrases : reading.requestPhrases)];
  const phrases: readonly string[] = reading.leaning === "offer" ? OFFER_PHRASES : REQUEST_PHRASES;
  return { type: reading.leaning, evidence, strong: evidence.some((e) => phrases.includes(e)) };
}
