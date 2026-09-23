import type { CSSProperties } from "react";

type Props = {
  w?: number | string;
  h?: number;
  r?: number;
  tone?: "primary" | "secondary" | "faint";
  round?: boolean;
  /** Position inside its row: offsets this bone's glint after the ones to
   *  its left, so light runs across a row instead of flashing at once. */
  c?: number;
  className?: string;
  style?: CSSProperties;
};

/** One placeholder shape. Its glint (styles.css, `.bone::after`) is delayed
 *  by the row (`--r`, set on the row) and by its place in the row (`--c`), so
 *  across the scene the light travels as one diagonal wave, element by
 *  element. */
export function Bone({ w = "100%", h = 10, r = 4, tone = "primary", round, c = 0, className, style }: Props) {
  return (
    <span
      className={className ? `bone ${className}` : "bone"}
      data-tone={tone}
      style={{
        width: round ? h : w,
        height: h,
        borderRadius: round ? "50%" : r,
        ["--c" as string]: c,
        ...style,
      }}
    />
  );
}
