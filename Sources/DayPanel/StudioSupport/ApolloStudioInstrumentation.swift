import SwiftUI

public struct StudioNodeID: RawRepresentable, Hashable, Codable, Sendable,
                            ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: StringLiteralType) { rawValue = value }
    public var description: String { rawValue }
}

public struct StudioSourceLocation: Hashable, Codable, Sendable {
    public var file: String
    public var line: Int
    public var column: Int

    public init(file: String, line: Int, column: Int = 1) {
        self.file = file
        self.line = line
        self.column = column
    }
}

public enum StudioNodeKind: String, CaseIterable, Codable, Sendable {
    case app, page, header, sidebar, section, list, row, card, button,
         label, image, field, popover, overlay, custom
}

public enum StudioPropertyKind: String, CaseIterable, Codable, Sendable {
    case horizontalPadding, verticalPadding, spacing, width, height,
         offsetX, offsetY, cornerRadius, opacity, shadowRadius, shadowY,
         zIndex, fontSize, foregroundColor, backgroundColor, material,
         scale, rotation, blur, animationDuration, lineLimit
}

public struct StudioPropertyDescriptor: Identifiable, Hashable, Codable, Sendable {
    public var id: StudioPropertyKind { kind }
    public var kind: StudioPropertyKind
    public var title: String
    public var value: Double?
    public var token: String?
    public var isEditable: Bool

    public init(kind: StudioPropertyKind,
                title: String,
                value: Double? = nil,
                token: String? = nil,
                isEditable: Bool = true) {
        self.kind = kind
        self.title = title
        self.value = value
        self.token = token
        self.isEditable = isEditable
    }
}

public struct StudioNodeDescriptor: Identifiable, Hashable, Sendable {
    public var id: StudioNodeID
    public var parentID: StudioNodeID?
    public var title: String
    public var kind: StudioNodeKind
    public var frame: CGRect
    public var source: StudioSourceLocation
    public var properties: [StudioPropertyDescriptor]

    public init(id: StudioNodeID,
                parentID: StudioNodeID? = nil,
                title: String,
                kind: StudioNodeKind,
                frame: CGRect = .zero,
                source: StudioSourceLocation,
                properties: [StudioPropertyDescriptor] = []) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.kind = kind
        self.frame = frame
        self.source = source
        self.properties = properties
    }
}

/// Non-destructive values used while the user experiments in the inspector.
/// They affect the live Studio canvas only; persisting them always goes through
/// the reviewed source-patch pipeline.
public struct StudioNodeOverride: Equatable, Codable, Sendable {
    public var horizontalPadding: Double = 0
    public var verticalPadding: Double = 0
    public var width: Double?
    public var height: Double?
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var opacity: Double = 1
    public var cornerRadius: Double?
    public var shadowRadius: Double = 0
    public var shadowY: Double = 0
    public var zIndex: Double = 0
    public var scale: Double = 1
    public var rotation: Double = 0
    public var blur: Double = 0
    public var fontSize: Double?
    public var lineLimit: Int?
    public var animationDuration: Double = 0
    public var foregroundColor: StudioColorValue?
    public var backgroundColor: StudioColorValue?
    public var allowsHitTesting = true
    public var accessibilityHidden = false

    public init() {}
}

/// Codable sRGB color used only by the non-destructive Studio canvas. Keeping
/// this value independent from NSColor also keeps ApolloRuntime testable and
/// prevents a visual experiment from leaking into the production theme.
public struct StudioColorValue: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

@MainActor
public final class ApolloStudioSession: ObservableObject {
    @Published public private(set) var nodes: [StudioNodeDescriptor] = []
    @Published public var selectedID: StudioNodeID?
    @Published public var hoveredID: StudioNodeID?
    @Published public var overrides: [StudioNodeID: StudioNodeOverride] = [:]

    private var swiftUINodes: [StudioNodeDescriptor] = []
    private var externalNodesByOwner: [StudioNodeID: [StudioNodeDescriptor]] = [:]

    public init() {}

    public var selectedNode: StudioNodeDescriptor? {
        nodes.first { $0.id == selectedID }
    }

    public func replaceNodes(_ incoming: [StudioNodeDescriptor]) {
        // SwiftUI preferences can arrive more than once for the same view while
        // layout settles. Stable identity wins and the final geometry replaces
        // the earlier sample.
        var byID: [StudioNodeID: StudioNodeDescriptor] = [:]
        for node in incoming { byID[node.id] = node }
        swiftUINodes = Array(byID.values)
        publishCombinedNodes()
    }

    /// AppKit lists use recycled NSCollectionView cells rather than one
    /// SwiftUI view per row. Their coordinator reports only the currently
    /// visible cells through this API, keyed by a stable task/notification id.
    /// Replacing the whole owner slice prevents a reused cell from retaining
    /// the identity of the item it previously displayed.
    public func replaceExternalNodes(owner: StudioNodeID,
                                     nodes incoming: [StudioNodeDescriptor]) {
        externalNodesByOwner[owner] = incoming
        publishCombinedNodes()
    }

    public func removeExternalNodes(owner: StudioNodeID) {
        externalNodesByOwner.removeValue(forKey: owner)
        publishCombinedNodes()
    }

    public func node(at point: CGPoint) -> StudioNodeDescriptor? {
        nodes
            .filter { $0.frame.contains(point) }
            .min { lhs, rhs in
                let lhsArea = lhs.frame.width * lhs.frame.height
                let rhsArea = rhs.frame.width * rhs.frame.height
                if lhsArea != rhsArea { return lhsArea < rhsArea }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    public func updateHover(at point: CGPoint?) {
        hoveredID = point.flatMap { node(at: $0)?.id }
    }

    private func publishCombinedNodes() {
        var byID: [StudioNodeID: StudioNodeDescriptor] = [:]
        for node in swiftUINodes { byID[node.id] = node }
        for (owner, externalNodes) in externalNodesByOwner {
            let origin = swiftUINodes.first(where: { $0.id == owner })?.frame.origin ?? .zero
            for var node in externalNodes {
                node.parentID = node.parentID ?? owner
                node.frame = node.frame.offsetBy(dx: origin.x, dy: origin.y)
                byID[node.id] = node
            }
        }
        let resolved = byID.values.sorted {
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.id.rawValue < $1.id.rawValue
        }
        if nodes != resolved { nodes = resolved }
        if let selectedID, byID[selectedID] == nil { self.selectedID = nil }
    }

    public func select(at point: CGPoint) {
        // Prefer the smallest hit rectangle: this selects the leaf control
        // instead of a page-sized ancestor when their frames overlap.
        selectedID = node(at: point)?.id
    }

    public func updateOverride(_ value: StudioNodeOverride, for id: StudioNodeID) {
        overrides[id] = value
    }

    public func clearOverride(for id: StudioNodeID) {
        overrides.removeValue(forKey: id)
    }
}

private struct ApolloStudioSessionKey: EnvironmentKey {
    static let defaultValue: ApolloStudioSession? = nil
}

public extension EnvironmentValues {
    var apolloStudioSession: ApolloStudioSession? {
        get { self[ApolloStudioSessionKey.self] }
        set { self[ApolloStudioSessionKey.self] = newValue }
    }
}

private struct StudioNodePreferenceKey: PreferenceKey {
    static var defaultValue: [StudioNodeDescriptor] = []
    static func reduce(value: inout [StudioNodeDescriptor],
                       nextValue: () -> [StudioNodeDescriptor]) {
        value.append(contentsOf: nextValue())
    }
}

#if DEBUG
private struct StudioOptionalFrameModifier: ViewModifier {
    let width: Double?
    let height: Double?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let width, let height {
            content.frame(width: CGFloat(width), height: CGFloat(height))
        } else if let width {
            content.frame(width: CGFloat(width))
        } else if let height {
            content.frame(height: CGFloat(height))
        } else {
            content
        }
    }
}

private struct StudioOptionalForegroundModifier: ViewModifier {
    let color: StudioColorValue?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color {
            content.foregroundStyle(color.swiftUIColor)
        } else {
            content
        }
    }
}

private struct StudioOptionalBackgroundModifier: ViewModifier {
    let color: StudioColorValue?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let color {
            content.background(color.swiftUIColor)
        } else {
            content
        }
    }
}

private struct StudioOptionalClipModifier: ViewModifier {
    let radius: Double?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let radius {
            content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
        }
    }
}

private struct StudioLiveOverrideModifier: ViewModifier {
    let value: StudioNodeOverride?

    func body(content: Content) -> some View {
        let resolved = value ?? StudioNodeOverride()

        content
            .padding(.horizontal, resolved.horizontalPadding)
            .padding(.vertical, resolved.verticalPadding)
            .modifier(StudioOptionalFrameModifier(width: resolved.width, height: resolved.height))
            .font(resolved.fontSize.map { .system(size: $0) })
            .lineLimit(resolved.lineLimit)
            .modifier(StudioOptionalForegroundModifier(color: resolved.foregroundColor))
            .modifier(StudioOptionalBackgroundModifier(color: resolved.backgroundColor))
            .modifier(StudioOptionalClipModifier(radius: resolved.cornerRadius))
            .opacity(resolved.opacity)
            .scaleEffect(resolved.scale)
            .rotationEffect(.degrees(resolved.rotation))
            .blur(radius: resolved.blur)
            .offset(x: resolved.offsetX, y: resolved.offsetY)
            .shadow(
                color: .black.opacity(resolved.shadowRadius > 0 ? 0.18 : 0),
                radius: resolved.shadowRadius,
                y: resolved.shadowY
            )
            .zIndex(resolved.zIndex)
            .allowsHitTesting(resolved.allowsHitTesting)
            .accessibilityHidden(resolved.accessibilityHidden)
            .animation(resolved.animationDuration > 0
                       ? .easeInOut(duration: resolved.animationDuration)
                       : nil,
                       value: resolved)
    }
}
#else
private struct StudioLiveOverrideModifier: ViewModifier {
    let value: StudioNodeOverride?

    func body(content: Content) -> some View {
        content
    }
}
#endif

private struct ApolloStudioNodeModifier: ViewModifier {
    @Environment(\.apolloStudioSession) private var session

    let prototype: StudioNodeDescriptor

    func body(content: Content) -> some View {
        content
            .modifier(StudioLiveOverrideModifier(value: session?.overrides[prototype.id]))
            .background {
                if session != nil {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: StudioNodePreferenceKey.self,
                            value: [descriptor(frame: proxy.frame(in: .named(ApolloStudioCanvasSpace.name)))]
                        )
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    private func descriptor(frame: CGRect) -> StudioNodeDescriptor {
        var result = prototype
        result.frame = frame
        return result
    }
}

public enum ApolloStudioCanvasSpace {
    public static let name = "ApolloStudioCanvasSpace"
}

public extension View {
    /// Registers a real Apollo view in the Studio hierarchy. In a public
    /// release this API is not compiled at all; in DEBUG it is inert unless an
    /// ApolloStudioSession is injected by the Studio host.
    func apolloStudioNode(
        _ id: StudioNodeID,
        title: String,
        kind: StudioNodeKind,
        parent: StudioNodeID? = nil,
        properties: [StudioPropertyDescriptor] = [],
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> some View {
#if DEBUG
        modifier(ApolloStudioNodeModifier(prototype: StudioNodeDescriptor(
            id: id,
            parentID: parent,
            title: title,
            kind: kind,
            source: StudioSourceLocation(file: String(describing: file), line: Int(line)),
            properties: properties
        )))
#else
        // The public Apollo build pays no view-tree or layout cost for Studio
        // instrumentation. The modifier (and its GeometryReader) only exists
        // in DEBUG hosts such as Apollo Studio and Xcode Canvas.
        self
#endif
    }

    func collectApolloStudioNodes(into session: ApolloStudioSession) -> some View {
#if DEBUG
        coordinateSpace(name: ApolloStudioCanvasSpace.name)
            .environment(\.apolloStudioSession, session)
            .onPreferenceChange(StudioNodePreferenceKey.self) { nodes in
                session.replaceNodes(nodes)
            }
#else
        self
#endif
    }
}
