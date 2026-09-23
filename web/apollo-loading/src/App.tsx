import { useEffect, useSyncExternalStore } from "react";
import { post, read, subscribe } from "./lib/bridge";
import { BoardScene } from "./scenes/BoardScene";
import { CommentsScene } from "./scenes/CommentsScene";
import { InboxScene } from "./scenes/InboxScene";
import { TasksScene } from "./scenes/TasksScene";

export function App() {
  const snapshot = useSyncExternalStore(subscribe, read);

  useEffect(() => {
    if (!snapshot) return;
    const root = document.documentElement;
    root.dataset.theme = snapshot.theme;
    root.style.setProperty("--accent", snapshot.accent);
  }, [snapshot?.theme, snapshot?.accent]);

  // `ready` only after the first real frame is on screen: Swift cross-fades
  // from the native skeleton the moment it hears this.
  const hasSnapshot = snapshot !== undefined;
  useEffect(() => {
    if (!hasSnapshot) return;
    let inner = 0;
    const outer = requestAnimationFrame(() => {
      inner = requestAnimationFrame(() => post({ type: "ready" }));
    });
    return () => {
      cancelAnimationFrame(outer);
      cancelAnimationFrame(inner);
    };
  }, [hasSnapshot]);

  if (!snapshot) return null;
  switch (snapshot.scene) {
    case "tasks":
      return <TasksScene s={snapshot} />;
    case "board":
      return <BoardScene s={snapshot} />;
    case "comments":
      return <CommentsScene s={snapshot} />;
    case "inbox":
      return <InboxScene s={snapshot} />;
  }
}
