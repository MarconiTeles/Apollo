import { useCallback, useEffect, useLayoutEffect, useState, useSyncExternalStore } from "react";
import { Month } from "./components/Month";
import { Timeline } from "./components/Timeline";
import { post } from "./lib/bridge";
import { setOcclusion } from "./lib/interaction";
import { ShadowFilters } from "./lib/squircle";
import { read, subscribe } from "./lib/store";

/** AgendaLayout.timelineWidth — computed here so live resize needs no round trip. */
const timelineWidth = (width: number) => Math.min(440, width * 0.43);

export function App() {
  const state = useSyncExternalStore(subscribe, read);
  const [width, setWidth] = useState(() => document.documentElement.clientWidth);
  const [selectedDay, setSelectedDay] = useState<string | null>(null);

  useLayoutEffect(() => {
    const root = document.documentElement;
    for (const [name, value] of Object.entries(state.theme)) root.style.setProperty(`--${name}`, value);
    root.classList.toggle("dark", state.dark);
  }, [state.theme, state.dark]);

  useLayoutEffect(() => {
    const root = document.documentElement.style;
    for (const [name, value] of Object.entries(state.metrics)) {
      if (name.endsWith("-dy")) root.setProperty(`--dy-${name.slice(0, -3)}`, `${value}px`);
      else root.setProperty(`--lh-${name}`, `${value}px`);
    }
  }, [state.metrics]);

  useLayoutEffect(() => setOcclusion(state.layout.occlusion), [state.layout.occlusion]);

  useEffect(() => {
    const onResize = () => setWidth(document.documentElement.clientWidth);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  // "Hoje": today selected in the grid (AgendaMonthView todayJumpToken).
  useLayoutEffect(() => {
    if (state.todayToken > 0 && state.month) {
      const today = state.month.cells.find((cell) => cell.today);
      setSelectedDay(today ? today.key : null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.todayToken]);

  // Reveal handshake: Swift keeps the web view hidden until this paints.
  useEffect(() => {
    const seq = state.seq;
    requestAnimationFrame(() => post({ type: "rendered", seq }));
  }, [state.seq]);

  const onSelect = useCallback((key: string) => setSelectedDay(key), []);
  const left = timelineWidth(Math.max(1, width));

  return (
    <div className={`agenda${state.reduceMotion ? " reduce-motion" : ""}`}>
      <ShadowFilters />
      <div className="column-left" style={{ width: left }}>
        <Timeline
          days={state.timeline}
          top={state.layout.agendaTop}
          scroll={state.scroll}
          reduceMotion={state.reduceMotion}
        />
        <div className="timeline-fade" />
      </div>
      <div className="divider" style={{ left }} />
      <div className="column-right" style={{ left: left + 1 }}>
        {state.month && (
          <Month
            month={state.month}
            top={state.layout.monthTop}
            error={state.error}
            glyphs={state.glyphs}
            selectedDay={selectedDay}
            onSelect={onSelect}
          />
        )}
      </div>
    </div>
  );
}
