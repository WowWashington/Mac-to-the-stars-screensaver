import AppKit
import QuartzCore

struct HUDInfo {
    var sector: String
    var target: String
    var kind: SceneKind
    var progress: Double
    var remaining: Double
    var warpActive: Bool
    var speedText: String
    var speedNorm: Double       // 0..1 for the gauge
    var yaw: Double
    var pitch: Double
}

/// Starship cockpit overlay. Thin, edge-hugging, leaves the center clear.
/// Pure CALayers so the text stays crisp even when the 3D render is upscaled.
final class HUDController {
    let root = CALayer()

    private let cyan  = NSColor(calibratedRed: 0.45, green: 0.92, blue: 1.00, alpha: 1.0)
    private let amber = NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.28, alpha: 1.0)

    private var brackets: [CAShapeLayer] = []
    private var panels: [CALayer] = []
    private let titleL  = CATextLayer()
    private let sectorL = CATextLayer()
    private let metL    = CATextLayer()
    private let statusL = CATextLayer()
    private let velL    = CATextLayer()
    private let gaugeBG = CAShapeLayer()
    private let gaugeFG = CAShapeLayer()
    private let hdgL    = CATextLayer()
    private let tgtL    = CATextLayer()
    private var lastTextUpdate: Double = -10

    private var textLayers: [CATextLayer] {
        [titleL, sectorL, metL, statusL, velL, hdgL, tgtL]
    }

    init() {
        root.zPosition = 10
        root.isGeometryFlipped = true       // top-left origin math below
        for _ in 0..<4 {
            // translucent backing so telemetry stays readable over bright scenes
            let p = CALayer()
            p.backgroundColor = NSColor(calibratedWhite: 0.0, alpha: 0.30).cgColor
            panels.append(p)
            root.addSublayer(p)
        }
        for _ in 0..<4 {
            let s = CAShapeLayer()
            s.fillColor = nil
            brackets.append(s)
            root.addSublayer(s)
        }
        for l in textLayers {
            l.font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
            l.truncationMode = .end
            root.addSublayer(l)
        }
        for g in [gaugeBG, gaugeFG] {
            g.fillColor = nil
            g.lineCap = .round
            root.addSublayer(g)
        }
    }

    func layout(in bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        let s = max(0.5, min(bounds.width, bounds.height) / 900.0)
        let fs = 13.0 * s
        let small = 11.0 * s
        let m = 26.0 * s                    // edge margin
        let glow = cyan.withAlphaComponent(0.85).cgColor

        for l in textLayers {
            l.contentsScale = scale
            l.shadowColor = glow
            l.shadowOpacity = 0.65
            l.shadowRadius = 3.0 * s
            l.shadowOffset = .zero
        }

        func place(_ l: CATextLayer, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat,
                   align: CATextLayerAlignmentMode) {
            l.fontSize = size
            l.alignmentMode = align
            l.frame = CGRect(x: x, y: y, width: w, height: size * 1.4)
        }

        let colW = bounds.width * 0.42
        // top-left: ship + sector
        place(titleL,  x: m, y: m,            w: colW, size: fs,    align: .left)
        place(sectorL, x: m, y: m + fs * 1.6, w: colW, size: small, align: .left)
        // top-right: mission clock + status
        place(metL,    x: bounds.width - colW - m, y: m,            w: colW, size: fs,    align: .right)
        place(statusL, x: bounds.width - colW - m, y: m + fs * 1.6, w: colW, size: small, align: .right)
        // bottom-left: velocity + gauge
        place(velL, x: m, y: bounds.height - m - fs * 2.9, w: colW, size: fs, align: .left)
        let gy = bounds.height - m - fs * 0.9
        let gw = 200.0 * s
        let bar = CGMutablePath()
        bar.move(to: CGPoint(x: m, y: gy))
        bar.addLine(to: CGPoint(x: m + gw, y: gy))
        gaugeBG.path = bar
        gaugeBG.strokeColor = cyan.withAlphaComponent(0.22).cgColor
        gaugeBG.lineWidth = 4 * s
        gaugeFG.path = bar
        gaugeFG.lineWidth = 4 * s
        // bottom-right: heading + target
        place(hdgL, x: bounds.width - colW - m, y: bounds.height - m - fs * 2.9, w: colW, size: fs,    align: .right)
        place(tgtL, x: bounds.width - colW - m, y: bounds.height - m - fs * 1.45, w: colW, size: small, align: .right)

        // backing panels behind each text cluster
        let panelH = fs * 3.4
        let pad = 10.0 * s
        let panelW = colW * 0.62
        let panelFrames = [
            CGRect(x: m - pad, y: m - pad * 0.7, width: panelW, height: panelH),
            CGRect(x: bounds.width - m - panelW + pad, y: m - pad * 0.7, width: panelW, height: panelH),
            CGRect(x: m - pad, y: bounds.height - m - fs * 3.0 - pad * 0.3, width: panelW, height: panelH),
            CGRect(x: bounds.width - m - panelW + pad, y: bounds.height - m - fs * 3.0 - pad * 0.3,
                   width: panelW, height: panelH),
        ]
        for (i, p) in panels.enumerated() {
            p.frame = panelFrames[i]
            p.cornerRadius = 5 * s
            p.borderWidth = max(1, 1 * s)
            p.borderColor = cyan.withAlphaComponent(0.18).cgColor
        }

        // corner brackets
        let L = 30.0 * s
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: m * 0.45, y: m * 0.45), 1, 1),
            (CGPoint(x: bounds.width - m * 0.45, y: m * 0.45), -1, 1),
            (CGPoint(x: m * 0.45, y: bounds.height - m * 0.45), 1, -1),
            (CGPoint(x: bounds.width - m * 0.45, y: bounds.height - m * 0.45), -1, -1),
        ]
        for (i, (p, dx, dy)) in corners.enumerated() {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: p.x + L * dx, y: p.y))
            path.addLine(to: p)
            path.addLine(to: CGPoint(x: p.x, y: p.y + L * dy))
            brackets[i].path = path
            brackets[i].strokeColor = cyan.withAlphaComponent(0.45).cgColor
            brackets[i].lineWidth = 1.6 * s
            brackets[i].shadowColor = glow
            brackets[i].shadowOpacity = 0.5
            brackets[i].shadowRadius = 3.0 * s
            brackets[i].shadowOffset = .zero
        }
        CATransaction.commit()
    }

    func update(info: HUDInfo, time: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let accent = info.warpActive ? amber : cyan
        // warp status blinks; everything else steady
        statusL.opacity = info.warpActive ? (sin(time * 7.0) > 0 ? 1.0 : 0.35) : 1.0
        gaugeFG.strokeColor = accent.withAlphaComponent(0.8).cgColor
        gaugeFG.strokeEnd = CGFloat(max(0.02, min(1.0, info.speedNorm)))

        // text updates throttled to ~4 Hz
        guard time - lastTextUpdate > 0.24 else { return }
        lastTextUpdate = time

        let fg = cyan.withAlphaComponent(0.78).cgColor
        let fgA = accent.withAlphaComponent(0.9).cgColor
        for l in textLayers { l.foregroundColor = fg }
        statusL.foregroundColor = fgA
        velL.foregroundColor = fgA

        let met = Int(time)
        let kindLabel: String
        switch info.kind {
        case .cruise:    kindLabel = "CRUISE"
        case .galaxy:    kindLabel = "GALACTIC APPROACH"
        case .planet:    kindLabel = "SYSTEM TRANSIT"
        case .warp:      kindLabel = "WARP ACTIVE"
        case .encounter: kindLabel = "ENCOUNTER"
        case .deepfield: kindLabel = "DEEP FIELD OBS"
        }

        titleL.string  = "GSV ODYSSEY · NAV"
        sectorL.string = (info.warpActive ? "DEST  " : "SECTOR  ") + info.sector
        metL.string    = String(format: "MET %02d:%02d:%02d", met / 3600, (met / 60) % 60, met % 60)
        statusL.string = kindLabel
        velL.string    = "VEL  " + info.speedText
        hdgL.string    = String(format: "HDG %05.1f°  PCH %+05.1f°", info.yaw, info.pitch)
        let rem = max(0, Int(info.remaining))
        tgtL.string    = "TGT  \(info.target)  T-\(String(format: "%02d:%02d", rem / 60, rem % 60))"
    }
}
