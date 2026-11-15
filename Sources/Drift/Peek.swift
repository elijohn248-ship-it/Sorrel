import AppKit
import WebKit

/// A preview that floats over the current page when a pinned tab's link leads to another site.
/// Close it, or expand it into a full tab.
final class PeekOverlay: NSView {
    let page: Page
    var onClose: (() -> Void)?
    var onExpand: (() -> Void)?
    var onSplit: (() -> Void)?

    private let shadowHost = NSView()
    private let panel = NSView()
    private let gutter: CGFloat = 54

    init(page: Page, cornerRadius: CGFloat) {
        self.page = page
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor

        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.45
        shadowHost.layer?.shadowRadius = 26
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -8)

        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        panel.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let close = roundButton("xmark", tooltip: "Close preview (Esc)") { [weak self] in self?.onClose?() }
        let expandKey = Keybindings.shared.display(for: "mini.expand")
        let expand = roundButton("arrow.up.left.and.arrow.down.right",
                                 tooltip: "Open as a full tab" + (expandKey.map { " (\($0))" } ?? "")) { [weak self] in
            self?.onExpand?()
        }

        let splitKey = Keybindings.shared.display(for: "split.peek")
        let split = roundButton("rectangle.split.2x1",
                                tooltip: "Open beside this tab (split view)" + (splitKey.map { " (\($0))" } ?? "")) { [weak self] in
            self?.onSplit?()
        }

        for v in [shadowHost, panel, close, expand, split] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let wv = page.webView
        wv.frame = panel.bounds
        wv.autoresizingMask = [.width, .height]
        panel.addSubview(wv)

        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),

            shadowHost.topAnchor.constraint(equalTo: panel.topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            shadowHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            // Top right, beside the preview.
            close.leadingAnchor.constraint(equalTo: panel.trailingAnchor, constant: 12),
            close.topAnchor.constraint(equalTo: panel.topAnchor, constant: 2),
            expand.leadingAnchor.constraint(equalTo: close.leadingAnchor),
            expand.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: close.leadingAnchor),
            split.topAnchor.constraint(equalTo: expand.bottomAnchor, constant: 8),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func roundButton(_ name: String, tooltip: String, handler: @escaping () -> Void) -> IconButton {
        let b = IconButton(symbol: name, size: 12, tooltip: tooltip, handler: handler)
        b.contentTintColor = .white
        b.wantsLayer = true
        b.layer?.cornerRadius = 15
        b.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    override func layout() {
        super.layout()
        shadowHost.layer?.shadowPath = CGPath(roundedRect: shadowHost.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    /// Clicking the dimmed page around the preview closes it.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { onClose?() }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

enum Site {
    /// A rough "same website" key: the registrable part of a host (example.com, bbc.co.uk).
    static func key(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let take = (labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Whether a host is on a list of sites. "google" matches google.com, google.co.uk, scholar.google.com;
    /// "kagi.com" matches kagi.com and its subdomains.
    static func host(_ host: String?, isIn list: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let brand = key(host)?.split(separator: ".").first.map(String.init)
        for raw in list {
            let entry = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            if entry.contains(".") {
                if host == entry || host.hasSuffix("." + entry) { return true }
            } else if brand == entry {
                return true
            }
        }
        return false
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let ka = key(a), let kb = key(b) else { return false }
        return ka == kb
    }
}
