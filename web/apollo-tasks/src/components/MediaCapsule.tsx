import { memo, useRef } from "react";
import type { CSSProperties } from "react";
import { post } from "../lib/bridge";
import { viewRect } from "../lib/interaction";
import type { MediaPayload } from "../lib/types";

// The ANEXAR capsule (MyTasksNativeRowView.updateMediaButton). Colours per
// phase arrive resolved; the progress fill keeps its pill shape and is
// revealed by an animated horizontal clip, like the native mask layer.

interface Props {
  taskId: string;
  media: MediaPayload;
  /** Selected with 2+ tasks: tooltip/label speak for the whole selection. */
  bulkCount: number;
  fileDrop: boolean;
  disabled: boolean;
}

export const MediaCapsule = memo(function MediaCapsule({ taskId, media, bulkCount, fileDrop, disabled }: Props) {
  const button = useRef<HTMLButtonElement>(null);
  const actsOnSelection = media.phase === null && bulkCount >= 2;
  const tooltip = fileDrop
    ? "Soltar para anexar nesta tarefa"
    : actsOnSelection
      ? `Anexar nas ${bulkCount} tarefas selecionadas`
      : media.label === "ANEXAR"
        ? "Adicionar HOOKs, BODYs ou vídeos completos"
        : media.label;
  const showBadge = (media.phase === "ready" || media.phase === "partialFailure") && media.badge > 0;
  const style = {
    "--m-bg": media.background,
    "--m-title": media.titleColor,
    "--m-fill": media.progressColor,
    "--m-p": media.progress,
    "--m-hbg": media.hoverBackground,
    "--m-htitle": media.hoverTitleColor,
  } as CSSProperties;

  return (
    <button
      ref={button}
      type="button"
      className={`capsule media${media.small ? " small" : ""}${fileDrop ? " file-drop" : ""}`}
      style={style}
      title={tooltip}
      disabled={disabled}
      draggable={false}
      aria-label={
        actsOnSelection ? `Anexar vídeos nas ${bulkCount} tarefas selecionadas` : "Anexar ou enviar vídeos desta tarefa"
      }
      onMouseDown={(event) => event.stopPropagation()}
      onClick={(event) => {
        event.stopPropagation();
        if (disabled || !button.current) return;
        post({ type: "media", id: taskId, rect: viewRect(button.current) });
      }}
    >
      <span className="track" />
      {media.showProgress && <span className="fill" />}
      {fileDrop && (
        <svg className="dash" width="64.4" height="26" aria-hidden="true">
          <rect
            x="0"
            y="0"
            width="64.4"
            height="26"
            rx="13"
            ry="13"
            fill="none"
            stroke="var(--orange)"
            strokeWidth="1.5"
            strokeDasharray="5 4"
          />
        </svg>
      )}
      <span className="caption">{media.label}</span>
      {showBadge && (
        <span className="badge" aria-label="Quantidade de vídeos preparados">
          {media.badge}
        </span>
      )}
    </button>
  );
});
