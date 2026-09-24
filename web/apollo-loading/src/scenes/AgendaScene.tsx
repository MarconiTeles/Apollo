import { useMemo } from "react";
import { Bone } from "../components/Bone";
import { replay, seeded, useArrivals } from "../lib/motion";
import type { Snapshot } from "../lib/types";
import { useViewport } from "../lib/viewport";

// Agenda — "the days being laid out".
//
// Shapes only (no words, numbers or progress). The events column holds the
// days: a date marker and its event capsules, stacked the way the
// real timeline stacks them, only whole capsules above the bottom edge. On
// the right the month assembles itself cell by cell (a diagonal wave from
// the first Monday) with the day panel below. Every batch of events that
// lands sends one band of light down the capsules.
//
// Geometry mirrors the native agenda (AgendaLayout, AgendaReactBody) and
// its lunar fallback (`AgendaLoadingPlaceholder`), so the cross-fade never
// moves a shape.

const CONSOLE = 0; // no text block (AgendaLoadingPlaceholder.consoleReserve)
const CARD = 47;
const CARD_GAP = 6;
const GROUP_GAP = 18;
const MONTH_GAP = 6.5;
const CELL_H = 51;

/** Day groups of 3, 4, then 3s — whole capsules only (Swift: groups(height:top:)). */
function agendaGroups(height: number, top: number) {
  const groups: number[] = [];
  let y = top;
  for (;;) {
    const wanted = groups.length === 0 ? 3 : groups.length === 1 ? 4 : 3;
    if (groups.length) y += GROUP_GAP;
    const fit = Math.floor((height - y + CARD_GAP) / (CARD + CARD_GAP));
    if (fit <= 0) break;
    const rows = Math.min(wanted, fit);
    groups.push(rows);
    y += rows * (CARD + CARD_GAP) - CARD_GAP;
    if (rows < wanted) break;
  }
  return groups;
}

export function AgendaScene({ s }: { s: Snapshot }) {
  const wave = useArrivals(s.metric?.value);
  const { w, h } = useViewport();
  const eventsTop = s.agenda?.eventsTop ?? 106;
  const monthTop = s.agenda?.monthTop ?? 106;
  const split = Math.min(440, w * 0.43);
  const groups = useMemo(() => agendaGroups(h - 24, eventsTop + CONSOLE), [h, eventsTop]);
  const monthLeft = split + 17;
  const monthWidth = Math.max(0, w - monthLeft - 12);
  const cell = Math.max(0, (monthWidth - 6 * MONTH_GAP) / 7);
  const receiving = s.metric != null;

  let row = 0;
  return (
    <main className="scene scene-agenda" data-offline={!s.online || undefined}>
      <section className="agenda-timeline" style={{ top: eventsTop, width: split }}>

        <div className="agenda-days" aria-hidden>
          {groups.map((count, g) => {
            const marker = row;
            return (
              <div key={g} className="agenda-day">
                <div className="day-marker" style={{ ["--r" as string]: marker }}>
                  <Bone w={26} h={7} r={3} tone="secondary" />
                  <Bone w={30} h={22} r={5} c={1} />
                </div>
                <div className="day-cards">
                  {Array.from({ length: count }, () => {
                    const i = row++;
                    return (
                      <div
                        key={i}
                        className="event-capsule"
                        data-wave={replay(wave)}
                        data-lit={receiving || undefined}
                        style={{ ["--i" as string]: i, ["--r" as string]: i }}
                      >
                        <span className="event-lines">
                          <Bone w={`${48 + seeded(i + 3) * 36}%`} h={11} c={2} />
                          <Bone w={`${30 + seeded(i + 7) * 24}%`} h={8} tone="secondary" c={3} />
                        </span>
                        <Bone h={26} round c={5} />
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      <section
        className="agenda-month"
        aria-hidden
        style={{ top: monthTop + 8, left: monthLeft, width: monthWidth, bottom: 24 }}
      >
        <div className="month-weekdays" style={{ gap: MONTH_GAP }}>
          {Array.from({ length: 7 }, (_, d) => (
            <span key={d} style={{ width: cell, ["--r" as string]: 0 }}>
              <Bone w={22} h={7} r={3} tone="secondary" c={d} />
            </span>
          ))}
        </div>
        <div className="month-grid" style={{ gap: MONTH_GAP, gridTemplateColumns: `repeat(7, ${cell}px)` }}>
          {Array.from({ length: 35 }, (_, i) => {
            const r = Math.floor(i / 7);
            const c = i % 7;
            return (
              <div
                key={i}
                className="month-cell"
                style={{ height: CELL_H, ["--i" as string]: r + c, ["--r" as string]: r + 1 }}
              >
                <Bone w={14} h={9} r={3} c={c} />
                {seeded(i + 31) > 0.62 && <Bone w={34} h={14} r={7} tone="faint" c={c + 1} />}
              </div>
            );
          })}
        </div>
        <div className="day-panel" style={{ ["--r" as string]: 7 }}>
          <Bone w={150} h={8} r={3} tone="secondary" />
          {Array.from({ length: 3 }, (_, i) => (
            <div key={i} className="panel-row" style={{ ["--r" as string]: 8 + i }}>
              <span className="panel-time">
                <Bone w={34} h={11} c={1} />
                <Bone w={26} h={8} tone="secondary" c={2} />
              </span>
              <span className="panel-bar" />
              <span className="panel-lines">
                <Bone w={`${52 + seeded(i + 41) * 30}%`} h={11} c={3} />
                <Bone w={96} h={16} r={8} tone="faint" c={4} />
              </span>
              <Bone h={26} round c={6} />
            </div>
          ))}
        </div>
      </section>
    </main>
  );
}
