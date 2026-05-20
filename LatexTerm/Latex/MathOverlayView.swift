import AppKit
import WebKit

final class MathOverlayView: NSView {
    private let bgView = NSView()
    private let web: WKWebView
    private let baseRowHeight: CGFloat

    init(latex: String,
         displayMode: Bool,
         fontPx: CGFloat,
         baseRowHeight: CGFloat,
         foreground: NSColor,
         background: NSColor,
         scale: CGFloat) {
        let cfg = WKWebViewConfiguration()
        self.web = WKWebView(frame: .zero, configuration: cfg)
        self.baseRowHeight = baseRowHeight
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        bgView.wantsLayer = true
        bgView.layer?.backgroundColor = background.cgColor
        addSubview(bgView)

        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)

        load(latex: latex, displayMode: displayMode, fontPx: fontPx, fg: foreground, scale: scale)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let bgY = (bounds.height - baseRowHeight) / 2
        bgView.frame = NSRect(x: 0, y: bgY, width: bounds.width, height: baseRowHeight)
        web.frame = bounds
    }

    private func load(latex: String, displayMode: Bool, fontPx: CGFloat, fg: NSColor, scale: CGFloat) {
        let escaped = latex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")

        // Skalierung: benutzerdefinierter Faktor × automatisches overflow-fit
        let scaleCSS = scale != 1.0 ? "scale(\(String(format: "%.2f", scale))) " : ""

        let html = """
        <!DOCTYPE html><html><head>
        <link rel="stylesheet" href="katex.min.css">
        <script src="katex.min.js"></script>
        <style>
        html,body{margin:0;padding:0;background:transparent;color:\(css(fg));overflow:hidden;height:100%;}
        body{position:relative;font-size:\(fontPx)px;line-height:1;}
        #m{position:absolute;left:2px;top:50%;transform:translateY(-50%) \(scaleCSS);transform-origin:left center;white-space:nowrap;}
        .katex{white-space:nowrap;}
        .fallback{font-family:ui-monospace,Menlo,monospace;opacity:.65;font-style:italic;}
        </style></head><body>
        <div id="m"></div>
        <script>
        (function(){
          var el=document.getElementById('m');
          var userScale=\(String(format: "%.4f", scale));
          try{el.innerHTML=katex.renderToString("\(escaped)",{displayMode:\(displayMode ? "true" : "false"),throwOnError:true});}
          catch(e){el.innerHTML='<span class="fallback">\(escaped)</span>';}
          var fit=function(){
            var pad=2;
            var maxH=window.innerHeight-pad;
            var maxW=window.innerWidth-pad;
            var rh=el.offsetHeight;
            var rw=el.offsetWidth;
            if(rh<=0||rw<=0)return;
            var fitScale=Math.min(1, maxH/rh, maxW/rw);
            var finalScale=userScale*fitScale;
            el.style.transform='translateY(-50%) scale('+finalScale+')';
          };
          if(document.fonts&&document.fonts.ready){document.fonts.ready.then(fit);}
          else{requestAnimationFrame(fit);}
        })();
        </script>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    private func css(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return "transparent" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return "rgb(\(r),\(g),\(b))"
    }
}
