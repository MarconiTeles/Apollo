import { Bone } from "../components/Bone";
import { Metric } from "../components/Metric";
import { ProgressRail } from "../components/ProgressRail";
import { StepsInline } from "../components/Steps";
import { formatCount } from "../lib/format";
import { seeded, useCreep, useFollow } from "../lib/motion";
import type { Snapshot } from "../lib/types";
import { fitting, useViewport } from "../lib/viewport";
import { tone } from "./TasksScene";

// Comentários — "reading the conversations".
//
// This is the one surface with a determinate answer: Apollo reads a known
// window of recently active tasks, so the ring shows exactly how many were
// read out of how many. Below, conversation cards mirror the real ones; the
// first unread one is "being read" (a typing cadence in its bubble), and
// every comment already found marks one card with an accent spine — the
// number of marked cards *is* the count found so far. As many whole cards
// as the window holds cascade in, and a glint travels down them element by element.

/** Console (100) + gap (12), mirrored by the native fallback. */
const TOP = 112;
const CARD = 116;
const CARD_GAP = 12;

export function CommentsScene({ s }: { s: Snapshot }) {
  const progress = useCreep(s.progress, s.ceiling);
  const scanned = s.scan ? s.scan.done / Math.max(1, s.scan.target) : 0;
  const ring = useFollow(Math.min(1, scanned), 0.2);
  const found = s.metric?.value ?? 0;
  const reading = s.steps.some((step) => step.id === "read" && step.state === "active");
  const { h } = useViewport();
  const cards = fitting(h, TOP, CARD, CARD_GAP);

  const R = 19;
  const C = 2 * Math.PI * R;

  return (
    <main className="scene scene-comments" data-offline={!s.online || undefined}>
      <header className="comments-console" data-tone={tone(s)}>
        <span className="scan-ring" aria-hidden>
          <svg viewBox="0 0 48 48">
            <circle className="ring-track" cx="24" cy="24" r={R} />
            {s.scan ? (
              <>
                <circle className="ring-arc" cx="24" cy="24" r={R} strokeDasharray={`${ring * C} ${C}`} />
                {/* The reading tip: a lit point riding the arc's leading end. */}
                <circle
                  className="ring-tip"
                  cx={24 + R * Math.cos(ring * 2 * Math.PI)}
                  cy={24 + R * Math.sin(ring * 2 * Math.PI)}
                  r="2.6"
                />
              </>
            ) : (
              <circle className="ring-seek" cx="24" cy="24" r={R} strokeDasharray={`${C * 0.18} ${C}`} />
            )}
          </svg>
          <span className="ring-count">{s.scan ? formatCount(s.scan.done) : "—"}</span>
        </span>
        <div className="console-text">
          <h1 className="headline">{s.headline}</h1>
          <p className="context">
            ¶ {s.context}
            {s.scan && ` · ${formatCount(s.scan.done)} de ${formatCount(s.scan.target)} tarefas`}
          </p>
          <StepsInline steps={s.steps} />
        </div>
        <div className="console-aside">
          <Metric value={found} label={s.metric?.label ?? "encontrados"} />
        </div>
        <div className="comments-rail">
          <ProgressRail steps={s.steps} value={progress} />
        </div>
      </header>

      <section className="comment-cards" aria-hidden>
        {Array.from({ length: cards }, (_, i) => {
          // found → already matched · reading → the conversation being read
          // right now (the next one after the matches) · queued → waiting.
          const state = i < found ? "found" : reading && i === Math.min(found, cards - 1) ? "reading" : "queued";
          return (
            <article
              key={i}
              className="comment-card"
              data-state={state}
              style={{ ["--i" as string]: i, ["--r" as string]: i * 3 }}
            >
              <div className="comment-top">
                <Bone h={8} round />
                <Bone w={Math.round(120 + seeded(i) * 70)} h={11} c={1} />
                <span className="row-spacer" />
                {state === "found" ? (
                  <span className="found-seal">
                    <svg viewBox="0 0 12 12" aria-hidden>
                      <path d="M3 6.3 L5.1 8.3 L9 4" />
                    </svg>
                  </span>
                ) : (
                  <Bone w={88} h={22} r={7} tone="secondary" c={6} />
                )}
              </div>
              <div className="comment-body">
                <Bone h={34} round className="comment-avatar" c={1} />
                <div className="comment-lines">
                  <Bone w={Math.round(96 + seeded(i + 4) * 50)} h={10} c={2} />
                  <div className="bubble">
                    <Bone className="bubble-line" w={`${78 + seeded(i + 7) * 18}%`} h={7} r={3.5} c={3} />
                    <Bone className="bubble-line" w={`${38 + seeded(i + 9) * 30}%`} h={7} r={3.5} c={4} />
                    {state === "reading" && (
                      <span className="typing">
                        <i />
                        <i />
                        <i />
                      </span>
                    )}
                  </div>
                </div>
              </div>
              {state === "reading" && <span className="read-head" />}
            </article>
          );
        })}
      </section>
    </main>
  );
}
