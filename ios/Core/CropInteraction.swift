import Foundation

extension PhotoCrop {
    func normalized(width: Double, height: Double) -> Self {
        let bounds = rect(width: width, height: height)
        var result = self
        result.centerX = (bounds.x + bounds.width / 2) / width
        result.centerY = (bounds.y + bounds.height / 2) / height
        result.zoom = min(5, max(1, zoom))
        return result
    }
    func zoomed(to value: Double, width: Double, height: Double, anchorX: Double = 0.5, anchorY: Double = 0.5) -> Self {
        let old = rect(width: width, height: height)
        var result = self; result.zoom = min(5, max(1, value))
        let size = result.rect(width: width, height: height)
        let x = old.x + old.width * anchorX - size.width * anchorX
        let y = old.y + old.height * anchorY - size.height * anchorY
        result.centerX = (min(max(0, x), width - size.width) + size.width / 2) / width
        result.centerY = (min(max(0, y), height - size.height) + size.height / 2) / height
        return result
    }
    func dragged(x: Double, y: Double, viewportWidth: Double, width: Double, height: Double) -> Self {
        let bounds = rect(width: width, height: height), scale = max(1, viewportWidth) / bounds.width
        var result = self
        result.centerX = (min(max(0, bounds.x - x / scale), width - bounds.width) + bounds.width / 2) / width
        result.centerY = (min(max(0, bounds.y - y / scale), height - bounds.height) + bounds.height / 2) / height
        return result
    }
}
