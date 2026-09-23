import subprocess
import tempfile
from pathlib import Path
source=Path('Sources/DayPanel/Views/Common/VisualEffectView.swift').read_text()
component=source[source.index('private struct PanelGlassMaterial:'):source.index('/// Bottom of the active route')]
probe=r'''
struct Sample: View {
 let height: CGFloat
 var body: some View {
  ZStack(alignment: .top) {
   VStack { ForEach(0..<20) { i in Text("CONTEUDO \\(i) TESTE DE MATERIAL").frame(height: 30) } }
   PanelGlassMaterial().id(height).frame(height: height).overlay(Color.white.opacity(0.252))
  }.frame(width: 800,height: 600)
 }
}
func read(_ node: CALayer) -> [String] {
 var result: [String] = []
 for f in node.filters ?? [] {
  let o=f as AnyObject
  if (o.value(forKey:"name") as? String)=="glassBackground" {
   result.append("radius=\(o.value(forKey:"inputBlurRadius") ?? "nil") fill=\(o.value(forKey:"inputBlurFillBlurRadius") ?? "nil") scale=\(node.value(forKey:"scale") ?? "nil")")
  }
 }
 for c in node.sublayers ?? [] { result += read(c) }
 return result
}
let app=NSApplication.shared
app.setActivationPolicy(.prohibited)
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
window.appearance=NSAppearance(named:.aqua)
let host=NSHostingController(rootView: Sample(height:82))
window.contentViewController=host
window.orderBack(nil)
func snapshot(_ label:String) { print(label, window.contentView?.layer.map { read($0) } ?? []) }
for i in 1...12 {
 DispatchQueue.main.asyncAfter(deadline:.now()+Double(i)*0.2) {
  if i == 2 {
   func reset(_ node: CALayer) {
    for f in node.filters ?? [] {
     if ((f as AnyObject).value(forKey: "name") as? String) == "glassBackground" {
      node.setValue(20.0, forKeyPath: "filters.glassBackground.inputBlurRadius")
      node.setValue(8.0, forKeyPath: "filters.glassBackground.inputBlurFillBlurRadius")
      node.setValue(0.5, forKey: "scale")
     }
    }
    for child in node.sublayers ?? [] { reset(child) }
   }
   func redraw(_ view: NSView) {
    view.needsDisplay = true
    for child in view.subviews { redraw(child) }
   }
   if let layer = window.contentView?.layer { reset(layer) }
   redraw(window.contentView!)
  }
  if i % 3 == 0 { host.rootView = Sample(height: i % 2 == 0 ? 96 : 82) }
  snapshot("step-\(i)")
  if i==12 { exit(0) }
 }
}
app.run()
'''
with tempfile.TemporaryDirectory(prefix="apollo-header-check-") as folder:
    swift = Path(folder) / "probe.swift"
    executable = Path(folder) / "probe"
    swift.write_text('import AppKit\nimport SwiftUI\n'+component+probe)
    subprocess.run(["swiftc", str(swift), "-o", str(executable)], check=True)
    result = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
    print(result.stdout, end="")
    for line in result.stdout.splitlines():
        if line.startswith("step-") and not line.startswith("step-2 "):
            assert 'radius=3.98034 fill=1.592136 scale=1' in line, line

