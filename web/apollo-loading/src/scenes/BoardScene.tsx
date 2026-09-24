import { Bone } from "../components/Bone";
import { replay, seeded, useArrivals } from "../lib/motion";
import type { Snapshot } from "../lib/types";
import { fitting, useViewport } from "../lib/viewport";

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
// is known. No words or numbers: shapes and light only.

const CARD = 106; // native board card (SyncLoadingLayout.boardCard)
const CARD_GAP = 12;
/** Bottom margin of the lanes (no status capsule). Mirrored in Swift. */
const CAPSULE_RESERVE = 24;
const DEFAULT_GEOMETRY: NonNullable<Snapshot["geometry"]> = { top: 150, leading: 220, columnX: 258, columnWidth: 260, columnGap: 20, cardWidth: 240 };

export function BoardScene({ s }: { s: Snapshot }) {
  const settle = useArrivals(s.metric?.value);
  const { h } = useViewport();
  const g = s.geometry ?? DEFAULT_GEOMETRY;
  const columns = s.columns.length > 0 ? s.columns : Array.from({ length: 5 }, () => null);
  const cardHeight = g.cardHeight ?? CARD;
  const cards = fitting(h - CAPSULE_RESERVE, g.top, cardHeight, CARD_GAP);
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
                  {g.indicators && (
                    <div className="card-indicators">
                      <Bone w={12} h={10} r={3} tone="faint" c={4} />
                      <Bone w={22} h={10} r={3} tone="faint" c={5} />
                    </div>
                  )}
                  <div className="card-footer">
                    <Bone h={18} round c={6} />
                    <Bone w={60} h={9} r={3} tone="secondary" c={7} />
                    <span className="row-spacer" />
                    <Bone w={48} h={9} r={3} tone="faint" c={8} />
                  </div>
                </div>
              );
            })}
          </div>
        );
      })}

    </main>
  );
}
