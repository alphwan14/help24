-- Store Daraja's ResultDesc when an STK push fails, so the Flutter app
-- can surface the exact reason (declined, timeout, insufficient funds, etc.)
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS failure_reason TEXT;
