import AppKit

// MARK: - Test mode

/// True for automated test runs (SORREL_SNAPSHOT is set). Test runs stay in the background:
/// no Dock icon, no taking focus, window opened behind everything else. SORREL_LOUD turns this off.
let isQuietTest: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["SORREL_SNAPSHOT"] != nil && env["SORREL_LOUD"] == nil
}()

/// Brings Sorrel to the front, except during quiet test runs.
func bringAppForward() {
    if !isQuietTest { NSApp.activate(ignoringOtherApps: true) }
}

/// Hands memory that has been freed back to macOS straight away.
/// Loading an extension's rules allocates a lot briefly; once that work is done the freed pages
/// otherwise stay charged to Sorrel until the system comes under memory pressure.
func releaseFreedMemory() {
    if ProcessInfo.processInfo.environment["SORREL_NO_RELIEF"] != nil { return }   // testing: measure without it
    malloc_zone_pressure_relief(nil, 0)
}

/// True when a test run points at a scratch profile (SORREL_HOME).
let isTestProfile: Bool = !(ProcessInfo.processInfo.environment["SORREL_HOME"] ?? "").isEmpty

/// True for build/SorrelTest.app (bundle id app.sorrel.browser.test): its own container, preferences and
/// site data, so nothing a test does can reach the owner's. Every test run uses it (see CLAUDE.md, Testing).
let isTestBuild: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".test") == true

// MARK: - Sandbox

/// Sorrel runs in the macOS App Sandbox (Resources/Sorrel.entitlements). Inside it, the home folder that
/// Foundation reports (NSHomeDirectory, homeDirectoryForCurrentUser, ~/Library) is the app's container,
/// ~/Library/Containers/<bundle id>/Data. Use these for anything that means the person's real folders.
enum Sandbox {
    static let isOn = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    /// The person's real home folder, inside or outside the sandbox.
    static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    /// ~/Downloads by its real path (in the container it is a symlink; Finder and icons want the real one).
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    }
}

// MARK: - Paths

enum Paths {
    /// The profile folder's name in Application Support. The test build uses its own name as well, so even an
    /// unsandboxed copy of it can never open the owner's profile.
    static let profileName = isTestBuild ? "Sorrel Test" : "Sorrel"
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent(profileName, isDirectory: true)
        // SORREL_HOME points a test run at a throwaway folder instead of the real profile.
        if let override = ProcessInfo.processInfo.environment["SORREL_HOME"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var state: URL { support.appendingPathComponent("state.json") }
    static var archive: URL { support.appendingPathComponent("archive.json") }
    static var zoom: URL { support.appendingPathComponent("zoom.json") }
    static var history: URL { support.appendingPathComponent("history.json") }
    static var settings: URL { support.appendingPathComponent("settings.json") }
    static var keybindings: URL { support.appendingPathComponent("keybindings.json") }
    static var keybindingDefaults: URL { support.appendingPathComponent("keybindings.default.json") }
    static var bangs: URL { support.appendingPathComponent("bangs.json") }
    static let favicons: URL = {
        let dir = support.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

// MARK: - Settings

struct Settings: Codable {
    var searchEngineName = "DuckDuckGo"
    var searchEngineURL = "https://duckduckgo.com/?q=%s"
    var stripTrackingParameters = true
    /// Try every plain http:// site over https:// first, and warn before opening one that has no secure version.
    var httpsFirst = true
    /// Block ads and trackers with EasyList and EasyPrivacy.
    var blockAds = true
    /// Also hide cookie-consent notices. Off by default: it can occasionally break a site.
    var blockCookieNotices = false
    /// Sites where blocking is turned off.
    var blockingDisabledSites: [String] = []
    /// Unpinned and pinned tabs left alone this long are unloaded to save memory, and reload when opened. 0 = never.
    var sleepTabsAfterMinutes = 120.0
    /// Suggest searches while typing. Off by default: it sends each keystroke to the search engine.
    var searchSuggestions = false
    /// Keep the built-in uBlock Origin Lite up to date from its official releases.
    var autoUpdateBlocker = true
    /// Which extensions are switched on, by id. Missing = on for the bundled one, off for the rest.
    var extensionStates: [String: Bool] = [:]
    /// Extra access the person approved when an extension asked for it, by extension id
    /// ("perm:<name>", "match:<pattern>", "url:<address>"). What a manifest requires is granted on switch-on.
    var extensionGrants: [String: [String]] = [:]
    /// Unpinned tabs untouched for this many hours are archived. 0 = never.
    var archiveAfterHours = 24.0
    var fallbackBrowser = "Helium"
    var externalLinksOpenInMiniWindow = true
    /// Clicking a link that leads to another site opens it as a preview over the page, from any tab.
    var peekLinksFromAllTabs = true
    /// The same, but only from pinned tabs and favorites. Used when peekLinksFromAllTabs is off.
    var peekLinksFromPinnedTabs = true
    /// Pages on these sites never open previews; their links open in the tab as usual.
    /// A bare name ("google") covers every country version; a full domain covers that domain.
    /// The search engine set above is always included.
    var peekExcludedSites = ["google", "bing", "yahoo", "yandex", "baidu", "duckduckgo.com", "search.brave.com",
                             "kagi.com", "startpage.com", "ecosia.org", "qwant.com", "perplexity.ai",
                             "mojeek.com", "search.marginalia.nu"]
    /// How close to the window's left edge the cursor must be to reveal the hidden sidebar.
    var sidebarHoverEdgeWidth = 14.0
    /// Overshooting the left edge still reveals the sidebar if the cursor stops within this distance
    /// outside the window. 0 turns this off.
    var sidebarOvershootReach = 90.0
    var settingsVersion = 2
    /// Seconds to wait after the cursor leaves the revealed sidebar before it slides away.
    var sidebarHideDelay = 0.12
    /// How far past the sidebar's right edge the cursor can go before it counts as leaving.
    var sidebarExitTolerance = 14.0
    var sidebarAnimationDuration = 0.2
    /// Reveal the sidebar on hover even when Sorrel is not the frontmost app.
    var sidebarHoverWhenInactive = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        searchEngineName = try c.decodeIfPresent(String.self, forKey: .searchEngineName) ?? d.searchEngineName
        searchEngineURL = try c.decodeIfPresent(String.self, forKey: .searchEngineURL) ?? d.searchEngineURL
        stripTrackingParameters = try c.decodeIfPresent(Bool.self, forKey: .stripTrackingParameters) ?? d.stripTrackingParameters
        httpsFirst = try c.decodeIfPresent(Bool.self, forKey: .httpsFirst) ?? d.httpsFirst
        extensionGrants = try c.decodeIfPresent([String: [String]].self, forKey: .extensionGrants) ?? d.extensionGrants
        blockAds = try c.decodeIfPresent(Bool.self, forKey: .blockAds) ?? d.blockAds
        blockCookieNotices = try c.decodeIfPresent(Bool.self, forKey: .blockCookieNotices) ?? d.blockCookieNotices
        blockingDisabledSites = try c.decodeIfPresent([String].self, forKey: .blockingDisabledSites) ?? d.blockingDisabledSites
        archiveAfterHours = try c.decodeIfPresent(Double.self, forKey: .archiveAfterHours) ?? d.archiveAfterHours
        extensionStates = try c.decodeIfPresent([String: Bool].self, forKey: .extensionStates) ?? d.extensionStates
        sleepTabsAfterMinutes = try c.decodeIfPresent(Double.self, forKey: .sleepTabsAfterMinutes) ?? d.sleepTabsAfterMinutes
        searchSuggestions = try c.decodeIfPresent(Bool.self, forKey: .searchSuggestions) ?? d.searchSuggestions
        autoUpdateBlocker = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateBlocker) ?? d.autoUpdateBlocker
        fallbackBrowser = try c.decodeIfPresent(String.self, forKey: .fallbackBrowser) ?? d.fallbackBrowser
        externalLinksOpenInMiniWindow = try c.decodeIfPresent(Bool.self, forKey: .externalLinksOpenInMiniWindow) ?? d.externalLinksOpenInMiniWindow
        peekLinksFromPinnedTabs = try c.decodeIfPresent(Bool.self, forKey: .peekLinksFromPinnedTabs) ?? d.peekLinksFromPinnedTabs
        peekLinksFromAllTabs = try c.decodeIfPresent(Bool.self, forKey: .peekLinksFromAllTabs) ?? d.peekLinksFromAllTabs
        peekExcludedSites = try c.decodeIfPresent([String].self, forKey: .peekExcludedSites) ?? d.peekExcludedSites
        sidebarHoverEdgeWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarHoverEdgeWidth) ?? d.sidebarHoverEdgeWidth
        sidebarHideDelay = try c.decodeIfPresent(Double.self, forKey: .sidebarHideDelay) ?? d.sidebarHideDelay
        sidebarExitTolerance = try c.decodeIfPresent(Double.self, forKey: .sidebarExitTolerance) ?? d.sidebarExitTolerance
        sidebarAnimationDuration = try c.decodeIfPresent(Double.self, forKey: .sidebarAnimationDuration) ?? d.sidebarAnimationDuration
        sidebarHoverWhenInactive = try c.decodeIfPresent(Bool.self, forKey: .sidebarHoverWhenInactive) ?? d.sidebarHoverWhenInactive
        sidebarOvershootReach = try c.decodeIfPresent(Double.self, forKey: .sidebarOvershootReach) ?? d.sidebarOvershootReach
        settingsVersion = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
    }

    static var current = Settings.load()

    static func load() -> Settings {
        if let data = try? Data(contentsOf: Paths.settings),
           var s = try? JSONDecoder().decode(Settings.self, from: data) {
            if s.settingsVersion < 2 {
                // The first build's 8pt reveal strip was too thin; widen it unless it was customized.
                if s.sidebarHoverEdgeWidth == 8 { s.sidebarHoverEdgeWidth = 14 }
                s.settingsVersion = 2
                s.save()
            }
            return s
        }
        let s = Settings()
        s.save()
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(self) { try? data.write(to: Paths.settings, options: .atomic) }
    }
}

// MARK: - Theme

struct Theme: Codable, Equatable {
    /// One to three hex colors.
    var colors: [String]
    /// Gradient direction in degrees.
    var angle: Double
    /// 0 = barely tinted, 1 = full color.
    var intensity: Double

    static let presets: [Theme] = [
        Theme(colors: ["#7C9CFF", "#C59BFF"], angle: 315, intensity: 0.55),
        Theme(colors: ["#46C2A8", "#8FD46B"], angle: 300, intensity: 0.5),
        Theme(colors: ["#FF9A6B", "#FF6F91"], angle: 320, intensity: 0.55),
        Theme(colors: ["#FFD36B", "#FF9F5A"], angle: 300, intensity: 0.5),
        Theme(colors: ["#5AC8FA", "#5A7BFA"], angle: 290, intensity: 0.55),
        Theme(colors: ["#F58FD0", "#9B8CFF", "#6BC8FF"], angle: 315, intensity: 0.55),
        Theme(colors: ["#2B3A67", "#51407A"], angle: 315, intensity: 0.95),
        Theme(colors: ["#12372A", "#2E5E4E"], angle: 300, intensity: 0.95),
        Theme(colors: ["#3A1F2B", "#7A2E48"], angle: 320, intensity: 0.95),
        Theme(colors: ["#A0A4AB"], angle: 0, intensity: 0.25),
    ]

    /// Colors as drawn: each is blended toward a neutral base by the intensity.
    func resolvedColors(systemIsDark: Bool) -> [NSColor] {
        let base = systemIsDark ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
                                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let t = CGFloat(max(0, min(1, intensity)))
        var out = colors.compactMap { NSColor(hex: $0) }.map { c in
            base.blended(withFraction: t, of: c) ?? c
        }
        if out.isEmpty { out = [base] }
        return out
    }

    /// Whether text on top of this theme should be light.
    func isDark(systemIsDark: Bool) -> Bool {
        let cs = resolvedColors(systemIsDark: systemIsDark)
        let lum = cs.map { $0.luminance }.reduce(0, +) / CGFloat(cs.count)
        return lum < 0.55
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    var luminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

extension NSWindow {
    /// The radius macOS rounds this window's corners with, so inner panels can be concentric with it.
    var outerCornerRadius: CGFloat {
        let sel = Selector(("_cornerRadius"))
        if responds(to: sel), let n = value(forKey: "_cornerRadius") as? NSNumber, n.doubleValue > 0 {
            return CGFloat(n.doubleValue)
        }
        return 16
    }
}

func systemIsDark() -> Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

/// A view that draws a space's gradient.
final class ThemeBackgroundView: NSView {
    private let gradient = CAGradientLayer()
    var cornerRadius: CGFloat = 0 { didSet { gradient.cornerRadius = cornerRadius } }
    private(set) var theme = Theme.presets[0]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { gradient }

    func apply(_ theme: Theme, animated: Bool = false) {
        self.theme = theme
        var cs = theme.resolvedColors(systemIsDark: systemIsDark()).map { $0.cgColor }
        if cs.count == 1 { cs.append(cs[0]) }
        let rad = theme.angle * .pi / 180
        let dx = CGFloat(cos(rad)) / 2, dy = CGFloat(sin(rad)) / 2
        Motion.layer(animated ? 0.35 : 0) {
            gradient.colors = cs
            gradient.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            gradient.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

// MARK: - Small helpers

func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

/// A borderless icon button that runs a closure.
final class IconButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(symbol name: String, size: CGFloat = 13, tooltip: String? = nil, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        image = symbol(name, size: size)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .secondaryLabelColor
        toolTip = tooltip
        self.handler = handler
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @objc private func fire() { handler?() }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class Debouncer {
    private var work: DispatchWorkItem?
    private let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func schedule(_ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
    func flush() {
        if let w = work, !w.isCancelled { w.perform(); w.cancel() }
        work = nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Motion

/// One vocabulary for how things move, so every slide, fade and pop feels like part of the same app.
enum Motion {
    /// Settles like a light spring: quick start, long soft landing. For things arriving or moving into place.
    static let settle = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    /// Leaves without lingering. For things going away.
    static let leave = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
    /// Eases both ways, for state changes that neither arrive nor leave (a highlight, a colour).
    static let glide = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)

    /// System ▸ Accessibility ▸ Reduce Motion: fades stay, movement and scaling are dropped.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Runs `changes` with implicit view animation on, so `animator()` proxies and constraint changes glide.
    static func run(_ duration: TimeInterval, _ timing: CAMediaTimingFunction = settle,
                    _ changes: () -> Void, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: done)
    }

    /// Changes layer properties inside one Core Animation transaction of the given length (0 = at once).
    static func layer(_ duration: TimeInterval, _ timing: CAMediaTimingFunction = glide, _ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(duration <= 0)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        body()
        CATransaction.commit()
    }
}

extension CALayer {
    /// Plays an arrival: the layer grows from `scale` around its centre and rises by `rise` points, fading in
    /// unless `fade` is off. Only the picture moves; the layer's own values are left exactly as they are.
    func popIn(scale: CGFloat = 0.96, rise: CGFloat = 0, fade: Bool = true, duration: TimeInterval = 0.22) {
        removeAnimation(forKey: "popIn")
        var anims: [CAAnimation] = []
        if fade {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = opacity
            anims.append(a)
        }
        if !Motion.reduced, scale != 1 || rise != 0 {
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            var t = CATransform3DMakeTranslation(c.x, c.y - rise, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DTranslate(t, -c.x, -c.y, 0)
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = t
            a.toValue = CATransform3DIdentity
            anims.append(a)
        }
        guard !anims.isEmpty else { return }
        let group = CAAnimationGroup()
        group.animations = anims
        group.duration = duration
        group.timingFunction = Motion.settle
        add(group, forKey: "popIn")
    }

    /// Shrinks the picture slightly toward the centre while something fades away. It holds its end state,
    /// so remove the layer (or call `clearPopOut`) afterwards.
    func popOut(scale: CGFloat = 0.97, duration: TimeInterval = 0.14) {
        guard !Motion.reduced, scale != 1 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = CATransform3DIdentity
        a.toValue = t
        a.duration = duration
        a.timingFunction = Motion.leave
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        add(a, forKey: "popOut")
    }

    func clearPopOut() { removeAnimation(forKey: "popOut") }
}

extension NSView {
    /// Fades a view in or out instead of flipping `isHidden`. A view fading out is hidden once it has gone,
    /// and comes back at full strength next time; starting a fade-in cancels a pending hide.
    func fade(in shown: Bool, duration: TimeInterval = 0.14) {
        if shown {
            if isHidden { alphaValue = 0; isHidden = false }
            Motion.run(duration, Motion.glide) { animator().alphaValue = 1 }
        } else {
            guard !isHidden else { return }
            Motion.run(duration, Motion.leave, { animator().alphaValue = 0 }) { [weak self] in
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
                self.alphaValue = 1
            }
        }
    }
}

extension CALayer {
    /// A quick squash and release, for a tile or button being clicked.
    func press(scale: CGFloat = 0.93) {
        guard !Motion.reduced else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = CATransform3DIdentity
        a.toValue = t
        a.duration = 0.09
        a.autoreverses = true
        a.timingFunction = Motion.glide
        add(a, forKey: "press")
    }
}
