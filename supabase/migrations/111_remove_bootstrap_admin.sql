-- 111: delete the bootstrap admin account seeded by migrations 045/052.
--
-- The row (founder@help24.app, "Founder (bootstrap)") existed only so the very
-- first operator could sign in before any real admin was created. Its plaintext
-- token is committed to the repository, it has been active=false since
-- hardening, and the backend self-check treats an absent row as the fully
-- hardened state. Nothing resolves, seeds, or authenticates against it.
--
-- Guard: refuses to run if it would leave zero active admins (lockout).

DO $$
DECLARE
  bootstrap_hash text := encode(digest('help24-super-admin-CHANGE-ME', 'sha256'), 'hex');
  real_active_admins integer;
BEGIN
  SELECT count(*) INTO real_active_admins
    FROM public.admin_users
   WHERE active = TRUE
     AND token_hash <> bootstrap_hash;

  IF real_active_admins = 0 THEN
    RAISE EXCEPTION
      'refusing to delete the bootstrap admin: no other active admin exists, this would be a lockout';
  END IF;

  DELETE FROM public.admin_users
   WHERE token_hash = bootstrap_hash
      OR email = 'founder@help24.app';
END $$;
