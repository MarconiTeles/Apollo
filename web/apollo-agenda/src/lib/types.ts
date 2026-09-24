// Swift → JS contract (AgendaReactBody.swift, `AgendaReactPatch`).
//
// Swift owns every date computation (calendar, locale, time zone), label and
// colour. Colours arrive resolved by AppKit under the web view's effective
// appearance; `*c` fields carry Display-P3 components ("r g b") for the
// places the native views apply their own opacity to a calendar colour.

export interface EventPayload {
  /** CalendarEvent.calendarIdentity — unique across shared calendars. */
  key: string;
  title: string;
  /** Timeline card subtitle: "09:30 – 10:00 · Boteco". */
  subtitle: string;
  /** Month panel detail: same range, trimmed location. */
  detail: string;
  /** "09:30" (day tooltip). */
  time: string;
  accepted: boolean;
  declined: boolean;
  /** Google-palette colour of the timeline card (components). */
  cardc: string;
  /** Vibrant status colour of the month disc (resolved). */
  dot: string;
  darkInk: boolean;
  monogram: string;
  /** Initials of the first attendee; absent when there are none. */
  initials?: string;
}

export interface TimelineDay {
  key: string;
  /** "HOJE" or the pt_BR abbreviated weekday ("SEX"). */
  label: string;
  day: string;
  today: boolean;
  past: boolean;
  events: EventPayload[];
}

export interface MonthCell {
  key: string;
  number: string;
  /** Abbreviated month for the 1st ("set"). */
  monthLabel?: string;
  inMonth: boolean;
  today: boolean;
  /** Panel folio ("Terça-feira, 15 de setembro"). */
  title: string;
  /** "Hoje", "Amanhã", "Há 9 dias"… */
  relative: string;
  tooltip: string;
  a11y: string;
  events: EventPayload[];
}

export interface MonthPayload {
  key: string;
  title: string;
  cells: MonthCell[];
  /** Today in the displayed month, otherwise its first day. */
  fallback: string;
}

export interface Layout {
  /** Resting reserve above today's row. */
  agendaTop: number;
  /** Month column top inset. */
  monthTop: number;
  /** Band covered by the SwiftUI page header (no hover there). */
  occlusion: number;
}

/** SwiftUI line heights (NSLayoutManager.defaultLineHeight) per text style. */
export interface Metrics {
  cardTitle: number;
  cardSubtitle: number;
  avatar: number;
  dateLabel: number;
  dateNumber: number;
  empty: number;
  weekday: number;
  cellNumber: number;
  cellMonth: number;
  folio: number;
  relative: number;
  rowTitle: number;
  rowDetail: number;
  panelEmpty: number;
  banner: number;
}

export interface Glyph {
  url: string;
  width: number;
  height: number;
}

export interface ScrollCommand {
  token: number;
  /** Day key, or null for the resting position (top). */
  day: string | null;
  animated: boolean;
}

export interface Patch {
  seq: number;
  theme?: Record<string, string>;
  dark?: boolean;
  metrics?: Metrics;
  glyphs?: Record<string, Glyph>;
  layout?: Layout;
  timeline?: TimelineDay[];
  month?: MonthPayload;
  error?: string | null;
  reduceMotion?: boolean;
  /** Selects today in the grid ("Hoje" / todayJumpToken). */
  todayToken?: number;
  scroll?: ScrollCommand;
}
