import SwiftUI

// MARK: - Header

struct GlassFormHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

// MARK: - Glass text field

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
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // Was `.regularMaterial` — see `GlassSectionCard`
            // for the per-frame backdrop-filter cost rationale.
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

// MARK: - Glass form row (generic container)

struct GlassFormRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Was `.regularMaterial` — multiple form rows per
        // section × multiple sections per popup compounded
        // into 8-12+ active CABackdropFilters per popup,
        // each redrawing on every scroll frame. Solid tint
        // gives the same readable surface without the
        // per-frame blur cost.
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Warning row

struct GlassWarningRow: View {
    let message: String
    var tint: Color = .orange

    init(_ message: String, tint: Color = .orange) {
        self.message = message
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tint == .red ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Glass section card (for Settings)

struct GlassSectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Was `.regularMaterial` — every section card allocated
        // its own `CABackdropFilter`, and the parent popup's
        // `.popupGlass(shape)` already provides one. With 4
        // sections in Settings (and similar counts in other
        // popups using this component), the stacked backdrop
        // filters re-rendered the blur of everything behind
        // them on every scroll frame, making the popup scroll
        // visibly stutter. Solid tinted fill matches the
        // visual weight without the per-frame backdrop cost.
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
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
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Text("Cancelar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Button(action: onCreate) {
                Text(createLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(createDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        createDisabled ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.accentColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(createDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
