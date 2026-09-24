// Pointer policy kept outside React so a scroll tick never re-renders:
//
// • Timeline hover is ignored while the list moves (scrollAwareOnHover) and
//   only returns with a real pointer movement.
// • No hover behind the SwiftUI page header (isBehindPageHeader).

const QUIET_PERIOD = 180;

const root = document.documentElement;
let scrolling = false;
let occluded = false;
let occlusionTop = 81;
let lastClientY: number | null = null;
let quietTimer: number | undefined;

// CSS reads `.occluded` (every hover) and `.scrolling` (timeline hover).
function sync() {
  root.classList.toggle("occluded", occluded);
  root.classList.toggle("scrolling", scrolling);
}

export function setOcclusion(value: number) {
  occlusionTop = value;
  if (lastClientY !== null) updateOccluded(lastClientY);
}

function updateOccluded(clientY: number) {
  const next = clientY < occlusionTop;
  if (next !== occluded) {
    occluded = next;
    sync();
  }
}

/** Called from the timeline scroller's passive scroll listener. */
export function noteScroll() {
  if (!scrolling) {
    scrolling = true;
    sync();
  }
  window.clearTimeout(quietTimer);
  quietTimer = window.setTimeout(() => {
    quietTimer = undefined;
  }, QUIET_PERIOD);
}

window.addEventListener(
  "mousemove",
  (event) => {
    lastClientY = event.clientY;
    updateOccluded(event.clientY);
    if (scrolling && quietTimer === undefined) {
      scrolling = false;
      sync();
    }
  },
  { passive: true },
);

document.addEventListener("mouseleave", () => {
  lastClientY = null;
});

sync();
