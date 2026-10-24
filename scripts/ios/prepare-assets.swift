import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Preserve the existing icon artwork while generating the opaque PNG required by iOS.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("src-tauri/icons/ios/AppIcon-512@2x.png")
let destination = root.appendingPathComponent("ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Unable to decode the existing application icon") }
context.setFillColor(CGColor(red: 23.0 / 255, green: 26.0 / 255, blue: 32.0 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let opaque = context.makeImage(),
      let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Unable to generate the iOS application icon") }
CGImageDestinationAddImage(output, opaque, nil)
guard CGImageDestinationFinalize(output) else { fatalError("Unable to write the iOS application icon") }
