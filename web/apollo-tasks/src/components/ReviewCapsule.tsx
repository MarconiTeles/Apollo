import { memo, useLayoutEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import { post } from "../lib/bridge";
import type { ReviewState } from "../lib/types";

// VER REVIEW / REVISADO (MyTasksNativeRowView.updateReviewButton) with the
// same choreography: pop-in, title cross-fade, success pulse, dismissal.

const CURVE_OUT = "cubic-bezier(0.18, 0.84, 0.24, 1)";
const CURVE_DISMISS = "cubic-bezier(0.4, 0, 0.67, 1)";

interface Visual {
  state: ReviewState;
  title: string;
  titleColor: string;
  fill: string;
}

function visualFor(state: ReviewState): Visual {
  if (state === "reviewed") {
    return { state, title: "REVISADO", titleColor: "var(--success-ink)", fill: "var(--success-fill)" };
  }
  return { state, title: "VER REVIEW", titleColor: "#fff", fill: "var(--accent)" };
}

interface Props {
  taskId: string;
  state: ReviewState;
  disabled: boolean;
}

export const ReviewCapsule = memo(function ReviewCapsule({ taskId, state, disabled }: Props) {
  // What is painted can lag behind `state` while a transition runs.
  const [shown, setShown] = useState<Visual | null>(state === "hidden" ? null : visualFor(state));
  const [caption, setCaption] = useState<Visual | null>(shown);
  const previous = useRef<ReviewState>("hidden");
  const generation = useRef(0);
  const track = useRef<HTMLSpanElement>(null);
  const label = useRef<HTMLSpanElement>(null);

  useLayoutEffect(() => {
    const from = previous.current;
    if (from === state) return;
    previous.current = state;
    const gen = ++generation.current;
    const timers: number[] = [];
    const later = (ms: number, run: () => void) =>
      timers.push(
        window.setTimeout(() => {
          if (generation.current === gen) run();
        }, ms),
      );

    if (state === "hidden") {
      track.current?.animate(
        [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.96)" }],
        { duration: 260, easing: CURVE_DISMISS, fill: "forwards" },
      );
      if (track.current) track.current.style.boxShadow = "none";
      label.current?.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 220, easing: "ease-in-out", fill: "forwards" });
      later(270, () => {
        setShown(null);
        setCaption(null);
      });
      return () => timers.forEach(clearTimeout);
    }

    const next = visualFor(state);
    setShown(next);
    if (from === "hidden") {
      setCaption(next);
      requestAnimationFrame(() => {
        if (generation.current !== gen) return;
        track.current?.getAnimations().forEach((animation) => animation.cancel());
        label.current?.getAnimations().forEach((animation) => animation.cancel());
        track.current?.animate(
          [{ opacity: 0, transform: "scale(0.94)" }, { opacity: 1, transform: "scale(1)" }],
          { duration: 300, easing: CURVE_OUT },
        );
        label.current?.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 280, easing: CURVE_OUT });
      });
    } else {
      label.current?.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 100, easing: "ease-out", fill: "forwards" });
      later(100, () => {
        setCaption(next);
        label.current?.getAnimations().forEach((animation) => animation.cancel());
        label.current?.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 240, easing: CURVE_OUT });
      });
    }
    if (state === "reviewed" && track.current) {
      // pulseReviewSuccess: green glow in, then settle to a faint halo.
      const el = track.current;
      el.style.transition = `background-color 0.36s ${CURVE_OUT}, box-shadow 0.3s ${CURVE_OUT}`;
      requestAnimationFrame(() => {
        if (generation.current === gen) el.style.boxShadow = "0 2px 16px var(--green-18)";
      });
      later(580, () => {
        el.style.transition = `background-color 0.36s ${CURVE_OUT}, box-shadow 0.42s ease-out`;
        el.style.boxShadow = "0 2px 6px var(--green-04)";
      });
    } else if (track.current) {
      track.current.style.boxShadow = "none";
    }
    return () => timers.forEach(clearTimeout);
  }, [state]);

  if (!shown) return null;
  const interactive = shown.state === "update" && state === "update" && !disabled;
  const style = {
    "--r-bg": shown.fill,
    "--r-title": (caption ?? shown).titleColor,
  } as CSSProperties;

  return (
    <button
      type="button"
      className={`capsule review ${shown.state}`}
      style={style}
      disabled={!interactive}
      draggable={false}
      title={shown.state === "reviewed" ? "Review concluída" : "Abrir a review atualizada"}
      aria-label={shown.state === "reviewed" ? "Review concluída" : "Ver nova review"}
      onMouseDown={(event) => event.stopPropagation()}
      onClick={(event) => {
        event.stopPropagation();
        if (interactive) post({ type: "review", id: taskId });
      }}
    >
      <span ref={track} className="track" />
      <span ref={label} className="caption">
        {(caption ?? shown).title}
      </span>
    </button>
  );
});
