import UIKit

// MARK: - App Icon Generator
//
// Generates the Steddi app icon: an S-shaped road in lavender on a dark background.
// The S reads as both the letter "S" and a winding road seen from above.
//
// To generate the icon PNG:
//   1. Build and run the app in DEBUG mode
//   2. Open Settings -> Developer -> "Generate App Icon"
//   3. The PNG is saved to the app's Documents directory
//   4. Retrieve it via Xcode's Device window or Files app
//   5. Copy icon_1024.png into Steddi/Assets.xcassets/AppIcon.appiconset/

enum IconGenerator {

    // MARK: - Design Constants

    private static let size: CGFloat = 1024

    private static let backgroundColor = UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1.0)
    private static var roadColor: UIColor { SteddiTheme.accentUIColor }
    private static let edgeLineColor = UIColor.white.withAlphaComponent(0.50)
    private static let centerLineColor = UIColor.white.withAlphaComponent(0.22)

    private static let roadWidth: CGFloat = 150
    private static let edgeLineWidth: CGFloat = 3.0
    private static let edgeInset: CGFloat = 10.0
    private static let centerLineWidth: CGFloat = 2.5
    private static let centerLineDash: [CGFloat] = [28, 22]

    // MARK: - Public

    /// Renders the 1024x1024 app icon.
    static func render() -> UIImage {
        let s = size
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: s, height: s))

        return renderer.image { ctx in
            let c = ctx.cgContext
            let road = buildSPath()

            // 1. Dark background
            backgroundColor.setFill()
            c.fill(CGRect(x: 0, y: 0, width: s, height: s))

            // 2. Outer edge line (slightly wider than road, white)
            strokePath(road, in: c, color: edgeLineColor, width: roadWidth + edgeLineWidth * 2)

            // 3. Road body (lavender, covers most of the white, leaving thin edges)
            strokePath(road, in: c, color: roadColor, width: roadWidth)

            // 4. Inner edge line (slightly narrower white stroke)
            strokePath(road, in: c, color: edgeLineColor, width: roadWidth - edgeInset * 2)

            // 5. Cover inner edge center (road color again, leaving thin inner edge)
            strokePath(road, in: c, color: roadColor, width: roadWidth - edgeInset * 2 - edgeLineWidth * 2)

            // 6. Center dashed line
            c.saveGState()
            c.setStrokeColor(centerLineColor.cgColor)
            c.setLineWidth(centerLineWidth)
            c.setLineCap(.round)
            c.setLineDash(phase: 0, lengths: centerLineDash)
            c.addPath(road)
            c.strokePath()
            c.restoreGState()
        }
    }

    // MARK: - S-Curve Path

    /// Builds a smooth S-curve bezier that flows from bottom to top.
    /// Designed to feel like a winding road seen from above.
    private static func buildSPath() -> CGPath {
        let path = CGMutablePath()

        let pad: CGFloat = 165
        let insetX: CGFloat = 55

        let startX = size / 2 - insetX
        let startY = size - pad
        let endX = size / 2 + insetX
        let endY = pad
        let midY = size / 2

        // How far the curves bow outward horizontally
        let spread: CGFloat = 310

        // Start at bottom
        path.move(to: CGPoint(x: startX, y: startY))

        // Bottom half of S: bows left then sweeps right to center
        path.addCurve(
            to: CGPoint(x: size / 2, y: midY),
            control1: CGPoint(x: startX - spread, y: startY - 180),
            control2: CGPoint(x: size / 2 + spread, y: midY + 180)
        )

        // Top half of S: bows right then sweeps left to top
        path.addCurve(
            to: CGPoint(x: endX, y: endY),
            control1: CGPoint(x: size / 2 - spread, y: midY - 180),
            control2: CGPoint(x: endX + spread, y: endY + 180)
        )

        return path
    }

    // MARK: - Helpers

    private static func strokePath(_ path: CGPath, in ctx: CGContext,
                                   color: UIColor, width: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Save to Disk

    #if DEBUG
    /// Generates the icon and writes it as a PNG to the app's Documents directory.
    /// Returns the file path on success, nil on failure.
    @discardableResult
    static func generateAndSave() -> URL? {
        let image = render()

        guard let data = image.pngData() else {
            print("[IconGenerator] Failed to create PNG data")
            return nil
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("icon_1024.png")

        do {
            try data.write(to: url, options: .atomic)
            print("[IconGenerator] Saved icon to: \(url.path)")
            return url
        } catch {
            print("[IconGenerator] Save failed: \(error)")
            return nil
        }
    }
    #endif
}
