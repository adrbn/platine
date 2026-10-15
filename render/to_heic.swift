// Packs render/room.py's output for the app: every PNG to HEIC (alpha kept), plus views.json.
//   swift render/to_heic.swift render/out/final Sources/Platine/Resources/Plates
import CoreImage

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: to_heic.swift <render dir> <Plates dir>") }
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let fm = FileManager.default
try fm.createDirectory(at: dst, withIntermediateDirectories: true)
let ctx = CIContext()
let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
for file in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
    guard let image = CIImage(contentsOf: file) else { fatalError("unreadable \(file.path)") }
    let out = dst.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".heic")
    try ctx.writeHEIFRepresentation(of: image, to: out, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    options: [quality: 0.85])
    print(out.lastPathComponent)
}
let views = dst.appendingPathComponent("views.json")
try? fm.removeItem(at: views)
try fm.copyItem(at: src.appendingPathComponent("views.json"), to: views)
