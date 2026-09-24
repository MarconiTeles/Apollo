import { Bone } from "../components/Bone";
import { seeded } from "../lib/motion";
import type { Snapshot } from "../lib/types";
import { fitting, useViewport } from "../lib/viewport";

// Inbox — "listening to every source".
//
// Shapes only (no words, numbers or progress): the feed's capsules. While a
// source is being read, light travels down toward them. As many whole capsules as the
// column holds drop in one after another, like notifications landing.

/** Capsules start at the top (no text block), mirrored in Swift. */
const TOP = 0;
const CAPSULE = 58;
const CAPSULE_GAP = 9;


export function InboxScene({ s }: { s: Snapshot }) {
  const listening = s.steps.some((step) => step.state === "active");
  const { h } = useViewport();
  const capsules = fitting(h, TOP, CAPSULE, CAPSULE_GAP);

  return (
    <main className="scene scene-inbox" data-offline={!s.online || undefined}>

      <section className="inbox-feed" data-listening={listening || undefined} aria-hidden>
        {Array.from({ length: capsules }, (_, i) => (
          <div key={i} className="capsule" style={{ ["--i" as string]: i, ["--r" as string]: i * 2 }}>
            <Bone h={28} round />
            <div className="capsule-lines">
              <Bone w={`${46 + seeded(i + 11) * 30}%`} h={10} c={1} />
              <Bone w={`${28 + seeded(i + 17) * 26}%`} h={8} tone="secondary" c={2} />
            </div>
            <Bone w={34} h={8} tone="faint" c={5} />
          </div>
        ))}
      </section>
    </main>
  );
}
