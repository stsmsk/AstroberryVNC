// Copyright (C) 2026 Satoshi Masuko
// SPDX-License-Identifier: GPL-2.0-or-later
// Build 31.9.4 — production Core Animation status-item overlay.
// Adopted from the separately verified Build 31.9.3 experiment.
// Only central status layer rotates. No status bar image redraw or timer.

import AppKit
import QuartzCore

@MainActor
final class AnimatedStatusIconOverlay: NSView {
    private let designSize = CGSize(width: 30, height: 22)
    private let artwork = CALayer()
    private var fixedMarks: [(layer: CAShapeLayer, filled: Bool)] = []
    private var movingMark: CALayer?
    private var status: ConnectionStatus = .disconnected
    private var hasSetStatus = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        artwork.bounds = CGRect(origin: .zero, size: designSize)
        artwork.masksToBounds = false
        layer?.addSublayer(artwork)
        createFixedMarks()
        setStatus(.disconnected)
    }

    required init?(coder: NSCoder) {
        fatalError("StatusIconOverlay is code-only")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.frame = CGRect(
            x: (bounds.width - designSize.width) / 2,
            y: (bounds.height - designSize.height) / 2,
            width: designSize.width, height: designSize.height
        )
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    // Convert the production 30×22 top-left SVG coordinates to Core Graphics.
    private func point(_ x: CGFloat, _ top: CGFloat) -> CGPoint {
        CGPoint(x: x, y: designSize.height - top)
    }

    private func polygon(_ coordinates: [(CGFloat, CGFloat)]) -> CGPath {
        let p = CGMutablePath()
        guard let first = coordinates.first else { return p }
        p.move(to: point(first.0, first.1))
        for (x, y) in coordinates.dropFirst() { p.addLine(to: point(x, y)) }
        p.closeSubpath()
        return p
    }

    private func addMark(_ path: CGPath, filled: Bool, width: CGFloat = 1.20) {
        let mark = CAShapeLayer()
        mark.path = path
        mark.lineWidth = width
        mark.lineCap = .round
        mark.lineJoin = .round
        artwork.addSublayer(mark)
        fixedMarks.append((mark, filled))
    }

    private func createFixedMarks() {
        let outer = CGRect(x: 1.15, y: 22 - 17.2, width: 27.7, height: 16.1)
        addMark(CGPath(roundedRect: outer, cornerWidth: 2.5,
                       cornerHeight: 2.5, transform: nil), filled: false)

        let stand = CGMutablePath()
        stand.move(to: point(15, 17.25)); stand.addLine(to: point(15, 19.7))
        stand.move(to: point(9.8, 20.55)); stand.addLine(to: point(20.2, 20.55))
        addMark(stand, filled: false)

        let tube = polygon([(4, 12.5), (10.35, 9.2), (11.65, 11.2), (5.1, 14.5)])
        addMark(tube, filled: true)
        let telescope = CGMutablePath()
        telescope.move(to: point(3, 14)); telescope.addLine(to: point(4.5, 13.2))
        telescope.move(to: point(7.15, 13.35)); telescope.addLine(to: point(7.15, 14.25))
        telescope.move(to: point(7.15, 14.25)); telescope.addLine(to: point(5.35, 16.2))
        telescope.move(to: point(7.15, 14.25)); telescope.addLine(to: point(9, 16.2))
        addMark(telescope, filled: false, width: 1.05)

        let star = CGMutablePath()
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 - .pi / 2
            let radius: CGFloat = i.isMultiple(of: 2) ? 2.15 : 2.15 * 0.23
            let p = point(24.2 + CGFloat(cos(angle)) * radius,
                          4.75 + CGFloat(sin(angle)) * radius)
            if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
        }
        star.closeSubpath()
        addMark(star, filled: true)
    }

    private func color() -> NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch status {
        case .disconnected:
            return dark ? NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.94, alpha: 1)
                        : NSColor(calibratedRed: 0.19, green: 0.24, blue: 0.31, alpha: 1)
        case .connecting, .disconnecting:
            return dark ? NSColor(calibratedRed: 0.37, green: 0.70, blue: 1.0, alpha: 1)
                        : NSColor(calibratedRed: 0.0, green: 0.40, blue: 0.82, alpha: 1)
        case .connected:
            return dark ? NSColor(calibratedRed: 0.29, green: 0.85, blue: 0.49, alpha: 1)
                        : NSColor(calibratedRed: 0.0, green: 0.55, blue: 0.19, alpha: 1)
        case .error:
            return dark ? NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.48, alpha: 1)
                        : NSColor(calibratedRed: 0.87, green: 0.10, blue: 0.19, alpha: 1)
        }
    }

    private func refreshColors() {
        let tint = color().cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (shape, filled) in fixedMarks {
            shape.strokeColor = filled ? nil : tint
            shape.fillColor = filled ? tint : nil
        }
        // The active symbol can be a group containing multiple shapes.
        updateTint(in: movingMark, color: tint)
        CATransaction.commit()
    }

    private func updateTint(in parent: CALayer?, color: CGColor) {
        guard let parent else { return }
        if let shape = parent as? CAShapeLayer {
            if shape.fillColor != nil { shape.fillColor = color }
            if shape.strokeColor != nil { shape.strokeColor = color }
        }
        for sub in parent.sublayers ?? [] { updateTint(in: sub, color: color) }
    }

    func setStatus(_ newStatus: ConnectionStatus) {
        guard !hasSetStatus || status != newStatus else { return }
        hasSetStatus = true
        status = newStatus
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movingMark?.removeAllAnimations()
        movingMark?.removeFromSuperlayer()
        movingMark = buildCenterMark(for: newStatus)
        if let movingMark { artwork.addSublayer(movingMark) }
        refreshColors()
        CATransaction.commit()
        updateRotationAnimation()
    }

    func refreshReduceMotion() { updateRotationAnimation() }

    private func updateRotationAnimation() {
        movingMark?.removeAnimation(forKey: "statusRotation")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let duration = AnimatedStatusItemPolicy.rotationDuration(for: status, reduceMotion: false),
              let movingMark else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = duration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        movingMark.add(spin, forKey: "statusRotation")
    }

    private func shape(_ path: CGPath, strokeWidth: CGFloat = 0,
                       filled: Bool = false) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = path
        s.lineWidth = strokeWidth
        s.lineCap = .round
        s.lineJoin = .round
        if filled { s.fillColor = NSColor.white.cgColor }
        else { s.fillColor = nil; s.strokeColor = NSColor.white.cgColor }
        return s
    }

    private func buildCenterMark(for state: ConnectionStatus) -> CALayer? {
        switch state {
        case .disconnected:
            return nil
        case .connected:
            let p = CGMutablePath()
            p.move(to: point(14, 9.5)); p.addLine(to: point(16.8, 12.3))
            p.addLine(to: point(22.1, 7))
            return shape(p, strokeWidth: 2.45)
        case .error:
            let group = CALayer()
            let p = CGMutablePath()
            p.move(to: point(18, 5.8)); p.addLine(to: point(18, 10.65))
            group.addSublayer(shape(p, strokeWidth: 2.5))
            group.addSublayer(shape(CGPath(ellipseIn: CGRect(x: 16.85, y: 22-14.3,
                                                          width: 2.3, height: 2.3), transform: nil),
                                    filled: true))
            return group
        case .connecting, .disconnecting:
            let group = CALayer()
            group.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
            group.position = point(17.6, 9.55)
            if state == .connecting {
                for i in 0..<8 {
                    let angle = Double(i) * .pi / 4 - .pi / 2
                    let x = 6 + 4 * CGFloat(cos(angle))
                    let y = 6 + 4 * CGFloat(sin(angle))
                    let p = CGPath(ellipseIn: CGRect(x: x - 0.85, y: y - 0.85,
                                                      width: 1.7, height: 1.7), transform: nil)
                    let dot = shape(p, filled: true)
                    dot.opacity = Float(1.0 - Double(i) * 0.105)
                    group.addSublayer(dot)
                }
            } else {
                let p = CGMutablePath()
                p.addArc(center: CGPoint(x: 6, y: 6), radius: 4.15,
                         startAngle: -.pi / 2, endAngle: -.pi / 2 + 250 * .pi / 180,
                         clockwise: false)
                group.addSublayer(shape(p, strokeWidth: 1.85))
            }
            return group
        }
    }
}

