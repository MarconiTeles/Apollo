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

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.6)
            resultsList
            footer
        }
        .frame(width: 640, height: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        // Entrance: scale up from 0.94 + fade in. The
        // anchor is `.top` so the palette appears to drop
        // into place from above its final position rather
        // than balloon out from the centre — reads as
        // "command bar lands" instead of "modal alert
        // pops".
        .scaleEffect(entered ? 1.0 : 0.94, anchor: .top)
        .opacity(entered ? 1 : 0)
        .onAppear {
            queryFocused = true
            withAnimation(
                .spring(response: 0.32, dampingFraction: 0.78)
            ) {
                entered = true
            }
        }
    }

    // MARK: - Header

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Buscar tarefa ou comando…",
                      text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($queryFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsList: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
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
                    .padding(8)
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
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6,
                                  style: .continuous)
                    .fill(item.tint.opacity(0.18))
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.tint)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let sub = item.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Section badge — minor signal so users learn
            // which results are tasks vs. events vs. app
            // commands.
            Text(item.kind.badge)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(.tertiary)

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            // Two-tier highlight. Keyboard selection wins
            // when both are true (the user is steering with
            // the keys; the cursor's position is incidental).
            // Hover-only paints a softer secondary tint so
            // the user gets feedback that the mouse IS over
            // a row but doesn't lose track of where the
            // keyboard cursor is.
            RoundedRectangle(cornerRadius: 8,
                              style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.20)
                        : isHovered
                            ? Color.primary.opacity(0.06)
                            : Color.clear
                )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty
                 ? "Comece a digitar para buscar tarefas ou comandos"
                 : "Nenhum resultado para “\(model.query)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Footer (key hints)

    private var footer: some View {
        HStack(spacing: 14) {
            keyHint(symbol: "↑↓", label: "navegar")
            keyHint(symbol: "↩", label: "abrir")
            keyHint(symbol: "esc", label: "fechar")
            Spacer()
            Text("\(model.items.count) resultado\(model.items.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thickMaterial.opacity(0.5))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.primary.opacity(0.06)),
            alignment: .top
        )
    }

    private func keyHint(symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(symbol)
                .font(.system(size: 10, weight: .semibold,
                              design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3,
                                      style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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

    /// Per-step delay, capped after a handful of rows so
    /// long result lists don't trail off.
    private static let stagger: Double = 0.022
    private static let maxStaggerSlots: Int = 12

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : -6)
            .onAppear {
                let slot = min(index, Self.maxStaggerSlots)
                let delay = Double(slot) * Self.stagger
                withAnimation(
                    .spring(response: 0.30,
                             dampingFraction: 0.85)
                        .delay(delay)
                ) {
                    appeared = true
                }
            }
    }
}
