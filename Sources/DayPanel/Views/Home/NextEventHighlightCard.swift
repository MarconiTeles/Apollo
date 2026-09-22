import SwiftUI

// Evento em destaque da Home — reintrodução do hero das versões anteriores,
// agora DENTRO da coluna da agenda (largura da lista de eventos) em vez de
// atravessar as duas colunas. A hierarquia tipográfica original é preservada,
// mas a superfície acompanha o restante do Apollo com um fundo Liquid Glass.

struct NextEventHighlightCard: View {
    @ObservedObject var appState: AppState
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Folio(minutesLabel, accent: true)

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(timeFmt(event.startDate))
                        .font(Editorial.serif(19, .medium))
                        .foregroundStyle(Editorial.ink)
                        .monospacedDigit()
                    Text("até \(timeFmt(event.endDate))")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkMute)
                }
                .padding(.top, 9)

                Text(event.title)
                    .font(Editorial.sans(15.5, .semibold))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.15)
                    .lineLimit(2)
                    .padding(.top, 3)
                if let sub = subline {
                    Text("— \(sub)")
                        .font(Editorial.serif(11.5).italic())
                        .foregroundStyle(Editorial.inkSoft)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 9) {
                if let url = meetingURL {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Text("Entrar")
                                .font(Editorial.sans(12, .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Editorial.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Editorial.page))
                        .overlay(
                            Capsule().strokeBorder(Editorial.rule, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .glassHover()
                }

                rsvpControls
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Keep the List row at the card's intrinsic content height. Applying
        // glass to a flexible Color.clear background let the material inherit
        // the row proposal and visually expand far beyond the hero content.
        .fixedSize(horizontal: false, vertical: true)
        .highlightCardGlass(
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
    }

    // ── RSVP "Você vai?" — mesmo contrato do EventDetailView ────────────────

    @ViewBuilder
    private var rsvpControls: some View {
        if let me = event.attendees.first(where: { $0.isCurrentUser }) {
            VStack(alignment: .trailing, spacing: 5) {
                Text("VOCÊ VAI?")
                    .font(Editorial.sans(9, .semibold))
                    .tracking(1)
                    .foregroundStyle(Editorial.inkMute)
                HStack(spacing: 7) {
                    rsvpPill("Sim", status: .accepted, me: me)
                    rsvpPill("Não", status: .declined, me: me)
                    rsvpPill("Talvez", status: .tentative, me: me)
                }
            }
        }
    }

    private func rsvpPill(_ label: String,
                          status: CalendarEvent.Attendee.Status,
                          me: CalendarEvent.Attendee) -> some View {
        let isCurrent = me.status == status
        return Button {
            appState.updateRSVP(for: event, attendeeEmail: me.email, to: status)
        } label: {
            Text(label)
                .font(Editorial.sans(10.5, .medium))
                .foregroundStyle(isCurrent ? Editorial.page : Editorial.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .liquidGlassCapsule(tint: isCurrent ? Editorial.ink : Editorial.page,
                                    tintOpacity: isCurrent ? 0.85 : 0.55)
                .overlay(
                    Capsule().strokeBorder(
                        isCurrent ? Color.clear : Editorial.rule,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glassHover()
        .animation(.easeOut(duration: 0.16), value: isCurrent)
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private var minutesLabel: String {
        let mins = Int(event.startDate.timeIntervalSinceNow / 60)
        if mins <= 0 { return "Agora" }
        if mins >= 60 * 24 {
            let days = mins / (60 * 24)
            return days == 1 ? "Amanhã" : "Em \(days) dias"
        }
        if mins >= 60 {
            let hours = mins / 60
            return "Em \(hours) h"
        }
        return "Em \(mins) min"
    }

    private var subline: String? {
        var bits: [String] = []
        if let loc = event.location, !loc.isEmpty { bits.append(loc) }
        let names = event.attendees
            .filter { !$0.isCurrentUser }
            .map(\.name)
            .filter { !$0.isEmpty }
            .prefix(3)
        if !names.isEmpty {
            bits.append("com " + names.joined(separator: ", "))
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private var meetingURL: URL? {
        if let u = event.meetingURL { return u }
        if let s = event.location {
            for token in s.split(whereSeparator: { " \n\t".contains($0) }) {
                if let u = URL(string: String(token)),
                   u.scheme?.hasPrefix("http") == true {
                    return u
                }
            }
        }
        return nil
    }

    private func timeFmt(_ d: Date) -> String {
        SharedDateFormatters.shortTime24h.string(from: d)
    }
}
