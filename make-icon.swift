import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let artworkURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let artwork = NSImage(contentsOf: artworkURL) else {
    fatalError("Cannot load bird artwork")
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.90, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904),
                     xRadius: 205, yRadius: 205).fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        artwork.draw(in: NSRect(x: 132, y: 132, width: 760, height: 760))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot render app icon")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
