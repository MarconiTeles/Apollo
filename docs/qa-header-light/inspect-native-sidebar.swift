import AppKit
import SwiftUI

struct Probe: View {
 var body: some View {
  NavigationSplitView {
   List { Text("Sidebar background"); Text("Selection") }
    .navigationSplitViewColumnWidth(220)
  } detail: {
   VStack {
    Color.clear.frame(height: 92).glassEffect(.regular, in: Rectangle())
    Text("Detail").frame(maxWidth: .infinity, maxHeight: .infinity)
   }
  }
 }
}
func dump(_ view: NSView, _ depth: Int = 0) {
 if true {
  print(String(repeating: " ", count: depth), type(of:view), view.frame)
  if let e = view as? NSVisualEffectView { print("   EFFECT", e.material.rawValue, e.blendingMode.rawValue, e.state.rawValue) }
  if let g = view as? NSGlassEffectView {
   for key in ["style", "tintColor", "cornerRadius", "_variant", "_subvariant", "_subduedState", "_scrimState", "_adaptiveAppearance", "_tintOpacityReduced", "_contentLensing", "_inverseMeshed", "_useReducedShadowRadius"] {
    if g.responds(to: NSSelectorFromString(key)) { print("   ",key,String(describing:g.value(forKey:key))) }
   }
  }
 }
 for child in view.subviews { dump(child,depth+1) }
}
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:714),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
window.appearance=NSAppearance(named:.aqua)
window.titlebarAppearsTransparent=true
let host=NSHostingController(rootView:Probe())
window.contentViewController=host
window.contentView?.layoutSubtreeIfNeeded()
DispatchQueue.main.asyncAfter(deadline:.now()+1) {
 dump(window.contentView!.superview!)
 fflush(stdout)
 exit(0)
}
app.run()
