"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Modal from "@/components/moderation/Modal";
import { reclassifyListingAction } from "@/lib/marketplace-actions";
import {
  EMPLOYMENT_TYPES,
  LISTING_TYPES,
  LISTING_TYPE_WORDS,
  changeLabel,
  reclassifyInputError,
  type EmploymentType,
  type ListingType,
} from "@/lib/listing-type";

/**
 * "Change type" for a listing posted as the wrong kind. Nothing changes until
 * the admin picks the new kind, gives a reason and confirms; the database
 * re-checks the listing and records the change with the admin's name.
 */
export default function ReclassifyListing({
  postId,
  currentType,
  suggestedType,
  applications,
  blockedReason,
}: {
  postId: string;
  currentType: string;
  /** The kind the listing's words read as (Wrong type list): chosen first in the dialog. */
  suggestedType?: ListingType;
  /** How many people already responded: they keep their responses. */
  applications: number;
  /** Why the type cannot change here, or null. */
  blockedReason: string | null;
}) {
  const router = useRouter();
  const others = LISTING_TYPES.filter((t) => t !== currentType);
  const first = suggestedType && others.includes(suggestedType) ? suggestedType : others[0];
  const [open, setOpen] = useState(false);
  const [type, setType] = useState<ListingType>(first);
  const [employment, setEmployment] = useState<EmploymentType | "">("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);
  const [busy, startTransition] = useTransition();

  const invalid = reclassifyInputError({ type, current: currentType, employmentType: employment || null, reason });

  function openDialog() {
    setType(first);
    setEmployment("");
    setReason("");
    setError(null);
    setOpen(true);
  }

  function save() {
    setError(null);
    startTransition(async () => {
      const res = await reclassifyListingAction(postId, currentType, type, employment || null, reason);
      if (!res.ok) {
        setError(res.error ?? "Nothing was changed.");
        return;
      }
      setResult(`Changed: ${changeLabel(currentType, type)}. It now shows as ${LISTING_TYPE_WORDS[type].feed} in the app.`);
      setOpen(false);
      router.refresh();
    });
  }

  return (
    <div className="space-y-2">
      <button type="button" className="btn-ghost" disabled={!!blockedReason} onClick={openDialog}>
        Change type
      </button>
      {blockedReason && <p className="text-[12px] text-gray-500">{blockedReason}</p>}
      {result && (
        <p role="status" className="p-3 rounded-lg bg-positive-50 border border-positive-200 text-[12.5px] text-positive-700">
          {result}
        </p>
      )}

      <Modal
        open={open}
        title="Change this listing's type"
        description="For a listing posted as the wrong kind. The author is not notified; the listing simply shows as its new kind."
        busy={busy}
        onClose={() => setOpen(false)}
        footer={
          <>
            <button type="button" className="btn-ghost" disabled={busy} onClick={() => setOpen(false)}>
              Cancel
            </button>
            <button type="button" className="btn-primary" disabled={busy || !!invalid} onClick={save}>
              {busy ? "Saving…" : `Change to ${LISTING_TYPE_WORDS[type].name.toLowerCase()}`}
            </button>
          </>
        }
      >
        <fieldset className="space-y-2">
          <legend className="text-xs font-semibold text-gray-600 mb-1">New type</legend>
          {others.map((t) => (
            <label key={t} className="flex items-start gap-2.5 text-[13px] text-gray-700 cursor-pointer">
              <input
                type="radio"
                name="listing-type"
                value={t}
                className="mt-0.5 h-4 w-4"
                checked={type === t}
                onChange={() => setType(t)}
              />
              <span>
                <span className="font-medium text-gray-900">{LISTING_TYPE_WORDS[t].name}</span>
                <span className="text-gray-500"> (shows as {LISTING_TYPE_WORDS[t].feed}). {LISTING_TYPE_WORDS[t].means}</span>
              </span>
            </label>
          ))}
        </fieldset>
        {type === "job" && (
          <label className="block">
            <span className="text-xs font-semibold text-gray-600">Employment type</span>
            <select
              className="input mt-1"
              name="employment-type"
              value={employment}
              onChange={(e) => setEmployment(e.target.value as EmploymentType | "")}
            >
              <option value="">Choose one</option>
              {EMPLOYMENT_TYPES.map(([k, label]) => (
                <option key={k} value={k}>
                  {label}
                </option>
              ))}
            </select>
          </label>
        )}
        <label className="block">
          <span className="text-xs font-semibold text-gray-600">Why</span>
          <textarea
            className="input resize-none mt-1"
            rows={2}
            maxLength={500}
            value={reason}
            placeholder="e.g. The title says they offer plumbing"
            onChange={(e) => setReason(e.target.value)}
          />
        </label>
        {applications > 0 && (
          <p className="text-[12.5px] text-caution-700">
            {applications} {applications === 1 ? "person" : "people"} already responded to it as a{" "}
            {LISTING_TYPE_WORDS[currentType as ListingType]?.name.toLowerCase() ?? currentType}. Their responses stay.
          </p>
        )}
        {error && (
          <p role="alert" className="p-3 rounded-lg bg-critical-50 border border-critical-200 text-[12.5px] text-critical-700">
            {error}
          </p>
        )}
      </Modal>
    </div>
  );
}
