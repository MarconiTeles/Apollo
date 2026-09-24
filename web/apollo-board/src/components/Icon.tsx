// Hairline glyphs drawn on a 16pt grid (1.25pt strokes, round joins) — the
// weight of ClickUp's card icons, crisp at 2x. Colour comes from
// `currentColor`.

import type { CSSProperties } from "react";

const PATHS: Record<string, string> = {
  description: "M3 4.5h10M3 8h10M3 11.5h6.5",
  attachment:
    "M12.2 7.6 7.9 11.9a2.6 2.6 0 0 1-3.7-3.7l4.6-4.6a1.75 1.75 0 0 1 2.5 2.5L6.7 10.7a.9.9 0 0 1-1.3-1.3l4-4",
  checklist: "M3 4.6 4.2 5.8 6.4 3.4M3 10.6l1.2 1.2 2.2-2.4M8.6 4.8H13M8.6 10.8H13",
  subtask: "M4.5 3v5.5a2 2 0 0 0 2 2H11M9 8.5l2 2-2 2",
  calendar: "M3 5.2a1.7 1.7 0 0 1 1.7-1.7h6.6A1.7 1.7 0 0 1 13 5.2v6.1a1.7 1.7 0 0 1-1.7 1.7H4.7A1.7 1.7 0 0 1 3 11.3zM3 7h10M5.8 2.2v2.4M10.2 2.2v2.4",
  flag: "M4 13.5V3M4 3.4c2.6-1.3 4.8 1.2 8 0v5.6c-3.2 1.2-5.4-1.3-8 0",
  tag: "M8.6 2.8h3.3a1.3 1.3 0 0 1 1.3 1.3v3.3a1 1 0 0 1-.3.7l-5.2 5.2a1.2 1.2 0 0 1-1.7 0L3 10.3a1.2 1.2 0 0 1 0-1.7l5.2-5.2a1 1 0 0 1 .4-.6zM10.6 5.4h.01",
  plus: "M8 3.2v9.6M3.2 8h9.6",
  more: "M3.6 8h.01M8 8h.01M12.4 8h.01",
  search: "M7.2 12a4.8 4.8 0 1 0 0-9.6 4.8 4.8 0 0 0 0 9.6zM10.6 10.6 13.6 13.6",
  layers: "M8 2.6 13.4 5.4 8 8.2 2.6 5.4zM2.6 8.2 8 11l5.4-2.8M2.6 10.9 8 13.7l5.4-2.8",
  sort: "M5 3v10M2.8 5.2 5 3l2.2 2.2M11 13V3M8.8 10.8 11 13l2.2-2.2",
  sliders: "M3 5h6M12 5h1M3 11h1M7 11h6M10.5 3.5v3M5.5 9.5v3",
  chevronDown: "M4.5 6.2 8 9.7l3.5-3.5",
  chevronRight: "M6.2 4.5 9.7 8l-3.5 3.5",
  check: "M3.6 8.3 6.6 11.2 12.4 4.8",
  close: "M4.5 4.5l7 7M11.5 4.5l-7 7",
  collapse: "M5 2.8 8 5.8l3-3M5 13.2l3-3 3 3",
  expand: "M5 5.4 8 2.4l3 3M5 10.6l3 3 3-3",
  user: "M8 8a2.6 2.6 0 1 0 0-5.2A2.6 2.6 0 0 0 8 8zM3.2 13.4c.6-2.3 2.5-3.6 4.8-3.6s4.2 1.3 4.8 3.6",
  eye: "M1.8 8S4 3.8 8 3.8 14.2 8 14.2 8 12 12.2 8 12.2 1.8 8 1.8 8zM8 9.8a1.8 1.8 0 1 0 0-3.6 1.8 1.8 0 0 0 0 3.6z",
  list: "M5.6 4h7.6M5.6 8h7.6M5.6 12h7.6M2.8 4h.01M2.8 8h.01M2.8 12h.01",
  image: "M3 4.6A1.6 1.6 0 0 1 4.6 3h6.8A1.6 1.6 0 0 1 13 4.6v6.8a1.6 1.6 0 0 1-1.6 1.6H4.6A1.6 1.6 0 0 1 3 11.4zM3.2 10.8l2.9-2.9 2.2 2.2 1.5-1.5 3 3M10.2 6.2h.01",
  person: "M8 7.2a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4zM3.6 13c.5-2 2.2-3.3 4.4-3.3s3.9 1.3 4.4 3.3",
  clear: "M4 4l8 8",
  /** SF `arrow.turn.down.right`, the native card's date glyph. */
  turnArrow: "M4 3v4.6a2.2 2.2 0 0 0 2.2 2.2H12.5M10 7.3l2.5 2.5L10 12.3",
};

export type IconName = keyof typeof PATHS;

export function Icon({
  name,
  size = 14,
  stroke = 1.25,
  className,
  style,
}: {
  name: IconName;
  size?: number;
  stroke?: number;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={PATHS[name]} />
    </svg>
  );
}

/** Filled priority flag (ClickUp paints the set priority solid). */
export function FlagFilled({ color, size = 14 }: { color: string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
      <path d="M4 13.5V3" stroke={color} strokeWidth={1.4} strokeLinecap="round" fill="none" />
      <path d="M4 3.4c2.6-1.3 4.8 1.2 8 0v5.6c-3.2 1.2-5.4-1.3-8 0z" fill={color} stroke={color} strokeWidth={1.1} strokeLinejoin="round" />
    </svg>
  );
}

/** ClickUp's status glyph: a ring with a solid core (closed: a check). */
export function StatusGlyph({ closed, size = 12 }: { closed?: boolean; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" aria-hidden="true">
      <circle cx="6" cy="6" r="4.9" fill="none" stroke="currentColor" strokeWidth="1.3" />
      {closed ? (
        <path d="M3.7 6.1 5.3 7.6 8.3 4.5" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
      ) : (
        <circle cx="6" cy="6" r="2.3" fill="currentColor" />
      )}
    </svg>
  );
}
