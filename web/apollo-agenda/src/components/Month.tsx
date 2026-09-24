import { memo, useLayoutEffect, useRef, useState } from "react";
import { post } from "../lib/bridge";
import { Squircle, useBoxSize } from "../lib/squircle";
import { BoxText } from "./BoxText";
import { People } from "./People";
import type { EventPayload, Glyph, MonthCell, MonthPayload } from "../lib/types";

// AgendaMonthView: weekday header, month grid of filled tiles with stacked
// event discs, and the selected day's panel. Sizes follow the native
// GeometryReader math one for one.

const WEEKDAYS = ["SEG", "TER", "QUA", "QUI", "SEX", "SÁB", "DOM"];
const WEEKDAY_ROW = 26;
const SECTION_GAP = 20;
const CELL_GAP = 6;
const MIN_ROW = 50;
const MIN_PANEL = 220;
const GRID_SHARE = 0.51;
const BANNER = 38;

const DOT = 14;
const DISC = DOT + 3;
const OVERLAP = 4;

function Disc({ event, size, ring }: { event: EventPayload; size: number; ring: boolean }) {
  return (
    <span
      className={`disc${ring ? " ring" : ""}`}
      style={{ "--size": `${size}px`, "--glyph": `var(--lh-disc${size})`, "--glyph-dy": `var(--dy-disc${size})` } as React.CSSProperties}
    >
      <span className="disc-fill" style={{ background: event.dot }}>
        <span className={`disc-letter${event.darkInk ? " dark-ink" : ""}`}>{event.monogram}</span>
      </span>
    </span>
  );
}

/** AgendaDayCell.visibleSlotCount for a stack of the given width. */
const slotsFor = (width: number) => Math.max(1, Math.floor((width - DISC) / (DISC - OVERLAP)) + 1);

function DotStack({ events, width }: { events: EventPayload[]; width: number }) {
  const slots = slotsFor(width);
  const shown = events.length <= slots ? events : events.slice(0, Math.max(0, slots - 1));
  const more = events.length - shown.length;
  const count = shown.length + (more > 0 ? 1 : 0);
  // AgendaDotStack.step: preferred overlap, tighter only when it must fit.
  const step = count > 1 ? Math.max(1, Math.min(DISC - OVERLAP, (width - DISC) / (count - 1))) : DISC - OVERLAP;
  return (
    <div className="dots">
      {shown.map((event, index) => (
        <span key={event.key} className="dot-slot" style={{ left: index * step, zIndex: events.length - index }}>
          <Disc event={event} size={DOT} ring />
        </span>
      ))}
      {more > 0 && (
        <span className="dot-slot" style={{ left: shown.length * step, zIndex: events.length + 1 }}>
          <span className="disc ring" style={{ "--size": `${DOT}px` } as React.CSSProperties}>
            {/* AgendaMoreDot: inkSoft disc, page-coloured count */}
            <span className="disc-fill more">
              <span className={`disc-more${more > 9 ? " small" : ""}`} style={{ fontSize: more > 9 ? DOT * 0.42 : DOT * 0.5 }}>
                +{more}
              </span>
            </span>
          </span>
        </span>
      )}
    </div>
  );
}

interface CellProps {
  cell: MonthCell;
  height: number;
  stackWidth: number;
  selected: boolean;
  onSelect: (key: string) => void;
}

const DayCell = memo(function DayCell({ cell, height, stackWidth, selected, onSelect }: CellProps) {
  const classes = ["cell"];
  if (cell.inMonth) classes.push("in-month");
  if (cell.today) classes.push("today");
  if (selected) classes.push("selected");
  const [ref, size] = useBoxSize<HTMLDivElement>();
  return (
    <div
      ref={ref}
      className={classes.join(" ")}
      style={{ height }}
      title={cell.tooltip || undefined}
      role="button"
      aria-label={cell.a11y}
      onClick={() => onSelect(cell.key)}
    >
      <Squircle width={size.width} height={size.height} radius={10} className="cell-base" />
      <Squircle width={size.width} height={size.height} radius={10} className="cell-selection" />
      <div className="cell-content">
        <div className="cell-head">
          <span className="cell-number">
            <span>{cell.number}</span>
          </span>
          {cell.monthLabel && <span className="cell-month">{cell.monthLabel}</span>}
        </div>
        {cell.events.length > 0 && <DotStack events={cell.events} width={stackWidth} />}
      </div>
    </div>
  );
});

function Mask({ glyph, className }: { glyph?: Glyph; className: string }) {
  if (!glyph) return null;
  return (
    <span
      className={className}
      style={{
        width: glyph.width,
        height: glyph.height,
        WebkitMaskImage: `url(${glyph.url})`,
        maskImage: `url(${glyph.url})`,
      }}
    />
  );
}

const PanelRow = memo(function PanelRow({ event, glyphs }: { event: EventPayload; glyphs: Record<string, Glyph> }) {
  const [ref, size] = useBoxSize<HTMLButtonElement>();
  const classes = ["prow"];
  if (event.phase) classes.push(event.phase);
  if (event.declined) classes.push("declined");
  return (
    <button ref={ref} type="button" className={classes.join(" ")}
            onClick={() => post({ type: "openMonth", key: event.key })}>
      <Squircle width={size.width} height={size.height} radius={10} className="prow-hover" />
      <span className="prow-time">
        <span className="prow-start">{event.start}</span>
        <span className="prow-end">{event.end}</span>
      </span>
      <span className="prow-bar" style={{ background: event.dot }} />
      <span className="prow-main">
        <span className="prow-title">{event.title}</span>
        {(event.location || event.phase === "now") && (
          <span className="prow-tags">
            {event.phase === "now" && <span className="tag now">Agora</span>}
            {event.location && (
              <span className="tag place" title={event.location}>
                <Mask glyph={glyphs.pin} className="tag-icon" />
                <span className="tag-text">{event.location}</span>
              </span>
            )}
          </span>
        )}
      </span>
      <People people={event.people} />
      {event.join && (
        <span
          className="join"
          role="button"
          title="Entrar na reunião"
          onClick={(e) => {
            e.stopPropagation();
            post({ type: "join", key: event.key });
          }}
        >
          <Mask glyph={glyphs.video} className="join-icon" />
          {event.join.label}
        </span>
      )}
    </button>
  );
});

function DayPanel({ cell, height, glyphs }: { cell: MonthCell; height: number; glyphs: Record<string, Glyph> }) {
  const [ref, size] = useBoxSize<HTMLDivElement>();
  return (
    <div ref={ref} className="panel" style={{ height }}>
      <Squircle width={size.width} height={size.height} radius={12} className="panel-bg" />
      <div className="panel-head">
        <span className="folio">{cell.title}</span>
        <BoxText className="panel-relative">{cell.relative}</BoxText>
      </div>
      {cell.events.length === 0 ? (
        <div className="panel-empty" key={`empty-${cell.key}`}>
          Nenhum compromisso neste dia.
        </div>
      ) : (
        <div className="panel-list" key={cell.key}>
          <div className="panel-stack">
            {cell.events.map((event) => (
              <PanelRow key={event.key} event={event} glyphs={glyphs} />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

interface MonthProps {
  month: MonthPayload;
  top: number;
  error: string | null;
  glyphs: Record<string, Glyph>;
  selectedDay: string | null;
  onSelect: (key: string) => void;
}

export function Month({ month, top, error, glyphs, selectedDay, onSelect }: MonthProps) {
  const column = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ width: 0, height: window.innerHeight });

  useLayoutEffect(() => {
    const element = column.current;
    if (!element) return;
    const measure = () => setSize({ width: element.clientWidth, height: element.clientHeight });
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  const weeks = month.cells.length / 7;
  const page = size.height - top - 16 - (error ? BANNER : 0);
  const rows = page * GRID_SHARE - WEEKDAY_ROW - (weeks - 1) * CELL_GAP;
  const rowHeight = Math.max(MIN_ROW, rows / weeks);
  const gridHeight = WEEKDAY_ROW + (weeks - 1) * CELL_GAP + rowHeight * weeks;
  const panelHeight = Math.max(MIN_PANEL, page - gridHeight - SECTION_GAP);
  // Tile width minus its 4pt padding and the stack's 3pt padding per side.
  const cellWidth = (size.width - 32 - 6 * CELL_GAP) / 7;
  const stackWidth = Math.max(0, cellWidth - 14);

  const focused =
    (selectedDay && month.cells.find((cell) => cell.key === selectedDay)) ||
    month.cells.find((cell) => cell.key === month.fallback) ||
    month.cells[0];

  const warning = glyphs.warning;
  return (
    <div className="month" ref={column} aria-label={month.title}>
      <div className="month-inner" style={{ paddingTop: top }}>
        {error && (
          <div className="banner">
            {warning && (
              <span
                className="banner-icon"
                style={{
                  width: warning.width,
                  height: warning.height,
                  WebkitMaskImage: `url(${warning.url})`,
                  maskImage: `url(${warning.url})`,
                }}
              />
            )}
            <span className="banner-text">{error}</span>
            <span className="banner-spacer" />
            <button type="button" className="banner-link" onClick={() => post({ type: "retry" })}>
              Tentar novamente
            </button>
          </div>
        )}
        <div className="month-scroll">
          <div className="month-stack">
            <div className="grid">
              <div className="weekdays">
                {WEEKDAYS.map((day, offset) => (
                  <span key={day} className={`weekday${offset >= 5 ? " weekend" : ""}`}>
                    {day}
                  </span>
                ))}
              </div>
              {Array.from({ length: weeks }, (_, week) => (
                <div className="week" key={week}>
                  {month.cells.slice(week * 7, week * 7 + 7).map((cell) => (
                    <DayCell
                      key={cell.key}
                      cell={cell}
                      height={rowHeight}
                      stackWidth={stackWidth}
                      selected={focused?.key === cell.key}
                      onSelect={onSelect}
                    />
                  ))}
                </div>
              ))}
            </div>
            {focused && <DayPanel cell={focused} height={panelHeight} glyphs={glyphs} />}
          </div>
        </div>
      </div>
    </div>
  );
}
