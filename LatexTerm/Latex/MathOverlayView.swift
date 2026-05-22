import AppKit
import WebKit

/// Eine einzige WKWebView für ALLE Formeln des Terminals.
///
/// Früher gab es eine WKWebView (= eigener Browser-Prozess + kompletter
/// KaTeX-Reload) pro Formel. Jetzt lädt diese Layer KaTeX genau einmal; jede
/// Formel ist nur noch ein absolut positionierter `<div>`. Der OverlayController
/// schickt den gewünschten Zustand als JSON; die Seite reconciled per `sync()`
/// (neue Keys anlegen, fehlende entfernen, vorhandene nur neu positionieren –
/// ohne KaTeX neu zu rendern).
final class FormulaLayer: WKWebView, WKNavigationDelegate, WKScriptMessageHandler {

    private var loaded = false
    /// Letztes noch nicht abgespieltes JS (Seite noch nicht fertig geladen).
    /// Da jeder Rescan den vollständigen Zustand schickt, genügt der jeweils letzte.
    private var pendingJS: String?

    /// Meldet die echten gerenderten Pixel-Bounds je Formel-Key (Host-Koordinaten).
    var onBounds: (([String: CGRect]) -> Void)?

    init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        super.init(frame: .zero, configuration: cfg)
        ucc.add(self, name: "bounds")
        setValue(false, forKey: "drawsBackground")   // transparent → Terminal scheint durch
        navigationDelegate = self
        autoresizingMask = [.width, .height]
        loadHTMLString(Self.pageHTML, baseURL: Bundle.main.resourceURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Komplett transparent fürs Hit-Testing: Klicks/Selektion/Scroll gehen ans Terminal.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let js = pendingJS { pendingJS = nil; evaluateJavaScript(js) }
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bounds", let arr = message.body as? [[String: Any]] else { return }
        var out: [String: CGRect] = [:]
        for e in arr {
            guard let k = e["key"] as? String,
                  let x = (e["x"] as? NSNumber)?.doubleValue,
                  let y = (e["y"] as? NSNumber)?.doubleValue,
                  let w = (e["w"] as? NSNumber)?.doubleValue,
                  let h = (e["h"] as? NSNumber)?.doubleValue, w > 0, h > 0 else { continue }
            out[k] = CGRect(x: x, y: y, width: w, height: h)
        }
        if !out.isEmpty { onBounds?(out) }
    }

    /// Führt JS aus, sobald die Seite bereit ist – sonst gepuffert.
    func run(_ js: String) {
        if loaded { evaluateJavaScript(js) } else { pendingJS = js }
    }

    private static let pageHTML = """
    <!DOCTYPE html><html><head>
    <link rel="stylesheet" href="katex.min.css">
    <script src="katex.min.js"></script>
    <style>
    html,body{margin:0;padding:0;background:transparent;overflow:hidden;height:100%;width:100%;}
    #root{position:absolute;top:0;left:0;}
    .f{position:absolute;overflow:hidden;}
    .f .bg{position:absolute;left:0;right:0;}
    .f .m{position:absolute;left:2px;top:50%;transform-origin:left center;white-space:nowrap;}
    .katex{white-space:nowrap;}
    .fallback{font-family:ui-monospace,Menlo,monospace;opacity:.65;font-style:italic;}
    </style></head><body>
    <div id="root"></div>
    <script>
    var root=document.getElementById('root');
    var els={};                 // key -> {wrap,bg,m,latex}
    var cfg={fontPx:13,cellH:16,fg:'rgb(230,225,225)',bg:'rgb(23,20,20)',userScale:1};

    function styleEl(e){ e.m.style.color=cfg.fg; e.bg.style.background=cfg.bg; }

    function fit(e){
      var pad=2;
      var maxH=e.wrap.clientHeight-pad, maxW=e.wrap.clientWidth-pad;
      var rh=e.m.offsetHeight, rw=e.m.offsetWidth;
      if(rh<=0||rw<=0)return;
      var s=Math.min(1, maxH/rh, maxW/rw)*cfg.userScale;
      e.m.style.transform='translateY(-50%) scale('+s+')';
    }

    function setConfig(c){
      Object.assign(cfg,c);
      root.style.fontSize=cfg.fontPx+'px';
      for(var k in els){ styleEl(els[k]); }
    }

    function sync(items){
      var seen={};
      for(var i=0;i<items.length;i++){
        var it=items[i]; seen[it.key]=1;
        var e=els[it.key];
        if(!e){
          var wrap=document.createElement('div'); wrap.className='f';
          var bg=document.createElement('div'); bg.className='bg';
          var m=document.createElement('div'); m.className='m';
          wrap.appendChild(bg); wrap.appendChild(m); root.appendChild(wrap);
          e={wrap:wrap,bg:bg,m:m,latex:null}; els[it.key]=e;
        }
        e.wrap.style.left=it.x+'px'; e.wrap.style.top=it.y+'px';
        e.wrap.style.width=it.w+'px'; e.wrap.style.height=it.h+'px';
        var bgY=(it.h-cfg.cellH)/2;
        e.bg.style.top=bgY+'px'; e.bg.style.height=cfg.cellH+'px';
        styleEl(e);
        if(e.latex!==it.latex){
          e.latex=it.latex;
          try{ e.m.className='m';
               e.m.innerHTML=katex.renderToString(it.latex,{displayMode:!!it.display,throwOnError:true}); }
          catch(err){ e.m.className='m fallback'; e.m.textContent=it.latex; }
          if(document.fonts&&document.fonts.ready){document.fonts.ready.then(function(){fit(e);});}
          fit(e);
        }
      }
      for(var k in els){ if(!seen[k]){ root.removeChild(els[k].wrap); delete els[k]; } }
      reportBounds();
      if(document.fonts&&document.fonts.ready){document.fonts.ready.then(reportBounds);}
    }

    // Echte gerenderte Pixel-Bounds je Formel (nach Skalierung) an Swift melden.
    // getBoundingClientRect ist relativ zum Viewport = Host-Ursprung (WebView füllt Host).
    function reportBounds(){
      var out=[];
      for(var k in els){
        var r=els[k].m.getBoundingClientRect();
        if(r.width>0&&r.height>0) out.push({key:k, x:r.left, y:r.top, w:r.width, h:r.height});
      }
      if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.bounds)
        window.webkit.messageHandlers.bounds.postMessage(out);
    }

    function clearAll(){ root.innerHTML=''; els={}; }
    </script>
    </body></html>
    """
}

/// Großer Vorschau-Popover für eine einzelne Formel (Ansichts-Modus beim Hover).
/// Rendert in echtem Display-Mode, misst die Inhaltsgröße per JS-Callback und
/// dimensioniert/positioniert sich selbst clamped in die Host-Bounds.
final class FormulaPreview: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private let web: WKWebView
    private var loaded = false
    private var pendingJS: String?
    private var anchor: CGRect = .zero
    private weak var hostView: NSView?
    private var shownLatex: String?

    private static let innerPad: CGFloat = 14   // Rand zwischen Box und Formel
    private static let gap: CGFloat = 10        // Abstand Box ↔ Quell-Formel
    private static let edge: CGFloat = 8        // Mindestabstand zum Host-Rand

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // rein visuell

    init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: 4)

        ucc.add(self, name: "size")
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        addSubview(web)
        isHidden = true
        web.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let js = pendingJS { pendingJS = nil; web.evaluateJavaScript(js) }
    }

    /// Zeigt die Formel groß über (oder unter) `rect` an.
    func show(latex: String, over rect: CGRect, in host: NSView, fontPx: CGFloat,
              foreground: NSColor, background: NSColor) {
        // Identischer Hover → nichts neu rendern (mouseMoved feuert pro Pixel)
        if !isHidden, shownLatex == latex, anchor == rect { return }
        if superview !== host { removeFromSuperview(); host.addSubview(self) }
        hostView = host
        anchor = rect
        shownLatex = latex

        layer?.backgroundColor = background.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let escaped = Self.jsString(latex)
        let big = max(30, fontPx * 2.4)
        let js = "render(\(escaped), \(big), \(Self.jsString(Self.css(foreground))));"
        if loaded { web.evaluateJavaScript(js) } else { pendingJS = js }
    }

    func hide() { isHidden = true; shownLatex = nil }

    // JS meldet die gerenderte Inhaltsgröße zurück → wir dimensionieren/positionieren.
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "size",
              let dict = message.body as? [String: Any],
              let w = (dict["w"] as? NSNumber)?.doubleValue,
              let h = (dict["h"] as? NSNumber)?.doubleValue,
              let host = hostView else { return }
        layoutPreview(contentW: CGFloat(w), contentH: CGFloat(h), in: host)
    }

    private func layoutPreview(contentW: CGFloat, contentH: CGFloat, in host: NSView) {
        let pad = Self.innerPad
        let maxW = host.bounds.width  - 2 * Self.edge
        let maxH = host.bounds.height - 2 * Self.edge

        var boxW = min(contentW + 2 * pad, maxW)
        var boxH = min(contentH + 2 * pad, maxH)
        boxW = max(boxW, 40); boxH = max(boxH, 30)

        // x: über der Formel zentriert, in Host-Bounds geklemmt
        var x = anchor.midX - boxW / 2
        x = max(Self.edge, min(x, host.bounds.width - Self.edge - boxW))

        // y: bevorzugt oberhalb; wenn kein Platz, darunter
        var y = anchor.minY - Self.gap - boxH
        if y < Self.edge { y = anchor.maxY + Self.gap }
        y = max(Self.edge, min(y, host.bounds.height - Self.edge - boxH))

        frame = CGRect(x: x, y: y, width: boxW, height: boxH)
        web.frame = bounds.insetBy(dx: pad, dy: pad)
        isHidden = false
        // nach vorn holen
        if let sv = superview { removeFromSuperview(); sv.addSubview(self) }
    }

    // MARK: - Helpers

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())   // JSON-escaptes Einzelelement
    }

    private static func css(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return "white" }
        return "rgb(\(Int(rgb.redComponent*255)),\(Int(rgb.greenComponent*255)),\(Int(rgb.blueComponent*255)))"
    }

    private static let html = """
    <!DOCTYPE html><html><head>
    <link rel="stylesheet" href="katex.min.css">
    <script src="katex.min.js"></script>
    <style>
    html,body{margin:0;padding:0;background:transparent;overflow:hidden;height:100%;width:100%;}
    #m{position:absolute;left:0;top:0;white-space:nowrap;}
    .katex{white-space:nowrap;}
    .fallback{font-family:ui-monospace,Menlo,monospace;font-style:italic;opacity:.7;}
    </style></head><body>
    <div id="m"></div>
    <script>
    var el=document.getElementById('m');
    function render(latex, fontPx, fg){
      el.style.fontSize=fontPx+'px'; el.style.color=fg; el.className='';
      try{ el.innerHTML=katex.renderToString(latex,{displayMode:true,throwOnError:true}); }
      catch(e){ el.className='fallback'; el.textContent=latex; }
      var post=function(){
        window.webkit.messageHandlers.size.postMessage({w:el.offsetWidth, h:el.offsetHeight});
      };
      if(document.fonts&&document.fonts.ready){document.fonts.ready.then(post);} else {requestAnimationFrame(post);}
    }
    </script>
    </body></html>
    """
}
