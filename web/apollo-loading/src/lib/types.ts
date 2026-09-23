// Mirror of `SyncLoadingSnapshot` (Sources/DayPanel/Views/Extensions/
// SyncLoading/SyncLoadingSnapshot.swift). Swift owns every fact and every
// word; the scenes only present them.

export type SceneId = "tasks" | "board" | "comments" | "inbox";
export type StepState = "pending" | "active" | "done" | "failed" | "skipped";

export type Step = {
  id: string;
  label: string;
  detail?: string | null;
  state: StepState;
};

export type Snapshot = {
  scene: SceneId;
  headline: string;
  context?: string | null;
  steps: Step[];
  /** Finished fraction, 0…1. */
  progress: number;
  /** The next step boundary — the most the scene may ease toward. */
  ceiling: number;
  metric?: { value: number; label: string } | null;
  columns: { name: string; color: string }[];
  scan?: { done: number; target: number; found: number } | null;
  startedAt?: number | null;
  lastSyncedAt?: number | null;
  online: boolean;
  geometry?: {
    top: number;
    leading: number;
    columnX: number;
    columnWidth: number;
    columnGap: number;
    cardWidth: number;
  } | null;
  theme: "dark" | "light";
  accent: string;
};
