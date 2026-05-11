import SwiftUI
import AppKit

// Inline detail rows shown below an event's compact header when the user
// taps it. Mirrors the Google-Calendar popup layout but compacted for the
// timeline column width.

struct EventInlineDetail: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(.separator.opacity(0.5))
                .frame(height: 0.5)
                .padding(.horizontal, -14)

            if let url = event.meetingURL { meetingRow(url: url) }
            if let loc = event.location, !loc.isEmpty { locationRow(loc) }
            if !event.attendees.isEmpty { attendeesSection }
            if let alarm = event.alarmOffsets.first { alarmRow(alarm) }
            if let calName = event.calendarName { calendarRow(calName) }
            if let notes = event.notes, !notes.isEmpty { notesSection(notes) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

    private func meetingRow(url: URL) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "video.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Link(meetingProvider(url), destination: url)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Text(url.host ?? url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help("Copiar link")
        }
    }

    private func meetingProvider(_ url: URL) -> String {
        let s = url.absoluteString
        if s.contains("meet.google.com") { return "Entrar com o Google Meet" }
        if s.contains("zoom.us")         { return "Entrar no Zoom" }
        if s.contains("teams.")          { return "Entrar no Teams" }
        if s.contains("webex.com")       { return "Entrar no Webex" }
        return "Entrar na chamada"
    }

    private func locationRow(_ location: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "mappin.circle.fill")
                .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
            Text(location)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var attendeesSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(event.attendees.count) convidado\(event.attendees.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                if !attendeeCounts.isEmpty {
                    Text(attendeeCounts).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(event.attendees, id: \.email) { a in
                    attendeeRow(a)
                }
            }
            Spacer()
        }
    }

    private var attendeeCounts: String {
        let g = Dictionary(grouping: event.attendees, by: \.status)
        var parts: [String] = []
        if let n = g[.accepted]?.count,  n > 0 { parts.append("\(n): sim") }
        if let n = g[.declined]?.count,  n > 0 { parts.append("\(n): não") }
        if let n = g[.tentative]?.count, n > 0 { parts.append("\(n): talvez") }
        if let n = g[.pending]?.count,   n > 0 { parts.append("\(n): pendente") }
        return parts.joined(separator: " · ")
    }

    private func attendeeRow(_ a: CalendarEvent.Attendee) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(avatarColor(for: a.name))
                Text(initials(for: a.name))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .overlay(alignment: .bottomTrailing) {
                statusBadge(a.status).offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(a.name).font(.caption2.weight(.medium)).lineLimit(1)
                if a.isOrganizer {
                    Text("Organizador").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: CalendarEvent.Attendee.Status) -> some View {
        switch status {
        case .accepted:  badge(systemName: "checkmark.circle.fill", color: .green)
        case .declined:  badge(systemName: "xmark.circle.fill",     color: .red)
        case .tentative: badge(systemName: "questionmark.circle.fill", color: .orange)
        default:         EmptyView()
        }
    }

    private func badge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8))
            .foregroundStyle(color)
            .background(Circle().fill(.background).frame(width: 8, height: 8))
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last  = parts.dropFirst().last?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    private func avatarColor(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo]
        return palette[abs(name.hashValue) % palette.count]
    }

    private func alarmRow(_ offset: TimeInterval) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
            Text(alarmText(offset)).font(.caption).foregroundStyle(.primary)
            Spacer()
        }
    }

    private func alarmText(_ offset: TimeInterval) -> String {
        let mins = Int(abs(offset) / 60)
        if mins == 0 { return "No início do evento" }
        if mins < 60 { return "\(mins) minutos antes" }
        let hours = mins / 60
        if hours < 24 { return "\(hours) hora\(hours == 1 ? "" : "s") antes" }
        let days = hours / 24
        return "\(days) dia\(days == 1 ? "" : "s") antes"
    }

    private func calendarRow(_ name: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .font(.caption).foregroundStyle(.tertiary).frame(width: 14)
            Text(name).font(.caption).foregroundStyle(.primary).lineLimit(1)
            Spacer()
        }
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(.separator.opacity(0.5))
                .frame(height: 0.5)
                .padding(.horizontal, -14)
            Text(LocalizedStringKey(notes))
                .font(.caption2)
                .foregroundStyle(.primary)
                .tint(.blue)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
