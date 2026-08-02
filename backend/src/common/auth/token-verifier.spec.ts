import { TokenVerifierService } from './token-verifier.service';
import { FirebaseAdminService } from '../../notifications/firebase-admin.service';

const verifyIdToken = jest.fn();

jest.mock('firebase-admin/auth', () => ({
  getAuth: () => ({ verifyIdToken: (...args: unknown[]) => verifyIdToken(...args) }),
}));

/** A structurally valid JWS — three dot-separated parts. */
function jwt(tag = 'a'): string {
  return `header.${tag}payload.signature`;
}

function decoded(uid = 'uid-1', ttlSeconds = 3600) {
  return {
    uid,
    email: `${uid}@example.com`,
    phone_number: '+254700000000',
    exp: Math.floor(Date.now() / 1000) + ttlSeconds,
    auth_time: Math.floor(Date.now() / 1000),
  };
}

function verifier(firebaseReady = true, env: Record<string, string> = {}): TokenVerifierService {
  const original = { ...process.env };
  Object.assign(process.env, env);
  try {
    const firebase = { app: firebaseReady ? ({} as never) : null } as FirebaseAdminService;
    return new TokenVerifierService(firebase);
  } finally {
    process.env = original;
  }
}

beforeEach(() => {
  verifyIdToken.mockReset();
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  jest.spyOn(console, 'debug').mockImplementation(() => undefined);
});

afterEach(() => jest.restoreAllMocks());

describe('TokenVerifierService — outcomes', () => {
  it('returns the identity for a good token', async () => {
    verifyIdToken.mockResolvedValue(decoded());
    const result = await verifier().verify(jwt());

    expect(result).toMatchObject({
      outcome: 'verified',
      cached: false,
      identity: { uid: 'uid-1', email: 'uid-1@example.com' },
    });
  });

  it('rejects structural garbage without touching the crypto', async () => {
    const service = verifier();
    expect(await service.verify('   ')).toMatchObject({ outcome: 'failed', reason: 'malformed' });
    expect(await service.verify('not-a-jwt')).toMatchObject({ outcome: 'failed', reason: 'malformed' });
    expect(await service.verify('two.parts')).toMatchObject({ outcome: 'failed', reason: 'malformed' });
    expect(verifyIdToken).not.toHaveBeenCalled();
  });

  it('never throws — every failure comes back as a value', async () => {
    verifyIdToken.mockRejectedValue(new Error('boom'));
    await expect(verifier().verify(jwt())).resolves.toMatchObject({ outcome: 'failed' });
  });
});

describe('TokenVerifierService — error classification', () => {
  // The split that matters: a caller problem (401) versus our problem (503).
  // Getting it wrong signs the entire user base out over a Firebase outage.
  const cases: Array<[string, unknown, string]> = [
    ['expired token', { code: 'auth/id-token-expired', message: 'Firebase ID token has expired' }, 'expired'],
    ['revoked token', { code: 'auth/id-token-revoked', message: 'has been revoked' }, 'revoked'],
    ['disabled user', { code: 'auth/user-disabled', message: 'user disabled' }, 'revoked'],
    ['bad signature', { code: 'auth/invalid-id-token', message: 'signature verification failed' }, 'invalid'],
    ['argument error', { code: 'auth/argument-error', message: 'Decoding failed' }, 'malformed'],
    ['key fetch failure', { message: 'Error fetching public keys for Google certs' }, 'unavailable'],
    ['DNS failure', { message: 'getaddrinfo ENOTFOUND www.googleapis.com' }, 'unavailable'],
    ['connection refused', { message: 'connect ECONNREFUSED 142.250.0.1:443' }, 'unavailable'],
    ['timeout', { message: 'socket hang up ETIMEDOUT' }, 'unavailable'],
  ];

  it.each(cases)('classifies %s as %s', async (_label, error, expected) => {
    const err = Object.assign(new Error((error as { message: string }).message), error);
    verifyIdToken.mockRejectedValue(err);
    expect(await verifier().verify(jwt())).toMatchObject({ outcome: 'failed', reason: expected });
  });

  it('reports unavailable — not invalid — when Firebase is unconfigured', async () => {
    expect(await verifier(false).verify(jwt())).toMatchObject({
      outcome: 'failed',
      reason: 'unavailable',
    });
    expect(verifyIdToken).not.toHaveBeenCalled();
  });
});

describe('TokenVerifierService — cache', () => {
  it('verifies a repeated token exactly once', async () => {
    // The performance claim, asserted rather than assumed: this client polls
    // payment status every 5s and job status every 30s on one hour-long token.
    verifyIdToken.mockResolvedValue(decoded());
    const service = verifier();

    const first = await service.verify(jwt());
    const second = await service.verify(jwt());
    const third = await service.verify(jwt());

    expect(verifyIdToken).toHaveBeenCalledTimes(1);
    expect(first).toMatchObject({ cached: false });
    expect(second).toMatchObject({ cached: true, identity: { uid: 'uid-1' } });
    expect(third).toMatchObject({ cached: true });
    expect(service.snapshot()).toMatchObject({ verified: 1, cacheHits: 2 });
  });

  it('keeps distinct tokens distinct', async () => {
    verifyIdToken.mockImplementation((token: string) =>
      Promise.resolve(decoded(token.includes('b') ? 'uid-b' : 'uid-a')),
    );
    const service = verifier();

    expect(await service.verify(jwt('a'))).toMatchObject({ identity: { uid: 'uid-a' } });
    expect(await service.verify(jwt('b'))).toMatchObject({ identity: { uid: 'uid-b' } });
    expect(verifyIdToken).toHaveBeenCalledTimes(2);
  });

  it('never caches a failure', async () => {
    // A refreshed token must be reassessed immediately; caching the rejection
    // would keep denying a caller who has already fixed the problem.
    verifyIdToken.mockRejectedValue(
      Object.assign(new Error('Firebase ID token has expired'), { code: 'auth/id-token-expired' }),
    );
    const service = verifier();

    await service.verify(jwt());
    await service.verify(jwt());
    expect(verifyIdToken).toHaveBeenCalledTimes(2);
  });

  it('does not cache a token that is about to expire', async () => {
    verifyIdToken.mockResolvedValue(decoded('uid-1', 0));
    const service = verifier();

    await service.verify(jwt());
    await service.verify(jwt());
    expect(verifyIdToken).toHaveBeenCalledTimes(2);
    expect(service.snapshot().cacheSize).toBe(0);
  });

  it('never serves an entry past the token expiry', async () => {
    // Two independent expiries are enforced — the entry TTL and the token's own
    // `exp` — so a cached identity cannot outlive the credential it represents.
    verifyIdToken.mockResolvedValue(decoded('uid-1', 30));
    const service = verifier();
    await service.verify(jwt());
    expect(service.snapshot().cacheSize).toBe(1);

    const realNow = Date.now;
    Date.now = () => realNow() + 31_000;
    try {
      await service.verify(jwt());
      expect(verifyIdToken).toHaveBeenCalledTimes(2);
    } finally {
      Date.now = realNow;
    }
  });

  it('evicts the least recently used entry at the ceiling', async () => {
    verifyIdToken.mockImplementation((token: string) => Promise.resolve(decoded(`uid-${token}`)));
    const service = verifier(true, { AUTH_TOKEN_CACHE_MAX: '2' });

    await service.verify(jwt('a'));
    await service.verify(jwt('b'));
    await service.verify(jwt('a')); // 'a' becomes most recent
    await service.verify(jwt('c')); // evicts 'b'

    expect(service.snapshot().cacheSize).toBe(2);
    expect(service.snapshot().cacheEvictions).toBe(1);

    verifyIdToken.mockClear();
    await service.verify(jwt('a'));
    expect(verifyIdToken).not.toHaveBeenCalled(); // still cached
    await service.verify(jwt('b'));
    expect(verifyIdToken).toHaveBeenCalledTimes(1); // was evicted
  });

  it('can be switched off entirely', async () => {
    verifyIdToken.mockResolvedValue(decoded());
    const service = verifier(true, { AUTH_TOKEN_CACHE: 'false' });

    await service.verify(jwt());
    await service.verify(jwt());
    expect(verifyIdToken).toHaveBeenCalledTimes(2);
  });

  it('does not store raw tokens as cache keys', async () => {
    // A heap dump or an accidental log of the cache must not yield a working
    // credential, so keys are SHA-256 digests.
    verifyIdToken.mockResolvedValue(decoded());
    const service = verifier();
    const token = jwt('secret');
    await service.verify(token);

    const keys = [...(service as unknown as { cache: Map<string, unknown> }).cache.keys()];
    expect(keys).toHaveLength(1);
    expect(keys[0]).not.toContain('secret');
    expect(keys[0]).not.toBe(token);
  });
});
