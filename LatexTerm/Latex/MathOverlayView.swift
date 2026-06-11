import AppKit
import WebKit

/// `WKUserContentController` hält seine Message-Handler **stark**. Eine View, die
/// sich selbst registriert, zykelt also über ihre eigene Configuration
/// (WebView → configuration → userContentController → View) und wird nie
/// freigegeben — inklusive des out-of-process WebContent-Prozesses. Der Proxy
/// hält das echte Ziel nur `weak` und bricht den Zyklus (#15).
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(uc, didReceive: message)
    }
}

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
    /// Noch nicht abgespieltes JS (Seite noch nicht fertig geladen). Wird
    /// **akkumuliert**, nicht ersetzt: `sync(...)` ist zwar idempotent, aber
    /// `setConfig(...)` wird nur bei Swift-seitiger Änderung gesendet — ein
    /// zweiter Rescan vor `didFinish` dürfte es sonst verschlucken (#16).
    private var pendingJS: String?

    /// Meldet die echten gerenderten Pixel-Bounds je Formel-Key (Host-Koordinaten).
    var onBounds: (([String: CGRect]) -> Void)?

    /// Meldet KaTeX-Render-Fehler je Formel-Key (Meldung, z.B. „Undefined control
    /// sequence: \\fra"). Keys ohne Eintrag haben fehlerfrei gerendert.
    var onError: (([String: String]) -> Void)?

    init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        super.init(frame: .zero, configuration: cfg)
        ucc.add(WeakScriptMessageHandler(self), name: "bounds")
        ucc.add(WeakScriptMessageHandler(self), name: "errors")
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
        guard let arr = message.body as? [[String: Any]] else { return }
        switch message.name {
        case "bounds":
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
        case "errors":
            // Vollständige aktuelle Fehlermenge je sync (leer = alles fehlerfrei).
            var out: [String: String] = [:]
            for e in arr {
                guard let k = e["key"] as? String, let m = e["message"] as? String else { continue }
                out[k] = m
            }
            onError?(out)
        default:
            break
        }
    }

    /// Führt JS aus, sobald die Seite bereit ist – sonst gepuffert (akkumulierend).
    func run(_ js: String) {
        if loaded { evaluateJavaScript(js) } else { pendingJS = (pendingJS ?? "") + js + ";" }
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
    /* KaTeX-Fehler: roher Text bleibt sichtbar, aber rot wellig unterstrichen. */
    .f .m.err{opacity:.85;text-decoration:underline wavy #E85E3E;text-decoration-skip-ink:none;text-underline-offset:2px;}
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
      // Display-Blöcke werden in beiden Achsen zentriert, Inline links/vertikal-mittig.
      e.m.style.transform=(e.display?'translate(-50%,-50%)':'translateY(-50%)')+' scale('+s+')';
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
          e={wrap:wrap,bg:bg,m:m,latex:null,display:false,err:null}; els[it.key]=e;
        }
        e.wrap.style.left=it.x+'px'; e.wrap.style.top=it.y+'px';
        e.wrap.style.width=it.w+'px'; e.wrap.style.height=it.h+'px';
        // Hintergrund maskiert den Quelltext: bei Display der ganze Block, sonst eine Zeile mittig.
        if(it.display){ e.bg.style.top='0px'; e.bg.style.height=it.h+'px'; }
        else { var bgY=(it.h-cfg.cellH)/2; e.bg.style.top=bgY+'px'; e.bg.style.height=cfg.cellH+'px'; }
        styleEl(e);
        if(e.latex!==it.latex || e.display!==!!it.display){
          e.latex=it.latex; e.display=!!it.display;
          if(e.display){ e.m.style.left='50%'; e.m.style.top='50%'; e.m.style.transformOrigin='center center'; }
          else { e.m.style.left='2px'; e.m.style.top='50%'; e.m.style.transformOrigin='left center'; }
          if(it.latex===""){           // reines Masken-Item (gewrappte Formel): nur bg, kein KaTeX
            e.m.className='m'; e.m.innerHTML=''; e.err=null;
          } else {
            try{ e.m.className='m';
                 e.m.innerHTML=katex.renderToString(it.latex,{displayMode:e.display,throwOnError:true});
                 e.err=null; }
            catch(err){ e.m.className='m fallback err'; e.m.textContent=it.latex;
                 e.err=(err&&err.message)?err.message:String(err); }
            if(document.fonts&&document.fonts.ready){document.fonts.ready.then(function(){fit(e);});}
            fit(e);
          }
        }
      }
      for(var k in els){ if(!seen[k]){ root.removeChild(els[k].wrap); delete els[k]; } }
      reportBounds();
      reportErrors();
      if(document.fonts&&document.fonts.ready){document.fonts.ready.then(reportBounds);}
    }

    // Aktuelle KaTeX-Fehlermenge (Key → Meldung) an Swift melden; leer = alles ok.
    function reportErrors(){
      var out=[];
      for(var k in els){ if(els[k].err){ out.push({key:k, message:els[k].err}); } }
      if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.errors)
        window.webkit.messageHandlers.errors.postMessage(out);
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

    // Block-Mitlauf beim Scrollen (#14): den ganzen Formel-Container vertikal verschieben.
    // CSS-translateY ist eindeutig (positiv = runter), GPU-composited und – anders als ein
    // negativer NSView-frame-Origin der Out-of-Process-WebView – auch nach oben verlässlich.
    function setScroll(dy){ root.style.transform = dy ? ('translateY('+dy+'px)') : ''; }

    function clearAll(){ root.innerHTML=''; els={}; root.style.transform=''; }

    // Vorwärmen: KaTeX-Init + Font-Download beim Laden erzwingen (off-screen, außerhalb
    // von #root → kein sync()-Konflikt), damit das ERSTE gerenderte Formel-Overlay sofort
    // erscheint statt erst nach dem WebView-Cold-Start.
    (function(){
      try{
        var warm=document.createElement('div');
        warm.style.cssText='position:absolute;left:-9999px;top:-9999px;visibility:hidden;';
        warm.innerHTML=katex.renderToString('x^2',{throwOnError:false});
        document.body.appendChild(warm);
        if(document.fonts&&document.fonts.ready){document.fonts.ready.then(function(){warm.remove();});}
      }catch(e){}
    })();
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
    /// Aktuelle KaTeX-Fehlermeldung (falls die gezeigte Formel nicht rendert) – wird beim
    /// „LaTeX"-Kopieren mit angehängt, damit man Quelle + Fehler zusammen weitergeben kann.
    private var shownError: String?
    /// Zuletzt tatsächlich in die WebView gerenderte Formel. Verhindert, dass der
    /// Hover (feuert pro Maus-Pixel) `render()` hunderte Male neu evaluiert und die
    /// WebView-Nachrichtenschlange flutet, sodass der `size`-Callback nie zurückkommt.
    private var renderedKey: String?

    /// Im gepinnten Zustand nimmt das Panel Klicks an (Buttons) und bleibt sichtbar,
    /// bis es aktiv geschlossen wird. Im Hover-Zustand ist es rein visuell.
    private(set) var pinned = false
    private let buttonBar = NSView()
    private var latexButton: NSButton!
    private var readableButton: NSButton!
    private var imageButton: NSButton!
    private var pdfButton: NSButton!
    private var markdownButton: NSButton!
    private var lastContentW: CGFloat = 0
    private var lastContentH: CGFloat = 0
    /// Zeigt die Vorschau gerade einen KaTeX-Fehler? Dann ergeben „Lesbar"/„Bild"
    /// keinen Sinn (Unicode-Konvertierung/Bild einer kaputten Formel) → ausgeblendet.
    private var isError = false

    /// Zuletzt gezeigte Hintergrundfarbe (für das Chip-Bild).
    private var exportBackground: NSColor = .black

    private static let innerPad: CGFloat = 14   // Rand zwischen Box und Formel
    private static let gap: CGFloat = 10        // Abstand Box ↔ Quell-Formel
    private static let edge: CGFloat = 8        // Mindestabstand zum Host-Rand
    private static let barH: CGFloat = 38       // Höhe der Button-Leiste (gepinnt)

    override var isFlipped: Bool { true }

    // Hover: komplett durchlässig. Gepinnt: Buttons sollen Klicks bekommen.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard pinned, !isHidden else { return nil }
        return super.hitTest(point)
    }

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

        ucc.add(WeakScriptMessageHandler(self), name: "size")
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        addSubview(web)

        latexButton = Self.makeButton("LaTeX", target: self, action: #selector(copyLatex))
        readableButton = Self.makeButton("Lesbar", target: self, action: #selector(copyReadable))
        imageButton = Self.makeButton("Bild", target: self, action: #selector(copyImage))
        pdfButton = Self.makeButton("PDF", target: self, action: #selector(copyPDF))
        markdownButton = Self.makeButton("MD", target: self, action: #selector(copyMarkdown))
        buttonBar.addSubview(latexButton)
        buttonBar.addSubview(readableButton)
        buttonBar.addSubview(imageButton)
        buttonBar.addSubview(pdfButton)
        buttonBar.addSubview(markdownButton)
        buttonBar.isHidden = true
        addSubview(buttonBar)

        isHidden = true
        web.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if let js = pendingJS { pendingJS = nil; web.evaluateJavaScript(js) }
    }

    /// Zeigt die Formel groß über (oder unter) `rect` an. Ist `error` gesetzt (KaTeX
    /// konnte nicht rendern), wird statt der Formel die rohe Quelle + die Fehlermeldung
    /// (rot) angezeigt.
    func show(latex: String, over rect: CGRect, in host: NSView, fontPx: CGFloat,
              foreground: NSColor, background: NSColor, error: String? = nil) {
        if superview !== host { removeFromSuperview(); host.addSubview(self) }
        hostView = host
        anchor = rect
        shownLatex = latex
        shownError = error
        exportBackground = background

        layer?.backgroundColor = background.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        // Gleiche Formel wie zuletzt gerendert → KaTeX nicht neu evaluieren (sonst flutet
        // der pro-Pixel-Hover die WebView). Nur sicherstellen, dass das Popover sichtbar
        // ist; die Maße liegen aus dem vorigen Render bereits vor.
        if renderedKey == latex {
            if isHidden, lastContentW > 0, let host = hostView {
                layoutPreview(contentW: lastContentW, contentH: lastContentH, in: host)
            }
            return
        }
        renderedKey = latex
        isError = (error != nil)

        let escaped = Self.jsString(latex)
        let js: String
        if let error {
            js = "renderError(\(escaped), \(Self.jsString(error)));"
        } else {
            let big = max(30, fontPx * 2.4)
            js = "render(\(escaped), \(big), \(Self.jsString(Self.css(foreground))));"
        }
        if loaded { web.evaluateJavaScript(js) } else { pendingJS = js }
    }

    func hide() {
        isHidden = true
        shownLatex = nil
        pinned = false
        buttonBar.isHidden = true
    }

    /// Fixiert die aktuell gezeigte Formel und blendet die Button-Leiste ein.
    func pin() {
        guard !isHidden else { return }
        pinned = true
        buttonBar.isHidden = false
        if let host = hostView, lastContentW > 0 || lastContentH > 0 {
            layoutPreview(contentW: lastContentW, contentH: lastContentH, in: host)
        }
    }

    @objc private func copyLatex() {
        guard let s = shownLatex else { return }
        // Bei Fehler Quelle + KaTeX-Meldung zusammen kopieren (zum Fixen/Weitergeben).
        let text = shownError.map { "\(s)\n\n\($0)" } ?? s
        copyToPasteboard(text)
        flash(latexButton, original: "LaTeX")
    }

    @objc private func copyReadable() {
        guard let s = shownLatex else { return }
        copyToPasteboard(LaTeXReadable.readable(s))
        flash(readableButton, original: "Lesbar")
    }

    @objc private func copyImage() {
        guard shownLatex != nil, lastContentW > 0, lastContentH > 0 else { return }
        imageButton.title = "…"
        let bg = exportBackground

        // Die sichtbare Vorschau-WebView ist garantiert gepaintet → von ihr snapshotten,
        // exakt auf die Inhaltsgröße (#m liegt links oben), dann den Chip komponieren.
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: lastContentW, height: lastContentH)
        web.takeSnapshot(with: cfg) { [weak self] snapshot, _ in
            guard let self else { return }
            if let snapshot,
               let chip = FormulaImageRenderer.makeChip(from: snapshot, background: bg),
               FormulaImageRenderer.copyToPasteboard(chip) {
                self.flash(self.imageButton, original: "Bild")
            } else {
                self.failFlash(self.imageButton, original: "Bild")
            }
        }
    }

    /// Vektorieller Export (#5): die Preview-WebView rendert KaTeX als HTML+CSS mit echten
    /// Font-Glyphen — `createPDF` druckt genau das als Vektor-PDF (beliebig skalierbar).
    /// KaTeX kann kein SVG; PDF ist der verlustfreie Pfad, SVG bleibt Stretch-Goal.
    @objc private func copyPDF() {
        guard shownLatex != nil, lastContentW > 0, lastContentH > 0 else { return }
        pdfButton.title = "…"
        let cfg = WKPDFConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: lastContentW, height: lastContentH)
        web.createPDF(configuration: cfg) { [weak self] result in
            guard let self else { return }
            if case .success(let data) = result {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(data, forType: .pdf)
                self.flash(self.pdfButton, original: "PDF")
            } else {
                self.failFlash(self.pdfButton, original: "PDF")
            }
        }
    }

    /// Markdown-Data-URI (#5): PNG-Chip base64-encodet als `![formula](data:image/png;…)` —
    /// ein-Klick-Paste in GitHub/Notion/Obsidian, ohne Datei-Anhang.
    @objc private func copyMarkdown() {
        guard shownLatex != nil, lastContentW > 0, lastContentH > 0 else { return }
        markdownButton.title = "…"
        let bg = exportBackground
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: lastContentW, height: lastContentH)
        web.takeSnapshot(with: cfg) { [weak self] snapshot, _ in
            guard let self else { return }
            if let snapshot,
               let chip = FormulaImageRenderer.makeChip(from: snapshot, background: bg),
               let png = FormulaImageRenderer.pngData(chip) {
                let alt = self.shownLatex ?? "formula"
                let md = "![\(Self.markdownAltText(alt))](data:image/png;base64,\(png.base64EncodedString()))"
                self.copyToPasteboard(md)
                self.flash(self.markdownButton, original: "MD")
            } else {
                self.failFlash(self.markdownButton, original: "MD")
            }
        }
    }

    /// LaTeX-Quelle als Markdown-Alt-Text: eckige Klammern und Zeilenumbrüche
    /// würden die `![…](…)`-Syntax brechen.
    private static func markdownAltText(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "(")
         .replacingOccurrences(of: "]", with: ")")
         .replacingOccurrences(of: "\n", with: " ")
    }

    private func failFlash(_ button: NSButton, original: String) {
        button.title = "Fehler"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak button] in
            button?.title = original
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func flash(_ button: NSButton, original: String) {
        button.title = "✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak button] in
            button?.title = original
        }
    }

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
        lastContentW = contentW
        lastContentH = contentH

        let pad = Self.innerPad
        let bar = pinned ? Self.barH : 0
        let maxW = host.bounds.width  - 2 * Self.edge
        let maxH = host.bounds.height - 2 * Self.edge

        var boxW = min(contentW + 2 * pad, maxW)
        var boxH = min(contentH + 2 * pad + bar, maxH)
        boxW = max(boxW, pinned ? 346 : 40)   // gepinnt: Platz für fünf Buttons
        boxH = max(boxH, 30 + bar)

        // x: über der Formel zentriert, in Host-Bounds geklemmt
        var x = anchor.midX - boxW / 2
        x = max(Self.edge, min(x, host.bounds.width - Self.edge - boxW))

        // y: bevorzugt oberhalb; wenn kein Platz, darunter
        var y = anchor.minY - Self.gap - boxH
        if y < Self.edge { y = anchor.maxY + Self.gap }
        y = max(Self.edge, min(y, host.bounds.height - Self.edge - boxH))

        frame = CGRect(x: x, y: y, width: boxW, height: boxH)
        web.frame = CGRect(x: pad, y: pad, width: boxW - 2 * pad, height: boxH - 2 * pad - bar)

        if pinned {
            buttonBar.isHidden = false
            buttonBar.frame = CGRect(x: 0, y: boxH - Self.barH, width: boxW, height: Self.barH)
            let bh: CGFloat = 24, gap: CGFloat = 6
            let by = (Self.barH - bh) / 2
            // Bei Fehler nur „LaTeX" (rohe Quelle kopieren, um sie zu fixen); die übrigen
            // Exporte sind für eine nicht-renderbare Formel sinnlos.
            let exportButtons: [NSButton] = [readableButton, imageButton, pdfButton, markdownButton]
            exportButtons.forEach { $0.isHidden = isError }
            let visible: [NSButton] = isError ? [latexButton] : [latexButton] + exportButtons
            let bw: CGFloat = isError ? 72 : 60
            let total = CGFloat(visible.count) * bw + CGFloat(visible.count - 1) * gap
            var bx = (boxW - total) / 2
            for b in visible {
                b.frame = CGRect(x: bx, y: by, width: bw, height: bh)
                bx += bw + gap
            }
        } else {
            buttonBar.isHidden = true
        }

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
    /* KaTeX-Fehleransicht: rohe Quelle + Meldung gestapelt, Meldung rot. */
    #m.err{white-space:normal;width:320px;font-family:ui-monospace,Menlo,monospace;}
    #m.err .src{font-size:14px;color:#C8C2C2;opacity:.7;margin-bottom:8px;word-break:break-word;}
    #m.err .msg{font-size:13px;line-height:1.4;color:#E85E3E;word-break:break-word;}
    </style></head><body>
    <div id="m"></div>
    <script>
    var el=document.getElementById('m');
    function post(){ window.webkit.messageHandlers.size.postMessage({w:el.offsetWidth, h:el.offsetHeight}); }
    function render(latex, fontPx, fg){
      el.style.fontSize=fontPx+'px'; el.style.color=fg; el.className='';
      try{ el.innerHTML=katex.renderToString(latex,{displayMode:true,throwOnError:true}); }
      catch(e){ el.className='fallback'; el.textContent=latex; }
      if(document.fonts&&document.fonts.ready){document.fonts.ready.then(post);} else {requestAnimationFrame(post);}
    }
    // Fehleransicht: zeigt die rohe Formel und die konkrete KaTeX-Meldung.
    function renderError(latex, message){
      el.style.color=''; el.style.fontSize='14px'; el.className='err'; el.innerHTML='';
      var src=document.createElement('div'); src.className='src'; src.textContent=latex;
      var msg=document.createElement('div'); msg.className='msg'; msg.textContent=message;
      el.appendChild(src); el.appendChild(msg);
      requestAnimationFrame(post);
    }
    // Vorwärmen: KaTeX-Init + Font-Download schon beim Laden erzwingen (off-screen,
    // ohne #m anzufassen → kein size-Post, kein Popover), damit das ERSTE Hover sofort
    // erscheint statt erst nach dem WebView-Cold-Start.
    (function(){
      try{
        var warm=document.createElement('div');
        warm.style.cssText='position:absolute;left:-9999px;top:-9999px;visibility:hidden;';
        warm.innerHTML=katex.renderToString('x^2',{throwOnError:false});
        document.body.appendChild(warm);
        if(document.fonts&&document.fonts.ready){document.fonts.ready.then(function(){warm.remove();});}
      }catch(e){}
    })();
    </script>
    </body></html>
    """
}
