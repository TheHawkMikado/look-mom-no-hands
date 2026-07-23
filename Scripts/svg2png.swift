#!/usr/bin/env swift
// svg2png <in.svg> <out.png> <width-px> <height-px>
//
// Rasterises an SVG with the WebKit that already ships with macOS, so the icon
// pipeline needs no Homebrew (rsvg/inkscape/imagemagick are all absent on a
// clean machine). Renders on a transparent background.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5,
      let width = Int(args[3]), let height = Int(args[4]) else {
    FileHandle.standardError.write("usage: svg2png <in.svg> <out.png> <w> <h>\n".data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let svg = try? String(contentsOf: inURL, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(inURL.path)\n".data(using: .utf8)!)
    exit(1)
}

// Force the SVG to fill the viewport exactly: the file's own width/height
// attributes are the design size, not the export size.
let html = """
<!doctype html><meta charset="utf-8">
<style>
  html,body { margin:0; padding:0; background:transparent; }
  svg { display:block; width:\(width)px; height:\(height)px; }
</style>
\(svg)
"""

final class Snapshotter: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let outURL: URL
    var failure: String?
    var done = false

    init(width: Int, height: Int, outURL: URL) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height),
                            configuration: config)
        self.outURL = outURL
        super.init()
        webView.navigationDelegate = self
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        webView.setValue(false, forKey: "drawsBackground")   // transparent snapshot
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // One turn of the run loop so layout/paint settles before the snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.snapshot() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    private func snapshot() {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { image, error in
            guard let image else { return self.fail(error?.localizedDescription ?? "no image") }
            guard let png = self.encode(image) else { return self.fail("PNG encode failed") }
            do { try png.write(to: self.outURL) } catch { return self.fail("\(error)") }
            self.done = true
        }
    }

    /// Redraws into a bitmap of exactly the requested pixel size. On a Retina
    /// Mac the snapshot comes back at 2x backing scale, so without this the
    /// output size would depend on which display the script happened to run on;
    /// the extra resolution is spent on supersampling instead.
    private func encode(_ image: NSImage) -> Data? {
        let w = Int(webView.bounds.width), h = Int(webView.bounds.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        ctx.flushGraphics()

        return rep.representation(using: .png, properties: [:])
    }

    private func fail(_ message: String) {
        failure = message
        done = true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let snap = Snapshotter(width: width, height: height, outURL: outURL)
snap.webView.loadHTMLString(html, baseURL: inURL.deletingLastPathComponent())

let deadline = Date().addingTimeInterval(30)
while !snap.done && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

if let failure = snap.failure {
    FileHandle.standardError.write("svg2png: \(failure)\n".data(using: .utf8)!)
    exit(1)
}
guard snap.done else {
    FileHandle.standardError.write("svg2png: timed out rendering \(inURL.lastPathComponent)\n".data(using: .utf8)!)
    exit(1)
}
