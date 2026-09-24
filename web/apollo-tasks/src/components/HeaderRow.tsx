import { memo, useLayoutEffect, useRef } from "react";
import { post } from "../lib/bridge";
import type { FontBoxes, Glyph, HeaderRowPayload } from "../lib/types";

// MyTasksHeaderView: 34pt first header, 52pt for the rest (18pt group
// spacer above a 34pt header). Toggles on mouse DOWN, like the native view.

interface Props {
  row: HeaderRowPayload;
  fonts: FontBoxes;
  chevron?: Glyph;
  register(key: string, element: HTMLElement | null): void;
}

export const HeaderRow = memo(function HeaderRow({ row, fonts, chevron, register }: Props) {
  const height = row.first ? 34 : 52;
  const centerY = row.first ? height / 2 : 18 + 17;
  const key = `h:${row.id}`;
  const name = useRef<HTMLSpanElement>(null);
  // sizeToFit() rounds the title cell up to a device pixel, so the count
  // starts on a pixel boundary; CSS text width is fractional.
  useLayoutEffect(() => {
    const element = name.current;
    if (!element) return;
    element.style.width = "";
    const scale = window.devicePixelRatio || 2;
    element.style.width = `${Math.ceil(element.getBoundingClientRect().width * scale) / scale}px`;
  }, [row.title, fonts]);
  return (
    <div
      ref={(element) => register(key, element)}
      className="hrow"
      data-key={key}
      style={{ height }}
      role="button"
      aria-expanded={!row.collapsed}
      onMouseDown={(event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        post({ type: "toggle", status: row.status });
      }}
    >
      {chevron && (
        <span className="chevron" style={{ top: centerY - 6 }}>
          <span
            className="glyph"
            style={{
              width: chevron.width,
              height: chevron.height,
              WebkitMaskImage: `url(${chevron.url})`,
              maskImage: `url(${chevron.url})`,
            }}
          />
        </span>
      )}
      <span className="htitle" style={{ top: 0 }}>
        <span ref={name} className="name" style={{ color: row.color, marginTop: centerY - fonts.headerTitle / 2 }}>
          {row.title}
        </span>
        <span className="count" style={{ marginTop: centerY - fonts.headerCount / 2 }}>
          {row.count}
        </span>
      </span>
      <span className="hrule" />
    </div>
  );
});

interface SlotProps {
  title: string;
  color: string;
  sc: string;
  width: number;
  labelHeight: number;
}

/** MyTasksDropPlaceholderView — "SOLTAR EM <STATUS>". */
export const DropSlot = memo(function DropSlot({ title, color, sc, width, labelHeight }: SlotProps) {
  const rectWidth = Math.max(0, width - 88);
  return (
    <div className="slot" data-key="d:slot" style={{ color }}>
      <svg width={width} height={36} aria-hidden="true">
        <rect
          x={44}
          y={4}
          width={rectWidth}
          height={28}
          rx={9}
          ry={9}
          fill={`color(display-p3 ${sc} / 0.055)`}
          stroke={`color(display-p3 ${sc} / 0.68)`}
          strokeWidth={1}
          strokeDasharray="5 4"
        />
        <circle cx={44 + 13 + 3} cy={18} r={3} fill={color} />
      </svg>
      <span className="slot-label" style={{ top: 18 - labelHeight / 2, height: labelHeight }}>
        SOLTAR EM {title}
      </span>
    </div>
  );
});
