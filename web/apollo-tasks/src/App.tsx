import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { CSSProperties, DragEvent as ReactDragEvent } from "react";
import { DropSlot, HeaderRow } from "./components/HeaderRow";
import { TaskRow } from "./components/TaskRow";
import type { RowHandlers } from "./components/TaskRow";
import { post } from "./lib/bridge";
import {
  displayKey,
  encodeDragPayload,
  firstIndexIntersecting,
  metrics,
  offsetsFor,
  rowIndexAt,
} from "./lib/geometry";
import type { DisplayRow } from "./lib/geometry";
import { drawStackImage } from "./lib/dragImage";
import { EASE_OUT, prefersReducedMotion } from "./lib/motion";
import {
  msSinceScroll,
  onScroll,
  setDragging,
  setOcclusion,
  setWindowKey,
  resetInteraction,
  viewToClientY,
} from "./lib/interaction";
import { read, subscribe } from "./lib/store";
import type { HeaderRowPayload, RowPayload, TaskRowPayload } from "./lib/types";

/** Beyond this, offscreen rows skip style/layout/paint until scrolled near. */
const HUGE_LIST = 800;
/** Reflow of surviving rows: a response to a click, so a strong ease-out. */
const REFLOW_MS = 220;
const ENTER_MS = 200;
const ENTER_STAGGER_MS = 12;
const ENTER_STAGGER_CAP_MS = 120;
const EXIT_MS = 140;
const ARRIVAL_MS = 450;
const MAX_GHOSTS = 40;
/** MyTasksViewport's quiet period: no native bookkeeping while moving. */
const QUIET_MS = 350;

interface Ghost {
  key: string;
  row: TaskRowPayload;
  y: number;
}

const EMPTY_IDS: ReadonlySet<string> = new Set();
const ghostHandlers: RowHandlers = {
  register() {},
  dragStart(event) {
    event.preventDefault();
  },
  dragEnd() {},
};

export function App() {
  const state = useSyncExternalStore(subscribe, read);
  const [width, setWidth] = useState(() => document.documentElement.clientWidth);
  const [slotStatus, setSlotStatus] = useState<string | null>(null);
  const [fileDropId, setFileDropId] = useState<string | null>(null);
  const [draggingIds, setDraggingIds] = useState<ReadonlySet<string>>(EMPTY_IDS);
  const [ghosts, setGhosts] = useState<Ghost[]>([]);
  const ghostTimer = useRef<number | undefined>(undefined);
  const previousRows = useRef(new Map<string, RowPayload>());
  const listRef = useRef<HTMLDivElement>(null);
  const stackCanvas = useRef<HTMLCanvasElement>(null);
  const elements = useRef(new Map<string, HTMLElement>());
  const previousOffsets = useRef(new Map<string, number>());
  const lastRowsVersion = useRef(state.rowsVersion);
  const slotMotion = useRef(false);
  const downInControl = useRef(false);
  const slotClear = useRef<number | undefined>(undefined);

  const inert = state.popupOpen;
  const obscured = state.insets.mode === "obscured";
  // Obscured mode: WKWebView.obscuredContentInsets covers only the page
  // header (occlusion); the rest of the top inset is padding on the page.
  const obscuredTop = obscured ? state.insets.occlusion : 0;
  const contentTop = state.insets.top - obscuredTop;

  // ── Theme, fonts, insets ────────────────────────────────────────────
  useLayoutEffect(() => {
    const root = document.documentElement;
    for (const [name, value] of Object.entries(state.theme)) root.style.setProperty(`--${name}`, value);
    root.classList.toggle("dark", state.dark);
  }, [state.theme, state.dark]);

  useLayoutEffect(() => {
    const root = document.documentElement.style;
    const f = state.fonts;
    root.setProperty("--f-title", `${f.title}px`);
    root.setProperty("--f-priority", `${f.priority}px`);
    root.setProperty("--f-assignee", `${f.assignee}px`);
    root.setProperty("--f-date", `${f.date}px`);
    root.setProperty("--f-htitle", `${f.headerTitle}px`);
    root.setProperty("--f-hcount", `${f.headerCount}px`);
  }, [state.fonts]);

  useLayoutEffect(() => {
    setOcclusion(state.insets.occlusion, obscuredTop);
  }, [state.insets, obscuredTop]);

  useEffect(() => setWindowKey(state.windowKey), [state.windowKey]);
  useEffect(() => {
    if (inert) resetInteraction();
  }, [inert]);

  useEffect(() => {
    const onResize = () => setWidth(document.documentElement.clientWidth);
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  useLayoutEffect(() => {
    if (state.resetScrollToken > 0) window.scrollTo(0, 0);
  }, [state.resetScrollToken]);

  // ── Rows ────────────────────────────────────────────────────────────
  const displayRows = useMemo<DisplayRow[]>(() => {
    if (!slotStatus) return state.rows;
    const index = state.rows.findIndex((row) => row.k === "h" && row.status === slotStatus);
    if (index < 0) return state.rows;
    const header = state.rows[index] as HeaderRowPayload;
    const slot: DisplayRow = { k: "d", id: "slot", status: header.status, title: header.title, color: header.color };
    return [...state.rows.slice(0, index + 1), slot, ...state.rows.slice(index + 1)];
  }, [state.rows, slotStatus]);

  const offsets = useMemo(() => offsetsFor(displayRows, contentTop), [displayRows, contentTop]);
  const live = useRef({ displayRows, offsets, selected: state.selected, rows: state.rows });
  live.current = { displayRows, offsets, selected: state.selected, rows: state.rows };

  const register = useCallback((key: string, element: HTMLElement | null) => {
    if (element) elements.current.set(key, element);
    else elements.current.delete(key);
  }, []);

  const tileWindow = () => {
    const height = window.innerHeight + (obscured ? obscuredTop + state.insets.bottom : 0);
    const top = window.scrollY - obscuredTop;
    const overscan = Math.max(180, height * 0.5);
    return { top: top - overscan, bottom: top + height + overscan };
  };

  // Row motion after a store change (collapse/expand, status moves, filter
  // changes) or a drop-slot change:
  // • survivors slide from their old y (FLIP, like MyTasksViewport.apply);
  // • rows that appear fade down into place with a short, capped stagger;
  // • rows that vanish leave a ghost that fades out while the rest closes up;
  // • a task that changed status pulses once where it landed.
  // Only rows inside the tiled window animate; offscreen work is skipped.
  useLayoutEffect(() => {
    const storeChange = state.rowsVersion !== lastRowsVersion.current && state.animate;
    const animate = storeChange || slotMotion.current;
    lastRowsVersion.current = state.rowsVersion;
    slotMotion.current = false;
    const next = new Map<string, number>();
    displayRows.forEach((row, index) => next.set(displayKey(row), offsets[index]));
    const nextRows = new Map<string, RowPayload>();
    state.rows.forEach((row) => nextRows.set(`${row.k}:${row.id}`, row));
    if (animate) {
      const reduced = prefersReducedMotion();
      const { top, bottom } = tileWindow();
      const onScreen = (y: number) => y <= bottom && y + 52 >= top;
      let entering = 0;
      next.forEach((y, key) => {
        const element = elements.current.get(key);
        if (!element) return;
        const prior = previousOffsets.current.get(key);
        if (prior === undefined) {
          if (!storeChange || !onScreen(y)) return;
          const delay = Math.min(entering * ENTER_STAGGER_MS, ENTER_STAGGER_CAP_MS);
          entering += 1;
          element.animate(
            reduced
              ? [{ opacity: 0 }, { opacity: 1 }]
              : [
                  { opacity: 0, transform: "translateY(-6px)" },
                  { opacity: 1, transform: "none" },
                ],
            { duration: ENTER_MS, easing: EASE_OUT, delay, fill: "backwards" },
          );
          return;
        }
        if (prior === y || reduced || !onScreen(prior) || !onScreen(y)) return;
        element.getAnimations().forEach((animation) => animation.cancel());
        element.animate([{ transform: `translateY(${prior - y}px)` }, { transform: "none" }], {
          duration: REFLOW_MS,
          easing: EASE_OUT,
        });
      });
      if (storeChange) {
        const exits: Ghost[] = [];
        previousOffsets.current.forEach((y, key) => {
          if (next.has(key) || exits.length >= MAX_GHOSTS || !onScreen(y)) return;
          const row = previousRows.current.get(key);
          if (row?.k === "t") exits.push({ key, row, y });
        });
        if (exits.length) {
          window.clearTimeout(ghostTimer.current);
          setGhosts(exits);
          ghostTimer.current = window.setTimeout(() => setGhosts([]), EXIT_MS + 30);
        }
        const arrival = state.theme["accent-075"];
        nextRows.forEach((row, key) => {
          const before = previousRows.current.get(key);
          if (row.k !== "t" || before?.k !== "t" || before.status === row.status) return;
          const y = next.get(key);
          const background = elements.current.get(key)?.querySelector(".bg");
          if (!arrival || y === undefined || !onScreen(y) || !background) return;
          background.animate([{ backgroundColor: arrival }, { backgroundColor: "transparent" }], {
            duration: ARRIVAL_MS,
            easing: EASE_OUT,
          });
        });
      }
    }
    previousOffsets.current = next;
    previousRows.current = nextRows;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [displayRows, offsets]);

  // ── Visible rows → native review watching (bind/unbind parity) ─────
  useEffect(() => {
    let lastSent = "";
    let timer: number | undefined;
    const report = () => {
      timer = undefined;
      // Review watches start polling; keep that bookkeeping off the app's
      // main thread until the list has been still for the quiet period.
      const moving = QUIET_MS - msSinceScroll();
      if (moving > 0) {
        timer = window.setTimeout(report, moving);
        return;
      }
      const { displayRows: rows, offsets: ys } = live.current;
      const { top, bottom } = tileWindow();
      const ids: string[] = [];
      for (let i = firstIndexIntersecting(ys, rows.length, top); i < rows.length && ys[i] <= bottom; i++) {
        const row = rows[i];
        if (row.k === "t") ids.push(row.id);
      }
      const signature = ids.join("\u0000");
      if (signature === lastSent) return;
      lastSent = signature;
      post({ type: "visible", ids });
    };
    const schedule = () => {
      if (timer === undefined) timer = window.setTimeout(report, 120);
    };
    schedule();
    const stop = onScroll(schedule);
    window.addEventListener("resize", schedule);
    return () => {
      stop();
      window.removeEventListener("resize", schedule);
      if (timer !== undefined) clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [displayRows, offsets, state.insets]);

  // ── Ack every patch after it is painted (native reveal / sequencing) ─
  useEffect(() => {
    let second = 0;
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => post({ type: "rendered", seq: state.seq }));
    });
    return () => {
      cancelAnimationFrame(first);
      cancelAnimationFrame(second);
    };
  }, [state.seq]);

  // ── Native hooks (file drags from Finder are handled natively) ─────
  useEffect(() => {
    const api = window.apolloTasks;
    if (!api) return;
    api.taskAt = (_x: number, viewY: number) => {
      const { displayRows: rows, offsets: ys } = live.current;
      const docY = viewToClientY(viewY) + window.scrollY;
      const index = firstIndexIntersecting(ys, rows.length, docY);
      const row = rows[index];
      if (!row || docY < ys[index] || docY >= ys[index + 1]) return null;
      return row.k === "t" ? row.id : null;
    };
    api.setFileDrop = (id: string | null) => setFileDropId(id);
  }, []);

  useEffect(() => {
    const onDown = (event: MouseEvent) => {
      downInControl.current = event.target instanceof Element && event.target.closest("button") !== null;
    };
    document.addEventListener("mousedown", onDown, true);
    return () => document.removeEventListener("mousedown", onDown, true);
  }, []);

  // ── Task drags (HTML5 → native NSDraggingSession, string pasteboard) ─
  const updateSlot = useCallback((status: string | null) => {
    setSlotStatus((current) => {
      if (current !== status) slotMotion.current = true;
      return status;
    });
  }, []);

  const targetStatusAt = (clientY: number) => {
    const { displayRows: rows, offsets: ys } = live.current;
    const index = rowIndexAt(ys, rows.length, clientY + window.scrollY);
    if (index === null) return null;
    return rows[index].status;
  };

  const handlers = useMemo<RowHandlers>(
    () => ({
      register,
      dragStart(event, row: TaskRowPayload) {
        if (read().popupOpen || downInControl.current) {
          event.preventDefault();
          return;
        }
        const selected = live.current.selected;
        const ids = selected.has(row.id)
          ? live.current.rows.filter((r) => r.k === "t" && selected.has(r.id)).map((r) => r.id)
          : [row.id];
        event.dataTransfer.effectAllowed = "move";
        event.dataTransfer.setData("text/plain", encodeDragPayload(ids));
        if (ids.length > 1 && stackCanvas.current) {
          const bounds = event.currentTarget.getBoundingClientRect();
          const size = { width: Math.min(300, Math.max(240, bounds.width * 0.42)), height: 60 };
          drawStackImage(stackCanvas.current, ids.length, row.sc, size);
          const frameX = Math.max(0, bounds.width / 2 - size.width / 2);
          const frameY = bounds.height / 2 - size.height / 2;
          event.dataTransfer.setDragImage(
            stackCanvas.current,
            event.clientX - bounds.left - frameX,
            event.clientY - bounds.top - frameY,
          );
        }
        resetInteraction();
        setDragging(true);
        // After the drag image snapshot: dim the rows being carried.
        window.setTimeout(() => setDraggingIds(new Set(ids)), 0);
        post({ type: "dragBegin", id: row.id });
      },
      dragEnd(event) {
        setDragging(false);
        setDraggingIds(EMPTY_IDS);
        updateSlot(null);
        post({ type: "dragEnd", completed: event.dataTransfer.dropEffect !== "none" });
      },
    }),
    [register, updateSlot],
  );

  const carriesTasks = (event: ReactDragEvent) => Array.from(event.dataTransfer.types).includes("text/plain");

  const onDragOver = (event: ReactDragEvent<HTMLDivElement>) => {
    if (!carriesTasks(event)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    window.clearTimeout(slotClear.current);
    const status = targetStatusAt(event.clientY);
    const hasHeader = live.current.rows.some((row) => row.k === "h" && row.status === status);
    updateSlot(hasHeader ? status : null);
  };

  const onDragLeave = () => {
    window.clearTimeout(slotClear.current);
    slotClear.current = window.setTimeout(() => updateSlot(null), 60);
  };

  const onDrop = (event: ReactDragEvent<HTMLDivElement>) => {
    if (!carriesTasks(event)) return;
    event.preventDefault();
    window.clearTimeout(slotClear.current);
    const raw = event.dataTransfer.getData("text/plain");
    const status = targetStatusAt(event.clientY);
    updateSlot(null);
    if (raw && status !== null) post({ type: "drop", raw, status });
    else post({ type: "dragEnd", completed: false });
  };

  // ── Render ──────────────────────────────────────────────────────────
  const m = metrics(width, state.widths);
  const style = {
    "--title-x": `${m.titleX}px`,
    "--title-w": `${m.titleWidth}px`,
    "--title-w-wide": `${m.titleWideWidth}px`,
    "--review-x": `${m.reviewX}px`,
    "--media-x": `${m.mediaX}px`,
    "--priority-x": `${m.priorityX}px`,
    "--priority-w": `${m.priorityWidth}px`,
    "--assignee-x": `${m.assigneeX}px`,
    "--assignee-w": `${m.assigneeWidth}px`,
    "--date-x": `${m.dateX}px`,
    "--date-w": `${m.dateWidth}px`,
    "--more-x": `${m.moreX}px`,
    paddingTop: contentTop,
    paddingBottom: obscured ? 0 : state.insets.bottom,
    // Group bands stick flush under the SwiftUI page header.
    "--sticky-top": `${obscured ? 0 : state.insets.occlusion}px`,
  } as CSSProperties;

  const bulkCount = state.selected.size;
  const taskCount = state.rows.length;

  // Each status group is its own block so its header band can stick under
  // the page header and be pushed away by the next group.
  const groups: { key: string; rows: DisplayRow[] }[] = [];
  for (const row of displayRows) {
    if (row.k === "h" || groups.length === 0) groups.push({ key: `s:${row.k === "h" ? row.id : ""}`, rows: [] });
    groups[groups.length - 1].rows.push(row);
  }

  const renderRow = (row: DisplayRow) => {
    if (row.k === "t") {
      const selected = state.selected.has(row.id);
      return (
        <TaskRow
          key={`t:${row.id}`}
          row={row}
          selected={selected}
          bulkCount={selected ? bulkCount : 0}
          fileDrop={fileDropId === row.id}
          dragging={draggingIds.has(row.id)}
          inert={inert}
          glyphs={state.glyphs}
          handlers={handlers}
        />
      );
    }
    if (row.k === "h") {
      return (
        <HeaderRow
          key={`h:${row.id}`}
          row={row}
          fonts={state.fonts}
          chevron={state.glyphs.chevronRight}
          register={register}
        />
      );
    }
    const header = state.rows.find((r) => r.k === "h" && r.status === row.status) as HeaderRowPayload | undefined;
    return (
      <DropSlot
        key="d:slot"
        title={row.title}
        color={row.color}
        sc={header?.sc ?? "0 0 0"}
        width={width}
        labelHeight={state.fonts.slot}
      />
    );
  };

  return (
    <>
      <div
        ref={listRef}
        className={`list${inert ? " inert" : ""}${taskCount > HUGE_LIST ? " huge" : ""}`}
        role="list"
        aria-label="Tarefas"
        style={style}
        onMouseDown={(event) => {
          if (event.button !== 0 || event.target !== event.currentTarget) return;
          post({ type: "clearSelection" });
        }}
        onDragOver={onDragOver}
        onDragEnter={onDragOver}
        onDragLeave={onDragLeave}
        onDrop={onDrop}
      >
        {groups.map((group) => (
          <div className="group" key={group.key}>
            {group.rows.map(renderRow)}
          </div>
        ))}
        {ghosts.map((ghost) => (
          <div className="ghost" key={`g:${ghost.key}`} style={{ top: ghost.y }} aria-hidden="true">
            <TaskRow
              row={ghost.row}
              selected={false}
              bulkCount={0}
              fileDrop={false}
              dragging={false}
              inert
              glyphs={state.glyphs}
              handlers={ghostHandlers}
            />
          </div>
        ))}
      </div>
      <div className="drag-image-host" aria-hidden="true">
        <canvas ref={stackCanvas} />
      </div>
    </>
  );
}

