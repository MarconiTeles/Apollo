import { formatElapsed } from "../lib/format";
import { useNow } from "../lib/motion";

export function Elapsed({ since }: { since?: number | null }) {
  const now = useNow(100);
  if (!since) return null;
  return <span className="elapsed">{formatElapsed(now - since)}</span>;
}
