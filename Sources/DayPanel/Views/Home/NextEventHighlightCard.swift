import SwiftUI

// Evento em destaque da Home — reintrodução do hero das versões anteriores,
// agora DENTRO da coluna da agenda (largura da lista de eventos) em vez de
// atravessar as duas colunas. Como o original, o destaque é TIPOGRÁFICO e
// senta flush na página — nenhuma caixa, borda ou barra: a linguagem da
// coluna é editorial e qualquer moldura destoa. A hierarquia vem do corpo
// maior + folio accent; um hairline com fade fecha a seção antes do dia.

struct NextEventHighlightCard: View {
    @ObservedObject var appState: AppState
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folio e Entrar na MESMA linha, 30pt abaixo do topo do painel
            // (medidas pedidas em 20/jul).
            HStack(alignment: .center, spacing: 8) {
                Folio(minutesLabel, accent: true)
                Spacer(minLength: 0)
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
            }
            .padding(.top, 10)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(timeFmt(event.startDate))
                    .font(Editorial.serif(24, .medium))
                    .foregroundStyle(Editorial.ink)
                    .monospacedDigit()
                Text("até \(timeFmt(event.endDate))")
                    .font(Editorial.serif(12).italic())
                    .foregroundStyle(Editorial.inkMute)
            }
            .padding(.top, 18)

            Text(event.title)
                .font(Editorial.sans(19, .semibold))
                .foregroundStyle(Editorial.ink)
                .tracking(-0.3)
                .lineLimit(2)
                .padding(.top, 5)
            if let sub = subline {
                Text("— \(sub)")
                    .font(Editorial.serif(13).italic())
                    .foregroundStyle(Editorial.inkSoft)
                    .lineLimit(1)
                    .padding(.top, 3)
            }

            rsvpRow

            // Fecho editorial da seção: hairline com fade, igual às demais
            // divisões da Home — é ele (e não uma caixa) que separa o
            // destaque da lista de dias.
            Rectangle().fill(Editorial.rule.opacity(0.65))
                .frame(height: 0.5)
                .edgeFadedHorizontal()
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── RSVP "Você vai?" — mesmo contrato do EventDetailView ────────────────

    @ViewBuilder
    private var rsvpRow: some View {
        if let me = event.attendees.first(where: { $0.isCurrentUser }) {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Editorial.rule.opacity(0.65))
                    .frame(height: 0.5)
                    .padding(.top, 8)
                HStack(spacing: 7) {
                    Text("VOCÊ VAI?")
                        .font(Editorial.sans(10, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Editorial.inkMute)
                    rsvpPill("Sim",    status: .accepted,  me: me)
                    rsvpPill("Não",    status: .declined,  me: me)
                    rsvpPill("Talvez", status: .tentative, me: me)
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
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
                .font(Editorial.sans(11.5, .medium))
                .foregroundStyle(isCurrent ? Editorial.page : Editorial.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
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
