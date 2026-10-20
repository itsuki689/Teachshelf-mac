import AppKit
import QuartzCore
import SwiftUI

/// Purely decorative layers; they never become hit-test targets above the table.
final class MaterialFolderGuideController {
    private let container = CALayer()
    private var layers: [UUID: CALayer] = [:]
    private var guides: [MaterialFolderGuide] = []
    private var reduceMotion = false
    var frames: [UUID: CGRect] { layers.mapValues(\.frame) }
    func layer(for id: UUID) -> CALayer? { layers[id] }

    func update(in table: NSTableView, guides: [MaterialFolderGuide], reduceMotion: Bool) {
        self.reduceMotion = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.guides = guides
        let ids = Set(guides.map(\.id))
        for id in Array(layers.keys) where !ids.contains(id) {
            guard let layer = layers.removeValue(forKey: id) else { continue }
            if self.reduceMotion { layer.removeFromSuperlayer() }
            else {
                animate(layer, height: 0, opacity: 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { layer.removeFromSuperlayer() }
            }
        }
        layout(in: table, animated: true)
    }

    func layout(in table: NSTableView, animated: Bool = false) {
        table.wantsLayer = true
        if container.superlayer !== table.layer {
            container.zPosition = 1000
            table.layer?.addSublayer(container)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = table.bounds
        for guide in guides {
            guard guide.firstChild >= 0, guide.lastChild < table.numberOfRows else { continue }
            let first = table.rect(ofRow: guide.firstChild), last = table.rect(ofRow: guide.lastChild)
            let frame = CGRect(x: MaterialBrowserLayout.borderInset(depth: guide.depth + 1) - 8,
                               y: first.minY + 4, width: 6, height: max(0, last.maxY - first.minY - 8))
            let fresh = layers[guide.id] == nil
            let layer = layers[guide.id] ?? CALayer()
            let previousHeight = layer.presentation()?.bounds.height ?? layer.bounds.height
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer.cornerRadius = 3
            layer.backgroundColor = NSColor(Color(hex: guide.colorHex)).cgColor
            layer.frame = frame
            layer.opacity = 1
            if fresh { container.addSublayer(layer); layers[guide.id] = layer }
            if !reduceMotion, animated, fresh || abs(previousHeight - frame.height) > 0.5 {
                let growth = CABasicAnimation(keyPath: "bounds.size.height")
                growth.fromValue = fresh ? 0 : previousHeight; growth.toValue = frame.height
                growth.duration = 0.22; growth.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(growth, forKey: "folderExpansion")
            } else if reduceMotion { layer.removeAllAnimations() }
        }
        CATransaction.commit()
    }

    func removeAll() {
        layers.removeAll(); guides = []; container.removeAllAnimations(); container.sublayers = nil; container.removeFromSuperlayer()
    }
    private func animate(_ layer: CALayer, height: CGFloat, opacity: Float) {
        let oldHeight = layer.presentation()?.bounds.height ?? layer.bounds.height
        let oldOpacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.bounds.size.height = height; layer.opacity = opacity
        CATransaction.commit()
        let shrink = CABasicAnimation(keyPath: "bounds.size.height")
        shrink.fromValue = oldHeight; shrink.toValue = height
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = oldOpacity; fade.toValue = opacity
        let group = CAAnimationGroup(); group.animations = [shrink, fade]; group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(group, forKey: "folderCollapse")
    }
}
