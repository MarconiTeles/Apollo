import { memo, useCallback, useEffect, useRef, useState } from "react";
import { post } from "../lib/bridge";
import { claimInteraction, hoverAllowed, releaseInteraction, viewRect } from "../lib/interaction";
import type { Glyph } from "../lib/types";

// MyTasksDoneCircle: 24pt hit target around the exact 10pt visual circle.
// The SVG repeats drawArtwork()'s paint order (fill, stroke, halo, then the
// crisp core again) so the translucent layers composite identically.

const CX = 12;
const R = 4.4; // (10 − 2 × 0.6) / 2

interface Props {
  taskId: string;
  sc: string;
  completed: boolean;
  disabled: boolean;
  check?: Glyph;
}

export const DoneCircle = memo(function DoneCircle({ taskId, sc, completed, disabled, check }: Props) {
  const [hovered, setHovered] = useState(false);
  const [pressed, setPressed] = useState(false);
  const [released, setReleased] = useState(false);
  const button = useRef<HTMLButtonElement>(null);
  const interactive = !completed && !disabled;

  const reset = useCallback(() => {
    setHovered(false);
    setPressed(false);
    setReleased(false);
  }, []);

  useEffect(() => {
    if (!interactive) reset();
  }, [interactive, reset]);
  useEffect(() => () => releaseInteraction(reset), [reset]);

  const status = (alpha: number) => `color(display-p3 ${sc} / ${alpha})`;
  const inner = status(hovered ? 0.88 : 0.62);
  const stroke = hovered ? status(1) : "var(--ink-faint-85)";
  const strokeWidth = hovered ? 1.05 : 0.75;

  // NSGradient interpolates premultiplied (linear fall-off to paper); CSS
  // gradients do too, SVG gradients do not — so the fill is a CSS disc and
  // only the solid stroke is SVG.
  const fill = (
    <span
      className="done-fill"
      style={{ background: `radial-gradient(circle farthest-corner at 50% 50%, ${inner}, var(--paper))` }}
    />
  );
  const ring = (
    <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
      <circle cx={CX} cy={CX} r={R} fill="none" stroke={stroke} strokeWidth={strokeWidth} />
    </svg>
  );

  return (
    <button
      ref={button}
      type="button"
      className={`done${completed ? " completed" : ""}${hovered ? " hovered" : ""}${pressed ? " pressed" : ""}${released ? " released" : ""}`}
      disabled={disabled}
      aria-label="Mover tarefa para outro status"
      aria-description="Abre a lista de status disponíveis"
      draggable={false}
      onMouseEnter={() => {
        if (!interactive || !hoverAllowed()) {
          reset();
          return;
        }
        claimInteraction(reset);
        setReleased(false);
        setHovered(true);
      }}
      onMouseLeave={() => {
        if (!hovered && !pressed) return;
        setHovered(false);
        setPressed(false);
        setReleased(false);
        releaseInteraction(reset);
      }}
      onMouseDown={(event) => {
        event.stopPropagation();
        if (event.button !== 0 || !interactive) return;
        setReleased(false);
        setPressed(true);
      }}
      onMouseUp={() => {
        if (!pressed) return;
        setPressed(false);
        setReleased(true);
      }}
      onClick={(event) => {
        event.stopPropagation();
        if (!interactive || !button.current) return;
        post({ type: "statusPicker", id: taskId, rect: viewRect(button.current) });
      }}
    >
      <span className="done-visual">
        {completed ? (
          <svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true">
            <circle cx={CX} cy={CX} r={R} fill="var(--green)" />
          </svg>
        ) : (
          <>
            {fill}
            {ring}
            {hovered && (
              <>
                <span className="done-halo" style={{ background: status(0.16) }} />
                {fill}
                {ring}
              </>
            )}
          </>
        )}
      </span>
      {completed && check && (
        <span
          className="glyph"
          style={{
            left: 9.1,
            top: 9.1,
            width: 5.8,
            height: 5.8,
            transform: "none",
            color: "#fff",
            WebkitMaskImage: `url(${check.url})`,
            maskImage: `url(${check.url})`,
          }}
        />
      )}
    </button>
  );
});
