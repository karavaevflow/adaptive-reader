import AppKit

// Original vector artwork: two reading pages and a quiet bookmark. No SF Symbols,
// external images or fonts are used. Rebuild with iconutil as documented below.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !FileManager.default.fileExists(atPath: destination.path) else { fatalError("Choose a new iconset directory") }
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let sizes = [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")]
for (size,name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:size, pixelsHigh:size, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let transform = AffineTransform(scale: CGFloat(size)/1024)
    (transform as NSAffineTransform).concat()
    let tile = NSBezierPath(roundedRect:NSRect(x:96,y:96,width:832,height:832),xRadius:180,yRadius:180)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 26; shadow.shadowOffset = NSSize(width:0,height:-14);shadow.set()
    NSColor(calibratedWhite:0.1,alpha:1).setFill();tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting:NSColor(srgbRed:0.10,green:0.11,blue:0.13,alpha:1),ending:NSColor(srgbRed:0.18,green:0.20,blue:0.23,alpha:1))!.draw(in:tile,angle:90)
    NSColor.white.withAlphaComponent(0.12).setStroke();tile.lineWidth=2;tile.stroke()
    func page(mirrored: Bool) -> NSBezierPath {
        let path=NSBezierPath()
        path.move(to:NSPoint(x:490,y:308))
        path.curve(to:NSPoint(x:274,y:352),controlPoint1:NSPoint(x:414,y:353),controlPoint2:NSPoint(x:348,y:375))
        path.line(to:NSPoint(x:274,y:674))
        path.curve(to:NSPoint(x:292,y:693),controlPoint1:NSPoint(x:274,y:689),controlPoint2:NSPoint(x:280,y:697))
        path.curve(to:NSPoint(x:490,y:647),controlPoint1:NSPoint(x:367,y:705),controlPoint2:NSPoint(x:421,y:686))
        path.close()
        if mirrored { var flip=AffineTransform();flip.translate(x:1024,y:0);flip.scale(x:-1,y:1);path.transform(using:flip) }
        return path
    }
    NSColor(srgbRed:0.96,green:0.97,blue:0.98,alpha:1).setFill();page(mirrored:false).fill()
    NSColor(srgbRed:0.84,green:0.88,blue:0.91,alpha:1).setFill();page(mirrored:true).fill()
    let bookmark=NSBezierPath();bookmark.move(to:NSPoint(x:646,y:691));bookmark.line(to:NSPoint(x:674,y:696));bookmark.line(to:NSPoint(x:674,y:572));bookmark.line(to:NSPoint(x:660,y:585));bookmark.line(to:NSPoint(x:646,y:572));bookmark.close()
    NSColor(srgbRed:0.43,green:0.78,blue:0.67,alpha:1).setFill();bookmark.fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent(name+".png"))
}
print(destination.path)
