import AppKit
import WebKit

// Split view: two to four tabs side by side (or stacked) in the main window, shown in the sidebar
// as one row. The model lives in Models.swift (`Item.split`, `Store.makeSplit` and friends);
// this file holds the views. ContentCard (MainWindow.swift) lays the panes out.

/// Same pasteboard type the sidebar uses when a tab row is dragged.
let splitItemDragType = NSPasteboard.PasteboardType("app.drift.item")

enum PaneAction {
    /// The pane's tab becomes a tab of its own again.
    case separate
    /// Close the pane's tab.
    case close
    /// Move this pane to the other end (with two panes: swap them).
    case swap
}

/// Where a tab dragged onto the page will open.
enum DropSide {
    case left, right, top, bottom
    var stacked: Bool { self == .top || self == .bottom }
    var first: Bool { self == .left || self == .top }
}

// MARK: - One pane

/// Holds one tab's web view. In a split view it gets its own rounded corners, a ring when focused,
/// and a small control strip that appears when the cursor nears its top edge.
final class PaneView: NSView {
    let webView: WKWebView
    var onAction: ((PaneAction) -> Void)?

    private let controls = NSView()
    private var area: NSTrackingArea?
    private var controlsShown = false

    /// True when the card shows more than one pane.
    var inSplit = false { didSet { if oldValue != inSplit { refreshLook(); if !inSplit { setControls(false) } } } }
    var isFocused = false { didSet { if oldValue != isFocused { refreshLook() } } }
    var themeIsDark = false { didSet { if oldValue != themeIsDark { refreshLook() } } }

    init(webView: WKWebView, cornerRadius: CGFloat) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        controls.wantsLayer = true
        controls.layer?.cornerRadius = 13
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        controls.alphaValue = 0
        controls.isHidden = true
        let buttons: [(String, String, PaneAction)] = [
            ("arrow.left.arrow.right", "Swap places", .swap),
            ("arrow.up.left.and.arrow.down.right", "Remove from split view (keep the tab)", .separate),
            ("xmark", "Close this tab", .close),
        ]
        var previous: NSView?
        for (name, tip, action) in buttons {
            let b = IconButton(symbol: name, size: 10, tooltip: tip) { [weak self] in self?.onAction?(action) }
            b.contentTintColor = .white
            controls.addSubview(b)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 26),
                b.heightAnchor.constraint(equalToConstant: 26),
                b.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
                b.leadingAnchor.constraint(equalTo: previous?.trailingAnchor ?? controls.leadingAnchor,
                                           constant: previous == nil ? 4 : 0),
            ])
            previous = b
        }
        previous?.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -4).isActive = true

        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.heightAnchor.constraint(equalToConstant: 26),
        ])
        refreshLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the web view back in this pane if something else (a peek, a mini window) borrowed it.
    func reclaimWebView() {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView, positioned: .below, relativeTo: controls)
    }

    private func refreshLook() {
        if inSplit {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            if isFocused {
                layer?.borderWidth = 2
                layer?.borderColor = (themeIsDark ? NSColor.white.withAlphaComponent(0.85)
                                                  : NSColor.black.withAlphaComponent(0.45)).cgColor
            } else {
                layer?.borderWidth = 0.5
                layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
            }
        } else {
            // A single page: the card draws the frame, as before split view existed.
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLook()
    }

    // The control strip shows when the cursor is near the top of a pane in a split view.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        setControls(inSplit && p.y >= bounds.height - 46 && bounds.contains(p))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setControls(false)
    }

    private func setControls(_ show: Bool) {
        guard show != controlsShown else { return }
        controlsShown = show
        if show { controls.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            controls.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.controlsShown else { return }
            self.controls.isHidden = true
        })
    }

    /// Test hook.
    var debugControlsShown: Bool { controlsShown }
}

// MARK: - Divider between panes

/// The gap between two panes. Drag to resize them; double-click to make all panes equal.
final class PaneDivider: NSView {
    var stacked = false { didSet { window?.invalidateCursorRects(for: self) } }
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: stacked ? .resizeUpDown : .resizeLeftRight) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { onDragEnd?() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        // A small grip in the middle of the gap.
        let len: CGFloat = 32, thick: CGFloat = 4
        let r = stacked
            ? NSRect(x: bounds.midX - len / 2, y: bounds.midY - thick / 2, width: len, height: thick)
            : NSRect(x: bounds.midX - thick / 2, y: bounds.midY - len / 2, width: thick, height: len)
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: r, xRadius: thick / 2, yRadius: thick / 2).fill()
    }
}

// MARK: - Sidebar row for a split view

/// One sidebar row showing every tab in a split view, side by side. Clicking a part focuses that pane.
final class SplitCell: NSTableCellView {
    private final class Segment: NSView {
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        override init(frame: NSRect) {
            super.init(frame: frame)
            icon.imageScaling = .scaleProportionallyUpOrDown
            label.font = .systemFont(ofSize: 12.5)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            for v in [icon, label] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 15),
                icon.heightAnchor.constraint(equalToConstant: 15),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    private var segments: [Segment] = []
    private var lines: [NSView] = []
    private(set) var closeButton: TabActionButton!
    private(set) weak var split: Item?
    private var level = 0
    private var hovered = false
    var onClose: ((Item) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeButton = TabActionButton()
        closeButton.onClick = { [weak self] in
            if let self, let sv = self.split { self.onClose?(sv) }
        }
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.isHidden = true
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ split: Item, level: Int, focused: Item?) {
        let sameSplit = self.split === split
        self.split = split
        // Pinned split view: "−" while any of its tabs is loaded, then "×" (close and unpin).
        let pinned = Store.shared.isPinned(split)
        let mode: TabActionButton.Mode = pinned && split.children.contains { $0.page != nil } ? .unload : .close
        closeButton.setMode(mode, animated: sameSplit && window != nil)
        closeButton.toolTip = mode == .unload ? "Unload Split View" : (pinned ? "Close and Unpin Split View" : "Close Split View")
        self.level = level
        let kids = split.children
        while segments.count < kids.count {
            let s = Segment()
            addSubview(s)
            segments.append(s)
        }
        while lines.count < max(0, kids.count - 1) {
            let l = NSView()
            l.wantsLayer = true
            l.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.18).cgColor
            addSubview(l)
            lines.append(l)
        }
        for (i, s) in segments.enumerated() {
            s.isHidden = i >= kids.count
            guard i < kids.count else { continue }
            let t = kids[i]
            let isFocus = t === focused
            s.icon.image = FaviconStore.shared.image(for: t) ?? symbol("globe", size: 12)
            s.icon.contentTintColor = .secondaryLabelColor
            s.icon.alphaValue = t.page == nil ? 0.55 : 1
            s.label.stringValue = t.displayTitle
            s.label.font = .systemFont(ofSize: 12.5, weight: isFocus ? .semibold : .regular)
            s.label.textColor = isFocus || focused == nil ? .labelColor : .secondaryLabelColor
            s.toolTip = t.displayTitle
        }
        for (i, l) in lines.enumerated() { l.isHidden = i >= kids.count - 1 }
        toolTip = nil
        needsLayout = true
    }

    func setHovered(_ h: Bool) {
        hovered = h
        closeButton.isHidden = !h
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = split?.children.count ?? 0
        guard n > 0 else { return }
        let start = 18 + CGFloat(level) * 16
        let end = bounds.width - 16 - (hovered ? 22 : 0)
        let gap: CGFloat = 9
        let w = max(10, (end - start - gap * CGFloat(n - 1)) / CGFloat(n))
        for i in 0..<n {
            let x = start + CGFloat(i) * (w + gap)
            segments[i].frame = NSRect(x: x, y: 0, width: w, height: bounds.height)
            if i < n - 1 {
                lines[i].frame = NSRect(x: x + w + gap / 2 - 0.5, y: bounds.midY - 8, width: 1, height: 16)
            }
        }
        closeButton.frame = NSRect(x: bounds.width - 16 - 18, y: bounds.midY - 9, width: 18, height: 18)
    }

    /// The tab whose part of the row contains `point` (in this cell's coordinates).
    func member(at point: NSPoint) -> Item? {
        guard let kids = split?.children else { return nil }
        for (i, s) in segments.enumerated() where i < kids.count {
            // Each part owns half the gap on either side, so there is no dead space.
            if point.x < s.frame.maxX + 4.5 { return kids[i] }
        }
        return kids.last
    }
}
