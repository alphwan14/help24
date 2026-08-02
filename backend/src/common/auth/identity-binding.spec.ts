import {
  applyBindings,
  conflictsIn,
  describeOutcomes,
  parseBinding,
  resolveConflictsToVerified,
} from './identity-binding';

const UID = 'firebase-uid-abc';
const OTHER = 'firebase-uid-someone-else';

describe('parseBinding', () => {
  it('parses body and query paths', () => {
    expect(parseBinding('body.client_user_id', 'required')).toEqual({
      source: 'body',
      field: 'client_user_id',
      mode: 'required',
    });
    expect(parseBinding('query.user_id', 'optional')).toEqual({
      source: 'query',
      field: 'user_id',
      mode: 'optional',
    });
  });

  it('rejects malformed paths at decoration time rather than at request time', () => {
    // A binding that silently does nothing is indistinguishable from one that
    // works, so these must fail the boot.
    expect(() => parseBinding('client_user_id', 'required')).toThrow(/Invalid identity binding/);
    expect(() => parseBinding('params.id', 'required')).toThrow(/Invalid identity binding/);
    expect(() => parseBinding('body.', 'required')).toThrow(/Invalid identity binding/);
    expect(() => parseBinding('headers.x', 'required')).toThrow(/Invalid identity binding/);
  });
});

describe('applyBindings — authenticated caller', () => {
  const binding = parseBinding('body.client_user_id', 'required');

  it('injects the verified uid when the field is absent', () => {
    const req = { body: { post_id: 'p1' } };
    const outcomes = applyBindings(req, UID, [binding], { enforcing: true });

    expect(req.body).toEqual({ post_id: 'p1', client_user_id: UID });
    expect(outcomes[0].kind).toBe('injected');
  });

  it('leaves a matching field untouched', () => {
    const req = { body: { post_id: 'p1', client_user_id: UID } };
    const outcomes = applyBindings(req, UID, [binding], { enforcing: true });

    expect(req.body.client_user_id).toBe(UID);
    expect(outcomes[0].kind).toBe('matched');
  });

  it('reports a conflict when the body names someone else', () => {
    const req = { body: { post_id: 'p1', client_user_id: OTHER } };
    const outcomes = applyBindings(req, UID, [binding], { enforcing: true });

    expect(outcomes[0]).toMatchObject({ kind: 'conflict', claimed: OTHER });
    // NOT rewritten by applyBindings — the guard decides whether a conflict is
    // rejected or corrected, and it must still be able to see what was claimed.
    expect(req.body.client_user_id).toBe(OTHER);
  });

  it('treats whitespace-only and non-string values as absent', () => {
    const blank = { body: { client_user_id: '   ' } };
    expect(applyBindings(blank, UID, [binding], { enforcing: true })[0].kind).toBe('injected');
    expect(blank.body.client_user_id).toBe(UID);

    const numeric = { body: { client_user_id: 12345 } as Record<string, unknown> };
    expect(applyBindings(numeric, UID, [binding], { enforcing: true })[0].kind).toBe('injected');
    expect(numeric.body.client_user_id).toBe(UID);
  });

  it('trims a padded claim before comparing, so whitespace is not a conflict', () => {
    const req = { body: { client_user_id: ` ${UID} ` } };
    expect(applyBindings(req, UID, [binding], { enforcing: true })[0].kind).toBe('matched');
  });

  it('binds only the declared field and never its neighbours', () => {
    // The select-provider shape: `provider_id` names the person being SELECTED.
    // Binding it would let a caller assign any open job to themselves — an
    // authorization hole created by the authorization layer.
    const req = { body: { post_id: 'p1', provider_id: OTHER, client_user_id: UID } };
    applyBindings(req, UID, [binding], { enforcing: true });
    expect(req.body.provider_id).toBe(OTHER);
  });

  it('handles a missing or non-object body without throwing', () => {
    expect(applyBindings({}, UID, [binding], { enforcing: true })[0].kind).toBe('skipped');
    expect(applyBindings({ body: null }, UID, [binding], { enforcing: true })[0].kind).toBe('skipped');
    expect(applyBindings({ body: [1, 2] }, UID, [binding], { enforcing: true })[0].kind).toBe('skipped');
    expect(applyBindings({ body: 'text' }, UID, [binding], { enforcing: true })[0].kind).toBe('skipped');
  });
});

describe('applyBindings — anonymous caller on a public route', () => {
  const binding = parseBinding('query.user_id', 'optional');

  it('leaves an asserted claim alone before enforcement, preserving today behaviour', () => {
    // The shipped client sends user_id with no token. De-personalising it here
    // would be a visible behaviour change, which the pre-enforcement stages
    // promise not to make.
    const req = { query: { user_id: OTHER } };
    const outcomes = applyBindings(req, null, [binding], { enforcing: false });

    expect(req.query.user_id).toBe(OTHER);
    expect(outcomes[0].kind).toBe('skipped');
  });

  it('drops an unprovable claim under enforcement', () => {
    // Honouring it would let anyone read another person's personalised ranking
    // — what they have searched for and applied to — by naming them.
    const req = { query: { user_id: OTHER, lat: '-1.28' } };
    const outcomes = applyBindings(req, null, [binding], { enforcing: true });

    expect(req.query).toEqual({ lat: '-1.28' });
    expect(outcomes[0]).toMatchObject({ kind: 'dropped', claimed: OTHER });
  });

  it('does nothing when an anonymous caller claims nothing', () => {
    const req = { query: { lat: '-1.28' } };
    expect(applyBindings(req, null, [binding], { enforcing: true })[0].kind).toBe('skipped');
    expect(req.query).toEqual({ lat: '-1.28' });
  });
});

describe('resolveConflictsToVerified', () => {
  it('rewrites conflicting fields to the proven identity', () => {
    // This is what makes `monitor` a security improvement rather than a purely
    // diagnostic stage: a caller holding a valid token cannot act as someone
    // else even before enforcement is switched on.
    const req = { body: { client_user_id: OTHER }, query: { user_id: OTHER } };
    const bindings = [
      parseBinding('body.client_user_id', 'required'),
      parseBinding('query.user_id', 'required'),
    ];

    const outcomes = applyBindings(req, UID, bindings, { enforcing: false });
    expect(conflictsIn(outcomes)).toHaveLength(2);

    resolveConflictsToVerified(req, UID, outcomes);
    expect(req.body.client_user_id).toBe(UID);
    expect(req.query.user_id).toBe(UID);
  });

  it('leaves matched and injected fields alone', () => {
    const req = { body: { client_user_id: UID } };
    const outcomes = applyBindings(req, UID, [parseBinding('body.client_user_id', 'required')], {
      enforcing: false,
    });
    resolveConflictsToVerified(req, UID, outcomes);
    expect(req.body.client_user_id).toBe(UID);
  });
});

describe('describeOutcomes', () => {
  it('names the claimed identity on a conflict, for the abuse log', () => {
    const req = { body: { client_user_id: OTHER } };
    const outcomes = applyBindings(req, UID, [parseBinding('body.client_user_id', 'required')], {
      enforcing: true,
    });
    expect(describeOutcomes(outcomes)).toBe(`body.client_user_id=conflict(claimed=${OTHER})`);
  });

  it('summarises an empty binding list', () => {
    expect(describeOutcomes([])).toBe('none');
  });
});
