import { Component, createRef, memo } from "react";
import { noteScroll } from "../lib/interaction";
import type { EventPayload, ScrollCommand, TimelineDay } from "../lib/types";
import { BoxText } from "./BoxText";
import { EventCard } from "./EventCard";

// TimelineView(forwardOnly: true) / AgendaNativeList: one recyclable row per
// event, explicit heights (card 47, single/empty day 52, +22 after a day's
// last row, +6 between events), the date gutter overlaid on a day's first
// row and the resting reserve as the first row. Rows never clip: the card's
// glow must stay whole (see `.trow` in styles.css).

const CARD = 47;
const SINGLE = 52;
const BOTTOM_INSET = 60;

interface Row {
  key: string;
  day: TimelineDay;
  event: EventPayload | null;
  first: boolean;
  last: boolean;
}

function rowsFor(days: TimelineDay[]): Row[] {
  const rows: Row[] = [];
  for (const day of days) {
    if (day.events.length === 0) {
      rows.push({ key: day.key, day, event: null, first: true, last: true });
      continue;
    }
    day.events.forEach((event, index) => {
      rows.push({
        key: index === 0 ? day.key : `${day.key}|${event.key}`,
        day,
        event,
        first: index === 0,
        last: index === day.events.length - 1,
      });
    });
  }
  return rows;
}

const heightOf = (row: Row) => (row.event === null || (row.first && row.last) ? SINGLE : CARD) + (row.last ? 22 : 6);

const DateColumn = memo(function DateColumn({ day }: { day: TimelineDay }) {
  return (
    <div className="date">
      <BoxText className={`date-label${day.today ? " today" : ""}`}>{day.label}</BoxText>
      <BoxText className="date-number">{day.day}</BoxText>
    </div>
  );
});

// Row objects are rebuilt with the day list; the store keeps unchanged days
// and events identical, so comparing fields skips every untouched row.
const sameRow = (a: { row: Row }, b: { row: Row }) =>
  a.row.day === b.row.day && a.row.event === b.row.event && a.row.first === b.row.first && a.row.last === b.row.last;

const TimelineRow = memo(function TimelineRow({ row }: { row: Row }) {
  const { day, event, first } = row;
  return (
    <div
      className={`trow${first ? " first" : ""}${day.past ? " past" : ""}`}
      style={{ height: heightOf(row) }}
      data-key={row.key}
      data-day={first ? day.key : undefined}
    >
      <div className="gutter">{first && <DateColumn day={day} />}</div>
      {event ? <EventCard event={event} /> : <span className="empty">— Sem compromissos</span>}
    </div>
  );
}, sameRow);

interface Props {
  days: TimelineDay[];
  top: number;
  scroll: ScrollCommand | null;
  reduceMotion: boolean;
}

interface Anchor {
  key: string;
  offset: number;
}

export class Timeline extends Component<Props> {
  private scroller = createRef<HTMLDivElement>();
  private rows: Row[] = rowsFor(this.props.days);
  private rowsSource: TimelineDay[] = this.props.days;
  private handledToken = 0;
  private animation = 0;

  componentDidMount() {
    this.scroller.current?.addEventListener("scroll", noteScroll, { passive: true });
    this.runScroll();
  }

  componentWillUnmount() {
    this.scroller.current?.removeEventListener("scroll", noteScroll);
    cancelAnimationFrame(this.animation);
  }

  // AgendaNativeList.Coordinator.update: keep the first visible row where it
  // was when the rows change (sync, calendar added, midnight).
  getSnapshotBeforeUpdate(previous: Props): Anchor | null {
    const scroller = this.scroller.current;
    if (!scroller || previous.days === this.props.days) return null;
    const y = scroller.scrollTop;
    for (const element of scroller.querySelectorAll<HTMLElement>(".trow")) {
      const top = element.offsetTop;
      if (top + element.offsetHeight > y) {
        return { key: element.dataset.key!, offset: y - top };
      }
    }
    return null;
  }

  componentDidUpdate(_: Props, __: unknown, anchor: Anchor | null) {
    const scroller = this.scroller.current;
    if (scroller && anchor) {
      const element = scroller.querySelector<HTMLElement>(`.trow[data-key="${CSS.escape(anchor.key)}"]`);
      if (element) this.setOffset(element.offsetTop + anchor.offset, false);
    }
    this.runScroll();
  }

  private runScroll() {
    const command = this.props.scroll;
    if (!command || command.token <= this.handledToken) return;
    this.handledToken = command.token;
    const scroller = this.scroller.current;
    if (!scroller) return;
    if (command.day === null) {
      this.setOffset(0, false);
      return;
    }
    const element = scroller.querySelector<HTMLElement>(`.trow[data-day="${CSS.escape(command.day)}"]`);
    if (element) this.setOffset(element.offsetTop, command.animated && !this.props.reduceMotion);
  }

  /** setOffset: clamped; animated = 0.35 s ease-in-out like the clip animator. */
  private setOffset(y: number, animated: boolean) {
    const scroller = this.scroller.current;
    if (!scroller) return;
    cancelAnimationFrame(this.animation);
    const maximum = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
    const target = Math.min(Math.max(0, y), maximum);
    const from = scroller.scrollTop;
    if (Math.abs(from - target) <= 0.01) return;
    if (!animated) {
      scroller.scrollTop = target;
      return;
    }
    const start = performance.now();
    const step = (now: number) => {
      const t = Math.min(1, (now - start) / 350);
      scroller.scrollTop = from + (target - from) * easeInOut(t);
      if (t < 1) this.animation = requestAnimationFrame(step);
    };
    this.animation = requestAnimationFrame(step);
  }

  render() {
    if (this.rowsSource !== this.props.days) {
      this.rows = rowsFor(this.props.days);
      this.rowsSource = this.props.days;
    }
    return (
      <div className="timeline" ref={this.scroller}>
        <div style={{ height: this.props.top }} />
        {this.rows.map((row) => (
          <TimelineRow key={row.key} row={row} />
        ))}
        <div style={{ height: BOTTOM_INSET }} />
      </div>
    );
  }
}

// CAMediaTimingFunction(name: .easeInEaseOut) = cubic-bezier(0.42, 0, 0.58, 1).
function easeInOut(t: number) {
  let lo = 0;
  let hi = 1;
  let u = t;
  for (let i = 0; i < 20; i++) {
    u = (lo + hi) / 2;
    const x = 3 * u * (1 - u) * (1 - u) * 0.42 + 3 * u * u * (1 - u) * 0.58 + u * u * u;
    if (x < t) lo = u;
    else hi = u;
  }
  return 3 * u * u * (1 - u) + u * u * u;
}
