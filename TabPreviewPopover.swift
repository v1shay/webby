import AppKit

/// A lightweight preview of an existing tab. It never creates or loads a web view.
@MainActor final class TabPreviewPopover {
    private let popover = NSPopover()
    private let thumbnail = NSView()
    private let placeholder = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private(set) var tabID: UUID?

    init() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.translatesAutoresizingMaskIntoConstraints = false

        // A raw NSImageView advertises the full website snapshot as its intrinsic
        // width, which makes NSPopover expand to desktop-window size. A layer-backed
        // view has no image-derived intrinsic size and scales within fixed bounds.
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 7
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.contentsGravity = .resizeAspect
        thumbnail.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        placeholder.textColor = .secondaryLabelColor
        placeholder.lineBreakMode = .byTruncatingTail

        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        address.translatesAutoresizingMaskIntoConstraints = false
        address.font = .systemFont(ofSize: 11)
        address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingMiddle

        root.addSubview(thumbnail)
        root.addSubview(placeholder)
        root.addSubview(title)
        root.addSubview(address)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 340),
            root.heightAnchor.constraint(equalToConstant: 240),
            thumbnail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            thumbnail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            thumbnail.heightAnchor.constraint(equalToConstant: 175),
            placeholder.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -16),
            placeholder.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor, constant: 3),
            title.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -3),
            title.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 10),
            address.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            address.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            address.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3)
        ])

        let controller = NSViewController()
        controller.view = root
        popover.contentSize = root.frame.size
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
    }

    func show(tabID: UUID, title: String, address: String, image: NSImage?, from row: NSView) {
        hide()
        self.tabID = tabID
        self.title.stringValue = title
        self.address.stringValue = address
        setThumbnail(image)
        placeholder.stringValue = title
        placeholder.isHidden = image != nil
        popover.show(relativeTo: row.bounds, of: row, preferredEdge: .maxX)
        popover.contentViewController?.view.window?.isOpaque = false
        popover.contentViewController?.view.window?.backgroundColor = .clear
    }

    func updateImage(_ image: NSImage, for id: UUID) {
        guard tabID == id else { return }
        setThumbnail(image)
        placeholder.isHidden = true
    }

    private func setThumbnail(_ image: NSImage?) {
        thumbnail.layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func hide(for id: UUID? = nil) {
        guard id == nil || id == tabID else { return }
        popover.close()
        tabID = nil
    }
}
