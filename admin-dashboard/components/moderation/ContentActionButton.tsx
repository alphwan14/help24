"use client";

import { useState } from "react";
import ReasonDialog from "./ReasonDialog";
import { setContentStateAction } from "@/lib/moderation-actions";

const COPY = {
  post: {
    remove: {
      button: "Hide listing…",
      title: "Hide this listing",
      body: "It disappears from Discover and search, and its owner cannot edit, re-open or delete it. Nothing is deleted — it stays here as evidence, and can be restored. The owner is told a listing was hidden, not who reported it.",
      confirm: "Hide listing",
    },
    restore: {
      button: "Restore listing…",
      title: "Restore this listing",
      body: "It becomes visible again exactly as it was.",
      confirm: "Restore listing",
    },
  },
  message: {
    remove: {
      button: "Hide message…",
      title: "Hide this message",
      body: "Both people see it as removed. The original text is kept for review, and can be restored.",
      confirm: "Hide message",
    },
    restore: {
      button: "Restore message…",
      title: "Restore this message",
      body: "Only a message hidden by moderation can be restored — one its sender deleted stays deleted.",
      confirm: "Restore message",
    },
  },
} as const;

export default function ContentActionButton({
  type,
  id,
  action,
  reportId,
  ownerUserId,
  compact = false,
}: {
  type: "post" | "message";
  id: string;
  action: "remove" | "restore";
  reportId?: string;
  ownerUserId?: string;
  compact?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const c = COPY[type][action];
  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={[
          "inline-flex items-center justify-center rounded-lg border font-semibold transition-colors",
          compact ? "px-2.5 min-h-[30px] text-[11.5px]" : "px-3 min-h-[36px] text-[12.5px]",
          action === "remove" ? "border-critical-200 text-critical-700 hover:bg-critical-50" : "border-gray-200 text-gray-700 hover:bg-gray-50",
        ].join(" ")}
      >
        {c.button}
      </button>
      <ReasonDialog
        open={open}
        onClose={() => setOpen(false)}
        title={c.title}
        description={c.body}
        reasonLabel="Reason"
        danger={action === "remove"}
        confirmLabel={c.confirm}
        onConfirm={(reason, note) =>
          setContentStateAction(type, id, action, { reason, internal_note: note, report_id: reportId, owner_user_id: ownerUserId })
        }
      />
    </>
  );
}
