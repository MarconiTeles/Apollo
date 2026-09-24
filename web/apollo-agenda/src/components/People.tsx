import type { PersonPayload } from "../lib/types";

/** Guests as stacked discs, organizer first and ringed in the accent (the
 *  month grid's disc language), photos when ClickUp knows the person. */
export function People({ people, maxPeople = 4 }: { people: PersonPayload[]; maxPeople?: number }) {
  if (people.length === 0) return null;
  const shown = people.length > maxPeople + 1 ? people.slice(0, maxPeople) : people;
  const more = people.length - shown.length;
  return (
    <span className="people" title={people.map((person) => person.name).join("\n")}>
      {shown.map((person, index) => (
        <span
          key={`${person.name}-${index}`}
          className={`person${person.organizer ? " organizer" : ""}`}
          style={{ zIndex: shown.length - index, background: person.color }}
        >
          <span className="person-initials">{person.initials}</span>
          {person.photo && <img className="person-photo" src={person.photo} alt="" draggable={false} />}
        </span>
      ))}
      {more > 0 && (
        <span className="person more" style={{ zIndex: 0 }}>
          <span className="person-initials">+{more}</span>
        </span>
      )}
    </span>
  );
}

