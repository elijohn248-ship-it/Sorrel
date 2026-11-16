import AppKit

/// Arc's "update ready" card, at the bottom of the sidebar above the space icons.
///
/// It only ever shows `Updater.card`, which is worked out from what the updater is really doing, so it can't
/// linger after a click the way Arc's did: Update and Restart turns it into "Updating…" at once, and the next
/// launch either says "Updated to X" (then the card goes by itself) or "Update didn't install" with the reason.
final class UpdateCard: NSView {
    /// Whether the sidebar is on screen; the "Updated" note only counts down while it can be seen.
    var isOnScreen: () -> Bool = { true }
    /// Told when the card starts or stops taking room, so the sidebar can add the gap below it.
    var onShownChange: ((Bool) -> Void)?
    /// While the Library is open it covers this spot, so the card steps aside.
    var isSuppressed = false { didSet { if isSuppressed != oldValue { refresh() } } }

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var close: IconButton!
    private let button = NSButton(title: "", target: nil, action: nil)
    private let auto = NSButton(checkboxWithTitle: "Update automatically", target: nil, action: nil)
    private let stack = NSStackView()
    private var collapsed: NSLayoutConstraint!
    private(set) var shown: Updater.Card?
    private var seenFor: TimeInterval = 0
    private var countdown: Timer?
    /// How long "Updated to X" stays once the person can see it.
    static let updatedLinger: TimeInterval = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        icon.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 4
        close = IconButton(symbol: "xmark", size: 9, tooltip: "Hide") { Updater.shared.dismissCard() }

        button.bezelStyle = .push
        button.controlSize = .regular
        button.bezelColor = .controlAccentColor
        button.keyEquivalent = ""
        button.target = self
        button.action = #selector(pressed)
        button.translatesAutoresizingMaskIntoConstraints = false
        auto.controlSize = .small
        auto.font = .systemFont(ofSize: 11)
        auto.target = self
        auto.action = #selector(toggledAuto)
        auto.toolTip = "Install future updates quietly the next time you quit Sorrel, without this card."

        let iconHolder = NSView()
        iconHolder.translatesAutoresizingMaskIntoConstraints = false
        iconHolder.addSubview(icon)
        iconHolder.addSubview(spinner)
        let header = NSStackView(views: [iconHolder, title, NSView(), close])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 10, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, detail, button, auto] as [NSView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(8, after: detail)
        addSubview(stack)

        collapsed = heightAnchor.constraint(equalToConstant: 0)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh   // gives way to `collapsed` while hidden
        NSLayoutConstraint.activate([
            iconHolder.widthAnchor.constraint(equalToConstant: 16),
            iconHolder.heightAnchor.constraint(equalToConstant: 16),
            icon.centerXAnchor.constraint(equalTo: iconHolder.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconHolder.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: iconHolder.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconHolder.centerYAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -18),
            detail.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -2),
            button.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom,
            collapsed,
        ])
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: .sorrelUpdateState, object: nil)
        DispatchQueue.main.async { [weak self] in self?.refresh() }   // "Updated to X" at launch
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.white.withAlphaComponent(0.6)).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor
    }
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func stateChanged() { refresh() }
    @objc private func pressed() { Updater.shared.cardAction() }
    @objc private func toggledAuto() { Updater.shared.setInstallAutomatically(auto.state == .on, fromCard: true) }

    /// Shows whatever the updater says now: slides in, changes in place with a crossfade, or leaves.
    func refresh() {
        let next = isSuppressed ? nil : Updater.shared.card
        guard next != shown else { return }
        let was = shown
        shown = next
        guard let next else { leave(); return }
        fill(next)
        if was == nil {
            arrive()
        } else if window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            fade.timingFunction = Motion.glide
            layer?.add(fade, forKey: "contents")
        }
        if case .updated = next { startCountdown() } else { countdown?.invalidate(); countdown = nil }
    }

    private func fill(_ card: Updater.Card) {
        var symbolName = "arrow.down.circle.fill"
        var tint = NSColor.controlAccentColor
        var busy = false
        var action: String?
        var showsAuto = false
        var closable = true
        switch card {
        case .ready(let v):
            title.stringValue = "Sorrel \(v) is ready"
            detail.stringValue = Settings.current.installUpdatesAutomatically
                ? "Future updates will install on their own when you quit Sorrel."
                : "Restart now, or it installs the next time you quit."
            action = "Update and Restart"
            showsAuto = true
        case .downloading(let v, let pct):
            title.stringValue = "Getting Sorrel \(v) again…"
            detail.stringValue = pct > 0 ? "Downloading a fresh copy… \(pct)%" : "Downloading a fresh copy…"
            busy = true
            closable = false
        case .updating(let v):
            title.stringValue = "Updating to Sorrel \(v)…"
            detail.stringValue = "Sorrel will close and reopen in a moment."
            busy = true
            closable = false
        case .updated(let v):
            title.stringValue = "Updated to Sorrel \(v)"
            detail.stringValue = "You’re on the newest version."
            symbolName = "checkmark.circle.fill"
            tint = .systemGreen
        case .failed(_, let reason):
            title.stringValue = "Update didn’t install"
            detail.stringValue = reason + " Sorrel is still on \(Updater.shared.current?.version ?? "the old version")."
            symbolName = "exclamationmark.triangle.fill"
            tint = .systemOrange
            action = "Try Again"
        case .gaveUp(let v):
            title.stringValue = "Sorrel \(v) couldn’t install"
            detail.stringValue = "It failed twice on this Mac, so Sorrel won’t keep trying. Download it from GitHub and replace Sorrel by hand."
            symbolName = "exclamationmark.triangle.fill"
            tint = .systemOrange
            action = "Open Download Page"
        }
        icon.image = symbol(symbolName, size: 14, weight: .semibold)
        icon.contentTintColor = tint
        icon.isHidden = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        button.title = action ?? ""
        button.isHidden = action == nil
        auto.isHidden = !showsAuto
        auto.state = Settings.current.installUpdatesAutomatically ? .on : .off
        close.isHidden = !closable
        toolTip = nil
    }

    private func arrive() {
        collapsed.isActive = false
        onShownChange?(true)
        isHidden = false
        alphaValue = 1
        superview?.layoutSubtreeIfNeeded()
        guard window != nil else { return }
        layer?.popIn(scale: 0.95, rise: 8, duration: 0.34)
    }

    private func leave() {
        countdown?.invalidate()
        countdown = nil
        guard window != nil, !isHidden else { collapse(); return }
        layer?.popOut(scale: 0.96, duration: 0.2)
        fade(in: false, duration: 0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, self.shown == nil else { return }
            self.collapse()
        }
    }

    /// Set at once rather than animating the sidebar's layout (that shifts the tab list's scroll position;
    /// the downloads strip learned the same).
    private func collapse() {
        isHidden = true
        layer?.clearPopOut()
        collapsed.isActive = true
        onShownChange?(false)
    }

    /// "Updated to X" goes by itself after it has been on screen for a few seconds (not while the sidebar is
    /// hidden, so a person who launches with it tucked away still sees the note when they open it).
    private func startCountdown() {
        countdown?.invalidate()
        seenFor = 0
        countdown = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.window?.isVisible == true, self.window?.occlusionState.contains(.visible) == true, self.isOnScreen() {
                self.seenFor += 0.5
            }
            if self.seenFor >= Self.updatedLinger { Updater.shared.dismissCard() }
        }
    }

    // MARK: Tests

    var debugText: String {
        guard let shown else { return "none (hidden=\(isHidden))" }
        return "\(shown) title=\"\(title.stringValue)\" button=\(button.isHidden ? "-" : "\"\(button.title)\"") auto=\(auto.isHidden ? "-" : (auto.state == .on ? "on" : "off")) close=\(close.isHidden ? "-" : "x") height=\(Int(frame.height))"
    }
    func debugPressButton() { if !button.isHidden { button.performClick(nil) } }
    func debugClickAuto() { if !auto.isHidden { auto.performClick(nil) } }
    func debugClose() { if !close.isHidden { close.performClick(nil) } }
}
