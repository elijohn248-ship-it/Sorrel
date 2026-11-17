import AppKit
import WebKit

/// Native WebKit media controls, with a fixed-script resume fallback. No page-to-app bridge.
enum TabMedia {
    static func mutedState(_ webView: WKWebView) -> UInt? {
        let selector = NSSelectorFromString("_mediaMutedState")
        guard webView.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(webView.method(for: selector), to: Getter.self)(webView, selector)
    }

    static func toggleMute(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard let state = mutedState(webView), webView.responds(to: selector) else { return }
        // Toggle only audio (bit 0); preserve camera, microphone and screen-capture mute bits.
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, state ^ 1)
    }

    static func play(_ webView: WKWebView, completion: @escaping (Bool) -> Void) {
        // Prefer WebKit's media session, which reaches cross-origin frames and site media handlers.
        let selector = NSSelectorFromString("_playPredominantOrNowPlayingMediaSession:")
        let verify: (Bool) -> Void = { [weak webView] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let webView else { completion(false); return }
                webView.requestMediaPlaybackState { state in
                    if state == .playing { completion(true); return }
                    // Some audio-only pages acknowledge the native command without resuming.
                    // Resume only a previously played element; never start an untouched autoplay candidate.
                    // Fixed source, no page values interpolated, and no page-to-app message handler.
                    webView.callAsyncJavaScript("""
                    function findMedia(win) {
                        let found = Array.from(win.document.querySelectorAll('audio,video'))
                            .filter(m => m.paused && !m.ended && m.played.length > 0);
                        for (let i = 0; i < win.frames.length; i++) {
                            try { found.push(...findMedia(win.frames[i])); } catch (_) {}
                        }
                        return found;
                    }
                    const media = findMedia(window).sort((a, b) => b.currentTime - a.currentTime)[0];
                    if (!media) return false;
                    await media.play();
                    return !media.paused;
                    """, arguments: [:], in: nil, in: .page) { result in
                        if case .success(let value) = result { completion(value as? Bool == true) }
                        else { completion(false) }
                    }
                }
            }
        }
        guard webView.responds(to: selector) else { verify(false); return }
        let callback: @convention(block) (Bool) -> Void = verify
        webView.perform(selector, with: callback as AnyObject)
    }

    static func metadata(_ webView: WKWebView, completion: @escaping (String?, String?) -> Void) {
        let selector = NSSelectorFromString("_nowPlayingMediaTitleAndArtist:")
        guard webView.responds(to: selector) else { completion(nil, nil); return }
        let callback: @convention(block) (String?, String?) -> Void = completion
        webView.perform(selector, with: callback as AnyObject)
    }
}

/// A small player above the space icons. Only normal sidebar tabs can become sources; nothing is saved.
final class SidebarMediaPlayer: NSView {
    private var store: Store { (window?.windowController as? MainWindowController)?.store ?? .shared }
    var isSuppressed = false { didSet { render() } }
    private(set) weak var source: Item?
    private var states: [UUID: WKMediaPlaybackState] = [:]
    private var previouslyPlaying: Set<UUID> = []
    private var timer: Timer?
    private var polling = false
    private var busy = false
    private var controlGeneration = 0
    private let artwork = NSImageView()
    private let track = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var playButton: IconButton!
    private var muteButton: IconButton!
    private var sourcesButton: IconButton!
    private var height: NSLayoutConstraint!
    private var mediaTitle: String?
    private var artist: String?
    private var revision = 0
    private(set) var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.contentTintColor = .secondaryLabelColor
        track.font = .systemFont(ofSize: 12, weight: .semibold)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        for label in [track, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        playButton = IconButton(symbol: "pause.fill", size: 15, tooltip: "Pause") { [weak self] in self?.togglePlayback() }
        muteButton = IconButton(symbol: "speaker.wave.2", size: 13, tooltip: "Mute Tab") { [weak self] in self?.toggleMute() }
        sourcesButton = IconButton(symbol: "chevron.down", size: 10, tooltip: "Choose Playing Tab") { [weak self] in self?.showSources() }
        let labels = NSStackView(views: [track, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let row = NSStackView(views: [artwork, labels, playButton, muteButton, sourcesButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 26),
            artwork.heightAnchor.constraint(equalToConstant: 26),
            playButton.widthAnchor.constraint(equalToConstant: 24),
            playButton.heightAnchor.constraint(equalToConstant: 30),
            muteButton.widthAnchor.constraint(equalToConstant: 22),
            muteButton.heightAnchor.constraint(equalToConstant: 30),
            sourcesButton.widthAnchor.constraint(equalToConstant: 14),
            sourcesButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        isHidden = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        for name in [Notification.Name.sorrelStructure, .sorrelItem] {
            NotificationCenter.default.addObserver(self, selector: #selector(tabsChanged), name: name, object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.10 : 0.55).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }
    override func mouseDown(with event: NSEvent) {
        if let source { store.select(source) }
    }
    @objc private func tabsChanged() { refresh() }

    /// One native state request per loaded tab per second; a stalled request cannot accumulate more polls.
    func refresh() {
        guard !polling else { return }
        let tabs = Store.shared.allTabs.map(\.item).filter { $0.page != nil && $0.page?.isPrivate == false }
        let live = Set(tabs.map(\.id))
        previouslyPlaying.formIntersection(live)
        states = states.filter { live.contains($0.key) }
        guard !tabs.isEmpty else { source = nil; render(); return }
        polling = true
        var remaining = tabs.count
        for item in tabs {
            guard let page = item.page else { continue }
            page.webView.requestMediaPlaybackState { [weak self, weak item, weak page] state in
                guard let self else { return }
                if let item, let page, item.page === page {
                    self.states[item.id] = state
                    page.mediaIsPlaying = state == .playing
                    if state == .playing { self.previouslyPlaying.insert(item.id) }
                    if state == .none { self.previouslyPlaying.remove(item.id) }
                }
                remaining -= 1
                if remaining == 0 {
                    self.polling = false
                    self.chooseSource()
                }
            }
        }
    }

    private var candidates: [Item] {
        Store.shared.allTabs.map(\.item).filter {
            $0.page != nil && $0.page?.isPrivate == false && previouslyPlaying.contains($0.id)
                && states[$0.id] != WKMediaPlaybackState.none && states[$0.id] != nil
        }
    }

    private func chooseSource() {
        let tabs = candidates
        // Keep the chosen source through pauses and space switches, until it closes or loses its media.
        if !tabs.contains(where: { $0 === source }) {
            source = tabs.first(where: { states[$0.id] == .playing }) ?? tabs.first
            mediaTitle = nil
            artist = nil
        }
        render()
        guard let source, let page = source.page else { return }
        revision += 1
        let revision = revision
        TabMedia.metadata(page.webView) { [weak self, weak source, weak page] title, artist in
            guard let self, let source, let page, self.revision == revision,
                  self.source === source, source.page === page else { return }
            self.mediaTitle = title?.isEmpty == false ? title : nil
            self.artist = artist?.isEmpty == false ? artist : nil
            self.render()
        }
    }

    private func render() {
        let visible = source?.page != nil && !isSuppressed
        let arriving = visible && !shown
        shown = visible
        if visible {
            height.constant = 62
            if isHidden { isHidden = false; alphaValue = 1; layer?.clearPopOut() }
            if arriving { alphaValue = 1; layer?.clearPopOut(); layer?.popIn(scale: 0.96, rise: 6, duration: 0.3) }
        } else if !isHidden {
            fade(in: false, duration: 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.shown else { return }
                self.isHidden = true
                self.height.constant = 0
            }
        }
        guard let source, let page = source.page else { return }
        let playing = states[source.id] == .playing
        let muted = TabMedia.mutedState(page.webView).map { $0 & 1 != 0 } ?? false
        track.stringValue = mediaTitle ?? source.displayTitle
        let site = Site.display(source.host) ?? "Media"
        detail.stringValue = artist ?? (muted ? "Muted · \(site)" : playing ? site : "Paused · \(site)")
        artwork.image = page.favicon ?? symbol("waveform", size: 22)
        playButton.image = symbol(playing ? "pause.fill" : "play.fill", size: 15)
        playButton.toolTip = playing ? "Pause" : "Play"
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
        playButton.isEnabled = !busy
        muteButton.image = symbol(muted ? "speaker.slash.fill" : "speaker.wave.2", size: 13)
        muteButton.toolTip = muted ? "Unmute Tab" : "Mute Tab"
        muteButton.setAccessibilityLabel(muted ? "Unmute Tab" : "Mute Tab")
        muteButton.isEnabled = TabMedia.mutedState(page.webView) != nil
        sourcesButton.toolTip = "Playing Tabs (\(candidates.count))"
        sourcesButton.setAccessibilityLabel("Choose Playing Tab")
    }

    func togglePlayback() {
        guard !busy, let source, let page = source.page else { return }
        busy = true
        controlGeneration += 1
        let generation = controlGeneration
        // A site's custom media handler can leave its play promise unresolved.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishedControl(generation) }
        render()
        if states[source.id] == .playing {
            page.webView.pauseAllMediaPlayback { [weak self] in self?.finishedControl(generation) }
        } else {
            TabMedia.play(page.webView) { [weak self] played in
                if ProcessInfo.processInfo.environment["SORREL_MEDIATEST"] != nil {
                    FileHandle.standardError.write("media: resume result expected=true got=\(played)\n".data(using: .utf8)!)
                }
                if !played { Engine.shared.onToast?("Open the media tab to resume playback") }
                self?.finishedControl(generation)
            }
        }
    }
    private func finishedControl(_ generation: Int) {
        guard controlGeneration == generation else { return }
        busy = false
        refresh()
        render()
    }
    func toggleMute() {
        guard let page = source?.page else { return }
        TabMedia.toggleMute(page.webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.render() }
    }
    private func showSources() {
        let menu = NSMenu()
        for tab in candidates {
            let entry = NSMenuItem(title: tab.displayTitle, action: #selector(pickSource(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = tab.id
            entry.state = tab === source ? .on : .off
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
    }
    @objc private func pickSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        source = candidates.first { $0.id == id }
        mediaTitle = nil
        artist = nil
        chooseSource()
    }

    var debugState: String {
        let muted = source.flatMap { $0.page }.flatMap { TabMedia.mutedState($0.webView) }.map { $0 & 1 != 0 } ?? false
        return "shown=\(shown) sources=\(candidates.count) playing=\(source.flatMap { states[$0.id] } == .playing) muted=\(muted)"
    }
}

extension SidebarMediaPlayer {
    /// Silent local WAVs exercise WebKit playback in real tabs, without downloads, permissions or sound.
    func runMediaTest() {
        func log(_ text: String) { FileHandle.standardError.write(("media: " + text + "\n").data(using: .utf8)!) }
        func after(_ seconds: Double, _ block: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
        }
        // PCM mono, 8 kHz, one minute. Silence avoids making noise on the owner's Mac.
        var wav = Data()
        func ascii(_ s: String) { wav.append(contentsOf: s.utf8) }
        func number(_ n: UInt32, bytes: Int) {
            for i in 0..<bytes { wav.append(UInt8((n >> (i * 8)) & 255)) }
        }
        let count: UInt32 = 8000 * 2 * 60
        ascii("RIFF"); number(count + 36, bytes: 4); ascii("WAVEfmt ")
        number(16, bytes: 4); number(1, bytes: 2); number(1, bytes: 2)
        number(8000, bytes: 4); number(16000, bytes: 4); number(2, bytes: 2); number(16, bytes: 2)
        ascii("data"); number(count, bytes: 4); wav.append(Data(count: Int(count)))
        let html = "<title>Media Fixture</title><audio loop controls src='data:audio/wav;base64,\(wav.base64EncodedString())'></audio>"
        let store = self.store
        let first = store.newTab(url: "about:blank", title: "Media Fixture")
        let page = Engine.shared.ensurePage(for: first)
        page.webView.loadHTMLString(html, baseURL: URL(string: "https://media.invalid"))
        func play(_ page: Page) {
            page.webView.callAsyncJavaScript("navigator.mediaSession.metadata = new MediaMetadata({title: 'Fixture Track', artist: 'Fixture Artist'}); await document.querySelector('audio').play(); return true", arguments: [:], in: nil, in: .page) { result in
                log("fixture play expected=true result=\(result)")
            }
        }
        after(2) { play(page) }
        after(4) {
            log("playing expected=shown/playing/1: \(self.debugState)")
            if let path = ProcessInfo.processInfo.environment["SORREL_MEDIASHOT"], let view = self.window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
            }
            self.togglePlayback()
        }
        after(6) { log("paused expected=shown/not-playing/1: \(self.debugState)"); self.togglePlayback() }
        after(8) {
            log("resumed expected=playing: \(self.debugState)")
            page.webView.evaluateJavaScript("document.querySelector('audio').paused") { value, _ in log("DOM paused expected=false got=\(value ?? "missing")") }
            self.toggleMute()
        }
        after(10) {
            log("muted expected=true playing=true sleep=false: \(self.debugState) sleep=\(store.canSleep(first))")
            self.toggleMute()
            _ = store.addSpace(name: "Other Space")
            _ = store.newTab(url: "about:blank")
        }
        after(12) {
            log("background expected=same-source/unmuted: \(self.source === first) \(self.debugState)")
            (self.superview as? SidebarView)?.openLibrary(.downloads)
        }
        after(13) { log("library expected=shown=false: \(self.debugState)"); (self.superview as? SidebarView)?.closeLibrary() }
        after(14) {
            let second = store.newTab(url: "about:blank", title: "Second Media Fixture")
            let secondPage = Engine.shared.ensurePage(for: second)
            secondPage.webView.loadHTMLString(html, baseURL: nil)
            after(2) { play(secondPage) }
            after(4) {
                log("multiple expected=sources=2: \(self.debugState)")
                let entry = NSMenuItem()
                entry.representedObject = second.id
                self.pickSource(entry)
                log("switch source expected=true: \(self.source === second)")
                store.close(second)
            }
        }
        after(20) { log("closed source expected=fallback-first: \(self.source === first) \(self.debugState)"); page.webView.loadHTMLString("<title>No media</title>", baseURL: nil) }
        after(23) {
            log("navigation expected=shown=false sources=0: \(self.debugState)")
            let privatePage = Engine.shared.makePage(profileID: nil, isPrivate: true)
            log("private expected=nonpersistent/not-source: \(!privatePage.webView.configuration.websiteDataStore.isPersistent) \(self.source == nil)")
            privatePage.teardown()
        }
    }
}
