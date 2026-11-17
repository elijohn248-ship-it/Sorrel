import AppKit
import WebKit

/// Borrows the existing web view: streams, cookies, DRM and private stores stay with their page.
/// All DOM bookkeeping lives in an isolated world; no page-to-app message handler is installed.
final class PictureInPicture: NSObject, NSWindowDelegate {
    static let shared = PictureInPicture()
    private let world = WKContentWorld.world(name: "SorrelPictureInPicture")
    private(set) weak var webView: WKWebView?
    private weak var originalHost: NSView?
    private var panel: NSPanel?
    private var canvas: VideoCanvas?
    private var timer: Timer?
    private var loading: NSKeyValueObservation?
    private var pending = false
    private var polling = false
    private var generation = 0

    func contains(_ view: WKWebView) -> Bool { webView === view }

    func setReturnHost(_ host: NSView, for view: WKWebView) {
        if contains(view) { originalHost = host }
    }

    func toggle(_ view: WKWebView) {
        if webView === view { close(); return }
        guard !pending else { return }
        close()
        pending = true
        let ticket = generation
        view.callAsyncJavaScript(Self.enterScript, arguments: [:], in: nil, in: world) { [weak self, weak view] result in
            guard let self, let view else { return }
            self.pending = false
            guard ticket == self.generation else {
                view.callAsyncJavaScript("globalThis.sorrelVideo?.restore(); delete globalThis.sorrelVideo;", arguments: [:], in: nil, in: self.world) { _ in }
                return
            }
            guard case .success(let value) = result, let size = value as? [String: Double] else {
                Engine.shared.onToast?("No accessible video on this page. For embedded players, use their own Picture in Picture control.")
                return
            }
            self.present(view, width: size["width"] ?? 16, height: size["height"] ?? 9)
        }
    }

    private func present(_ view: WKWebView, width: Double, height: Double) {
        webView = view
        originalHost = view.superview
        let ratio = min(2.4, max(0.6, width / max(1, height)))
        let size = NSSize(width: 420, height: 420 / ratio)
        let screen = view.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSPanel(contentRect: NSRect(x: screen.maxX - size.width - 24, y: screen.minY + 24,
                                                 width: size.width, height: size.height),
                             styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = isQuietTest ? .normal : .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 240, height: 240 / ratio)
        window.contentAspectRatio = size
        window.hasShadow = true
        window.backgroundColor = .black
        window.isOpaque = false
        window.delegate = self
        let content = VideoCanvas(frame: NSRect(origin: .zero, size: size))
        content.onClose = { [weak self] in self?.close() }
        content.onToggle = { [weak self] in self?.control("toggle") }
        content.onSeek = { [weak self] seconds in self?.control("seek", seconds: seconds) }
        window.contentView = content
        view.removeFromSuperview()
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view, positioned: .below, relativeTo: content.overlay)
        panel = window
        canvas = content
        (originalHost as? PaneView)?.reclaimWebView()
        if isQuietTest { window.orderBack(nil) } else { window.orderFrontRegardless() }
        loading = view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            if view.isLoading { self?.close() }
        }
        let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
        poll()
    }

    func close() {
        generation += 1
        timer?.invalidate(); timer = nil
        loading?.invalidate(); loading = nil
        polling = false
        guard let view = webView else { return }
        webView = nil
        view.callAsyncJavaScript("globalThis.sorrelVideo?.restore(); delete globalThis.sorrelVideo;", arguments: [:], in: nil, in: world) { _ in }
        view.removeFromSuperview()
        if let host = originalHost {
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
            (host as? PaneView)?.reclaimWebView()
        }
        originalHost = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        canvas = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }

    private func control(_ action: String, seconds: Double = 0) {
        guard let view = webView else { return }
        view.callAsyncJavaScript("""
        const v = globalThis.sorrelVideo?.video;
        if (!v || !v.isConnected) return false;
        if (action === 'toggle') { if (v.paused) await v.play(); else v.pause(); }
        if (action === 'seek' && v.seekable.length) {
            const start = v.seekable.start(0), end = v.seekable.end(v.seekable.length - 1);
            v.currentTime = Math.max(start, Math.min(end, v.currentTime + seconds));
        }
        return true;
        """, arguments: ["action": action, "seconds": seconds], in: nil, in: world) { [weak self] result in
            if case .failure = result { Engine.shared.onToast?("Open the video tab to resume playback") }
            self?.poll()
        }
    }

    private func poll() {
        guard !polling, let view = webView else { return }
        polling = true
        let ticket = generation
        view.callAsyncJavaScript("""
        const v = globalThis.sorrelVideo?.video;
        if (!v || !v.isConnected) return null;
        return { paused: v.paused, time: Number.isFinite(v.currentTime) ? v.currentTime : 0,
                 duration: Number.isFinite(v.duration) ? v.duration : 0, seekable: v.seekable.length > 0 };
        """, arguments: [:], in: nil, in: world) { [weak self] result in
            guard let self, ticket == self.generation else { return }
            self.polling = false
            guard case .success(let value) = result, let state = value as? [String: Any] else { self.close(); return }
            self.canvas?.render(paused: state["paused"] as? Bool ?? true, time: state["time"] as? Double ?? 0,
                                duration: state["duration"] as? Double ?? 0, seekable: state["seekable"] as? Bool ?? false)
        }
    }

    /// Local silent fixture only; never reads a real profile or contacts a media host.
    func runTest(store: Store, fixture: String) {
        func log(_ value: String) { FileHandle.standardError.write(("pip: " + value + "\n").data(using: .utf8)!) }
        func after(_ delay: Double, _ block: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: fixture)) else { log("fixture expected=readable got=false"); return }
        let html = "<body style='background:red'><h1>Fixture</h1><video controls muted style='width:180px' src='data:video/mp4;base64,\(data.base64EncodedString())'></video></body>"
        let tab = store.newTab(url: "about:blank", title: "Video Fixture")
        let page = Engine.shared.ensurePage(for: tab)
        let view = page.webView
        view.loadHTMLString(html, baseURL: nil)
        func inspect(_ label: String) {
            view.callAsyncJavaScript("const v=document.querySelector('video'); return {paused:v.paused, time:v.currentTime, controls:v.controls, width:v.getBoundingClientRect().width, viewport:innerWidth};", arguments: [:], in: nil, in: .page) {
                switch $0 {
                case .success(let value):
                    if let value, let json = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                       let line = String(data: json, encoding: .utf8) { log("\(label) got=\(line)") }
                    else { log("\(label) got=missing") }
                case .failure(let error): log("\(label) got=error \(error.localizedDescription)")
                }
            }
        }
        after(2) {
            view.callAsyncJavaScript("const v=document.querySelector('video'); v.currentTime=20; await v.play(); return v.videoWidth;", arguments: [:], in: nil, in: .page) {
                log("fixture width expected=320 got=\($0)")
                self.toggle(view)
            }
        }
        after(4) {
            log("floating expected=true got=\(self.contains(view) && view.window === self.panel)")
            log("sleep protected expected=true got=\(!store.canSleep(tab))")
            self.canvas?.setHovered(true)
            self.panel?.setFrameOrigin(NSPoint(x: 100, y: 100))
            log("move expected=100 got=\(self.panel?.frame.origin.x ?? -1)")
            inspect("video fills viewport expected=equal-width/controls-false")
            self.canvas?.onToggle?()
            if let path = ProcessInfo.processInfo.environment["SORREL_PIPSHOT"] {
                view.takeSnapshot(with: nil) { image, _ in
                    if let data = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                       let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
                }
            }
        }
        after(5) {
            log("hover buttons clickable expected=true got=\(self.canvas?.buttonsReceiveClicks ?? false)")
            inspect("pause expected=true/time-about22")
            self.control("seek", seconds: 10)
        }
        after(6) { inspect("forward expected=time-about32"); self.control("seek", seconds: -10) }
        after(7) {
            inspect("rewind expected=time-about22")
            self.canvas?.render(paused: true, time: 22, duration: 60, seekable: true)
            log("remaining expected=−0:38 got=\(self.canvas?.remainingText ?? "missing")")
            log("hover expected=visible got=\((self.canvas?.overlay.alphaValue ?? 0) > 0.9)")
            self.canvas?.setHovered(false)
            _ = store.newTab(url: "about:blank")
        }
        after(8) {
            log("background expected=still-floating got=\(view.window === self.panel)")
            log("hover exit expected=hidden got=\((self.canvas?.overlay.alphaValue ?? 1) < 0.1)")
            store.select(tab)
        }
        after(9) {
            log("reselect expected=still-floating got=\(view.window === self.panel)")
            self.close()
        }
        after(10) {
            log("returned expected=pane got=\(view.superview is PaneView)")
            inspect("restored expected=controls-true/width180/paused")
            self.toggle(view)
        }
        after(11) { self.control("seek", seconds: -10000) }
        after(12) { inspect("rewind clamps expected=time0"); self.control("seek", seconds: 10000) }
        after(13) { inspect("forward clamps expected=time60"); view.loadHTMLString("<p>Navigation fixture</p>", baseURL: nil) }
        after(14) {
            log("navigation closes expected=true got=\(self.webView == nil)")
            view.loadHTMLString("<iframe srcdoc=\"" + html.replacingOccurrences(of: "\"", with: "&quot;") + "\"></iframe>", baseURL: nil)
        }
        after(16) { self.toggle(view) }
        after(17) { log("same-origin frame expected=floating got=\(self.contains(view))"); store.close(tab); log("tab close expected=true got=\(self.webView == nil)") }
        let privatePage = Engine.shared.makePage(profileID: nil, isPrivate: true)
        let privateHost = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        after(18) {
            AppDelegate.shared?.main.window?.contentView?.addSubview(privateHost)
            privateHost.addSubview(privatePage.webView)
            privatePage.webView.loadHTMLString(html, baseURL: nil)
        }
        after(20) {
            privatePage.webView.callAsyncJavaScript("const v=document.querySelector('video'); await v.play(); return v.videoWidth;", arguments: [:], in: nil, in: .page) { result in
                log("private fixture width expected=320 got=\(result)")
                self.toggle(privatePage.webView)
            }
        }
        after(21) {
            log("private expected=floating/nonpersistent got=\(self.contains(privatePage.webView))/\(!privatePage.webView.configuration.websiteDataStore.isPersistent)")
            privatePage.teardown()
            privateHost.removeFromSuperview()
            log("private teardown expected=closed got=\(self.webView == nil)")
        }
        after(22) {
            let empty = Engine.shared.makePage(profileID: nil)
            self.toggle(empty.webView)
            after(1) { log("no video expected=no-panel got=\(self.webView == nil)"); empty.teardown() }
        }
    }

    private static let enterScript = """
    function find(win, frames = []) {
        let found = Array.from(win.document.querySelectorAll('video'))
            .filter(v => v.readyState >= 1 && v.videoWidth > 0).map(video => ({video, frames}));
        for (const frame of win.document.querySelectorAll('iframe,frame')) {
            try { found.push(...find(frame.contentWindow, [...frames, frame])); } catch (_) {}
        }
        return found;
    }
    const chosen = find(window).sort((a,b) => Number(a.video.paused) - Number(b.video.paused)
        || b.video.videoWidth * b.video.videoHeight - a.video.videoWidth * a.video.videoHeight)[0];
    if (!chosen) return null;
    globalThis.sorrelVideo?.restore();
    const saved = [], sheets = [];
    function focus(element) {
        const doc = element.ownerDocument;
        const sheet = doc.createElement('style');
        sheet.textContent = '* { visibility: hidden !important; } html, body { background: black !important; overflow: hidden !important; }';
        doc.documentElement.appendChild(sheet); sheets.push(sheet);
        for (let node = element; node; node = node.parentElement) {
            saved.push([node, node.getAttribute('style')]);
            for (const [key, value] of Object.entries({transform:'none', filter:'none', perspective:'none',
                contain:'none', 'clip-path':'none', opacity:'1', isolation:'auto', overflow:'visible'}))
                node.style.setProperty(key, value, 'important');
            if (node !== element) {
                node.style.setProperty('position', 'static', 'important');
                node.style.setProperty('z-index', 'auto', 'important');
            }
        }
        for (const [key, value] of Object.entries({position:'fixed', top:'0', left:'0', width:'100vw',
            height:'100vh', 'max-width':'none', 'max-height':'none', 'min-width':'0', 'min-height':'0',
            margin:'0', padding:'0', border:'0', visibility:'visible', 'object-fit':'contain', 'z-index':'2147483647'}))
            element.style.setProperty(key, value, 'important');
    }
    for (const frame of chosen.frames) focus(frame);
    focus(chosen.video);
    const video = chosen.video, controls = video.controls;
    video.controls = false;
    globalThis.sorrelVideo = {video, restore() {
        video.controls = controls;
        for (const [node, style] of saved.reverse()) {
            if (style === null) node.removeAttribute('style'); else node.setAttribute('style', style);
        }
        for (const sheet of sheets) sheet.remove();
    }};
    return {width: video.videoWidth, height: video.videoHeight};
    """
}

private final class VideoCanvas: NSView {
    let overlay = NSView()
    private let bottom = NSView()
    private let bar = NSProgressIndicator()
    private let remaining = NSTextField(labelWithString: "")
    private var pause: NSButton!
    private var backward: NSButton!
    private var forward: NSButton!
    var onClose: (() -> Void)?
    var onToggle: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        bottom.wantsLayer = true
        bottom.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        overlay.addSubview(bottom)
        backward = button("gobackward.10", "Rewind 10 seconds", #selector(rewind))
        pause = button("pause.fill", "Pause", #selector(toggle))
        forward = button("goforward.10", "Forward 10 seconds", #selector(advance))
        let close = button("pip.exit", "Return video to tab", #selector(exitVideo))
        close.frame = NSRect(x: 10, y: bounds.height - 38, width: 32, height: 28)
        close.autoresizingMask = [.maxXMargin, .minYMargin]
        overlay.addSubview(close)
        remaining.textColor = .white
        remaining.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        bottom.addSubview(remaining)
        bar.isIndeterminate = false
        bar.minValue = 0; bar.maxValue = 1
        bar.style = .bar
        bottom.addSubview(bar)
        overlay.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = title
        b.setAccessibilityLabel(title)
        bottom.addSubview(b)
        return b
    }
    override func layout() {
        super.layout()
        bottom.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 76)
        for (i, button) in [backward, pause, forward].enumerated() {
            button?.frame = NSRect(x: bounds.midX + CGFloat(i - 1) * 48 - 18, y: 35, width: 36, height: 30)
        }
        bar.frame = NSRect(x: 14, y: 12, width: max(0, bounds.width - 118), height: 10)
        remaining.frame = NSRect(x: bounds.width - 98, y: 7, width: 88, height: 20)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ hover: Bool) { Motion.run(0.18, Motion.glide) { self.overlay.animator().alphaValue = hover ? 1 : 0 } }
    // The transparent native overlay receives drags instead of sending clicks into the website.
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        let hit = super.hitTest(point)
        if overlay.alphaValue > 0.05, hit is NSButton { return hit }
        return self
    }
    var remainingText: String { remaining.stringValue }
    var buttonsReceiveClicks: Bool {
        let point = bottom.convert(NSPoint(x: pause.frame.midX, y: pause.frame.midY), to: superview)
        return hitTest(point) === pause
    }

    func render(paused: Bool, time: Double, duration: Double, seekable: Bool) {
        let title = paused ? "Play" : "Pause"
        pause.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: title)
        pause.toolTip = title; pause.setAccessibilityLabel(title)
        backward.isEnabled = seekable; forward.isEnabled = seekable
        bar.doubleValue = duration > 0 ? min(1, max(0, time / duration)) : 0
        let seconds = Int(min(359999, max(0, duration - time)).rounded(.up))
        remaining.stringValue = duration > 0 ? String(format: "−%d:%02d", seconds / 60, seconds % 60) : "Live"
        bar.setAccessibilityLabel(duration > 0 ? "Video progress" : "Live video")
    }
    @objc private func toggle() { onToggle?() }
    @objc private func rewind() { onSeek?(-10) }
    @objc private func advance() { onSeek?(10) }
    @objc private func exitVideo() { onClose?() }
}
