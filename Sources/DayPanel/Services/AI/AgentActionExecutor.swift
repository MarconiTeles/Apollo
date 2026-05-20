import Foundation
import AppKit


/// Routes parsed `AgentAction`s through `AppState`'s mutation
/// API and reports back what actually happened. The executor
/// is the bridge between the AI's text-emission world and the
/// app's "real" task state — without it, the model's
/// `[[CREATE_TASK …]]` markers would just be decorative
/// strings on screen (which is exactly the bug that motivated
/// this whole agent layer).
///
/// All execution is `@MainActor` because every call site
/// touches `AppState`, which lives on the main actor.
@MainActor
final class AgentActionExecutor {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Executes one action, returning the result the chat layer
    /// can render as a confirmation pill (or error message).
    func execute(_ action: AgentAction) async -> AgentActionResult {
        guard let appState else {
            return .failed(reason: "Estado do app indisponível")
        }

        switch action {
        case let .createTask(title, priority, due, status, assignees,
                             description, start, tags, parent, links,
                             attachments):
            return await runCreateTask(
                title: title,
                priority: priority,
                due: due,
                status: status,
                assignees: assignees,
                description: description,
                start: start,
                tags: tags,
                parent: parent,
                links: links,
                attachments: attachments,
                appState: appState
            )

        case let .completeTask(ref):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            await appState.completeTask(task)
            let updated = appState.tasksById[task.id] ?? task
            return .updatedTask(updated)

        case let .updateTaskStatus(ref, newStatus):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            guard let target = appState.availableStatuses
                .first(where: {
                    $0.status.lowercased() == newStatus.lowercased()
                })
            else {
                return .failed(reason: "Status '\(newStatus)' não existe na lista")
            }
            await appState.updateTaskStatus(task, to: target)
            let updated = appState.tasksById[task.id] ?? task
            return .updatedTask(updated)

        case let .updateTaskPriority(ref, newPriority):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            guard let prio = priorityCode(from: newPriority) else {
                return .failed(reason: "Prioridade '\(newPriority)' inválida")
            }
            await appState.updateTaskPriority(task, to: prio)
            let updated = appState.tasksById[task.id] ?? task
            return .updatedTask(updated)

        case let .createEvent(title, start, end, dur, location, guests,
                              notes, meetingURL, color, availability, alarm):
            return await runCreateEvent(
                title: title,
                start: start,
                end: end,
                durationMinutes: dur,
                location: location,
                guests: guests,
                notes: notes,
                meetingURL: meetingURL,
                color: color,
                availability: availability,
                alarm: alarm,
                appState: appState
            )

        case let .deleteEvent(ref):
            guard let event = resolveEvent(ref: ref, in: appState) else {
                return .failed(reason: "Evento '\(ref)' não encontrado")
            }
            let title = event.title
            await appState.deleteEvent(event)
            return .deletedEvent(title: title)

        case let .scheduleTaskWork(ref, start, dur):
            return await runScheduleTaskWork(
                ref: ref,
                start: start,
                durationMinutes: dur,
                appState: appState
            )

        case let .convertEventToTask(ref, delSrc, newTitle, status, priority,
                                     assignees, description, start, due, tags,
                                     links, attachments):
            guard let event = resolveEvent(ref: ref, in: appState) else {
                return .failed(reason: "Evento '\(ref)' não encontrado")
            }
            // Merge event-derived defaults with user overrides.
            let titleM       = (newTitle?.isEmpty == false) ? newTitle : event.title
            let descM        = mergedConvertDescription(userDesc: description,
                                                        event: event)
            let dueM         = due ?? Self.isoDateTimeFormatter
                .string(from: event.startDate)
            let startM       = start
                ?? (event.isAllDay ? nil
                    : Self.isoDateTimeFormatter.string(from: event.startDate))
            // Funnel through the canonical create-task pipeline so
            // mentions / attachments / links land the same way they
            // do for plain CREATE_TASK markers.
            let result = await runCreateTask(
                title:       titleM ?? event.title,
                priority:    priority,
                due:         dueM,
                status:      status,
                assignees:   assignees,
                description: descM,
                start:       startM,
                tags:        tags,
                parent:      nil,
                links:       links,
                attachments: attachments,
                appState:    appState
            )
            // Delete source unless the user opted to keep both.
            if case .createdTask = result,
               !isFalseString(delSrc) {
                await appState.deleteEvent(event)
            }
            return result

        case let .convertTaskToEvent(ref, delSrc, newTitle, start, end, dur,
                                     location, guests, notes, meetingURL,
                                     color, availability, alarm):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            // Derive defaults from the task's start→due window
            // (matching the legacy `AppState.convertTaskToEvent`
            // logic) and let the user-supplied attrs override.
            let derivedStart = task.startDate
                ?? task.dueDate ?? Date().addingTimeInterval(3600)
            let derivedMinutes: Int = {
                if let s = task.startDate, let d = task.dueDate, d > s {
                    return min(Int(d.timeIntervalSince(s) / 60), 8 * 60)
                }
                return 60
            }()
            let derivedEnd = derivedStart
                .addingTimeInterval(TimeInterval(derivedMinutes * 60))
            let startM = start ?? Self.isoDateTimeFormatter
                .string(from: derivedStart)
            let endM   = end ?? Self.isoDateTimeFormatter
                .string(from: derivedEnd)
            let titleM = (newTitle?.isEmpty == false) ? newTitle : task.title
            let notesM = mergedConvertNotes(userNotes: notes, task: task)
            // Route through the canonical create-event pipeline so
            // guests / location / meeting URL etc. all land the
            // same way they do for plain CREATE_EVENT markers.
            let result = await runCreateEvent(
                title:           titleM ?? task.title,
                start:           startM,
                end:             endM,
                durationMinutes: dur,
                location:        location,
                guests:          guests,
                notes:           notesM,
                meetingURL:      meetingURL,
                color:           color,
                availability:    availability,
                alarm:           alarm,
                appState:        appState
            )
            if case .createdEvent = result,
               !isFalseString(delSrc) {
                await appState.deleteTask(task)
            }
            return result

        // ── Read / fetch routing ───────────────────────────

        case let .fetchComments(ref):
            return await runFetchComments(ref: ref, appState: appState)

        case let .fetchTaskDetails(ref):
            return await runFetchTaskDetails(ref: ref, appState: appState)

        case .fetchWorkspaceLists:
            return await runFetchWorkspaceLists(appState: appState)

        case let .fetchTaskHistory(ref):
            return await runFetchTaskHistory(ref: ref, appState: appState)

        case let .fetchTimeEntries(ref):
            return await runFetchTimeEntries(ref: ref, appState: appState)

        // ── Extended task mutations ────────────────────────

        case let .updateTaskDue(ref, due):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            let date = (due?.isEmpty ?? true) ? nil : Self.parseDateTime(due!)
            await appState.updateTaskDueDate(task, to: date)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .updateTaskStart(ref, start):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            let date = (start?.isEmpty ?? true) ? nil : Self.parseDateTime(start!)
            await appState.updateTaskStartDate(task, to: date)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .updateTaskTitle(ref, newTitle):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            await appState.updateTaskTitle(task, to: newTitle)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .updateTaskDescription(ref, desc, links, attachments):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            let (localFiles, remoteLinks) = resolveAttachments(
                links: links, attachments: attachments,
                pickerMessage: "Escolha arquivos para anexar a \"\(task.title)\"",
                appState: appState)
            // New body if given; otherwise keep the current one
            // so "anexa esse arquivo na descrição" doesn't wipe
            // existing text. Links/remote files appended below.
            var parts: [String] = []
            if let d = desc?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !d.isEmpty {
                parts.append(d)
            } else if let cur = task.description?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                      !cur.isEmpty {
                parts.append(cur)
            }
            if !remoteLinks.isEmpty {
                parts.append(remoteLinks.joined(separator: "\n"))
            }
            let body = parts.joined(separator: "\n\n")
            if !body.isEmpty {
                await appState.updateTaskDescription(task, to: body)
            }
            await uploadAll(localFiles, to: task, appState: appState)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .updateTaskAssignees(ref, add, remove):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            var current = Set(task.assignees.map(\.id))
            if let add, !add.isEmpty {
                let ids = Set(resolveClickUpMemberIds(add, in: appState))
                current.formUnion(ids)
            }
            if let remove, !remove.isEmpty {
                let ids = Set(resolveClickUpMemberIds(remove, in: appState))
                current.subtract(ids)
            }
            await appState.updateTaskAssignees(task, to: current)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .addTaskTag(ref, tag):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            var names = Set(task.tags.map { $0.name.lowercased() })
            names.insert(tag.lowercased())
            await appState.updateTaskTags(task, to: names)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .removeTaskTag(ref, tag):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            var names = Set(task.tags.map { $0.name.lowercased() })
            names.remove(tag.lowercased())
            await appState.updateTaskTags(task, to: names)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .addTaskComment(ref, text, attachments):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            let (localFiles, remoteLinks) = resolveAttachments(
                links: nil, attachments: attachments,
                pickerMessage: "Escolha arquivos para o comentário em \"\(task.title)\"",
                appState: appState)
            var commentParts: [String] = []
            if let t = text?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !t.isEmpty {
                commentParts.append(t)
            }
            if !remoteLinks.isEmpty {
                commentParts.append(remoteLinks.joined(separator: "\n"))
            }
            // Comment text is required by ClickUp even when the
            // point is the file — fall back to a short caption.
            let commentText = commentParts.isEmpty
                ? (localFiles.count == 1
                   ? "📎 \(localFiles[0].lastPathComponent)"
                   : "📎 \(localFiles.count) anexo(s)")
                : commentParts.joined(separator: "\n\n")
            let comment = await appState.addComment(
                to: task, text: commentText)
            await uploadAll(localFiles, to: task,
                            commentId: comment?.id, appState: appState)
            let fileNote = localFiles.isEmpty
                ? "" : " · \(localFiles.count) arquivo(s) anexado(s)"
            return .fetchedContext(
                label: "comment-posted",
                body: "Comentário enviado em \"\(task.title)\": "
                    + "\"\(commentText)\"\(fileNote)"
            )

        case let .addTaskAttachment(ref, files):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            let (localFiles, remoteLinks) = resolveAttachments(
                links: nil, attachments: files,
                pickerMessage: "Escolha arquivos para anexar a \"\(task.title)\"",
                appState: appState)
            if localFiles.isEmpty && remoteLinks.isEmpty {
                return .failed(
                    reason: "Nenhum arquivo selecionado para anexar")
            }
            await uploadAll(localFiles, to: task, appState: appState)
            // Remote URLs can't be uploaded as files — record
            // them as a link comment so they're not lost.
            if !remoteLinks.isEmpty {
                _ = await appState.addComment(
                    to: task,
                    text: "🔗 " + remoteLinks.joined(separator: "\n"))
            }
            let n = localFiles.count + remoteLinks.count
            return .fetchedContext(
                label: "attachment-added",
                body: "\(n) anexo(s) adicionado(s) em \"\(task.title)\""
            )

        case let .createSubtask(parentRef, title, priority, due, assignees):
            guard let parent = resolveTask(ref: parentRef, in: appState) else {
                return .failed(reason: "Tarefa pai '\(parentRef)' não encontrada")
            }
            let prio = priority.flatMap(Self.priorityCode(from:)) ?? 0
            let dueDate = due.flatMap(Self.parseDateTime)
            let assigneeIds = assignees.flatMap { raw in
                Array(Self.parseClickUpAssigneesSync(raw: raw, members: appState.availableMembers))
            } ?? []
            guard let sub = await appState.createSubtask(
                parent: parent,
                title: title,
                priority: prio,
                dueDate: dueDate,
                assigneeIds: assigneeIds
            ) else {
                return .failed(reason: "Falha ao criar subtarefa")
            }
            return .createdTask(sub)

        case let .deleteTask(ref):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            await appState.deleteTask(task)
            return .fetchedContext(
                label: "task-deleted",
                body: "Tarefa \"\(task.title)\" apagada."
            )

        case let .archiveTask(ref):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            await appState.archiveTask(task)
            return .updatedTask(appState.tasksById[task.id] ?? task)

        case let .duplicateTask(ref, newTitle):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            guard let duped = await appState.duplicateTask(task, newTitle: newTitle) else {
                return .failed(reason: "Falha ao duplicar tarefa")
            }
            return .createdTask(duped)

        case let .moveTaskToList(ref, listName):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            // Resolve list name → id via the workspace tree.
            let target = await resolveListId(named: listName, appState: appState)
            guard let targetId = target else {
                return .failed(reason: "Lista '\(listName)' não encontrada")
            }
            await appState.moveTaskToList(task, toListId: targetId)
            return .fetchedContext(
                label: "task-moved",
                body: "Tarefa \"\(task.title)\" movida para a lista \(listName)."
            )

        // ── Extended calendar mutations ────────────────────

        case let .updateEvent(ref, ns, ne, ndur, nt, nl, ag):
            guard let event = resolveEvent(ref: ref, in: appState) else {
                return .failed(reason: "Evento '\(ref)' não encontrado")
            }
            let newStart = ns.flatMap(Self.parseDateTime)
            var newEnd = ne.flatMap(Self.parseDateTime)
            // Duration takes precedence if both end and duration
            // are absent — let the user say "estende em 30min".
            if newEnd == nil, let dur = ndur,
               let mins = Self.parseDurationMinutes(dur) {
                let base = newStart ?? event.startDate
                newEnd = base.addingTimeInterval(TimeInterval(mins * 60))
            }
            // Append guests: merge incoming emails (or names
            // resolved via roster lookup) with the existing
            // attendee list so we EXTEND the invitee roster
            // rather than replace it. Without this merge a
            // PATCH with a partial attendees list would drop
            // anyone already on the event.
            var attendeesToWrite: [String]? = nil
            if let ag, !ag.trimmingCharacters(in: .whitespaces).isEmpty {
                let resolved = resolveAttendeeEmails(ag, in: appState)
                let existing = event.attendees.compactMap { $0.email }
                // Dedupe via Set, then back to array. Order is
                // not significant — Google sorts by response.
                attendeesToWrite = Array(Set(existing + resolved))
            }
            guard let updated = await appState.updateEvent(
                event,
                newStart: newStart,
                newEnd: newEnd,
                newTitle: nt,
                newLocation: nl,
                attendees: attendeesToWrite
            ) else {
                return .failed(reason: "Falha ao atualizar evento")
            }
            return .createdEvent(updated)

        case let .respondToEvent(ref, status):
            guard let event = resolveEvent(ref: ref, in: appState) else {
                return .failed(reason: "Evento '\(ref)' não encontrado")
            }
            let attendeeStatus: CalendarEvent.Attendee.Status = {
                switch status.lowercased() {
                case "accepted", "accept", "yes", "sim":     return .accepted
                case "declined", "decline", "no",  "não":    return .declined
                case "tentative", "maybe", "talvez":         return .tentative
                default: return .pending
                }
            }()
            await appState.respondToEvent(event, status: attendeeStatus)
            return .fetchedContext(
                label: "rsvp",
                body: "RSVP enviado para \"\(event.title)\": \(attendeeStatus.rawValue)."
            )

        // ── Batch / bulk ───────────────────────────────────

        case let .batchCreateTasks(titlesJSON):
            return await runBatchCreate(json: titlesJSON, appState: appState)

        case let .bulkUpdateStatus(filter, newStatus):
            return await runBulkUpdateStatus(filter: filter,
                                              newStatus: newStatus,
                                              appState: appState)

        case let .bulkReassign(filter, fromName, toName):
            return await runBulkReassign(filter: filter,
                                          fromName: fromName,
                                          toName: toName,
                                          appState: appState)

        // ── UI control ─────────────────────────────────────

        case let .openTask(ref):
            guard let task = resolveTask(ref: ref, in: appState) else {
                return .failed(reason: "Tarefa '\(ref)' não encontrada")
            }
            await MainActor.run { appState.detailTask = task }
            return .fetchedContext(
                label: "ui",
                body: "Popup da tarefa \"\(task.title)\" aberto."
            )

        case let .openEvent(ref):
            guard let event = resolveEvent(ref: ref, in: appState) else {
                return .failed(reason: "Evento '\(ref)' não encontrado")
            }
            await MainActor.run { appState.detailEvent = event }
            return .fetchedContext(
                label: "ui",
                body: "Popup do evento \"\(event.title)\" aberto."
            )

        case let .jumpToDate(date):
            guard let target = Self.parseDateTime(date) else {
                return .failed(reason: "Data '\(date)' inválida")
            }
            await MainActor.run {
                appState.selectedDate = target
                appState.todayJumpToken &+= 1
            }
            return .fetchedContext(
                label: "ui",
                body: "Timeline movida para \(date)."
            )

        case let .switchList(name):
            let ok = await appState.switchList(named: name)
            return ok
                ? .fetchedContext(label: "ui",
                                   body: "Lista ativa alterada para '\(name)'.")
                : .failed(reason: "Lista '\(name)' não encontrada no workspace")

        case .triggerSync:
            await appState.sync()
            return .fetchedContext(label: "ui",
                                    body: "Sincronização disparada.")

        case let .setSearch(query):
            await MainActor.run { appState.searchQuery = query }
            return .fetchedContext(label: "ui",
                                    body: "Busca de tarefas: \"\(query)\".")

        case let .setFilter(priority, assignees, tags, status):
            await MainActor.run {
                if let status, !status.isEmpty {
                    appState.selectedTaskStatus = status
                }
                var f = appState.taskFilters
                if let priority {
                    let codes = priority
                        .split(separator: ",")
                        .compactMap { Self.priorityCode(from: String($0).trimmingCharacters(in: .whitespaces)) }
                    f.priorities = Set(codes)
                }
                if let assignees, !assignees.isEmpty {
                    let ids = assignees
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .compactMap { needle -> Int? in
                            appState.availableMembers
                                .first { $0.username.lowercased().contains(needle.lowercased()) }?.id
                        }
                    f.assigneeIds = Set(ids)
                }
                if let tags, !tags.isEmpty {
                    let names = tags
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    f.tagNames = Set(names)
                }
                appState.taskFilters = f
            }
            return .fetchedContext(label: "ui",
                                    body: "Filtros aplicados.")

        case .clearFilters:
            await MainActor.run { appState.clearAllFilters() }
            return .fetchedContext(label: "ui",
                                    body: "Filtros limpos.")

        // ── Notifications / reminders ──────────────────────

        case let .scheduleReminder(title, body, fireDate, offset, anchor, isBefore):
            return await runScheduleReminder(
                title: title, body: body,
                fireDate: fireDate,
                relativeOffset: offset,
                relativeTo: anchor,
                relativeBefore: isBefore,
                appState: appState
            )

        case .fetchPendingReminders:
            return await runFetchPendingReminders()

        case let .cancelReminder(id):
            await NativeNotifier.shared.cancelScheduled(id: id)
            return .fetchedContext(
                label: "reminder-cancelled",
                body: "Lembrete \(id) cancelado."
            )
        }
    }

    // MARK: - Reminder scheduling

    /// Resolves the fire date — either parses an absolute
    /// datetime string OR computes "X before/after target"
    /// using an anchor task/event. Then registers a real
    /// UNCalendarNotificationTrigger via NativeNotifier.
    private func runScheduleReminder(
        title: String,
        body: String?,
        fireDate: String?,
        relativeOffset: String?,
        relativeTo: String?,
        relativeBefore: Bool,
        appState: AppState
    ) async -> AgentActionResult {
        // Resolve absolute target date.
        var when: Date? = nil
        var anchorTaskId: String? = nil
        var anchorEventId: String? = nil

        if let fireDate, !fireDate.isEmpty {
            when = Self.parseDateTime(fireDate)
        } else if let relativeOffset, let relativeTo {
            // "X before/after task/event Y"
            guard let mins = Self.parseDurationMinutes(relativeOffset)
                ?? Self.parseRelativeDays(relativeOffset)
            else {
                return .failed(reason: "Não entendi o offset '\(relativeOffset)' — use '2 dias', '3h', '30min', etc.")
            }

            // Try task first (richest set), then event.
            if let task = resolveTask(ref: relativeTo, in: appState),
               let due = task.dueDate {
                let direction = relativeBefore ? -1 : 1
                when = due.addingTimeInterval(TimeInterval(direction * mins * 60))
                anchorTaskId = task.id
            } else if let event = resolveEvent(ref: relativeTo, in: appState) {
                let base = relativeBefore ? event.startDate : event.endDate
                let direction = relativeBefore ? -1 : 1
                when = base.addingTimeInterval(TimeInterval(direction * mins * 60))
                anchorEventId = event.id
            } else {
                return .failed(reason: "Não encontrei a tarefa/evento '\(relativeTo)' como âncora")
            }
        }

        guard let fireAt = when else {
            return .failed(reason: "Não foi possível determinar o horário do lembrete")
        }
        guard fireAt > Date() else {
            return .failed(reason: "Esse horário (\(fireAt)) já passou")
        }

        let id = UUID()
        let scheduled = await NativeNotifier.shared.schedule(
            appNotifId: id,
            fireDate:   fireAt,
            kind:       .info,
            title:      title,
            subtitle:   nil,
            body:       body,
            targetKind: anchorTaskId != nil ? .task
                        : anchorEventId != nil ? .event : nil,
            targetId:   anchorTaskId ?? anchorEventId,
            tintHex:    nil
        )
        guard scheduled else {
            return .failed(reason: "Apollo não tem permissão pra disparar notificações. Habilite em Ajustes do macOS → Notificações → Apollo.")
        }
        let when_human = DateFormatter.localizedString(
            from: fireAt, dateStyle: .full, timeStyle: .short
        )
        return .fetchedContext(
            label: "reminder-scheduled",
            body: "Lembrete agendado: \"\(title)\" — disparará em \(when_human). (id: \(id.uuidString))"
        )
    }

    private func runFetchPendingReminders() async -> AgentActionResult {
        let pending = await NativeNotifier.shared.listPending()
        guard !pending.isEmpty else {
            return .fetchedContext(
                label: "reminders",
                body: "Você não tem nenhum lembrete agendado no momento."
            )
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "pt_BR")
        df.dateStyle = .medium
        df.timeStyle = .short
        var lines: [String] = ["Lembretes agendados (\(pending.count)):"]
        for r in pending {
            lines.append("• \(df.string(from: r.fireDate)) — \"\(r.title)\"\(r.body.isEmpty ? "" : ": \(r.body)")  [id: \(r.id.prefix(8))…]")
        }
        return .fetchedContext(label: "reminders",
                                body: lines.joined(separator: "\n"))
    }

    /// Parses "3 dias", "2 dia", "1 day", "5 days" as a
    /// minute-count for use in scheduleReminder offsets.
    /// Falls through (returns nil) for hour/minute strings —
    /// those are handled by `parseDurationMinutes` already.
    static func parseRelativeDays(_ raw: String) -> Int? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // Try "<num> dia(s)" or "<num> day(s)"
        let pattern = #"^(\d+)\s*(dia|dias|day|days|d)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: s),
              let n = Int(s[r])
        else { return nil }
        return n * 24 * 60
    }

    // MARK: - History / time entries

    private func runFetchTaskHistory(ref: String, appState: AppState) async -> AgentActionResult {
        guard let task = resolveTask(ref: ref, in: appState) else {
            return .failed(reason: "Tarefa '\(ref)' não encontrada")
        }
        do {
            let entries = try await appState.clickUpService.getTaskHistory(id: task.id)
            guard !entries.isEmpty else {
                return .fetchedContext(
                    label: "history:\(task.id)",
                    body: "A tarefa \"\(task.title)\" não tem histórico de mudanças registrado."
                )
            }
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withInternetDateTime, .withTimeZone]
            var lines: [String] = ["Histórico da tarefa \"\(task.title)\":"]
            for e in entries {
                lines.append("[\(df.string(from: e.date))] \(e.who) — \(e.what)")
            }
            return .fetchedContext(label: "history:\(task.id)",
                                    body: lines.joined(separator: "\n"))
        } catch {
            return .failed(reason: "Falha ao buscar histórico: \(error.localizedDescription)")
        }
    }

    private func runFetchTimeEntries(ref: String, appState: AppState) async -> AgentActionResult {
        guard let task = resolveTask(ref: ref, in: appState) else {
            return .failed(reason: "Tarefa '\(ref)' não encontrada")
        }
        do {
            let entries = try await appState.clickUpService.getTaskTimeEntries(id: task.id)
            guard !entries.isEmpty else {
                return .fetchedContext(
                    label: "time:\(task.id)",
                    body: "Nenhum tempo rastreado na tarefa \"\(task.title)\"."
                )
            }
            let totalMs = entries.reduce(0) { $0 + $1.durationMs }
            let totalH  = totalMs / 3_600_000
            let totalM  = (totalMs % 3_600_000) / 60_000
            var lines: [String] = ["Tempo rastreado em \"\(task.title)\" — total \(totalH)h\(totalM)m em \(entries.count) entrada(s):"]
            let df = DateFormatter()
            df.locale = Locale(identifier: "pt_BR")
            df.dateStyle = .short
            df.timeStyle = .short
            for e in entries {
                let durH = e.durationMs / 3_600_000
                let durM = (e.durationMs % 3_600_000) / 60_000
                let durStr = durH > 0 ? "\(durH)h\(durM)m" : "\(durM)m"
                let endStr = e.end.map { df.string(from: $0) } ?? "em curso"
                let note = e.note.isEmpty ? "" : " — \(e.note)"
                lines.append("• \(df.string(from: e.start)) → \(endStr)  ·  \(durStr)  ·  \(e.who)\(note)")
            }
            return .fetchedContext(label: "time:\(task.id)",
                                    body: lines.joined(separator: "\n"))
        } catch {
            return .failed(reason: "Falha ao buscar tempo: \(error.localizedDescription)")
        }
    }

    // MARK: - Bulk ops

    private func runBatchCreate(json: String, appState: AppState) async -> AgentActionResult {
        // Accept either a JSON array of strings ("['A','B']") or
        // a comma-separated list ("A, B, C") for resilience.
        var titles: [String] = []
        if let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            titles = arr
        } else {
            titles = json
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        guard !titles.isEmpty else {
            return .failed(reason: "Lista de títulos vazia")
        }
        var created: [String] = []
        for t in titles {
            if let task = await appState.createTask(title: t) {
                created.append(task.title)
            }
        }
        return .fetchedContext(
            label: "batch-created",
            body: "Criadas \(created.count) tarefas: " +
                created.map { "\"\($0)\"" }.joined(separator: ", ")
        )
    }

    private func runBulkUpdateStatus(filter: String,
                                     newStatus: String,
                                     appState: AppState) async -> AgentActionResult {
        let matches = matchTasks(filter: filter, in: appState)
        guard !matches.isEmpty else {
            return .failed(reason: "Filtro '\(filter)' não casou com nenhuma tarefa")
        }
        guard let target = appState.availableStatuses
            .first(where: { $0.status.lowercased() == newStatus.lowercased() })
        else {
            return .failed(reason: "Status '\(newStatus)' não existe")
        }
        var updated = 0
        for t in matches {
            await appState.updateTaskStatus(t, to: target)
            updated += 1
        }
        return .fetchedContext(
            label: "bulk-status",
            body: "\(updated) tarefa(s) movida(s) para \"\(target.status)\"."
        )
    }

    private func runBulkReassign(filter: String,
                                 fromName: String?,
                                 toName: String,
                                 appState: AppState) async -> AgentActionResult {
        var matches = matchTasks(filter: filter, in: appState)
        if let fromName, !fromName.isEmpty {
            let needle = fromName.lowercased()
            matches = matches.filter { task in
                task.assignees.contains { $0.username.lowercased().contains(needle) }
            }
        }
        guard !matches.isEmpty else {
            return .failed(reason: "Nenhuma tarefa casou com filtro+'\(fromName ?? "")'")
        }
        let toIds = Set(resolveClickUpMemberIds(toName, in: appState))
        guard !toIds.isEmpty else {
            return .failed(reason: "Membro '\(toName)' não encontrado")
        }
        var updated = 0
        for t in matches {
            var ids = Set(t.assignees.map(\.id))
            if let fromName {
                let needle = fromName.lowercased()
                let removeIds = t.assignees
                    .filter { $0.username.lowercased().contains(needle) }
                    .map(\.id)
                ids.subtract(removeIds)
            }
            ids.formUnion(toIds)
            await appState.updateTaskAssignees(t, to: ids)
            updated += 1
        }
        return .fetchedContext(
            label: "bulk-reassign",
            body: "\(updated) tarefa(s) reatribuída(s) para \(toName)."
        )
    }

    /// Loose filter resolver — matches tasks by status name,
    /// priority label, tag name, or substring on title.
    private func matchTasks(filter: String, in appState: AppState) -> [CUTask] {
        let needle = filter.lowercased().trimmingCharacters(in: .whitespaces)
        let pending = appState.tasks.filter { !$0.isCompleted }
        // Try as status name
        if pending.contains(where: { $0.status.lowercased() == needle }) {
            return pending.filter { $0.status.lowercased() == needle }
        }
        // Priority labels
        let prioMap: [String: Int] = [
            "urgente": 1, "urgent": 1,
            "alta": 2, "high": 2,
            "normal": 3,
            "baixa": 4, "low": 4
        ]
        if let p = prioMap[needle] {
            return pending.filter { $0.priority == p }
        }
        // Tag (with or without #)
        let tagNeedle = needle.hasPrefix("#") ? String(needle.dropFirst()) : needle
        let byTag = pending.filter { $0.tags.contains { $0.name.lowercased() == tagNeedle } }
        if !byTag.isEmpty { return byTag }
        // Substring on title — fallback
        return pending.filter { $0.title.lowercased().contains(needle) }
    }

    /// Synchronous-friendly version of the assignee resolver
    /// for code paths where async await isn't readily
    /// available.
    private static func parseClickUpAssigneesSync(raw: String,
                                                  members: [CUMember]) -> Set<Int> {
        var ids: Set<Int> = []
        for piece in raw.split(separator: ",") {
            let needle = piece.trimmingCharacters(in: .whitespaces).lowercased()
            if needle.isEmpty { continue }
            let stripped = needle.hasPrefix("@") ? String(needle.dropFirst()) : needle
            if let m = members.first(where: { $0.username.lowercased() == stripped })
                ?? members.first(where: { $0.username.lowercased().split(separator: " ").first.map(String.init) == stripped })
                ?? members.first(where: { $0.username.lowercased().contains(stripped) }) {
                ids.insert(m.id)
            }
        }
        return ids
    }

    /// Resolves `name` to a list id via the workspace tree.
    /// Loose match (case-insensitive contains) so the agent
    /// doesn't have to know the exact spelling.
    private func resolveListId(named name: String, appState: AppState) async -> String? {
        do {
            let workspaces = try await appState.clickUpService.getWorkspaces()
            for ws in workspaces {
                let spaces = (try? await appState.clickUpService.getSpaces(workspaceId: ws.id)) ?? []
                for sp in spaces {
                    let lists = (try? await appState.clickUpService.getLists(spaceId: sp.id)) ?? []
                    let needle = name.lowercased()
                    if let m = lists.first(where: { $0.name.lowercased() == needle })
                        ?? lists.first(where: { $0.name.lowercased().contains(needle) }) {
                        return m.id
                    }
                }
            }
        } catch {
            print("[Apollo] resolveListId: \(error)")
        }
        return nil
    }

    // MARK: - Read action routing

    /// Pulls the comment thread for one task from ClickUp,
    /// formats every comment + reply as plain text the model
    /// can reason about. Falls through to a `.failed` result
    /// when the task can't be resolved or the API call fails.
    private func runFetchComments(ref: String, appState: AppState) async -> AgentActionResult {
        guard let task = resolveTask(ref: ref, in: appState) else {
            return .failed(reason: "Tarefa '\(ref)' não encontrada")
        }
        let comments = await appState.loadComments(for: task)
        guard !comments.isEmpty else {
            return .fetchedContext(
                label: "comments:\(task.id)",
                body: "A tarefa \"\(task.title)\" ainda não tem nenhum comentário."
            )
        }
        var lines: [String] = ["Comentários da tarefa \"\(task.title)\" (\(comments.count) totais, do mais antigo ao mais recente):"]
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withTimeZone]
        for c in comments.sorted(by: { $0.date < $1.date }) {
            let when = df.string(from: c.date)
            let who  = c.userName ?? c.userEmail ?? "—"
            let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = text.isEmpty ? "(sem texto)" : text
            lines.append("[\(when)] \(who):\n\(snippet)")
            if !c.attachments.isEmpty {
                let names = c.attachments
                    .map { $0.title.isEmpty ? $0.url : $0.title }
                    .joined(separator: ", ")
                lines.append("  📎 \(c.attachments.count) anexo(s): \(names)")
            }
            if c.replyCount > 0 {
                let replies = await appState.loadReplies(to: c.id)
                for r in replies.sorted(by: { $0.date < $1.date }) {
                    let rWhen = df.string(from: r.date)
                    let rWho  = r.userName ?? r.userEmail ?? "—"
                    let rText = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    lines.append("    ↳ [\(rWhen)] \(rWho): \(rText.isEmpty ? "(sem texto)" : rText)")
                }
            }
        }
        return .fetchedContext(
            label: "comments:\(task.id)",
            body: lines.joined(separator: "\n\n")
        )
    }

    /// Re-fetches a task with the FULL ClickUp payload —
    /// untruncated description, every assignee, every
    /// attachment, custom fields. Useful when the prompt's
    /// 120-char snippet of the description isn't enough.
    private func runFetchTaskDetails(ref: String, appState: AppState) async -> AgentActionResult {
        guard let task = resolveTask(ref: ref, in: appState) else {
            return .failed(reason: "Tarefa '\(ref)' não encontrada")
        }
        // Trigger the same hydration the popup uses — it
        // refreshes attachments and any other field the list
        // endpoint omitted.
        await appState.hydrateTaskAttachments(taskId: task.id)
        let fresh = appState.tasksById[task.id] ?? task

        var lines: [String] = ["Detalhes completos da tarefa \"\(fresh.title)\":"]
        lines.append("- Status: \(fresh.status)")
        lines.append("- Prioridade: \(fresh.priorityLabel)")
        if let s = fresh.startDate {
            lines.append("- Início: \(s)")
        }
        if let d = fresh.dueDate {
            lines.append("- Vencimento: \(d)")
        }
        if !fresh.assignees.isEmpty {
            lines.append("- Responsáveis: " +
                         fresh.assignees.map(\.username).joined(separator: ", "))
        }
        if let creator = fresh.creator {
            lines.append("- Criada por: \(creator.username)")
        }
        if let created = fresh.dateCreated {
            lines.append("- Data de criação: \(created)")
        }
        if !fresh.tags.isEmpty {
            lines.append("- Tags: " +
                         fresh.tags.map { "#\($0.name)" }.joined(separator: " "))
        }
        if let desc = fresh.description?
            .trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            lines.append("- Descrição (completa):\n\(desc)")
        }
        if !fresh.attachments.isEmpty {
            lines.append("- Anexos (\(fresh.attachments.count)):")
            for att in fresh.attachments {
                let size = att.sizeString.map { " · \($0)" } ?? ""
                lines.append("  • \(att.title) [\(att.ext)\(size)] — \(att.url)")
            }
        }
        let subs = appState.subtasks(of: fresh.id)
        if !subs.isEmpty {
            lines.append("- Subtarefas (\(subs.count)):")
            for s in subs {
                let due = s.dueDate.map { " · vence \($0)" } ?? ""
                lines.append("  • \(s.title) [\(s.status)]\(due)")
            }
        }
        if let url = fresh.url {
            lines.append("- URL ClickUp: \(url)")
        }
        return .fetchedContext(
            label: "task:\(fresh.id)",
            body: lines.joined(separator: "\n")
        )
    }

    /// Lists the OTHER ClickUp lists the user has in the
    /// workspace. Useful when the user asks "tenho outra
    /// lista?" and the prompt itself only carries the active
    /// one.
    private func runFetchWorkspaceLists(appState: AppState) async -> AgentActionResult {
        do {
            let workspaces = try await appState.clickUpService.getWorkspaces()
            var allLists: [(workspace: String, space: String, list: String, id: String)] = []
            for ws in workspaces {
                let spaces = (try? await appState.clickUpService.getSpaces(workspaceId: ws.id)) ?? []
                for sp in spaces {
                    let lists = (try? await appState.clickUpService.getLists(spaceId: sp.id)) ?? []
                    for ls in lists {
                        allLists.append((ws.name, sp.name, ls.name, ls.id))
                    }
                }
            }
            guard !allLists.isEmpty else {
                return .fetchedContext(
                    label: "lists",
                    body: "Não encontrei nenhuma outra lista no seu ClickUp."
                )
            }
            let activeListId = KeychainHelper.load(for: KeychainHelper.Keys.clickupListId) ?? ""
            var lines: [String] = ["Listas do ClickUp do usuário (a lista ATIVA está marcada com →):"]
            for entry in allLists.sorted(by: { $0.list < $1.list }) {
                let marker = entry.id == activeListId ? "→" : "•"
                lines.append("\(marker) \(entry.list)  (espaço: \(entry.space), workspace: \(entry.workspace))")
            }
            return .fetchedContext(
                label: "lists",
                body: lines.joined(separator: "\n")
            )
        } catch {
            return .failed(reason: "Falha ao listar workspaces: \(error.localizedDescription)")
        }
    }

    // MARK: - createTask routing

    private func runCreateTask(
        title: String,
        priority: String?,
        due: String?,
        status: String?,
        assignees: String?,
        description: String?,
        start: String?,
        tags: String?,
        parent: String?,
        links: String?,
        attachments: String?,
        appState: AppState
    ) async -> AgentActionResult {
        let prio       = priority.flatMap(Self.priorityCode(from:)) ?? 0
        let dueDate    = due.flatMap(Self.parseDueDate(_:))
        let startDate  = start.flatMap {
            Self.parseDateTime($0) ?? Self.parseDueDate($0)
        }
        let statusName = status?.isEmpty == false ? status : nil
        let tagNames   = Self.splitList(tags)

        // Links + attachments. http(s) entries become clickable
        // links appended to the description (ClickUp linkifies
        // raw URLs); local file paths are queued for a real
        // attachment upload once the task exists.
        let (localFiles, remoteLinks) = resolveAttachments(
            links: links, attachments: attachments,
            pickerMessage: "Escolha arquivos para anexar a \"\(title)\"",
            appState: appState)
        var descParts: [String] = []
        if let d = description?
            .trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            descParts.append(d)
        }
        if !remoteLinks.isEmpty {
            descParts.append(remoteLinks.joined(separator: "\n"))
        }
        let finalDescription = descParts.isEmpty
            ? nil : descParts.joined(separator: "\n\n")

        // Assignees: explicit `assignees` attr UNION any
        // @mentions found in the title/description. The user's
        // "@Marconi Reis" must become a real assignee, not sit
        // as dead literal text (the reported bug).
        var ids = Set<Int>()
        if let raw = assignees,
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            ids.formUnion(resolveClickUpMemberIds(raw, in: appState))
        }
        ids.formUnion(Self.mentionedMemberIds(
            in: "\(title)\n\(description ?? "")", appState: appState))
        var resolvedAssignees = Array(ids)
        if resolvedAssignees.isEmpty {
            // Nothing explicit/mentioned → default to me so the
            // task is owned (the dictation invariant).
            resolvedAssignees = appState.clickUpAuthService.userId
                .map { [$0] } ?? []
        }

        // Subtask path — `parent` resolves to an existing task.
        if let parentRef = parent?
            .trimmingCharacters(in: .whitespaces), !parentRef.isEmpty,
           let parentTask = resolveTask(ref: parentRef, in: appState) {
            await appState.createSubtask(
                parent: parentTask,
                title: title,
                description: finalDescription,
                status: statusName,
                priority: prio,
                startDate: startDate,
                dueDate: dueDate,
                assigneeIds: resolvedAssignees,
                tagNames: tagNames
            )
            if let created = appState.tasks.first(where: {
                $0.parentId == parentTask.id && $0.title == title
            }) {
                await uploadAll(localFiles, to: created, appState: appState)
                return .createdTask(created)
            }
            return .updatedTask(
                appState.tasksById[parentTask.id] ?? parentTask)
        }

        let task = await appState.createTask(
            title: title,
            description: finalDescription,
            status: statusName,
            priority: prio,
            startDate: startDate,
            dueDate: dueDate,
            assigneeIds: resolvedAssignees,
            tagNames: tagNames
        )
        guard let task else {
            return .failed(reason: "Não foi possível criar a tarefa")
        }
        await uploadAll(localFiles, to: task, appState: appState)
        return .createdTask(task)
    }

    /// Comma/newline list → trimmed non-empty tokens.
    private static func splitList(_ s: String?) -> [String] {
        guard let s,
              !s.trimmingCharacters(in: .whitespaces).isEmpty
        else { return [] }
        return s.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Members whose username (or first name) is @-mentioned
    /// anywhere in `text`. Substring (not token) match so
    /// "@Marconi Reis" inside "@Marconi Reis testando" still
    /// resolves the person.
    private static func mentionedMemberIds(in text: String,
                                           appState: AppState) -> [Int] {
        guard text.contains("@") else { return [] }
        let hay = text.lowercased()
        var ids: [Int] = []
        for m in appState.availableMembers {
            let uname = m.username.lowercased()
            let first = uname
                .split(whereSeparator: { $0 == " " || $0 == "." })
                .first.map(String.init) ?? uname
            if hay.contains("@\(uname)") || hay.contains("@\(first)") {
                ids.append(m.id)
            }
        }
        return Array(Set(ids))
    }

    private func uploadAll(_ urls: [URL], to task: CUTask,
                           commentId: String? = nil,
                           appState: AppState) async {
        for u in urls {
            // Panel-vended URLs are security-scoped under the
            // sandbox; opening the scope makes the read reliable
            // (harmless no-op for already-accessible paths).
            let scoped = u.startAccessingSecurityScopedResource()
            _ = await appState.uploadCommentAttachment(
                for: task, fileURL: u, commentId: commentId)
            if scoped { u.stopAccessingSecurityScopedResource() }
        }
    }

    /// Resolves the AI's `links` + `attachments` strings into
    /// real local files (to upload) and remote URLs (to keep as
    /// links). http(s) entries are links; an entry that's
    /// already a sandbox-readable file is used as-is. Anything
    /// else — an LLM-typed path the sandbox can't read, or a
    /// keyword like "arquivo" — means "the user wants to send a
    /// file": we open an `NSOpenPanel` so they pick it (the only
    /// sandbox-correct way to grant read access), exactly like
    /// the manual create-task sheet.
    private func resolveAttachments(
        links: String?, attachments: String?, pickerMessage: String,
        appState: AppState
    ) -> (local: [URL], links: [String]) {
        var remote: [String] = Self.splitList(links)
        var local:  [URL]    = []
        var needsPicker = false
        for a in Self.splitList(attachments) {
            let scheme = URL(string: a)?.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                remote.append(a)
            } else {
                let path = a.hasPrefix("file://")
                    ? (URL(string: a)?.path ?? a) : a
                if FileManager.default.fileExists(atPath: path) {
                    local.append(URL(fileURLWithPath: path))
                } else {
                    // Sandbox can't read arbitrary LLM-typed
                    // paths — need either composer-attached files
                    // or a user file pick.
                    needsPicker = true
                }
            }
        }
        // Files the user dropped / picked in the chat composer
        // (identical UX to the task-comment box) take priority —
        // one-shot: consumed by the action that needs them so a
        // later message doesn't re-attach the same files.
        let dropped = appState.aiAgent.pendingAttachments
        if !dropped.isEmpty {
            local.append(contentsOf: dropped)
            appState.aiAgent.pendingAttachments = []
            needsPicker = false
        }
        // Only fall back to the native picker when an attachment
        // was clearly requested but nothing is available.
        if needsPicker && local.isEmpty {
            local.append(contentsOf: Self.promptForFiles(pickerMessage))
        }
        return (local, remote)
    }

    /// Sandbox-compatible file chooser (mirrors the manual
    /// `CreateTaskSheet.pickAttachments`). NSOpenPanel-vended
    /// URLs are readable by the sandboxed app.
    private static func promptForFiles(_ message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.allowsMultipleSelection = true
        panel.title                   = "Selecionar arquivos"
        panel.message                 = message
        panel.prompt                  = "Anexar"
        return panel.runModal() == .OK ? panel.urls : []
    }

    // MARK: - Calendar event creation

    private func runCreateEvent(
        title: String,
        start: String,
        end: String?,
        durationMinutes: String?,
        location: String?,
        guests: String?,
        notes: String?,
        meetingURL: String?,
        color: String?,
        availability: String?,
        alarm: String?,
        appState: AppState
    ) async -> AgentActionResult {
        guard let startDate = Self.parseDateTime(start) else {
            return .failed(reason: "Data/hora de início inválida: '\(start)'")
        }

        // End time resolution: explicit `end` wins; else
        // start + duration; else 1-hour default.
        let endDate: Date
        if let e = end, let parsed = Self.parseDateTime(e) {
            endDate = parsed
        } else if let dur = durationMinutes,
                  let minutes = Self.parseDurationMinutes(dur) {
            endDate = startDate.addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            endDate = startDate.addingTimeInterval(60 * 60)
        }

        guard endDate > startDate else {
            return .failed(reason: "Fim do evento precisa ser depois do início")
        }

        let resolvedGuests = guests.flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }.map { resolveAttendeeEmails($0, in: appState) } ?? []

        let notesValue = notes?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let meetURL: URL? = meetingURL.flatMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return URL(string: t.contains("://") ? t : "https://\(t)")
        }
        let colorId: String? = color.flatMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        // Default busy; only "free"/"livre"/"disponível" flips it.
        let busy: Bool = {
            guard let a = availability?.lowercased() else { return true }
            if a.contains("free") || a.contains("livre")
                || a.contains("dispon") { return false }
            return true
        }()
        // Alarm minutes → positive seconds offset (matches the
        // manual sheet's `Double(alarmMinutes) * 60`). "none"/
        // "sem"/0 → no alarm.
        let alarmOffset: TimeInterval? = alarm.flatMap { raw in
            let t = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "none" || t == "sem"
                || t == "nao" || t == "não" || t == "0" { return nil }
            if let mins = Self.parseDurationMinutes(t) {
                return TimeInterval(mins * 60)
            }
            let digits = t.filter { $0.isNumber }
            if let n = Int(digits), n > 0 { return TimeInterval(n * 60) }
            return nil
        }

        let event = await appState.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarId: nil,
            location: location?.isEmpty == false ? location : nil,
            notes: (notesValue?.isEmpty == false) ? notesValue : nil,
            meetingURL: meetURL,
            guestEmails: resolvedGuests,
            availabilityBusy: busy,
            alarmOffset: alarmOffset,
            colorId: colorId
        )

        if let event {
            return .createdEvent(event)
        }
        return .failed(reason: "Não foi possível criar o evento")
    }

    // MARK: - Cross-reference: schedule work block for a task

    private func runScheduleTaskWork(
        ref: String,
        start: String,
        durationMinutes: String,
        appState: AppState
    ) async -> AgentActionResult {
        guard let task = resolveTask(ref: ref, in: appState) else {
            return .failed(reason: "Tarefa '\(ref)' não encontrada")
        }
        guard let startDate = Self.parseDateTime(start) else {
            return .failed(reason: "Data/hora de início inválida: '\(start)'")
        }
        guard let minutes = Self.parseDurationMinutes(durationMinutes) else {
            return .failed(reason: "Duração inválida: '\(durationMinutes)'")
        }
        let endDate = startDate.addingTimeInterval(TimeInterval(minutes * 60))

        // Title matches the task title verbatim so the chat's
        // event-pill parser AND the timeline's pill share the
        // same identity. Visually it reads as "this slot is
        // for that task" without needing a separate "linked"
        // affordance.
        let event = await appState.createEvent(
            title: task.title,
            startDate: startDate,
            endDate: endDate,
            calendarId: nil,
            location: nil,
            notes: "Bloco de trabalho para a tarefa do ClickUp.",
            meetingURL: nil,
            guestEmails: [],
            availabilityBusy: true,
            alarmOffset: nil
        )
        if let event {
            return .createdEvent(event)
        }
        return .failed(reason: "Não foi possível agendar o bloco")
    }

    // MARK: - Event lookup

    private func resolveEvent(ref: String,
                              in appState: AppState) -> CalendarEvent? {
        if let direct = appState.events.first(where: { $0.id == ref }) {
            return direct
        }
        let lower = ref.lowercased()
        if let exact = appState.events.first(where: {
            $0.title.lowercased() == lower
        }) {
            return exact
        }
        return appState.events.first {
            $0.title.lowercased().contains(lower)
        }
    }

    // MARK: - Contact resolution

    /// Resolves a comma-separated string of names / usernames
    /// into ClickUp member ids. Match priority: exact id →
    /// exact username (case-insensitive) → first-name match →
    /// contains-match anywhere in username. Unresolved tokens
    /// are silently dropped — the caller decides whether to
    /// fall back to "me" if everything misses.
    private func resolveClickUpMemberIds(_ raw: String,
                                         in appState: AppState) -> [Int] {
        let tokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map(Self.stripMentionPrefix(_:))   // "@João" → "João"
            .filter { !$0.isEmpty }

        var ids: [Int] = []
        for token in tokens {
            // Numeric id straight through.
            if let n = Int(token) { ids.append(n); continue }

            let lower = token.lowercased()
            if let exact = appState.availableMembers.first(where: {
                $0.username.lowercased() == lower
            }) {
                ids.append(exact.id); continue
            }
            // First-name match — splits on space + dot to
            // tolerate "joao.silva" vs "João Silva".
            if let firstName = appState.availableMembers.first(where: { m in
                let first = m.username
                    .split(whereSeparator: { $0 == " " || $0 == "." })
                    .first
                    .map(String.init)?
                    .lowercased()
                return first == lower
            }) {
                ids.append(firstName.id); continue
            }
            // Last resort: substring.
            if let contains = appState.availableMembers.first(where: {
                $0.username.lowercased().contains(lower)
            }) {
                ids.append(contains.id)
            }
        }
        return Array(Set(ids))   // de-dup
    }

    /// Resolves a comma-separated string of names / e-mails
    /// into a list of e-mail addresses suitable for the
    /// EventKit `guestEmails` parameter.
    /// Lookup order:
    ///   • Token already looks like an e-mail → use as-is
    ///   • Match against `appState.calendarContacts` (built
    ///     from recent attendee history)
    ///   • Match against `appState.availableMembers` (ClickUp)
    ///     with the member's `email` if present
    /// Unresolved tokens are dropped.
    private func resolveAttendeeEmails(_ raw: String,
                                       in appState: AppState) -> [String] {
        let tokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map(Self.stripMentionPrefix(_:))   // "@João" → "João"
            .filter { !$0.isEmpty }

        var emails: [String] = []
        for token in tokens {
            if token.contains("@") {
                emails.append(token); continue
            }
            let lower = token.lowercased()
            if let match = appState.calendarContacts.first(where: { c in
                c.name.lowercased() == lower
                    || c.name.lowercased().split(whereSeparator: {
                        $0 == " " || $0 == "."
                    }).first.map(String.init)?.lowercased() == lower
                    || c.name.lowercased().contains(lower)
            }) {
                emails.append(match.email)
            }
        }
        return Array(Set(emails))   // de-dup
    }

    /// Strips a leading `@` from a contact reference. The chat
    /// composer's `@`-autocomplete inserts `@João Silva ` into
    /// the user's text; the AI may copy that verbatim into a
    /// marker (`assignees="@João Silva"`). Both tokenisers
    /// already handle the case-insensitive name matching, so
    /// dropping the `@` makes them work identically whether
    /// the AI included it or not.
    private static func stripMentionPrefix(_ s: String) -> String {
        guard s.hasPrefix("@") else { return s }
        return String(s.dropFirst())
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Datetime parsing

    /// Parses a wide range of datetime strings the model might
    /// emit. Accepts:
    ///   • `YYYY-MM-DDTHH:MM` (ISO with `T`)
    ///   • `YYYY-MM-DD HH:MM` (space-separated)
    ///   • `DD/MM/YYYY HH:MM`
    ///   • `today HH:MM` / `hoje HH:MM`
    ///   • `tomorrow HH:MM` / `amanhã HH:MM` / `amanha HH:MM`
    /// Returns nil for anything else.
    static func parseDateTime(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }

        // Try the absolute formats first.
        for fmt in absoluteDateTimeFormatters {
            if let d = fmt.date(from: trimmed) { return d }
        }

        // Relative formats: "today/hoje HH:MM" or
        // "tomorrow/amanhã HH:MM".
        let lower = trimmed.lowercased()
        let cal = Calendar.current
        let now = Date()

        let relativeKeywords: [(String, Int)] = [
            ("today",    0), ("hoje",    0),
            ("tomorrow", 1), ("amanhã",  1), ("amanha", 1),
        ]
        for (keyword, dayOffset) in relativeKeywords
        where lower.hasPrefix(keyword) {
            let rest = lower
                .dropFirst(keyword.count)
                .trimmingCharacters(in: .whitespaces)
            // "tomorrow 14:00" or "tomorrow 14h"
            guard let baseDay = cal.date(byAdding: .day,
                                         value: dayOffset, to: now)
            else { continue }
            if let time = parseClockTime(String(rest)) {
                return cal.date(bySettingHour: time.hour,
                                minute: time.minute,
                                second: 0, of: baseDay)
            }
            // No time given — default 09:00.
            return cal.date(bySettingHour: 9, minute: 0,
                            second: 0, of: baseDay)
        }
        return nil
    }

    /// Parses HH:MM / HHhMM / HHh into (hour, minute).
    private static func parseClockTime(_ raw: String) -> (hour: Int, minute: Int)? {
        let s = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "h", with: ":")
        let parts = s.split(separator: ":")
        guard let hour = parts.first.flatMap({ Int($0) }),
              hour >= 0, hour < 24
        else { return nil }
        let minute = parts.count >= 2
            ? (Int(parts[1]) ?? 0)
            : 0
        return (hour, minute)
    }

    /// Parses duration strings: `60` / `60min` / `1h` /
    /// `1h30` / `1:30` / `1.5h` → minutes.
    static func parseDurationMinutes(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }

        // Pure integer → minutes.
        if let n = Int(s) { return n }

        // "1.5h", "0.5h" → fractional hours.
        if s.hasSuffix("h"),
           let v = Double(s.dropLast()) {
            return Int(v * 60)
        }

        // "1h", "1h30", "2h15"
        if let hRange = s.range(of: "h") {
            let hPart = String(s[..<hRange.lowerBound])
            let mPart = String(s[hRange.upperBound...])
                .replacingOccurrences(of: "min", with: "")
                .replacingOccurrences(of: "m", with: "")
            guard let hours = Int(hPart) else { return nil }
            let minutes = Int(mPart.trimmingCharacters(in: .whitespaces)) ?? 0
            return hours * 60 + minutes
        }

        // "30min" / "30m"
        if s.hasSuffix("min"),
           let n = Int(s.dropLast(3)) {
            return n
        }
        if s.hasSuffix("m"),
           let n = Int(s.dropLast()) {
            return n
        }

        // "1:30"
        let parts = s.split(separator: ":")
        if parts.count == 2,
           let h = Int(parts[0]), let m = Int(parts[1]) {
            return h * 60 + m
        }
        return nil
    }

    private static let absoluteDateTimeFormatters: [DateFormatter] = {
        let templates = [
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "dd/MM/yyyy HH:mm",
            "dd/MM/yyyy HH:mm:ss",
        ]
        return templates.map { template in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = template
            f.timeZone = TimeZone.current
            return f
        }
    }()

    // MARK: - Task lookup

    /// Resolves a `taskRef` (id OR title) to a real `CUTask`.
    /// Lookup order, most → least precise:
    ///   1. Direct id hit in `tasksById`
    ///   2. Exact case-insensitive title match
    ///   3. Case-insensitive contains match (last resort —
    ///      lets the model say "the closet 18 task" and still
    ///      resolve to the right row).
    /// Excludes archived tasks from the contains-match path
    /// so we don't accidentally complete a stale archived task.
    private func resolveTask(ref: String, in appState: AppState) -> CUTask? {
        if let direct = appState.tasksById[ref] { return direct }

        let lower = ref.lowercased()
        if let exact = appState.tasks.first(where: {
            $0.title.lowercased() == lower
        }) {
            return exact
        }
        return appState.tasks
            .filter { !$0.archived }
            .first { $0.title.lowercased().contains(lower) }
    }

    // MARK: - Mappers

    /// Instance proxy so action cases can use the same code
    /// path as `runCreateTask` without going through `Self.`.
    private func priorityCode(from raw: String) -> Int? {
        Self.priorityCode(from: raw)
    }

    /// Maps the model's priority vocabulary to ClickUp's
    /// integer codes. Tolerant of pt-BR / en-US variants
    /// because the prompt accepts both.
    /// Shared ISO-8601 formatter (date+time, UTC offset) used to
    /// stringify Dates from convert-action sources so the strings
    /// round-trip back through `parseDateTime` cleanly when we
    /// hand them to `runCreateTask` / `runCreateEvent`. Distinct
    /// from the existing date-only `isoFormatter` further down
    /// (used by `parseDueDate`) — this one preserves the time.
    private static let isoDateTimeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Convert helpers

    /// True when the supplied string looks like the user opting
    /// OUT of source-deletion ("false"/"no"/"não"/"keep"/etc).
    private func isFalseString(_ s: String?) -> Bool {
        guard let raw = s?.trimmingCharacters(in: .whitespaces).lowercased(),
              !raw.isEmpty else { return false }
        return ["false", "no", "não", "nao", "0", "keep",
                "manter", "ambos", "both"].contains(raw)
    }

    /// Combines an optional user-supplied description with the
    /// canonical event-derived block (notes / Local / Link /
    /// Participantes + the "Convertido de…" footer). The user
    /// text goes FIRST so it's the prominent body; the derived
    /// context follows.
    private func mergedConvertDescription(
        userDesc: String?, event: CalendarEvent
    ) -> String {
        var lines: [String] = []
        if let u = userDesc?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !u.isEmpty {
            lines.append(u)
            lines.append("")     // blank line between user + derived
        }
        if let n = event.notes?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty { lines.append(n) }
        if let loc = event.location?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !loc.isEmpty { lines.append("Local: \(loc)") }
        if let url = event.meetingURL {
            lines.append("Link: \(url.absoluteString)")
        }
        let guests = event.attendees
            .map { $0.name.isEmpty ? ($0.email ?? "") : $0.name }
            .filter { !$0.isEmpty }
        if !guests.isEmpty {
            lines.append("Participantes: \(guests.joined(separator: ", "))")
        }
        lines.append("— Convertido de um evento do calendário.")
        return lines.joined(separator: "\n")
    }

    /// Mirrors `mergedConvertDescription` for the task→event
    /// direction: user notes first, then the task's body + the
    /// "Convertido da tarefa…" footer.
    private func mergedConvertNotes(
        userNotes: String?, task: CUTask
    ) -> String {
        var parts: [String] = []
        if let u = userNotes?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !u.isEmpty {
            parts.append(u)
            parts.append("")
        }
        if let d = task.description?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !d.isEmpty { parts.append(d) }
        parts.append("— Convertido da tarefa do ClickUp · \(task.priorityLabel).")
        return parts.joined(separator: "\n")
    }

    private static func priorityCode(from raw: String) -> Int? {
        switch raw.lowercased() {
        case "urgent", "urgente":         return 1
        case "high", "alta":              return 2
        case "normal", "média", "media":  return 3
        case "low", "baixa":              return 4
        case "none", "sem", "":           return 0
        default:                          return nil
        }
    }

    /// Parses `due` strings the model is told to emit. Accepts:
    ///   • `YYYY-MM-DD` (canonical)
    ///   • `DD/MM/YYYY` (PT-BR, common slip-up)
    ///   • `today` / `hoje`
    ///   • `tomorrow` / `amanhã` / `amanha`
    /// Returns nil for anything else — the executor reports
    /// "data inválida" and the user can re-prompt.
    private static func parseDueDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let cal = Calendar.current
        let now = Date()

        switch trimmed {
        case "today", "hoje":
            return cal.date(bySettingHour: 23, minute: 59, second: 59, of: now)
        case "tomorrow", "amanhã", "amanha":
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return cal.date(bySettingHour: 23, minute: 59, second: 59, of: tomorrow)
        default:
            break
        }

        // ISO YYYY-MM-DD
        if let date = isoFormatter.date(from: raw) {
            return cal.date(bySettingHour: 23, minute: 59, second: 59, of: date)
                ?? date
        }
        // PT-BR DD/MM/YYYY
        if let date = ptBRDateFormatter.date(from: raw) {
            return cal.date(bySettingHour: 23, minute: 59, second: 59, of: date)
                ?? date
        }
        return nil
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private static let ptBRDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM/yyyy"
        f.timeZone = TimeZone.current
        return f
    }()
}
