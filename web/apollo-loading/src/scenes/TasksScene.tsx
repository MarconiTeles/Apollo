import { useMemo } from "react";
import { Bone } from "../components/Bone";
import { Elapsed } from "../components/Elapsed";
import { Metric } from "../components/Metric";
import { MoonPhase } from "../components/MoonPhase";
import { ProgressRail } from "../components/ProgressRail";
import { StepsInline } from "../components/Steps";
import { replay, seeded, useArrivals, useCreep } from "../lib/motion";
import type { Snapshot } from "../lib/types";
import { taskGroups, useViewport } from "../lib/viewport";

// Tarefas — "the list being written".
//
// Above: the account of the sync — the moon waxing with real progress, the
// steps in plain words, the task count as it streams in. Below: the list,
// status group after status group down to the window's bottom edge — only
// whole rows, never one cut by the edge.
//
// The body is never still and never random: rows cascade in on arrival, a
// glint runs through every row element by element (row delay × column
// delay, one diagonal wave), the list's real status names replace the
// header bones as soon as they are known, and once tasks start landing each
// row's status ring lights up in its group's colour, one row after another.
// Every page of tasks that lands sends one band of light down the rows.

/** Console block height, mirrored by `MyTasksLoadingPlaceholder.consoleReserve`. */
const CONSOLE = 93;

export function TasksScene({ s }: { s: Snapshot }) {
  const progress = useCreep(s.progress, s.ceiling);
  const wave = useArrivals(s.metric?.value);
  const { h } = useViewport();
  const groups = useMemo(() => taskGroups(h, CONSOLE), [h]);
  const receiving = s.metric != null;

  let row = 0;
  return (
    <main className="scene scene-tasks" data-offline={!s.online || undefined}>
      <header className="console">
        <MoonPhase value={progress} tone={tone(s)} />
        <div className="console-text">
          <h1 className="headline">{s.headline}</h1>
          {s.context && <p className="context">¶ {s.context}</p>}
        </div>
        <div className="console-aside">
          {s.metric && <Metric value={s.metric.value} label={s.metric.label} />}
          <Elapsed since={s.startedAt} />
        </div>
      </header>
      <ProgressRail steps={s.steps} value={progress} />
      <StepsInline steps={s.steps} />

      <section className="task-groups" aria-hidden>
        {groups.map((count, g) => {
          // Only real statuses get a name; groups past the list's status count
          // stay anonymous rather than repeat one.
          const status = s.columns[g];
          const headerRow = row++;
          return (
            <div key={g} className="task-group" style={{ ["--status" as string]: status?.color ?? "var(--ink-faint)" }}>
              <div className="group-header" style={{ ["--r" as string]: headerRow }}>
                <Bone w={10} h={6} r={2} />
                {status ? (
                  <span className="status-name" key={status.name}>
                    <i className="status-dot" />
                    {status.name}
                  </span>
                ) : (
                  <>
                    <Bone h={7} round c={1} />
                    <Bone w={g % 2 ? 76 : 96} h={9} r={3} c={2} />
                    <Bone w={20} h={9} r={3} tone="secondary" c={3} />
                  </>
                )}
              </div>
              {Array.from({ length: count }, () => {
                const i = row++;
                return (
                  <div
                    key={i}
                    className="task-row"
                    data-wave={replay(wave)}
                    data-lit={receiving || undefined}
                    style={{ ["--i" as string]: i, ["--r" as string]: i }}
                  >
                    <span className="row-status" />
                    <Bone w={`${52 + seeded(i) * 34}%`} h={12} style={{ maxWidth: 390 }} c={1} />
                    <span className="row-spacer" />
                    <Bone w={74} h={9} tone="secondary" c={4} />
                    <span className="row-assignee">
                      <Bone h={20} round c={5} />
                      <Bone w={50 + seeded(i + 9) * 22} h={10} c={6} />
                    </span>
                    <span className="row-due">
                      <Bone w={54} h={9} tone="secondary" c={7} />
                    </span>
                    <Bone h={4} round c={8} />
                  </div>
                );
              })}
            </div>
          );
        })}
      </section>
    </main>
  );
}

export function tone(s: Snapshot): "live" | "failed" | "offline" {
  if (!s.online) return "offline";
  return s.steps.some((step) => step.state === "failed") ? "failed" : "live";
}
