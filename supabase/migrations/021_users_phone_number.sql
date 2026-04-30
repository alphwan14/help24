-- Ensure phone_number column exists on users table.
-- Single source of truth for M-Pesa payout/payment numbers.
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS phone_number TEXT;

-- Index for fast lookups by phone (e.g. backend validations).
CREATE INDEX IF NOT EXISTS idx_users_phone_number
  ON public.users (phone_number)
  WHERE phone_number IS NOT NULL;
