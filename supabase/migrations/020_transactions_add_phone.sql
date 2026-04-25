-- Add buyer phone to transactions for audit / B2C lookup.
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS phone TEXT;
