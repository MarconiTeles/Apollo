// Motion tokens shared with the task list: a strong ease-out for responses
// to a click (reflow, entrances, press) and a reduced-motion switch.

export const EASE_OUT = "cubic-bezier(0.23, 1, 0.32, 1)";

const reducedQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
export const prefersReducedMotion = () => reducedQuery.matches;
