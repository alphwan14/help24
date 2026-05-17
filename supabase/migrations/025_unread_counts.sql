-- Migration 025: unread message counts per chat participant
-- Adds user1_unread_count and user2_unread_count to chats.
-- A trigger auto-increments the recipient's counter on every chat_messages INSERT.
-- markMessagesSeen() in the Flutter client resets the counter to 0.

ALTER TABLE chats
  ADD COLUMN IF NOT EXISTS user1_unread_count INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS user2_unread_count INTEGER NOT NULL DEFAULT 0;

-- Function: increment the recipient's unread counter when a new message is inserted.
CREATE OR REPLACE FUNCTION increment_unread_count()
RETURNS TRIGGER AS $$
DECLARE
  v_user1 UUID;
  v_user2 UUID;
BEGIN
  SELECT user1, user2
    INTO v_user1, v_user2
    FROM chats
   WHERE id = NEW.chat_id;

  IF v_user1 IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.sender_id = v_user1 THEN
    -- sender is user1, recipient is user2
    UPDATE chats
       SET user2_unread_count = user2_unread_count + 1
     WHERE id = NEW.chat_id;
  ELSE
    -- sender is user2 (or anyone else), recipient is user1
    UPDATE chats
       SET user1_unread_count = user1_unread_count + 1
     WHERE id = NEW.chat_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop and re-create trigger so this migration is idempotent.
DROP TRIGGER IF EXISTS trg_increment_unread ON chat_messages;

CREATE TRIGGER trg_increment_unread
  AFTER INSERT ON chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION increment_unread_count();
