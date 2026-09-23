import { Bone } from "../components/Bone";
import { Elapsed } from "../components/Elapsed";
import { Metric } from "../components/Metric";
import { MoonPhase } from "../components/MoonPhase";
import { ProgressRail } from "../components/ProgressRail";
import { StepsInline } from "../components/Steps";
import { replay, seeded, useArrivals, useCreep } from "../lib/motion";
import type { Snapshot } from "../lib/types";
import { fitting, useViewport } from "../lib/viewport";
import { tone } from "./TasksScene";

// Quadro — "columns filling up".
//
// Ghost cards sit exactly where the native columns will draw the real ones
// (geometry from `BoardViewportView`), as many whole cards as fit above the
// capsule. They land
// column by column, card by card; a glint then crosses the board as one
// diagonal wave (column delay + card delay + element delay). Each column has
// an intake line from its header: while cards are being fetched a packet of
// light runs down it, and every batch that lands makes the cards settle in
// sequence. Card status dots take their column's colour once the structure
// is known. A floating capsule, centred in the visible canvas, reports the
// sync.

const CARD = 106;
const CARD_GAP = 12;
/** Capsule (64) + its bottom margin (28) + breathing room (16): cards stop
 *  above it instead of running underneath. Mirrored in Swift. */
const CAPSULE_RESERVE = 108;
const DEFAULT_GEOMETRY = { top: 150, leading: 220, columnX: 258, columnWidth: 260, columnGap: 20, cardWidth: 240 };

export function BoardScene({ s }: { s: Snapshot }) {
  const progress = useCreep(s.progress, s.ceiling);
  const settle = useArrivals(s.metric?.value);
  const { h } = useViewport();
  const g = s.geometry ?? DEFAULT_GEOMETRY;
  const columns = s.columns.length > 0 ? s.columns : Array.from({ length: 5 }, () => null);
  const cards = fitting(h - CAPSULE_RESERVE, g.top, CARD, CARD_GAP);
  const fetching = s.steps.some((step) => step.id === "tasks" && step.state === "active");

  return (
    <main
      className="scene scene-board"
      style={{ ["--canvas-leading" as string]: `${g.leading}px` }}
      data-offline={!s.online || undefined}
    >
      {columns.map((column, c) => {
        const x = g.columnX + c * (g.columnWidth + g.columnGap) + (g.columnWidth - g.cardWidth) / 2;
        return (
          <div
            key={c}
            className="board-column"
            style={{
              left: x,
              top: g.top,
              width: g.cardWidth,
              ["--col" as string]: c,
              ["--status" as string]: column?.color ?? "transparent",
            }}
            data-known={column?.name ? true : undefined}
          >
            <span className="intake" data-live={fetching || undefined} aria-hidden />
            {Array.from({ length: cards }, (_, k) => {
              const n = c * 31 + k;
              return (
                <div
                  key={k}
                  className="ghost-card"
                  data-settle={replay(settle)}
                  style={{ ["--k" as string]: k, ["--r" as string]: c * 2 + k * 3 }}
                >
                  <div className="card-crumb">
                    <i className="card-dot" />
                    <Bone w={Math.round(90 + seeded(n) * 50)} h={8} r={3} tone="secondary" c={1} />
                  </div>
                  <div className="card-title">
                    <Bone h={13} r={3} c={2} />
                    <Bone w={Math.round(110 + seeded(n + 5) * 70)} h={13} r={3} c={3} />
                  </div>
                  <div className="card-footer">
                    <Bone h={18} round c={4} />
                    <Bone w={60} h={9} r={3} tone="secondary" c={5} />
                    <span className="row-spacer" />
                    <Bone w={48} h={9} r={3} tone="faint" c={6} />
                  </div>
                </div>
              );
            })}
          </div>
        );
      })}

      <aside className="board-capsule">
        <MoonPhase value={progress} tone={tone(s)} size={24} />
        <div className="console-text">
          <h1 className="headline">{s.headline}</h1>
          {s.context && <p className="context">{s.context}</p>}
        </div>
        <span className="capsule-rule" />
        <div className="capsule-steps">
          <ProgressRail steps={s.steps} value={progress} />
          <StepsInline steps={s.steps.filter((step) => step.id !== "account")} />
        </div>
        <span className="capsule-rule" />
        <div className="console-aside">
          <Metric value={s.metric?.value ?? 0} label={s.metric?.label ?? "cartões"} />
          <Elapsed since={s.startedAt} />
        </div>
      </aside>
    </main>
  );
}
