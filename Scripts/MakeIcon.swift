import AppKit
import CoreText
import Foundation

// Original vector composition: pure #777 block + native calligraphic glyph outlines.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let font = CTFontCreateWithName("STKaitiSC-Bold" as CFString, 340, nil)
var combined = CGMutablePath()
for (position, text) in ["磁", "盘"].enumerated() {
    let characters = Array(text.utf16)
    var glyph: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(font, characters, &glyph, 1), let path = CTFontCreatePathForGlyph(font, glyph, nil) else { fatalError("书法字形不可用") }
    let shift = CGAffineTransform(translationX: 0, y: CGFloat(1 - position) * 325)
    combined.addPath(path, transform: shift)
}
let bounds = combined.boundingBoxOfPath
let targetHeight: CGFloat = 596
let scale = targetHeight / bounds.height
let width = bounds.width * scale
var placement = CGAffineTransform(translationX: 512 - width/2, y: 512 - targetHeight/2)
placement = placement.scaledBy(x: scale, y: scale).translatedBy(x: -bounds.minX, y: -bounds.minY)
let placed = combined.copy(using: &placement)!
func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:pixels*4,bitsPerPixel:32)!
    bitmap.size = NSSize(width:pixels,height:pixels)
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    context.setFillColor(NSColor(srgbRed:119/255,green:119/255,blue:119/255,alpha:1).cgColor)
    context.addPath(CGPath(roundedRect:CGRect(x:82,y:82,width:860,height:860),cornerWidth:189,cornerHeight:189,transform:nil)); context.fillPath()
    context.setFillColor(NSColor.white.cgColor); context.addPath(placed); context.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
try render(1024).write(to:root.appendingPathComponent("AppIcon.png"),options:.atomic)
func length(_ n:Int)->Data { var v=UInt32(n).bigEndian; return withUnsafeBytes(of:&v){Data($0)} }
var body = Data()
for (key, pixels) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024),("ic11",32),("ic12",64),("ic13",256),("ic14",512)] {
    let data = render(pixels); body.append(Data(key.utf8));body.append(length(data.count+8));body.append(data)
}
var icon=Data("icns".utf8);icon.append(length(body.count+8));icon.append(body)
try icon.write(to:root.appendingPathComponent("AppIcon.icns"),options:.atomic)
// The editable source of the lettermark is the CoreText glyph/path composition above.
print("Original icon: gray #777777, glyph bounds \(Int(width))×596, STKaitiSC-Bold")
