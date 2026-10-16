// Render an SVG to a transparent PNG with WebKit, so SVG filters (the icon's drop
// shadow) are honoured. AppKit's SVG support ignores filters; Quick Look paints
// onto an opaque white background.
//   swift scripts/render_icon.swift in.svg out.png SIZE
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let parsed = Int(args[3]) else {
    FileHandle.standardError.write("usage: render_icon.swift in.svg out.png size\n".data(using: .utf8)!)
    exit(1)
}
let size = parsed
let svg = try! String(contentsOfFile: args[1], encoding: .utf8)
let html = """
<!doctype html><html><head><style>html,body{margin:0;background:transparent}svg{width:\(size)px;height:\(size)px;display:block}</style></head><body>\(svg)</body></html>
"""

final class Delegate: NSObject, WKNavigationDelegate {
    let size: Int
    let output: String
    init(size: Int, output: String) { self.size = size; self.output = output }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: size, height: size)
        config.snapshotWidth = NSNumber(value: size)
        webView.takeSnapshot(with: config) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                FileHandle.standardError.write("snapshot failed: \(String(describing: error))\n".data(using: .utf8)!)
                exit(1)
            }
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: self.output))
            exit(0)
        }
    }
}

let app = NSApplication.shared
let view = WKWebView(frame: CGRect(x: 0, y: 0, width: size, height: size))
view.setValue(false, forKey: "drawsBackground")
let delegate = Delegate(size: size, output: args[2])
view.navigationDelegate = delegate
let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.backgroundColor = .clear
window.isOpaque = false
window.contentView = view
view.loadHTMLString(html, baseURL: nil)
app.run()
