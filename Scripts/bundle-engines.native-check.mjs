import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, cp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
execFileSync(process.execPath, [path.join(root, 'Scripts/bundle-engines.check.mjs')], { cwd: root, stdio: 'inherit' });
const scratch = await mkdtemp(path.join(tmpdir(), 'leaf-native-render-'));
try {
  const bundle = path.join(scratch, 'LeafRender.bundle');
  await mkdir(path.join(bundle, 'Contents/Resources'), { recursive: true });
  await cp(path.join(root, 'Sources/LeafRender/Resources'), path.join(bundle, 'Contents/Resources'), { recursive: true });
  const probe = `import Foundation
import AppKit
extension Bundle { static var module: Bundle { Bundle(path: ${JSON.stringify(bundle)})! } }
@main struct NativeEngineProbe {
 static func main() async throws {
  let diagrams = DiagramEngine()
  let result = try await diagrams.render("flowchart LR\\n A[Native] --> B{Works}\\n B --> C[Swift]", theme: "dark")
  guard result.type == "flowchart" else { throw RenderError.invalidResult("diagram actor") }
  let casesURL = URL(fileURLWithPath: "/tmp/leaf-render-native-cases.json")
  let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: casesURL)) as! [[String: Any]]
  for item in cases {
   let image = NSImage(data: Data((item["svg"] as! String).utf8))
   guard let image, image.size.width > 0 else { throw RenderError.invalidResult(item["name"] as! String) }
   let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
   NSGraphicsContext.saveGraphicsState()
   NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)!
   image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
   NSGraphicsContext.restoreGraphicsState()
   guard let bytes = pixels.bitmapData, (0..<(256 * 256)).contains(where: { bytes[$0 * 4 + 3] > 0 }) else { throw RenderError.invalidResult("empty image") }
  }
  let markup = MarkupEngine()
  let html = try await markup.html("# Probe\\n\\n|A|B|\\n|-|-|\\n|1|2|\\n\\nMath $x^2$.\\n\\n\u0060\u0060\u0060mermaid\\nflowchart LR\\n A --> B\\n\u0060\u0060\u0060", options: .init(title: "Probe", dark: true, includeTOC: true))
  guard html.contains("<table>"), html.contains("katex"), html.contains("leaf-diagram"), html.contains("Table of contents") else { throw RenderError.invalidResult("HTML integration") }
  do { _ = try await diagrams.render("not a diagram"); throw RenderError.invalidResult("missing syntax failure") }
  catch RenderError.rendering(_, let code, _, _) { guard code == "unsupported-diagram" else { throw RenderError.invalidResult("error code") } }
  let fragment = try await markup.fragment("A **native** result.")
  guard fragment.contains("<strong>native</strong>") else { throw RenderError.invalidResult("fragment actor") }
  guard let image = NSImage(data: Data(result.svg.utf8)) else { throw RenderError.invalidResult("native SVG") }
  let view = NSImageView(frame: NSRect(x: 0, y: 0, width: result.width, height: result.height))
  view.image = image
  view.imageScaling = .scaleNone
  let pdf = view.dataWithPDF(inside: view.bounds)
  guard pdf.starts(with: Data("%PDF".utf8)) else { throw RenderError.invalidResult("PDF export") }
  print("PASS: Swift 6 actor isolation, JavaScriptCore actors, typed errors, 66 native SVG decoding/drawing cases and native PDF export.")
 }
}
`;
  const source = path.join(scratch, 'Probe.swift');
  await writeFile(source, probe);
  const binary = path.join(scratch, 'Probe');
  execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-sdk', '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk', ...['RenderTypes.swift', 'EngineRuntime.swift', 'DiagramEngine.swift', 'MarkupEngine.swift'].map(file => path.join(root, 'Sources/LeafRender', file)), source, '-o', binary], { cwd: root, stdio: 'inherit' });
  execFileSync(binary, [], { cwd: root, stdio: 'inherit' });
} finally {
  await rm(scratch, { recursive: true, force: true });
}
