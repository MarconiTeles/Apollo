import { memo, useState } from "react";
import type { Person } from "../lib/types";

export const Avatar = memo(function Avatar({ person, size = 20 }: { person: Person; size?: number }) {
  const [failed, setFailed] = useState(false);
  const photo = person.photo && !failed;
  return (
    <span
      className="avatar"
      title={person.name}
      style={{ width: size, height: size, fontSize: size * 0.42, background: photo ? undefined : person.background }}
    >
      {photo ? (
        <img src={person.photo} alt="" draggable={false} onError={() => setFailed(true)} />
      ) : (
        person.initials
      )}
    </span>
  );
});

export function AvatarStack({ people, size = 20, max = 3 }: { people: Person[]; size?: number; max?: number }) {
  const shown = people.slice(0, max);
  const extra = people.length - shown.length;
  return (
    <span className="avatar-stack">
      {shown.map((p) => (
        <Avatar key={p.id} person={p} size={size} />
      ))}
      {extra > 0 && (
        <span className="avatar avatar-more" style={{ width: size, height: size, fontSize: size * 0.4 }}>
          +{extra}
        </span>
      )}
    </span>
  );
}
