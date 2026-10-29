import { typesForScope } from './feed.service';

// The server half of the scope mirror. mobile-app/test/feed_scope_test.dart
// holds the same table; change both or neither.
describe('typesForScope', () => {
  it('maps every Discover scope to the post types it shows', () => {
    expect(typesForScope('all')).toEqual(['request', 'offer', 'job']);
    expect(typesForScope('requests')).toEqual(['request']);
    expect(typesForScope('offers')).toEqual(['offer']);
    expect(typesForScope('jobs')).toEqual(['job']);
  });

  it('"All" includes jobs (owner decision, 2026-10-29)', () => {
    expect(typesForScope('all')).toContain('job');
  });

  it('an absent or unknown scope is "all", and never "no filter"', () => {
    expect(typesForScope(undefined)).toEqual(typesForScope('all'));
    expect(typesForScope('nonsense')).toEqual(typesForScope('all'));
  });
});
