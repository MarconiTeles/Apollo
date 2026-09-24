// Pointer/hover policy of the native rows, kept outside React so a scroll
// tick never re-renders anything:
//
// • Hover is suppressed while the list moves (MyTasksViewport's 350 ms quiet
//   period after the last real clip movement), and — like AppKit tracking
//   areas — it only comes back with a REAL pointer movement, not because
//   content slid under a resting cursor.
// • No hover behind the SwiftUI page header (isBehindPageHeader).
// • No hover while the window is not key (.activeInKeyWindow) or during a
//   drag session.

const QUIET_PERIOD = 350;

const root = document.documentElement;
let scrolling = false;
let occluded = false;
let dragging = false;
let windowKey = true;
let lastScroll = -Infinity;
let lastPointer: { x: number; y: number } | null = null;
let lastClientY: number | null = null;
let occlusionTop = 82;
let viewOffset = 0;
const scrollListeners = new Set<() => void>();

function sync() {
  root.classList.toggle("hover-on", !scrolling && !occluded && !dragging && windowKey);
}

export function isScrolling() {
  return scrolling;
}

export function hoverAllowed() {
  return !scrolling && !occluded && !dragging && windowKey;
}

export function setDragging(value: boolean) {
  if (dragging === value) return;
  dragging = value;
  sync();
}

export function setWindowKey(value: boolean) {
  if (windowKey === value) return;
  windowKey = value;
  sync();
}

/** occlusion: header band in web view points; offset: view y of client 0. */
export function setOcclusion(occlusion: number, offset: number) {
  occlusionTop = occlusion;
  viewOffset = offset;
  if (lastClientY !== null) updateOccluded(lastClientY);
}

function updateOccluded(clientY: number) {
  const next = clientY + viewOffset < occlusionTop;
  if (next !== occluded) {
    occluded = next;
    sync();
  }
}

/** Client → web view coordinates (the WKWebView is flipped). */
export function viewRect(element: Element) {
  const r = element.getBoundingClientRect();
  return { x: r.left, y: r.top + viewOffset, width: r.width, height: r.height };
}

export const clientToViewY = (clientY: number) => clientY + viewOffset;
export const viewToClientY = (viewY: number) => viewY - viewOffset;

// The one control currently showing hover/press feedback. Scrolling or a
// popup clears it, like MyTasksNativeRowView.forceExitAllInteraction().
let activeReset: (() => void) | null = null;

export function claimInteraction(reset: () => void) {
  if (activeReset && activeReset !== reset) activeReset();
  activeReset = reset;
}

export function releaseInteraction(reset: () => void) {
  if (activeReset === reset) activeReset = null;
}

export function resetInteraction() {
  const reset = activeReset;
  activeReset = null;
  reset?.();
}

export function onScroll(listener: () => void) {
  scrollListeners.add(listener);
  return () => {
    scrollListeners.delete(listener);
  };
}

window.addEventListener(
  "scroll",
  () => {
    lastScroll = performance.now();
    if (!scrolling) {
      scrolling = true;
      sync();
      resetInteraction();
    }
    scrollListeners.forEach((listener) => listener());
  },
  { passive: true },
);

window.addEventListener(
  "mousemove",
  (event) => {
    const moved = !lastPointer || lastPointer.x !== event.screenX || lastPointer.y !== event.screenY;
    lastPointer = { x: event.screenX, y: event.screenY };
    lastClientY = event.clientY;
    updateOccluded(event.clientY);
    // WebKit re-hit-tests after scrolling with simulated moves at the same
    // screen point; only a real movement ends the suppression.
    if (scrolling && moved && performance.now() - lastScroll >= QUIET_PERIOD) {
      scrolling = false;
      sync();
    }
  },
  { passive: true },
);

document.addEventListener("mouseleave", () => {
  lastPointer = null;
  lastClientY = null;
});

sync();
