import AppKit

enum ProviderIconRenderer {

    /// Returns an icon from Base64-encoded image data (SVG or raster), tinted with `color`.
    /// iconName is kept in the model for JSON compat but no built-in logos are bundled.
    static func image(iconData: String?, iconName: String?, size: CGFloat, color: NSColor) -> NSImage? {
        guard let b64 = iconData else { return nil }
        return image(fromBase64: b64, size: size, color: color)
    }

    /// Decodes a Base64-encoded image (SVG or raster) and returns it tinted.
    static func image(fromBase64 base64: String, size: CGFloat, color: NSColor) -> NSImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let base = NSImage(data: data) else { return nil }
        let targetSize = NSSize(width: size, height: size)
        base.size = targetSize
        return tinted(base, to: targetSize, with: color)
    }

    // Renders `image` as a shape mask filled with `color` using destinationIn compositing.
    private static func tinted(_ image: NSImage, to size: NSSize, with color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { bounds in
            color.setFill()
            bounds.fill()
            image.draw(in: bounds, from: NSRect(origin: .zero, size: size), operation: .destinationIn, fraction: 1.0)
            return true
        }
    }
}
