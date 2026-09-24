import { memo, useRef } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { post } from "../lib/bridge";
import { pressSpring } from "../lib/motion";
import { Squircle, squircle, useBoxSize } from "../lib/squircle";
import type { ShadowLayer } from "../lib/squircle";
import type { EventPayload } from "../lib/types";

// AgendaEventCard + interactivePillFeedback(glow, hoverScale 1.015,
// pulseFromClick). Hover/press scale and the glow are CSS transitions on
// SwiftUI's springs; the click ripple is InteractivePillFeedback.flashOverlay.

const RIPPLE_MS = 700;
// pow(1 - p, 1.6) * 0.6, sampled in progress space; the effect's ease-out
// maps time → progress exactly like withAnimation(.easeOut(duration: 0.7)).
const RIPPLE_FRAMES: Keyframe[] = Array.from({ length: 11 }, (_, index) => {
  const p = index / 10;
  return { offset: p, transform: `scale(${p})`, opacity: Math.pow(1 - p, 1.6) * 0.6 };
});

// drawingGroup().shadow(radius: 4, y: 1) under the pill glow
// (radius 10.4, y 3.9 on hover).
const CARD_SHADOWS: ShadowLayer[] = [
  { className: "card-glow", dy: 3.9, sigma: 10.4 },
  { className: "card-shadow", dy: 1, sigma: 4 },
];

export const EventCard = memo(function EventCard({ event }: { event: EventPayload }) {
  const [card, size] = useBoxSize<HTMLButtonElement>();
  const ripple = useRef<HTMLSpanElement>(null);
  const release = useRef<number | undefined>(undefined);

  const onPointerDown = (e: ReactPointerEvent<HTMLButtonElement>) => {
    if (e.button !== 0 || e.ctrlKey) return;
    const element = card.current;
    const disc = ripple.current;
    if (!element || !disc) return;
    window.clearTimeout(release.current);
    element.classList.remove("releasing");
    element.classList.add("pressed");
    // Layout box, not the (scaled) visual rect: the ripple lives inside.
    const rect = element.getBoundingClientRect();
    const scale = rect.width / element.offsetWidth || 1;
    const x = (e.clientX - rect.left) / scale;
    const y = (e.clientY - rect.top) / scale;
    const diameter = Math.max(element.offsetWidth, element.offsetHeight) * 1.7;
    disc.style.width = disc.style.height = `${diameter}px`;
    disc.style.left = `${x - diameter / 2}px`;
    disc.style.top = `${y - diameter / 2}px`;
    disc.getAnimations().forEach((animation) => animation.cancel());
    disc.animate(RIPPLE_FRAMES, { duration: RIPPLE_MS, easing: "cubic-bezier(0, 0, 0.58, 1)", fill: "forwards" });
    element.setPointerCapture(e.pointerId);
  };

  const endPress = () => {
    const element = card.current;
    if (!element || !element.classList.contains("pressed")) return;
    element.classList.remove("pressed");
    element.classList.add("releasing");
    release.current = window.setTimeout(
      () => element.classList.remove("releasing"),
      pressSpring.duration * 1000,
    );
  };

  const style = { "--c": event.cardc } as React.CSSProperties;
  return (
    <button
      ref={card}
      type="button"
      className={`card${event.accepted ? " accepted" : ""}${event.declined ? " declined" : ""}`}
      style={style}
      onPointerDown={onPointerDown}
      onPointerUp={endPress}
      onPointerCancel={endPress}
      onLostPointerCapture={endPress}
      onClick={() => post({ type: "open", key: event.key })}
      onContextMenu={(e) => {
        e.preventDefault();
        post({ type: "menu", key: event.key, x: e.clientX, y: e.clientY });
      }}
    >
      {!event.accepted && (
        // The group shadow of the text sits under the 14% fill (drawingGroup):
        // a transparent copy casts it from behind the squircle.
        <span className={`card-text card-text-shadow${event.initials !== undefined ? " with-avatar" : ""}`} aria-hidden>
          <span className="card-title">{event.title}</span>
          <span className="card-subtitle">{event.subtitle}</span>
        </span>
      )}
      <Squircle
        width={size.width}
        height={size.height}
        radius={13}
        className="card-bg"
        stroke={event.accepted ? { className: "card-stroke", width: 0.5 } : undefined}
        shadows={CARD_SHADOWS}
      />
      <span className="card-text">
        <span className="card-title">{event.title}</span>
        <span className="card-subtitle">{event.subtitle}</span>
      </span>
      {event.initials !== undefined && (
        <span className="card-avatar">
          <span>{event.initials || "?"}</span>
        </span>
      )}
      <span
        className="card-ripple-clip"
        style={{ clipPath: `path("${squircle(0, 0, size.width, size.height, 13)}")` }}
        aria-hidden
      >
        <span ref={ripple} className="card-ripple" />
      </span>
    </button>
  );
});
