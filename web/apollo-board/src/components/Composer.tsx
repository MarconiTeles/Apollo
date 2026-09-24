// Quick create in context (ClickUp "+ Adicionar Tarefa"): Enter saves and
// keeps the composer open for the next task, Escape or an empty blur
// closes it. Each submission shows a pending line until Swift confirms it.

import { useEffect, useRef, useState } from "react";

type Resolver = (ok: boolean) => void;
const pending = new Map<string, Resolver>();
let counter = 0;

/** Swift → JS: `window.apolloBoard.created(token, ok)`. */
export function resolveCreated(token: string, ok: boolean) {
  pending.get(token)?.(ok);
  pending.delete(token);
}

interface Pending {
  token: string;
  title: string;
  failed: boolean;
}

export function Composer({
  placeholder = "Nome da tarefa",
  compact,
  onSubmit,
  onClose,
}: {
  placeholder?: string;
  compact?: boolean;
  onSubmit: (title: string, token: string) => void;
  onClose: () => void;
}) {
  const [value, setValue] = useState("");
  const [items, setItems] = useState<Pending[]>([]);
  const input = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    input.current?.focus();
  }, []);

  useEffect(() => {
    const element = input.current;
    if (!element) return;
    element.style.height = "0px";
    element.style.height = `${element.scrollHeight}px`;
  }, [value]);

  const submit = () => {
    const title = value.trim();
    if (!title) return;
    const token = `c${Date.now().toString(36)}${(counter++).toString(36)}`;
    setItems((list) => [...list, { token, title, failed: false }]);
    pending.set(token, (ok) => {
      setItems((list) =>
        ok ? list.filter((item) => item.token !== token) : list.map((item) => (item.token === token ? { ...item, failed: true } : item)),
      );
    });
    onSubmit(title, token);
    setValue("");
  };

  return (
    <div className="composer" data-compact={compact ? "" : undefined}>
      {items.map((item) => (
        <div key={item.token} className="composer-pending" data-failed={item.failed ? "" : undefined}>
          <span className="composer-spinner" aria-hidden="true" />
          <span className="composer-pending-title">{item.title}</span>
          {item.failed && <span className="composer-failed">Não foi criada</span>}
        </div>
      ))}
      <textarea
        ref={input}
        rows={1}
        value={value}
        placeholder={placeholder}
        aria-label={placeholder}
        onChange={(event) => setValue(event.target.value.replace(/\n/g, " "))}
        onKeyDown={(event) => {
          if (event.key === "Enter" && !event.nativeEvent.isComposing) {
            event.preventDefault();
            submit();
          } else if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            onClose();
          }
        }}
        onBlur={() => {
          if (!value.trim() && !items.some((i) => !i.failed)) onClose();
        }}
      />
    </div>
  );
}
