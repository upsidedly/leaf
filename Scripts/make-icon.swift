import AppKit
import Foundation

@main enum LeafIconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else { throw CocoaError(.fileNoSuchFile) }
        let folder = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let iconset = folder.appendingPathComponent("AppIcon.iconset",isDirectory:true)
        try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
        for size in [16,32,128,256,512] {
            for scale in [1,2] {
                let pixels = size * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let context = NSGraphicsContext(bitmapImageRep:bitmap) else { throw CocoaError(.fileWriteUnknown) }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                let transform = NSAffineTransform(); transform.scale(by:CGFloat(pixels)/1024); transform.concat()
                NSColor(calibratedWhite:0.94,alpha:1).setFill()
                NSBezierPath(roundedRect:NSRect(x:60,y:60,width:904,height:904),xRadius:205,yRadius:205).fill()
                NSColor(calibratedWhite:0.16,alpha:1).setStroke()
                let leaf = NSBezierPath(); leaf.lineWidth = 43; leaf.lineCapStyle = .round; leaf.lineJoinStyle = .round
                leaf.move(to:NSPoint(x:294,y:283))
                leaf.curve(to:NSPoint(x:754,y:752),controlPoint1:NSPoint(x:224,y:594),controlPoint2:NSPoint(x:433,y:800))
                leaf.curve(to:NSPoint(x:294,y:283),controlPoint1:NSPoint(x:822,y:441),controlPoint2:NSPoint(x:610,y:223))
                leaf.close(); leaf.stroke()
                let stem = NSBezierPath(); stem.lineWidth = 39; stem.lineCapStyle = .round
                stem.move(to:NSPoint(x:250,y:240)); stem.line(to:NSPoint(x:638,y:630)); stem.stroke()
                let veins = NSBezierPath(); veins.lineWidth = 30; veins.lineCapStyle = .round
                veins.move(to:NSPoint(x:408,y:401)); veins.line(to:NSPoint(x:400,y:552))
                veins.move(to:NSPoint(x:500,y:493)); veins.line(to:NSPoint(x:644,y:492))
                veins.stroke()
                NSGraphicsContext.restoreGraphicsState()
                guard let data = bitmap.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to:iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
                if pixels == 512 { try data.write(to:folder.appendingPathComponent("leaf-icon.png")) }
            }
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/iconutil")
        process.arguments = ["-c","icns",iconset.path,"-o",folder.appendingPathComponent("AppIcon.icns").path]
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }
}
