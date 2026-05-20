import SwiftUI

// Pure-presentational SwiftUI view for the command palette.
// All state lives on `CommandPaletteModel`; navigation
// (↑↓⏎⎋) lives on `CommandPaletteController` via a
// key-down monitor. This file just renders.
struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel
    let onDismiss: () -> Void
    /// Closure the controller passes in. Tapping a row needs
    /// to fire the action AND close the panel; we forward to
    /// the controller so the model + panel lifecycle stay
    /// orchestrated in one place.
    let onPick: (Int) -> Void

    @FocusState private var queryFocused: Bool
    /// Pure-visual hover tracking. Kept separate from
    /// `model.selectedIndex` so the mouse cursor never
    /// fights keyboard navigation: arrow keys move the
    /// keyboard highlight, hover paints a softer secondary
    /// highlight on whichever row the cursor sits on, and
    /// the two can diverge without a feedback loop.
    @State private var hoveredId: String?
    /// Last cursor location seen by `.onContinuousHover`.
    /// Used to distinguish real mouse motion from
    /// `.active` re-fires triggered by layout shifts (rows
    /// sliding under a stationary cursor as `keyboardNavToken`
    /// scrolls the list). Only a genuine point-to-point
    /// change exits keyboard mode.
    @State private var lastHoverLocation: CGPoint = .zero
    /// Drives the entrance animation. `false` on first
    /// build, flips `true` on `.onAppear` so the palette
    /// scales/fades into place rather than appearing
    /// instantly. Tied to the SwiftUI side only — the
    /// NSPanel itself is created at full size; the
    /// in-content scale is what reads as "popping in".
    @State private var entered: Bool = false

    /// Respect the system "Reduce Motion" setting — when on, the
    /// palette still fades but skips scale/blur/slide so it can't
    /// induce motion discomfort.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Springs tuned for a Raycast/Linear-grade feel. `selSpring`
    /// drives the moving highlight + chevron; `enterSpring` the
    /// drop-in.
    private var selSpring: Animation {
        reduceMotion ? .easeInOut(duration: 0.12)
                     : .spring(response: 0.28, dampingFraction: 0.82)
    }
    private var enterSpring: Animation {
        .spring(response: 0.34, dampingFraction: 0.80)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Rectangle().fill(Editorial.rule).frame(height: 1)
            resultsList
            Rectangle().fill(Editorial.rule).frame(height: 1)
            footer
        }
        .frame(width: 680, height: 540)
        // Editorial card (prototype `PPalette` / `PPopup`):
        // near-neutral popup surface, hairline border, soft
        // ambient shadow — no glass.
        .background(Editorial.popup)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 50, x: 0, y: 40)
        .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 8)
        // Entrance: a confident "command bar lands" — scales up
        // from 0.96 anchored at the top, lifts 10pt, and a brief
        // 6→0 blur sharpens it into focus. Reduce Motion → fade
        // only.
        .scaleEffect(reduceMotion ? 1 : (entered ? 1.0 : 0.96), anchor: .top)
        .offset(y: reduceMotion ? 0 : (entered ? 0 : -10))
        .blur(radius: reduceMotion ? 0 : (entered ? 0 : 6))
        .opacity(entered ? 1 : 0)
        .onAppear {
            queryFocused = true
            withAnimation(reduceMotion ? .easeOut(duration: 0.18)
                                       : enterSpring) {
                entered = true
            }
        }
    }

    // MARK: - Header

    private var searchHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("COMANDO")
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1)
                .foregroundStyle(model.query.isEmpty
                                 ? Editorial.inkMute : Editorial.accent)
                .animation(.easeInOut(duration: 0.2),
                           value: model.query.isEmpty)
            TextField("Buscar tarefa, evento ou comando…",
                      text: $model.query)
                .textFieldStyle(.plain)
                .font(Editorial.serif(26).italic())
                .foregroundStyle(Editorial.ink)
                .tracking(-0.6)
                .focused($queryFocused)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.items.enumerated()),
                                id: \.element.id) { idx, item in
                            row(item,
                                isSelected: idx == model.selectedIndex,
                                isHovered:  item.id == hoveredId)
                                // Per-row entrance: each row
                                // fades in from -6pt with a
                                // small index-based delay so
                                // the result set lands as a
                                // cascade instead of all at
                                // once. State lives on the
                                // modifier so a row that
                                // survives a query refresh
                                // (same id) keeps `appeared
                                // == true` and stays put;
                                // only NEW rows replay the
                                // animation.
                                .modifier(
                                    RowAppearance(index: idx)
                                )
                                // Use the item's STABLE id
                                // (not the integer index) so
                                // `proxy.scrollTo(...)` keeps
                                // referring to the same row
                                // across query refreshes —
                                // integer ids shift when the
                                // result set changes and the
                                // scroll target jumps to a
                                // different row that happens
                                // to occupy the old slot.
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(idx) }
                                .onHover { hovering in
                                    // Hover updates ONLY the
                                    // visual hover state —
                                    // never `model.select(_:)`.
                                    // Otherwise rapid arrow-key
                                    // navigation would scroll
                                    // rows under the stationary
                                    // cursor, the cursor would
                                    // hover whichever row took
                                    // the previous one's slot,
                                    // and that hover would
                                    // immediately yank
                                    // selection back — a
                                    // feedback loop the user
                                    // can't escape.
                                    //
                                    // Suppressed entirely while
                                    // keyboard nav is active so
                                    // the secondary mouse-tint
                                    // doesn't compete with the
                                    // keyboard highlight on a
                                    // different row. The view's
                                    // `.onContinuousHover` below
                                    // clears `keyboardNavActive`
                                    // the moment the user
                                    // actually moves the cursor.
                                    guard !model.keyboardNavActive
                                    else { return }
                                    if hovering {
                                        hoveredId = item.id
                                    } else if hoveredId == item.id {
                                        hoveredId = nil
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 10)
                }
                // Reset to the top whenever the candidate
                // list itself changes — `itemsVersion` is
                // bumped by the model on every recompute.
                // Without this the previous query's scroll
                // offset persists and the LazyVStack lands
                // mid-list on a fresh result set, which
                // reads as the "auto-scroll glitch" the
                // user was seeing.
                .onChange(of: model.itemsVersion) { _, _ in
                    guard let first = model.items.first else { return }
                    proxy.scrollTo(first.id, anchor: .top)
                }
                // Detect REAL cursor movement (vs. rows
                // scrolling under a stationary cursor).
                // `.onContinuousHover` reports the cursor's
                // location as it moves; comparing against
                // the last seen location lets us tell a
                // genuine mouse motion from a re-fire of
                // the SAME location. Genuine motion hands
                // control back to the mouse: keyboard mode
                // off, hover tints come back. Layout
                // changes that fire `.active` with the same
                // location don't trip it.
                .onContinuousHover { phase in
                    if case .active(let loc) = phase {
                        if loc != lastHoverLocation {
                            lastHoverLocation = loc
                            model.resumeMouseMode()
                        }
                    }
                }
                // While keyboard nav is active, drop any
                // mouse-hover tint that was painted before
                // the user reached for the arrow keys.
                .onChange(of: model.keyboardNavActive) { _, active in
                    if active { hoveredId = nil }
                }
                // Keep the highlighted row visible while
                // the user navigates with ↑↓. No `anchor:`
                // — that flavour of `scrollTo` only nudges
                // when the row is OFF-SCREEN and leaves the
                // viewport untouched otherwise, which is
                // what makes Spotlight-style nav feel
                // crisp: most arrow presses don't scroll
                // at all (the highlight just walks down
                // visible rows), and when the highlight
                // hits the viewport edge we scroll exactly
                // one row's worth.
                //
                // No `withAnimation` either — animated
                // scrolls stack up on rapid keypresses and
                // create the laggy "navigation isn't fluid"
                // feel.
                .onChange(of: model.keyboardNavToken) { _, _ in
                    let new = model.selectedIndex
                    guard model.items.indices.contains(new)
                    else { return }
                    proxy.scrollTo(model.items[new].id)
                }
            }
        }
    }

    private func row(_ item: CommandPaletteItem,
                     isSelected: Bool,
                     isHovered: Bool) -> some View {
        // Prototype `PPalette` row, refined: a 2px cinnabar
        // accent bar grows in on the active row, the kind word +
        // chevron pick up the accent, the content steps 4pt to
        // the right, and a soft handoff crossfades the wash
        // between the old and new rows (no matchedGeometry —
        // robust under LazyVStack recycling). All motion springs;
        // Reduce Motion collapses it to a quick fade.
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(item.kind.badge)
                .font(Editorial.sans(10.5, .semibold))
                .tracking(0.8)
                .foregroundStyle(isSelected ? Editorial.accent : Editorial.inkMute)
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Editorial.serif(17))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.2)
                    .lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Caption(sub, size: 12.5)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Always present so the row width never reflows —
            // it slides + fades in on selection.
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Editorial.accent)
                .opacity(isSelected ? 1 : 0)
                .offset(x: isSelected ? 0 : (reduceMotion ? 0 : 6))
        }
        // The active row steps forward — a small but premium
        // "this is where you are" cue.
        .offset(x: (isSelected && !reduceMotion) ? 4 : 0)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // 3% wash in the row's accent (task status colour for
            // tasks, calendar colour for events, category colour
            // for commands) so the palette mirrors the same colour
            // language as the task list. The selection / hover ink
            // overlay sits on top.
            ZStack {
                item.tint.opacity(0.03)
                if isSelected {
                    Editorial.ink.opacity(0.05)
                } else if isHovered {
                    Editorial.ink.opacity(0.035)
                }
            }
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Editorial.accent)
                .frame(width: 2)
                .scaleEffect(y: isSelected ? 1 : 0, anchor: .center)
                .opacity(isSelected ? 1 : 0)
        }
        // Per-row animation keyed to BOTH states → moving the
        // selection animates the leaving row out and the arriving
        // row in simultaneously (the "soft handoff").
        .animation(selSpring, value: isSelected)
        .animation(reduceMotion ? .easeInOut(duration: 0.1)
                                : .easeOut(duration: 0.14),
                   value: isHovered)
    }

    private var emptyState: some View {
        Text(model.query.isEmpty
             ? "Comece a digitar para buscar tarefas, eventos ou comandos."
             : "Nada encontrado para “\(model.query)”.")
            .font(Editorial.serif(14).italic())
            .foregroundStyle(Editorial.inkMute)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
    }

    // MARK: - Footer (key hints)

    private var footer: some View {
        HStack(spacing: 18) {
            keyHint(symbols: ["↑", "↓"], label: "navegar")
            keyHint(symbols: ["⏎"],      label: "abrir")
            keyHint(symbols: ["esc"],    label: "fechar")
            Spacer(minLength: 0)
            Text("\(model.items.count) resultado\(model.items.count == 1 ? "" : "s")")
                .font(Editorial.sans(11))
                .foregroundStyle(Editorial.inkSoft)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: model.items.count)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func keyHint(symbols: [String], label: String) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(symbols, id: \.self) { s in
                    Text(s)
                        .font(Editorial.sans(10.5, .medium))
                        .foregroundStyle(Editorial.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Editorial.rule)
                        )
                }
            }
            Text(label)
                .font(Editorial.sans(11))
                .foregroundStyle(Editorial.inkSoft)
        }
    }
}

// MARK: - RowAppearance
//
// Per-row entrance animation for the palette's result list.
// Each NEW row (one whose id wasn't in the previous result
// set) gets a brief delayed fade-in from a few px above its
// resting position; rows that were already visible before
// the query refresh keep `appeared == true` and stay still.
//
// SwiftUI keeps the modifier instance alive across re-renders
// when its host row's id is stable (the `ForEach` we use is
// keyed on `item.id`), so `@State appeared` survives query
// changes for surviving rows. New rows get a fresh modifier
// instance with `appeared == false` and animate in.
//
// Stagger delay scales with the visible index — first row
// arrives at ~0ms, then ~22ms apart. Capped so a 40-result
// list doesn't drag the last row in 800ms later.
private struct RowAppearance: ViewModifier {
    let index: Int

    @State private var appeared: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-step delay, capped after a handful of rows so
    /// long result lists don't trail off.
    private static let stagger: Double = 0.024
    private static let maxStaggerSlots: Int = 12

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            // Slightly larger lift + a hair of scale so the
            // cascade reads as a deliberate "deal the cards"
            // beat rather than a flat fade. Reduce Motion →
            // fade only, no offset/scale, no stagger.
            .offset(y: (appeared || reduceMotion) ? 0 : -8)
            .scaleEffect((appeared || reduceMotion) ? 1 : 0.985,
                         anchor: .topLeading)
            .onAppear {
                guard !reduceMotion else { appeared = true; return }
                let slot = min(index, Self.maxStaggerSlots)
                let delay = Double(slot) * Self.stagger
                withAnimation(
                    .spring(response: 0.32, dampingFraction: 0.86)
                        .delay(delay)
                ) {
                    appeared = true
                }
            }
    }
}
