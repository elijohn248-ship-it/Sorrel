import AppKit
import WebKit

/// TEMPORARY (branch `proton-list`, 2026-11-16): the owner's signed-in Proton Pass pop-up shows its header but
/// a blank item list and blank details, and nothing can be inspected there. Each time a pop-up opens this
/// writes layout facts to `popup-diagnostics.txt` in the profile folder: visibility, animation frames,
/// animation states, list sizes, element counts and class names. Never page text, item names or addresses.
/// The file stays on this Mac. Remove this file and its one call before merging.
enum PopupDiagnostics {
    static var file: URL { Paths.support.appendingPathComponent("popup-diagnostics.txt") }

    static func start(webView: WKWebView?, popover: NSPopover) {
        guard let webView else { return }
        try? "Sorrel pop-up diagnostics, opened \(Date())\n".write(to: file, atomically: true, encoding: .utf8)
        let started = Date()
        for delay in [0.3, 1.0, 2.0, 4.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard popover.isShown else { append("+\(delay)s: pop-up already closed\n"); return }
                probe(webView, popover: popover, label: String(format: "+%.1fs", Date().timeIntervalSince(started)))
            }
        }
    }

    private static func append(_ text: String) {
        guard let data = text.data(using: .utf8), let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    private static func probe(_ webView: WKWebView, popover: NSPopover, label: String) {
        let window = webView.window
        var hiddenAncestor = false
        var view: NSView? = webView
        while let v = view { if v.isHidden { hiddenAncestor = true }; view = v.superview }
        let inPopover = popover.contentViewController.map { webView.isDescendant(of: $0.view) } ?? false
        let occlusionOff = (webView.value(forKey: "_windowOcclusionDetectionEnabled") as? Bool).map { !$0 } ?? false
        var native = "\(label) native: appActive=\(NSApp.isActive) windowVisible=\(window?.isVisible ?? false)"
        native += " occlusionVisible=\(window?.occlusionState.contains(.visible) ?? false) occlusionDetectionOff=\(occlusionOff)"
        native += " webViewInPopover=\(inPopover) hiddenAncestor=\(hiddenAncestor) frame=\(Int(webView.frame.width))x\(Int(webView.frame.height))"
        native += " windowAlpha=\(window.map { String(format: "%.2f", $0.alphaValue) } ?? "-") popoverSize=\(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))\n"
        let script = """
        if (!window.__sorrelDiag) {
          window.__sorrelDiag = [];
          addEventListener('error', function (e) { window.__sorrelDiag.push('error: ' + String(e.message).slice(0, 160)); });
          addEventListener('unhandledrejection', function (e) { var r = e.reason; window.__sorrelDiag.push('rejection: ' + String(r && r.message || r).slice(0, 160)); });
        }
        var raf = await new Promise(function (done) { var t = setTimeout(function () { done('stalled'); }, 500); requestAnimationFrame(function () { clearTimeout(t); done('ok'); }); });
        var box = function (el) {
          if (!el) return 'none';
          var r = el.getBoundingClientRect(), c = getComputedStyle(el);
          return Math.round(r.width) + 'x' + Math.round(r.height) + '@' + Math.round(r.left) + ',' + Math.round(r.top) + ' op' + c.opacity + ' ' + c.display + (c.visibility !== 'visible' ? ' ' + c.visibility : '');
        };
        var cls = function (el) {
          var c = typeof el.className === 'string' ? el.className : 'svg';
          return el.tagName.toLowerCase() + '.' + c.split(/\\s+/).filter(Boolean).slice(0, 5).join('.');
        };
        var anims = {};
        document.getAnimations().forEach(function (a) { var k = (a.animationName || a.transitionProperty || '?') + ':' + a.playState + (a.playState === 'running' ? '@' + Math.round(a.currentTime || 0) : ''); anims[k] = (anims[k] || 0) + 1; });
        var grids = Array.prototype.map.call(document.querySelectorAll('.ReactVirtualized__Grid'), function (g) {
          var inner = g.querySelector('.ReactVirtualized__Grid__innerScrollContainer');
          return box(g) + ' styleH=' + g.style.height + ' rows=' + (inner ? inner.children.length : -1) + ' inner=' + box(inner) + (inner && inner.firstElementChild ? ' firstRow=' + box(inner.firstElementChild) : '');
        });
        var outers = Array.prototype.map.call(document.querySelectorAll('.scroll-outer-vertical'), function (el) { return box(el) + ' kids=' + el.children.length; });
        var clear = {};
        Array.prototype.forEach.call(document.querySelectorAll('body *'), function (el) { if (getComputedStyle(el).opacity === '0') { var k = cls(el); clear[k] = (clear[k] || 0) + 1; } });
        var main = document.querySelector('main') || document.querySelector('.app-root');
        return [
          'visibility=' + document.visibilityState + ' focus=' + document.hasFocus() + ' rAF=' + raf + ' win=' + innerWidth + 'x' + innerHeight + ' dpr=' + devicePixelRatio + ' reducedMotion=' + matchMedia('(prefers-reduced-motion: reduce)').matches + ' elements=' + document.querySelectorAll('*').length,
          'html=' + box(document.documentElement) + ' | body=' + box(document.body) + ' | appRoot=' + box(document.querySelector('.app-root')) + ' | main=' + box(main),
          'animations=' + JSON.stringify(anims),
          'lists=' + (grids.length ? grids.join(' || ') : 'none'),
          'scrollOuters=' + (outers.length ? outers.join(' || ') : 'none'),
          'transparent=' + JSON.stringify(clear),
          'errors=' + JSON.stringify(window.__sorrelDiag.slice(-8))
        ].join('\\n   ');
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): append(native + "   " + String(describing: value) + "\n")
            case .failure(let error): append(native + "   script failed: \(error.localizedDescription)\n")
            }
        }
    }
}
