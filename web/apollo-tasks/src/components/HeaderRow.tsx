import { memo, useLayoutEffect, useRef } from "react";
import { post } from "../lib/bridge";
import { HEADER_BAND, headerSpacer } from "../lib/geometry";
import type { FontBoxes, Glyph, HeaderRowPayload } from "../lib/types";

// MyTasksHeaderView, split in two: the group spacer (18pt, 10pt for an empty
// group, none for the first) and the 34pt band that sticks under the page
// header while its group scrolls. Both toggle on mouse DOWN, like the native
// view.

interface Props {
  row: HeaderRowPayload;
  fonts: FontBoxes;
  chevron?: Glyph;
  register(key: string, element: HTMLElement | null): void;
}

const CENTER_Y = HEADER_BAND / 2;

export const HeaderRow = memo(function HeaderRow({ row, fonts, chevron, register }: Props) {
  const key = `h:${row.id}`;
  const spacer = headerSpacer(row);
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
  const toggle = (event: React.MouseEvent) => {
    if (event.button !== 0) return;
    event.preventDefault();
    post({ type: "toggle", status: row.status });
  };
  const empty = row.count === 0;
  return (
    <>
      {spacer > 0 && <div className="gspace" style={{ height: spacer }} onMouseDown={toggle} />}
      <div
        ref={(element) => register(key, element)}
        className={`hrow${empty ? " empty" : ""}`}
        data-key={key}
        role="button"
        aria-expanded={!row.collapsed}
        onMouseDown={toggle}
      >
        {chevron && (
          <span className={`chevron${row.collapsed ? "" : " open"}`} style={{ top: CENTER_Y - 6 }}>
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
          <span ref={name} className="name" style={{ color: row.color, marginTop: CENTER_Y - fonts.headerTitle / 2 }}>
            {row.title}
          </span>
          <span className="count" style={{ marginTop: CENTER_Y - fonts.headerCount / 2 }}>
            {row.count}
          </span>
          {row.collapsed && row.overdue > 0 && (
            <span className="summary" style={{ marginTop: CENTER_Y - fonts.headerCount / 2 }}>
              · {row.overdue} {row.overdue === 1 ? "atrasada" : "atrasadas"}
            </span>
          )}
        </span>
        <span className="hrule" />
      </div>
    </>
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
