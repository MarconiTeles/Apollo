import { useLayoutEffect, useRef } from "react";

// SwiftUI sizes a Text to its glyph width rounded up to a device pixel, then
// centres / trails that box. Where the box position shows (centred date
// column, trailing "Hoje"), give the span the same rounded width.
export function BoxText({ className, children }: { className: string; children: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    element.style.width = "";
    const scale = window.devicePixelRatio || 2;
    const width = element.getBoundingClientRect().width;
    element.style.width = `${Math.ceil(width * scale - 0.001) / scale}px`;
  }, [children, className]);
  return (
    <span ref={ref} className={className}>
      {children}
    </span>
  );
}
