import SwiftUI

// Editorial Calm form chrome. (Filename kept for git history;
// the "Glass" materials were replaced by paper + hairline +
// serif/sans + the single cinnabar accent — matching the
// prototype's `PNewTask` / `PNewEvent` overlays.)

// MARK: - Header

struct GlassFormHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Editorial.serif(22))
                    .foregroundStyle(Editorial.ink)
                    .tracking(-0.4)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Editorial.inkSoft)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Rectangle().fill(Editorial.rule).frame(height: 1)
        }
    }
}

// MARK: - Editorial text field

struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Editorial.sans(13))
            .foregroundStyle(Editorial.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Editorial.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Editorial.rule, lineWidth: 1)
            )
    }
}

// MARK: - Form row (generic container)

struct GlassFormRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
    }
}

// MARK: - Warning row

struct GlassWarningRow: View {
    let message: String
    var tint: Color = Editorial.accent

    init(_ message: String, tint: Color = Editorial.accent) {
        self.message = message
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(tint)
                .font(.system(size: 12, weight: .regular))
            Text(message)
                .font(Editorial.sans(12))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - Section card (for Settings)

struct GlassSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Folio(title)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Editorial.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Editorial.rule, lineWidth: 1)
        )
    }
}

// MARK: - Footer

struct GlassFormFooter: View {
    let onCancel:       () -> Void
    let onCreate:       () -> Void
    let createLabel:    String
    let createDisabled: Bool

    var body: some View {
        // Prototype `PNewTask`/`PNewEvent` footer: no divider —
        // the body flows continuously into a right-aligned button
        // pair (`gap 8`, `marginTop 24`) inside the 28px body gutter.
        HStack(spacing: 8) {
            Spacer()

            // Cancelar — paperButton(): page surface, hairline, ink.
            Button(action: onCancel) {
                Text("Cancelar")
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 4,
                                                      style: .continuous),
                                 tint: Editorial.page, tintOpacity: 0.6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Editorial.rule, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            // Criar — paperButton(true): solid ink surface, page
            // text, dimmed to 0.5 opacity while disabled (exact
            // prototype behavior — no separate muted style).
            Button(action: onCreate) {
                Text(createLabel)
                    .font(Editorial.sans(12.5, .medium))
                    .foregroundStyle(Editorial.page)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 4,
                                                      style: .continuous),
                                 tint: Editorial.ink, tintOpacity: 0.85)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Editorial.ink, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .opacity(createDisabled ? 0.5 : 1)
            .disabled(createDisabled)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 22)
    }
}
