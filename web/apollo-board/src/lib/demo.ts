// Vite dev server only: a board shaped like the ClickUp reference capture
// (A GRAVAR, CAPTADO, A EDITAR, EDITANDO, REVIEW…) that answers the page's
// messages the way Swift does, so layout and interactions can be iterated
// in a browser. Never bundled into the app build.

import type { OutboundMessage } from "./bridge";
import { bucketDue } from "./dates";
import { apply, read } from "./store";
import type { CardPayload, Patch, Person, Prefs, StatusPayload, TagPayload } from "./types";
import { DEFAULT_PREFS } from "./types";

const P3 = (hex: string) => {
  const n = Number.parseInt(hex.slice(1), 16);
  return `${((n >> 16) & 255) / 255} ${((n >> 8) & 255) / 255} ${(n & 255) / 255}`;
};

const STATUS: [string, string, boolean][] = [
  ["backlog", "#87909e", false],
  ["a gravar", "#4466ff", false],
  ["captado", "#aa8d80", false],
  ["a editar", "#f8ae00", false],
  ["editando", "#e16b16", false],
  ["review", "#b660e0", false],
  ["ajustes", "#d33d44", false],
  ["aprovado", "#0f9d9f", false],
  ["publicado", "#008844", true],
];

const people: Person[] = [
  { id: 1, name: "Marconi Reis", initials: "MR", background: "#1f1f1f" },
  { id: 2, name: "Paula Nogueira", initials: "PN", background: "#e040fb" },
  { id: 3, name: "João Ribeiro", initials: "JR", background: "#5f4bd8" },
  { id: 4, name: "Henrique Dias", initials: "HD", background: "#0ab4aa" },
];

const tags: TagPayload[] = [
  { name: "black friday", fg: "#ffffff", bg: "#e5484d" },
  { name: "ugc", fg: "#ffffff", bg: "#2f80ed" },
  { name: "ads", fg: "#1d1d1f", bg: "#ffd43b" },
  { name: "orgânico", fg: "#ffffff", bg: "#12a150" },
];

const titles = [
  "Camiseta 2.0 - Black Friday - Ofertas - Galpão 2 - B1 - 5H",
  "Calça Jeans - Black Friday - Ofertas - Escritório - B1 - 7H",
  "Abertura de Campanha - Black Friday - Oferta - Galpão - B1 - 6H - Takes extras",
  "Calça Jeans - Black Friday - Ofertas - Loja - B1 - 6H",
  "Abertura de Campanha - Black Friday - Frente a Câmera - Loja - B1",
  "[IA] Calça Jeans - Conforto e Flexibilidade - IA + Takes UGC - B2",
  "Camiseta 1.0 - Status Social - IA - Consultor de Moda - 5H - 1B",
  "Camiseta 1.0 - Status Social - IA - Rico x Quebrado - Consultor de Moda",
  "Fernando - Calça Comfort - Comparação Espelhado - 5H-1B",
  "Henrique - Camiseta 1.0 - Tela Verde - Bilionários - 5H - 1B",
  "Henrique - Camiseta 1.0 - Unboxing - 5H - 1B",
  "Fernando - Calça Comfort - Antes e Depois - 5H-1B",
  "Calça Comfort - Black Friday - Ofertas - Galpão - B1 - 6H",
  "5 Variações: 0226-185-MOF-FB_IG",
  "5 Variações: 0526-8-MOF-FB_IG",
];

function coverSVG(index: number) {
  const hues = [[8, 20], [210, 240], [28, 45], [280, 320]][index % 4];
  const text = ["BLACK FRIDAY", "MINIMAL CLUB", "É FEITA", "NOVA COLEÇÃO"][index % 4];
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="480" height="270" viewBox="0 0 480 270">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hues[0]} 70% 22%)"/><stop offset="1" stop-color="hsl(${hues[1]} 80% 45%)"/></linearGradient>
<radialGradient id="r" cx="0.3" cy="0.35" r="0.7"><stop offset="0" stop-color="rgba(255,255,255,0.35)"/><stop offset="1" stop-color="rgba(255,255,255,0)"/></radialGradient></defs>
<rect width="480" height="270" fill="url(#g)"/><rect width="480" height="270" fill="url(#r)"/>
<circle cx="360" cy="120" r="70" fill="rgba(0,0,0,0.25)"/><rect x="300" y="170" width="140" height="100" rx="30" fill="rgba(0,0,0,0.28)"/>
<text x="36" y="226" fill="white" font-family="-apple-system, system-ui" font-weight="800" font-size="34" letter-spacing="1">${text}</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

function makeCards(): CardPayload[] {
  const now = Date.now();
  const day = 86_400_000;
  const counts: Record<string, number> = { backlog: 0, "a gravar": 1, captado: 9, "a editar": 7, editando: 0, review: 6, ajustes: 3, aprovado: 4, publicado: 5 };
  const out: CardPayload[] = [];
  let n = 0;
  for (const [status] of STATUS) {
    for (let i = 0; i < counts[status]; i++, n++) {
      const title = titles[n % titles.length];
      const due = n % 7 === 3 ? undefined : now + ((n % 5) - 1) * day;
      out.push({
        id: `t${n}`,
        title,
        status,
        closed: status === "publicado",
        priority: [0, 0, 3, 2, 0, 1, 4][n % 7],
        assignees: n % 6 === 0 ? [1] : n % 6 === 3 ? [3] : n % 9 === 4 ? [2, 4] : [2],
        tags: n % 5 === 1 ? ["black friday"] : n % 8 === 2 ? ["ugc", "ads"] : [],
        due,
        created: now - n * day,
        updated: now - (n % 4) * 3600_000,
        hasDescription: n % 3 !== 2,
        attachments: status === "review" ? [8, 14, 3, 5, 1, 2][i % 6] : n % 4 === 0 ? 2 : 0,
        checklist: n % 6 === 5 ? { done: 2, total: 5 } : null,
        cover: status === "review" || (status === "aprovado" && i % 2 === 0) ? coverSVG(n) : undefined,
        parentId: n === 12 ? "t2" : undefined,
        parentTitle: n === 12 ? titles[2] : undefined,
        otherList: n === 20 ? "Social · Orgânico" : undefined,
      });
    }
  }
  return out;
}

let seq = 0;
let prefs: Prefs = { ...DEFAULT_PREFS };
let cards = makeCards();
const orders: Record<string, string[]> = {};
let selected: string[] = [];

const statuses = (): StatusPayload[] =>
  STATUS.map(([key, hex, closed]) => ({ key, name: key.toUpperCase(), color: hex, sc: P3(hex), closed }));

const scope = () => cards.filter((c) => prefs.showClosed || !c.closed);

function send(patch: Omit<Patch, "seq">) {
  apply({ seq: ++seq, ...patch });
}

function full() {
  const shown = scope();
  send({
    reset: true,
    upsert: shown,
    order: shown.map((c) => c.id),
    statuses: statuses(),
    members: people,
    tags,
    orders,
    prefs,
    selected,
    me: 1,
    listName: "Produção · Black Friday",
    theme: {},
    dark: window.matchMedia("(prefers-color-scheme: dark)").matches,
    insets: { top: 12, leading: 24, bottom: 24 },
  });
}

function update(ids: string[], change: (card: CardPayload) => CardPayload) {
  cards = cards.map((c) => (ids.includes(c.id) ? change(c) : c));
  send({ upsert: cards.filter((c) => ids.includes(c.id)) });
}

function handle(message: OutboundMessage) {
  switch (message.type) {
    case "boot":
      full();
      break;
    case "prefs": {
      const closedChanged = message.prefs.showClosed !== prefs.showClosed;
      prefs = message.prefs;
      if (closedChanged) full();
      else send({ prefs });
      break;
    }
    case "activate": {
      if (message.command || message.shift) {
        selected = selected.includes(message.id) ? selected.filter((x) => x !== message.id) : [...selected, message.id];
        send({ selected });
      } else {
        console.info("open task", message.id);
      }
      break;
    }
    case "select":
      selected = [...new Set([...(message.additive ? selected : []), ...message.ids])];
      send({ selected });
      break;
    case "clearSelection":
      selected = [];
      send({ selected });
      break;
    case "field":
      // The app opens a native menu/popover here; the fixture cycles the
      // value so the card can still be exercised in a browser.
      if (message.field === "priority") update([message.id], (c) => ({ ...c, priority: (c.priority + 1) % 5 }));
      else console.info("native editor", message.field, message.id);
      break;
    case "columnMenu":
      console.info("native column menu", message.gk, message.ids.length);
      break;
    case "drop": {
      const key = `${message.groupBy}:${message.to}`;
      orders[key] = message.order;
      if (message.sourceOrder && message.from != null) orders[`${message.groupBy}:${message.from}`] = message.sourceOrder;
      const to = message.to;
      if (message.from !== to) {
        update(message.ids, (c) => {
          switch (message.groupBy) {
            case "status":
              return { ...c, status: to };
            case "priority":
              return { ...c, priority: to === "none" ? 0 : Number(to) };
            case "assignee": {
              const rest = c.assignees.filter((a) => String(a) !== message.from);
              return { ...c, assignees: to === "none" ? rest : [...new Set([...rest, Number(to)])] };
            }
            case "tag": {
              const rest = c.tags.filter((t) => t !== message.from);
              return { ...c, tags: to === "none" ? rest : [...new Set([...rest, to])] };
            }
            case "due":
              return { ...c, due: bucketDue(to) ?? undefined };
          }
        });
      }
      send({ orders: { ...orders } });
      break;
    }
    case "create": {
      const id = `new${Date.now()}`;
      const card: CardPayload = {
        id,
        title: message.title,
        status: message.groupBy === "status" ? message.group : "a gravar",
        closed: false,
        priority: message.groupBy === "priority" && message.group !== "none" ? Number(message.group) : 0,
        assignees: message.groupBy === "assignee" && message.group !== "none" ? [Number(message.group)] : [],
        tags: message.groupBy === "tag" && message.group !== "none" ? [message.group] : [],
        due: message.groupBy === "due" ? (bucketDue(message.group) ?? undefined) : undefined,
        hasDescription: false,
        attachments: 0,
      };
      window.setTimeout(() => {
        cards = [...cards, card];
        send({ upsert: [card], order: [...read().order, id] });
        window.apolloBoard?.created(message.token, true);
      }, 450);
      break;
    }
    case "createSubtask":
      window.setTimeout(() => window.apolloBoard?.created(message.token, true), 450);
      break;
    default:
      break;
  }
}

export function startDemo() {
  window.__apolloBoardDemo = handle;
  // Stand-in for the native toolbar search: `?q=` filters the fixture.
  const q = new URLSearchParams(location.search).get("q");
  if (q) window.setTimeout(() => send({ query: q }), 0);
  document.documentElement.classList.add("demo");
}
