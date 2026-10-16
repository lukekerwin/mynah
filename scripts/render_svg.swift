// Render an SVG to a PNG at an exact pixel size using AppKit's SVG support.
//   swift scripts/render_svg.swift in.svg out.png WIDTH HEIGHT
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let w = Int(args[3]), let h = Int(args[4]),
      let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: render_svg.swift in.svg out.png width height\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
