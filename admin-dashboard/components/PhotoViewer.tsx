"use client";

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";

/**
 * A photo that opens in place, over the page, instead of in a new tab.
 *
 * Opening a photo used to navigate to it, which put a storage address in the
 * browser bar and took the admin away from the case. Now the page dims and the
 * photo fills it; Esc, the backdrop or ✕ closes it, and the arrow keys move
 * through the other photos of the same message or case.
 */
export type Photo = { src: string; alt: string };

export function PhotoLink({
  photos,
  index = 0,
  className = "",
  children,
}: {
  /** Every photo the viewer can move through; [index] is the one tapped. */
  photos: Photo[];
  index?: number;
  className?: string;
  children: ReactNode;
}) {
  const [open, setOpen] = useState<number | null>(null);
  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(index)}
        className={["block cursor-zoom-in focus:outline-none focus-visible:ring-2 focus-visible:ring-accent-500 rounded-xl", className].join(" ")}
        aria-label={`Open ${photos[index]?.alt ?? "photo"}`}
      >
        {children}
      </button>
      {open !== null && <Viewer photos={photos} start={open} onClose={() => setOpen(null)} />}
    </>
  );
}

function Viewer({ photos, start, onClose }: { photos: Photo[]; start: number; onClose: () => void }) {
  const [i, setI] = useState(start);
  const many = photos.length > 1;
  const step = useCallback((d: number) => setI((v) => (v + d + photos.length) % photos.length), [photos.length]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      else if (many && e.key === "ArrowRight") step(1);
      else if (many && e.key === "ArrowLeft") step(-1);
    };
    window.addEventListener("keydown", onKey);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = overflow;
    };
  }, [many, onClose, step]);

  const photo = photos[i];
  return createPortal(
    <div
      role="dialog"
      aria-modal="true"
      aria-label={photo.alt}
      className="fixed inset-0 z-[100] flex items-center justify-center bg-black/90 p-4 sm:p-10"
      onClick={onClose}
    >
      {/* eslint-disable-next-line @next/next/no-img-element -- storage photos, not static assets */}
      <img
        src={photo.src}
        alt={photo.alt}
        className="max-h-full max-w-full rounded-lg object-contain shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      />
      <button
        type="button"
        onClick={onClose}
        aria-label="Close photo"
        className="absolute right-3 top-3 grid h-10 w-10 place-items-center rounded-full bg-white/10 text-xl text-white hover:bg-white/20"
      >
        ✕
      </button>
      {many && (
        <>
          <button
            type="button"
            aria-label="Previous photo"
            onClick={(e) => {
              e.stopPropagation();
              step(-1);
            }}
            className="absolute left-3 top-1/2 grid h-11 w-11 -translate-y-1/2 place-items-center rounded-full bg-white/10 text-2xl text-white hover:bg-white/20"
          >
            ‹
          </button>
          <button
            type="button"
            aria-label="Next photo"
            onClick={(e) => {
              e.stopPropagation();
              step(1);
            }}
            className="absolute right-3 top-1/2 grid h-11 w-11 -translate-y-1/2 place-items-center rounded-full bg-white/10 text-2xl text-white hover:bg-white/20"
          >
            ›
          </button>
          <p className="absolute bottom-4 left-1/2 -translate-x-1/2 rounded-full bg-white/10 px-3 py-1 text-xs text-white">
            {i + 1} of {photos.length}
          </p>
        </>
      )}
    </div>,
    document.body,
  );
}
