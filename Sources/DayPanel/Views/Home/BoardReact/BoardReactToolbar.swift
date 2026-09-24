#if APOLLO_BOARD_REACT
import SwiftUI

/// The board's view controls as native window-toolbar menus (macOS 27,
/// same cells as the Comments filter): group by, sort and view options.
/// Search is the toolbar `.searchable` field and the task count the window
/// subtitle, so the page itself carries no toolbar.
struct BoardReactToolbarMenus: View {
    @ObservedObject var preferences: BoardReactPreferences

    private typealias Prefs = BoardReactPreferences.Prefs

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<Prefs, Value>) -> Binding<Value> {
        Binding(get: { preferences.current[keyPath: keyPath] },
                set: { value in preferences.update { $0[keyPath: keyPath] = value } })
    }

    static let groups: [(value: String, title: String, symbol: String)] = [
        ("status", "Status", "circle.dashed"),
        ("assignee", "Responsável", "person"),
        ("priority", "Prioridade", "flag"),
        ("tag", "Etiquetas", "tag"),
        ("due", "Vencimento", "calendar"),
    ]

    static let sorts: [(value: String, title: String)] = [
        ("manual", "Manual"),
        ("due", "Vencimento"),
        ("priority", "Prioridade"),
        ("title", "Nome da tarefa"),
        ("created", "Data de criação"),
        ("updated", "Última atualização"),
    ]

    private static let fields: [(value: String, title: String)] = [
        ("cover", "Capa"),
        ("parent", "Tarefa-pai"),
        ("description", "Descrição"),
        ("attachments", "Anexos"),
        ("checklist", "Checklist"),
        ("list", "Localização"),
        ("assignees", "Responsáveis"),
        ("due", "Vencimento"),
        ("priority", "Prioridade"),
        ("tags", "Etiquetas"),
    ]

    var body: some View {
        groupMenu
        sortMenu
        viewMenu
    }

    private var groupMenu: some View {
        let current = Self.groups.first { $0.value == preferences.current.groupBy } ?? Self.groups[0]
        return Menu {
            Picker("Agrupar por", selection: binding(\.groupBy)) {
                ForEach(Self.groups, id: \.value) { option in
                    Label(option.title, systemImage: option.symbol).tag(option.value)
                }
            }
            .pickerStyle(.inline)
        } label: {
            cell("Agrupar por \(current.title)", symbol: "rectangle.3.group", active: current.value != "status")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Agrupar por: \(current.title)")
    }

    private var sortMenu: some View {
        let manual = preferences.current.sort == "manual"
        let current = Self.sorts.first { $0.value == preferences.current.sort } ?? Self.sorts[0]
        return Menu {
            Picker("Ordenar por", selection: binding(\.sort)) {
                ForEach(Self.sorts, id: \.value) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.inline)
            Picker("Direção", selection: binding(\.desc)) {
                Text("Crescente").tag(false)
                Text("Decrescente").tag(true)
            }
            .pickerStyle(.inline)
            .disabled(manual)
        } label: {
            cell("Ordenar", symbol: "arrow.up.arrow.down", active: !manual)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(manual ? "Ordenar cards: manual (arraste)" : "Ordenar cards: \(current.title)")
    }

    private var viewMenu: some View {
        let prefs = preferences.current
        let hidden = Set(prefs.hidden)
        let touched = prefs.size != "m" || !prefs.covers || prefs.showClosed
            || prefs.subtasks != "cards" || !hidden.isEmpty
        return Menu {
            Picker("Subtarefas", selection: binding(\.subtasks)) {
                Text("Como cards").tag("cards")
                Text("Dentro da tarefa-pai").tag("nested")
                Text("Ocultar").tag("hidden")
            }
            Picker("Tamanho do card", selection: binding(\.size)) {
                Text("Pequeno").tag("s")
                Text("Médio").tag("m")
                Text("Grande").tag("l")
            }
            Menu("Campos no card") {
                ForEach(Self.fields, id: \.value) { field in
                    Toggle(field.title, isOn: Binding(
                        get: { !hidden.contains(field.value) },
                        set: { visible in
                            preferences.update { prefs in
                                prefs.hidden.removeAll { $0 == field.value }
                                if !visible { prefs.hidden.append(field.value) }
                            }
                        }))
                }
            }
            Divider()
            Toggle("Imagens de capa", isOn: binding(\.covers))
            Toggle("Mostrar campos vazios", isOn: binding(\.emptyFields))
            Toggle("Incluir tarefas fechadas", isOn: binding(\.showClosed))
            Divider()
            Toggle("Recolher grupos vazios", isOn: binding(\.collapseEmpty))
            Button("Recolher todos os grupos") { preferences.commands.send("collapseAll") }
            Button("Expandir todos os grupos") { preferences.commands.send("expandAll") }
        } label: {
            cell("Opções de exibição", symbol: "slider.horizontal.3", active: touched)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Opções de exibição do quadro")
    }

    /// Toolbar icon cell (ToolbarGlassButtonStyle metrics); accent while the
    /// option is away from its default, like the Comments filter.
    private func cell(_ title: String, symbol: String, active: Bool) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .foregroundStyle(active ? Editorial.accent : .primary)
            .font(.system(size: 15, weight: .regular))
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(Rectangle())
    }
}
#endif

#if APOLLO_BOARD_REACT
/// Visible task count as the window subtitle under "Quadro".
struct BoardReactSearchModifier: ViewModifier {
    @ObservedObject var preferences: BoardReactPreferences

    func body(content: Content) -> some View {
        if BoardReactRenderer.usesReact {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }

    private var subtitle: String {
        guard let total = preferences.total else { return "" }
        return total == 1 ? "1 tarefa" : "\(total) tarefas"
    }
}

/// Board search from the toolbar's glass group. The magnifier opens a
/// native popover with the search field, so the toolbar never changes width
/// (an inline field pushed "Minhas tarefas" into the overflow menu). The
/// popover closes on an outside click or Esc; while a filter is active the
/// magnifier stays in the accent colour and reopens it with the text.
struct BoardToolbarSearch: View {
    @ObservedObject var preferences: BoardReactPreferences
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Label("Buscar no quadro", systemImage: "magnifyingglass")
                .foregroundStyle(preferences.query.isEmpty ? Color.primary : Editorial.accent)
        }
        .help(preferences.query.isEmpty ? "Buscar no quadro (⌘K abre a busca geral)"
                                        : "Filtrando: \(preferences.query)")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            BoardSearchField(text: $preferences.query) { presented = false }
                .frame(width: 260)
                .padding(10)
        }
    }
}

/// NSSearchField with the system look. Esc clears the text, a second Esc
/// (or Return on an empty field) closes the popover.
private struct BoardSearchField: NSViewRepresentable {
    @Binding var text: String
    let onCollapse: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Buscar no quadro"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .none
        field.controlSize = .regular
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BoardSearchField
        init(_ parent: BoardSearchField) { self.parent = parent }

        @objc func changed(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        /// Esc clears, a second Esc closes; Return keeps the filter and closes.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCollapse()
                return true
            }
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if parent.text.isEmpty {
                parent.onCollapse()
            } else {
                parent.text = ""
                (control as? NSSearchField)?.stringValue = ""
            }
            return true
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            parent.text = ""
        }
    }
}
#endif
