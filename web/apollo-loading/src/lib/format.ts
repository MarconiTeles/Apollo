const number = new Intl.NumberFormat("pt-BR");

export const formatCount = (value: number) => number.format(Math.round(value));

/** "0,8 s" under ten seconds, then "12 s", then "1 min 04 s". */
export function formatElapsed(ms: number) {
  const seconds = Math.max(0, ms) / 1000;
  if (seconds < 10) return `${seconds.toFixed(1).replace(".", ",")} s`;
  if (seconds < 60) return `${Math.floor(seconds)} s`;
  const minutes = Math.floor(seconds / 60);
  const rest = String(Math.floor(seconds % 60)).padStart(2, "0");
  return `${minutes} min ${rest} s`;
}
