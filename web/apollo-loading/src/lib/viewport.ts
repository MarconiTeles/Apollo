import { useEffect, useState } from "react";

// Layout rule shared with `SyncLoadingLayout` in Swift: a scene shows only
// items that fit *entirely* — down to the bottom edge (or to whatever sits
// there, like the board's capsule), never one cut by it.

/** Live viewport size; the scenes re-flow when the window is resized. */
export function useViewport() {
  const [size, setSize] = useState(() => ({ w: window.innerWidth, h: window.innerHeight }));
  useEffect(() => {
    const onResize = () => setSize({ w: window.innerWidth, h: window.innerHeight });
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);
  return size;
}

/** Items of `size` separated by `gap` that fit whole between `top` and
 *  `bottom` (the usable bottom edge). */
export function fitting(bottom: number, top: number, size: number, gap: number) {
  return Math.max(1, Math.floor((bottom - top + gap) / (size + gap)));
}

const HEADER = 38;
const ROW = 44;
const GROUP_GAP = 16;

/** Rows per status group — 3, 6, then 5s — until the next row would be cut.
 *  A header is only placed when at least one row fits under it. */
export function taskGroups(height: number, top: number) {
  const groups: number[] = [];
  let y = top;
  for (;;) {
    const wanted = groups.length === 0 ? 3 : groups.length === 1 ? 6 : 5;
    if (y + HEADER + ROW > height) break;
    y += HEADER;
    const rows = Math.min(wanted, Math.floor((height - y) / ROW));
    groups.push(rows);
    y += rows * ROW;
    if (rows < wanted) break;
    y += GROUP_GAP;
  }
  return groups.length > 0 ? groups : [1];
}
