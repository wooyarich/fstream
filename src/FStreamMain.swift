import Cocoa
import Network
import AudioToolbox
import AVFoundation

// MARK: - NSBezierPath RoundedRect Compatibility (Matches FStream 0x1000023b0)
extension NSBezierPath {
    static func fsRoundedRect(_ aRect: NSRect, cornerRadius radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.fsAppendRoundedRect(aRect, cornerRadius: radius)
        return path
    }

    func fsAppendRoundedRect(_ aRect: NSRect, cornerRadius radius: CGFloat) {
        if NSIsEmptyRect(aRect) { return }
        if radius > 0.0 {
            let clampedRadius = min(radius, min(aRect.size.width, aRect.size.height) * 0.5)
            let topLeft = NSMakePoint(NSMinX(aRect), NSMaxY(aRect))
            let topRight = NSMakePoint(NSMaxX(aRect), NSMaxY(aRect))
            let bottomRight = NSMakePoint(NSMaxX(aRect), NSMinY(aRect))

            self.move(to: NSMakePoint(NSMidX(aRect), NSMaxY(aRect)))
            self.appendArc(from: topLeft, to: aRect.origin, radius: clampedRadius)
            self.appendArc(from: aRect.origin, to: bottomRight, radius: clampedRadius)
            self.appendArc(from: bottomRight, to: topRight, radius: clampedRadius)
            self.appendArc(from: topRight, to: topLeft, radius: clampedRadius)
            self.close()
        } else {
            self.appendRect(aRect)
        }
    }
}

// MARK: - NSBitmapImageRep Helper (Matches FStream makeImageWidth:height:)
extension NSBitmapImageRep {
    static func fsMakeImage(width: Int, height: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSMakeSize(CGFloat(width), CGFloat(height))
        return rep
    }
}

// MARK: - CTGradient (Matches FStream 0x100013f30 & 0x100016230)
final class CTGradient {
    let beginR: CGFloat, beginG: CGFloat, beginB: CGFloat, beginA: CGFloat
    let endR: CGFloat, endG: CGFloat, endB: CGFloat, endA: CGFloat

    init(beginningColor: NSColor, endingColor: NSColor) {
        let c1 = beginningColor.usingColorSpace(.genericRGB) ?? beginningColor
        let c2 = endingColor.usingColorSpace(.genericRGB) ?? endingColor
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        self.beginR = r1; self.beginG = g1; self.beginB = b1; self.beginA = a1
        self.endR = r2; self.endG = g2; self.endB = b2; self.endA = a2
    }

    func fillRect(_ rect: NSRect, angle: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        let colorSpace = CGColorSpace(name: "kCGColorSpaceGenericRGB" as CFString) ?? CGColorSpaceCreateDeviceRGB()
        let comps: [CGFloat] = [
            beginR, beginG, beginB, beginA,
            endR, endG, endB, endA
        ]
        let locs: [CGFloat] = [0.0, 1.0]
        if let grad = CGGradient(colorSpace: colorSpace, colorComponents: comps, locations: locs, count: 2) {
            let startPt = CGPoint(x: rect.minX, y: rect.minY)
            let endPt = CGPoint(x: rect.minX, y: rect.maxY)
            ctx.drawLinearGradient(grad, start: startPt, end: endPt, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
}

// MARK: - MyPlugin (Loads exact original FStream MyPlugin assets + dynamic wave animation)
final class MyPlugin {
    // Extra padding offset (+5, +6) inside 300x72 window so NSShadow (offset -7, blur 10) never clips at window bounds
    static let padX: CGFloat = 5.0
    static let padY: CGFloat = 6.0

    var style: Int // 0 = Yellow ("FStreamDefaultYellow"), 1 = Blue ("FStreamDefaultBlue")
    var isRecording: Bool = false
    var hidePercent: Bool = true
    var doSwitchPercent: Bool = false
    var p100: Int = 0
    var loadX: Int = 0
    var loadPath: NSBezierPath
    var standardImages: [Int: NSImage] = [:]
    var recordImages: [Int: NSImage] = [:]
    private var hideTimer: Timer?

    init(style: Int) {
        self.style = style
        self.loadPath = NSBezierPath()
        var angle: Float = 0.0
        self.loadPath.move(to: NSMakePoint(0.0, 8.5 + 2.5 * sin(Double(angle))))
        for i in 1..<36 {
            angle += 0.718078
            let y = 8.5 + 2.5 * sin(Double(angle))
            self.loadPath.line(to: NSMakePoint(Double(i), y))
        }
        buildImages()
    }

    var name: String {
        return style == 0 ? "FStream > Yellow" : "FStream > Blue"
    }

    var identifiant: String {
        return style == 0 ? "FStreamDefaultYellow" : "FStreamDefaultBlue"
    }

    private func loadBundledAsset(style: Int, rec: Int, id: Int) -> NSImage? {
        let fileName = "style\(style)_rec\(rec)_id\(id).png"
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let relResPath = execDir.appendingPathComponent("../Resources/SkinAssets/\(fileName)").standardized.path
        let candidates: [String] = [
            Bundle.main.resourcePath.map { "\($0)/SkinAssets/\(fileName)" } ?? "",
            relResPath
        ]
        for path in candidates where !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            if let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }

    private func buildImages() {
        standardImages.removeAll()
        recordImages.removeAll()

        // First try loading exact bit-for-bit assets extracted from original FStream MyPlugin
        var loadedCount = 0
        for idx in 0...25 {
            if let sImg = loadBundledAsset(style: style, rec: 0, id: idx) {
                standardImages[idx] = sImg
                loadedCount += 1
            }
            if let rImg = loadBundledAsset(style: style, rec: 1, id: idx) {
                recordImages[idx] = rImg
            }
        }
        if loadedCount == 26 && recordImages.count == 26 {
            return
        }

        // Procedural fallback if SkinAssets folder is missing
        let pillRect = NSMakeRect(1.0, 1.0, 258.0, 28.0)
        let pillPath = NSBezierPath.fsRoundedRect(pillRect, cornerRadius: 30.0)

        if let rep = NSBitmapImageRep.fsMakeImage(width: 260, height: 30) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.saveGraphicsState()
            pillPath.setClip()

            let cBegin = (style == 1)
                ? NSColor(deviceRed: 14.0/255.0, green: 62.0/255.0, blue: 205.0/255.0, alpha: 1.0)
                : NSColor(deviceRed: 0.8, green: 0.8156862745, blue: 0.6784313725, alpha: 1.0)
            let cEnd = (style == 1)
                ? NSColor(deviceRed: 51.0/255.0, green: 131.0/255.0, blue: 230.0/255.0, alpha: 1.0)
                : NSColor(deviceRed: 0.9960784314, green: 1.0, blue: 0.8745098039, alpha: 1.0)
            CTGradient(beginningColor: cBegin, endingColor: cEnd).fillRect(NSMakeRect(0, 0, 260, 30), angle: 90.0)
            NSGraphicsContext.restoreGraphicsState()

            let borderColor = (style == 1)
                ? NSColor(deviceRed: 31.0/255.0, green: 96.0/255.0, blue: 218.0/255.0, alpha: 1.0)
                : NSColor(deviceRed: 0.6784313725, green: 0.6784313725, blue: 0.6784313725, alpha: 1.0)
            borderColor.set()
            pillPath.lineWidth = 2.0
            pillPath.stroke()
            NSGraphicsContext.restoreGraphicsState()

            let img = NSImage(size: rep.size)
            img.addRepresentation(rep)
            standardImages[25] = img
            recordImages[25] = img
            standardImages[24] = img
            recordImages[24] = img
        }

        // In original FStream (0x10000f49c..0x10000f6b4):
        // ID 18, 19, 20 = makeButtonPopup (top dome at ID 2 (255, 36))
        // ID 21, 22, 23 = makeButtonVolume (bottom bowl at ID 3 (255, 28))
        let pop0 = makeButtonPopup(0)
        let pop1 = makeButtonPopup(1)
        let pop2 = makeButtonPopup(2)
        standardImages[18] = pop0; standardImages[20] = pop1; standardImages[19] = pop2
        recordImages[18] = pop0; recordImages[20] = pop1; recordImages[19] = pop2

        let vol0 = makeButtonVolume(0)
        let vol1 = makeButtonVolume(1)
        let vol2 = makeButtonVolume(2)
        standardImages[21] = vol0; standardImages[23] = vol1; standardImages[22] = vol2
        recordImages[21] = vol0; recordImages[23] = vol1; recordImages[22] = vol2

        for isRec in [false, true] {
            let base = isRec ? 3 : 0
            var dict = isRec ? recordImages : standardImages
            dict[2] = makeButton(base + 0, kind: 0)
            dict[0] = makeButton(base + 1, kind: 0)
            dict[1] = makeButton(base + 2, kind: 0)
            dict[5] = makeButton(base + 0, kind: 2)
            dict[3] = makeButton(base + 1, kind: 2)
            dict[4] = makeButton(base + 2, kind: 2)
            dict[15] = makeButton(base + 0, kind: 4)
            dict[17] = makeButton(base + 1, kind: 4)
            dict[16] = makeButton(base + 2, kind: 4)
            dict[14] = makeButton(base + 0, kind: 5)
            dict[12] = makeButton(base + 1, kind: 5)
            dict[13] = makeButton(base + 2, kind: 5)
            dict[8] = makeButton(base + 0, kind: 1)
            dict[6] = makeButton(base + 1, kind: 1)
            dict[7] = makeButton(base + 2, kind: 1)
            dict[11] = makeButton(base + 0, kind: 3)
            dict[9]  = makeButton(base + 1, kind: 3)
            dict[10] = makeButton(base + 2, kind: 3)
            if isRec { recordImages = dict } else { standardImages = dict }
        }
    }

    func drawBackButton(stat: Int, rect: NSRect) {
        let ovalRect = NSMakeRect(rect.origin.x + 1.0, rect.origin.y + 1.0, rect.size.width - 2.0, rect.size.height - 2.0)
        let ovalPath = NSBezierPath(ovalIn: ovalRect)
        NSGraphicsContext.saveGraphicsState()
        NSColor.clear.set()
        rect.fill()

        let cBegin = NSColor(deviceRed: 0.4509803922, green: 0.5176470588, blue: 0.8823529412, alpha: 1.0)
        let cEnd   = NSColor(deviceRed: 0.6862745098, green: 0.7529411765, blue: 1.0, alpha: 1.0)

        NSGraphicsContext.saveGraphicsState()
        ovalPath.setClip()
        CTGradient(beginningColor: cEnd, endingColor: cBegin).fillRect(rect, angle: 90.0)
        NSGraphicsContext.restoreGraphicsState()

        if style == 1 {
            NSColor(deviceRed: 0.0, green: 0.0, blue: 0.862745098, alpha: 1.0).set()
        } else {
            NSColor(deviceRed: 0.4039215686, green: 0.4039215686, blue: 0.4039215686, alpha: 1.0).set()
        }
        ovalPath.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func drawButtonContent(_ kind: Int, recording: Bool) {
        let fg: NSColor
        if recording {
            fg = NSColor(deviceRed: 0.9921568627, green: 0.9921568627, blue: 0.9921568627, alpha: 1.0)
        } else if style == 1 {
            fg = NSColor(deviceRed: 0.0392156863, green: 0.0392156863, blue: 0.0392156863, alpha: 1.0)
        } else {
            fg = NSColor(deviceRed: 0.4039215686, green: 0.4039215686, blue: 0.4039215686, alpha: 1.0)
        }
        fg.set()

        let path = NSBezierPath()
        let xform = AffineTransform(translationByX: 1.0, byY: 1.0)

        switch kind {
        case 0:
            path.move(to: NSMakePoint(5.0, 3.0))
            path.line(to: NSMakePoint(5.0, 12.0))
            path.line(to: NSMakePoint(12.0, 8.0))
            path.close()
            path.transform(using: xform)
            path.fill()
        case 1:
            path.move(to: NSMakePoint(4.0, 4.0))
            path.line(to: NSMakePoint(4.0, 11.0))
            path.line(to: NSMakePoint(11.0, 11.0))
            path.line(to: NSMakePoint(11.0, 4.0))
            path.close()
            path.transform(using: xform)
            path.fill()
        case 2:
            path.move(to: NSMakePoint(6.0, 4.0))
            path.line(to: NSMakePoint(6.0, 11.0))
            path.move(to: NSMakePoint(9.0, 4.0))
            path.line(to: NSMakePoint(9.0, 11.0))
            path.lineWidth = 1.0
            path.transform(using: xform)
            path.stroke()
        case 3:
            path.appendOval(in: NSMakeRect(4.0, 4.0, 7.0, 7.0))
            path.transform(using: xform)
            path.fill()
        case 4:
            let clipPath = NSBezierPath(ovalIn: NSMakeRect(1.0, 1.0, 15.0, 15.0))
            clipPath.setClip()
            loadPath.stroke()
        case 5:
            path.lineWidth = 1.0
            path.appendArc(withCenter: NSMakePoint(7.5, 7.5), radius: 4.0, startAngle: 0.0, endAngle: 270.0)
            path.transform(using: xform)
            path.stroke()
            path.removeAllPoints()
            path.move(to: NSMakePoint(7.5, 1.0))
            path.line(to: NSMakePoint(7.5, 6.0))
            path.line(to: NSMakePoint(11.0, 3.5))
            path.close()
            path.transform(using: xform)
            path.fill()
        default:
            break
        }
    }

    func makeButton(_ stat: Int, kind: Int) -> NSImage {
        guard let rep = NSBitmapImageRep.fsMakeImage(width: 17, height: 17) else {
            return NSImage(size: NSMakeSize(17, 17))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawBackButton(stat: stat, rect: NSMakeRect(0, 0, 17, 17))
        if kind != 4 {
            drawButtonContent(kind, recording: stat > 2)
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSMakeSize(17, 17))
        img.addRepresentation(rep)
        return img
    }

    func makeButtonVolume(_ stat: Int) -> NSImage {
        guard let rep = NSBitmapImageRep.fsMakeImage(width: 12, height: 6) else {
            return NSImage(size: NSMakeSize(12, 6))
        }
        // Bottom bowl (y=0..6 of oval (0, 0, 12, 12))
        let oval = NSBezierPath(ovalIn: NSMakeRect(0, 0, 12, 12))
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSMakeRect(0, 0, 12, 6).fill()
        if style == 1 {
            NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0).set()
        } else {
            let v: CGFloat = (stat == 1) ? 0.4823529412 : ((stat == 2) ? 0.4039215686 : 0.3254901961)
            NSColor(deviceRed: v, green: v, blue: v, alpha: 1.0).set()
        }
        NSBezierPath.clip(NSMakeRect(0, 0, 12, 6))
        oval.fill()
        NSGraphicsContext.restoreGraphicsState()
        return img
    }

    func makeButtonPopup(_ stat: Int) -> NSImage {
        guard let rep = NSBitmapImageRep.fsMakeImage(width: 12, height: 6) else {
            return NSImage(size: NSMakeSize(12, 6))
        }
        // Top dome (y=0..6 of oval (0, -6, 12, 12))
        let oval = NSBezierPath(ovalIn: NSMakeRect(0, -6, 12, 12))
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        NSMakeRect(0, 0, 12, 6).fill()
        if style == 1 {
            NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0).set()
        } else {
            let v: CGFloat = (stat == 1) ? 0.4823529412 : ((stat == 2) ? 0.4039215686 : 0.3254901961)
            NSColor(deviceRed: v, green: v, blue: v, alpha: 1.0).set()
        }
        NSBezierPath.clip(NSMakeRect(0, 0, 12, 6))
        oval.fill()
        NSGraphicsContext.restoreGraphicsState()
        return img
    }

    func image(withID id: Int) -> NSImage? {
        let dict = isRecording ? recordImages : standardImages
        guard let base = dict[id] else { return nil }
        if id >= 15 && id <= 17 {
            guard let tiff = base.tiffRepresentation,
                  let copy = NSImage(data: tiff) else { return base }
            copy.lockFocus()
            drawButtonContent(4, recording: isRecording)
            copy.unlockFocus()
            return copy
        }
        return base
    }

    func position(withID id: Int) -> NSPoint {
        let px = Self.padX
        let py = Self.padY
        switch id {
        case 0: return NSMakePoint(15.0 + px, 20.0 + py)
        case 1: return NSMakePoint(25.0 + px, 27.0 + py)
        case 2: return NSMakePoint(255.0 + px, 36.0 + py) // Top dome (Popup menu)
        case 3: return NSMakePoint(255.0 + px, 28.0 + py) // Bottom bowl (Volume slider)
        case 4:
            return hidePercent ? NSMakePoint(47.0 + px, 24.0 + py) : NSMakePoint(87.0 + px, 24.0 + py)
        case 5: return NSMakePoint(47.0 + px, 24.0 + py)
        default: return .zero
        }
    }

    func size(withID id: Int) -> NSSize {
        switch id {
        case 0: return NSMakeSize(260.0, 30.0)
        case 1: return NSMakeSize(17.0, 17.0)
        case 2: return NSMakeSize(12.0, 6.0)
        case 3: return NSMakeSize(12.0, 6.0)
        case 4:
            return hidePercent ? NSMakeSize(197.0, 22.0) : NSMakeSize(160.0, 22.0)
        case 5: return NSMakeSize(40.0, 22.0)
        default: return .zero
        }
    }

    func style(withID id: Int) -> [NSAttributedString.Key: Any] {
        let font = NSFont.systemFont(ofSize: 12.0)
        let color: NSColor = (style == 1)
            ? NSColor(deviceRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            : NSColor(deviceRed: 0.4039215686, green: 0.4039215686, blue: 0.4039215686, alpha: 1.0)
        return [
            .font: font,
            .foregroundColor: color
        ]
    }

    func setStyle(_ newStyle: Int) {
        guard style != newStyle else { return }
        style = newStyle
        buildImages()
    }

    func setBufferPercent(_ pct: Int) {
        p100 = pct
        if pct >= 100 {
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.hidePercent = true
                self?.doSwitchPercent = true
            }
        } else {
            hideTimer?.invalidate()
            hideTimer = nil
            if hidePercent {
                hidePercent = false
                doSwitchPercent = true
            }
        }
    }

    func stepWaveAnimation() {
        let xform: AffineTransform
        if loadX <= -17 {
            xform = AffineTransform(translationByX: CGFloat(-loadX), byY: 0.0)
            loadX = 0
        } else {
            xform = AffineTransform(translationByX: -1.0, byY: 0.0)
            loadX -= 1
        }
        loadPath.transform(using: xform)
    }
}

// MARK: - Playlist Parser (.pls, .m3u, .asx)
struct RadioStation: Codable, Equatable {
    var name: String
    var url: String
}

final class FSPlaylistParser {
    static func parsePlaylistContent(_ text: String, fallbackName: String = "Sky24") -> (url: String, title: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.range(of: "[playlist]", options: .caseInsensitive) != nil ||
           trimmed.range(of: "File1=", options: .caseInsensitive) != nil {
            var fileUrl: String?
            var title: String?
            let lines = trimmed.components(separatedBy: .newlines)
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.lowercased().hasPrefix("file1=") {
                    fileUrl = String(line.dropFirst("file1=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if fileUrl == nil, line.lowercased().hasPrefix("file"), let eq = line.firstIndex(of: "=") {
                    let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if val.lowercased().hasPrefix("http") { fileUrl = val }
                } else if line.lowercased().hasPrefix("title1=") {
                    title = String(line.dropFirst("title1=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let u = fileUrl, !u.isEmpty {
                return (u, title)
            }
        }

        if trimmed.lowercased().contains("<asx") || trimmed.lowercased().contains("<ref") {
            if let range = trimmed.range(of: #"href\s*=\s*["']([^"']+)["']"#, options: [.regularExpression, .caseInsensitive]) {
                let match = String(trimmed[range])
                if let q1 = match.firstIndex(where: { $0 == "\"" || $0 == "'" }),
                   let q2 = match.lastIndex(where: { $0 == "\"" || $0 == "'" }), q1 < q2 {
                    let u = String(match[match.index(after: q1)..<q2])
                    return (u, fallbackName)
                }
            }
        }

        var extTitle: String?
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                if let comma = line.firstIndex(of: ",") {
                    extTitle = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("http://") || line.lowercased().hasPrefix("https://") {
                return (line, extTitle)
            }
        }
        return nil
    }
}

// MARK: - Permissive URLSession Delegate
final class PermissiveSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - CoreAudio Stream Decoder + ICY/HTTP Stream Engine (Matches FSSound)
enum StreamState {
    case disconnected
    case connecting
    case buffering(Int)
    case playing
    case paused
}

protocol FSSoundDelegate: AnyObject {
    func soundStateDidChange(_ state: StreamState)
    func soundMetadataDidChange(station: String?, title: String?, bitrate: String?, genre: String?)
    func soundErrorDidOccur(_ message: String)
}

final class FSSoundEngine {
    weak var delegate: FSSoundDelegate?

    private let stateLock = NSLock()
    private var _state: StreamState = .disconnected
    private(set) var state: StreamState {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _state
        }
        set {
            stateLock.lock()
            _state = newValue
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.soundStateDidChange(newValue)
            }
        }
    }

    private var _volume: Float = 1.0
    var volume: Float {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _volume
        }
        set {
            stateLock.lock()
            _volume = newValue
            stateLock.unlock()
            netQueue.async { [weak self] in
                guard let self = self else { return }
                if let q = self.audioQueue {
                    AudioQueueSetParameter(q, kAudioQueueParam_Volume, newValue)
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.avPlayer?.volume = newValue
            }
        }
    }

    private var _lastDataReceivedAt: Date = Date()
    var lastDataReceivedAt: Date {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _lastDataReceivedAt
        }
        set {
            stateLock.lock()
            _lastDataReceivedAt = newValue
            stateLock.unlock()
        }
    }

    private var _currentStationName: String = "Sky24"
    var currentStationName: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _currentStationName
        }
        set {
            stateLock.lock()
            _currentStationName = newValue
            stateLock.unlock()
        }
    }

    private var _currentStreamTitle: String?
    var currentStreamTitle: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _currentStreamTitle
        }
        set {
            stateLock.lock()
            _currentStreamTitle = newValue
            stateLock.unlock()
        }
    }

    private var _currentBitrate: String?
    var currentBitrate: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _currentBitrate
        }
        set {
            stateLock.lock()
            _currentBitrate = newValue
            stateLock.unlock()
        }
    }

    private var _currentGenre: String?
    var currentGenre: String? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _currentGenre
        }
        set {
            stateLock.lock()
            _currentGenre = newValue
            stateLock.unlock()
        }
    }

    // All stream socket, parser, and CoreAudio state below is accessed EXCLUSIVELY on netQueue
    private let netQueue = DispatchQueue(label: "com.sourcemac.fstream.net", qos: .userInitiated)
    private var sessionID: UInt64 = 0
    private var connection: NWConnection?
    private var playlistTask: URLSessionDataTask?
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        return URLSession(configuration: config, delegate: PermissiveSessionDelegate(), delegateQueue: nil)
    }()
    private var isStopped: Bool = true
    private var currentPlayURL: String = ""

    private var headerParsed: Bool = false
    private var headerBuffer = Data()
    private var icyMetaInt: Int = 0
    private var bytesUntilMeta: Int = 0
    private var metaBytesRemaining: Int = -1
    private var metaBuffer = Data()
    private var triedShoutcastSemicolon: Bool = false
    private var redirectCount: Int = 0

    fileprivate var audioFileStream: AudioFileStreamID?
    fileprivate var audioQueue: AudioQueueRef?
    fileprivate var audioQueueStarted: Bool = false
    fileprivate var totalAudioBytesReceived: Int = 0
    fileprivate let prebufferTargetBytes: Int = 32768
    fileprivate var packetDataBuffer = Data()
    fileprivate var packetDescs: [AudioStreamPacketDescription] = []
    fileprivate let packetFlushThreshold: Int = 16384
    private var avPlayer: AVPlayer?

    func play(urlString: String, stationName: String = "Sky24") {
        lastDataReceivedAt = Date()
        currentStationName = stationName
        currentStreamTitle = nil
        currentBitrate = nil
        currentGenre = nil

        DispatchQueue.main.async { [weak self] in
            self?.avPlayer?.pause()
            self?.avPlayer = nil
        }

        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.sessionID &+= 1
            let sid = self.sessionID
            self.cleanupStreamOnNetQueue()
            self.isStopped = false
            self.currentPlayURL = urlString
            self.lastDataReceivedAt = Date()
            self.triedShoutcastSemicolon = false
            self.redirectCount = 0
            self.state = .connecting

            var normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.lowercased().hasPrefix("fsradio://") {
                let tail = String(normalized.dropFirst("fsradio://".count))
                if let decodedData = Data(base64Encoded: tail),
                   let decodedStr = String(data: decodedData, encoding: .utf8),
                   decodedStr.lowercased().hasPrefix("http") {
                    normalized = decodedStr
                } else {
                    normalized = "http://" + tail
                }
            }

            if normalized.hasPrefix("/") && FileManager.default.fileExists(atPath: normalized) {
                if let content = Self.decodeString(from: (try? Data(contentsOf: URL(fileURLWithPath: normalized))) ?? Data()),
                   let parsed = FSPlaylistParser.parsePlaylistContent(content, fallbackName: stationName) {
                    if let t = parsed.title, !t.isEmpty { self.currentStationName = t }
                    self.connectToStream(urlString: parsed.url, sid: sid)
                    return
                }
            }

            self.resolveAndConnect(urlString: normalized, sid: sid)
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.avPlayer?.pause()
            self?.avPlayer = nil
        }
        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.sessionID &+= 1
            self.isStopped = true
            self.cleanupStreamOnNetQueue()
            self.state = .disconnected
        }
    }

    func togglePause() {
        switch state {
        case .playing:
            DispatchQueue.main.async { [weak self] in
                self?.avPlayer?.pause()
                self?.avPlayer = nil
            }
            netQueue.async { [weak self] in
                guard let self = self else { return }
                self.sessionID &+= 1
                self.isStopped = true
                self.cleanupStreamOnNetQueue()
                self.state = .paused
            }
        case .paused:
            let stName = currentStationName
            netQueue.async { [weak self] in
                guard let self = self else { return }
                let urlToPlay = self.currentPlayURL
                guard !urlToPlay.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.play(urlString: urlToPlay, stationName: stName)
                }
            }
        default:
            break
        }
    }

    private func cleanupStreamOnNetQueue() {
        playlistTask?.cancel()
        playlistTask = nil
        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
            connection = nil
        }
        headerParsed = false
        headerBuffer.removeAll(keepingCapacity: false)
        icyMetaInt = 0
        bytesUntilMeta = 0
        metaBytesRemaining = -1
        metaBuffer.removeAll(keepingCapacity: false)
        totalAudioBytesReceived = 0
        packetDataBuffer.removeAll(keepingCapacity: false)
        packetDescs.removeAll(keepingCapacity: false)
        teardownCoreAudioOnNetQueue()
    }

    private func resolveAndConnect(urlString: String, sid: UInt64) {
        guard sessionID == sid, !isStopped else { return }
        guard let url = URL(string: urlString) else {
            state = .disconnected
            return
        }
        let pathLower = url.path.lowercased()
        let isPlaylistExt = pathLower.hasSuffix(".pls") || pathLower.hasSuffix(".m3u") || pathLower.hasSuffix(".asx")

        if isPlaylistExt {
            var req = URLRequest(url: url, timeoutInterval: 10.0)
            req.setValue("FStream/1.4.9", forHTTPHeaderField: "User-Agent")
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            playlistTask?.cancel()
            let task = urlSession.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self else { return }
                self.netQueue.async { [weak self] in
                    guard let self = self, self.sessionID == sid, !self.isStopped else { return }
                    self.playlistTask = nil
                    self.lastDataReceivedAt = Date()
                    if let data = data, !data.isEmpty,
                       let text = Self.decodeString(from: data),
                       let parsed = FSPlaylistParser.parsePlaylistContent(text, fallbackName: self.currentStationName) {
                        if let t = parsed.title, !t.isEmpty {
                            self.currentStationName = t
                        }
                        self.notifyMetadata()
                        self.connectToStream(urlString: parsed.url, sid: sid)
                    } else {
                        self.connectToStream(urlString: urlString, sid: sid)
                    }
                }
            }
            playlistTask = task
            task.resume()
        } else {
            connectToStream(urlString: urlString, sid: sid)
        }
    }

    private func connectToStream(urlString: String, sid: UInt64) {
        guard sessionID == sid, !isStopped else { return }
        guard let url = URL(string: urlString), let host = url.host else {
            state = .disconnected
            return
        }

        if url.path.lowercased().hasSuffix(".m3u8") {
            let vol = self.volume
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let player = AVPlayer(url: url)
                player.volume = vol
                self.avPlayer = player
                player.play()
                self.state = .playing
                self.notifyMetadata()
            }
            return
        }

        let scheme = (url.scheme ?? "http").lowercased()
        let isTLS = (scheme == "https")
        let portNum = url.port ?? (isTLS ? 443 : 80)
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portNum)) else {
            state = .disconnected
            return
        }

        cleanupStreamOnNetQueue()
        lastDataReceivedAt = Date()

        let params: NWParameters
        if isTLS {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, completionHandler in
                completionHandler(true)
            }, netQueue)
            params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.connection = conn

        var pathAndQuery = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            pathAndQuery += "?" + query
        }
        if urlString.hasSuffix(";") && !pathAndQuery.hasSuffix(";") {
            pathAndQuery += ";"
        }

        let hostHeader = (url.port != nil && url.port != 80 && url.port != 443) ? "\(host):\(portNum)" : host
        let requestString =
            "GET \(pathAndQuery) HTTP/1.0\r\n" +
            "Host: \(hostHeader)\r\n" +
            "User-Agent: FStream/1.4.9\r\n" +
            "Icy-MetaData: 1\r\n" +
            "Accept: */*\r\n" +
            "Connection: close\r\n\r\n"

        conn.stateUpdateHandler = { [weak self, weak conn] newState in
            guard let self = self, let conn = conn else { return }
            guard self.sessionID == sid, !self.isStopped, self.connection === conn else { return }
            switch newState {
            case .ready:
                self.lastDataReceivedAt = Date()
                let reqData = requestString.data(using: .utf8)!
                conn.send(content: reqData, completion: .contentProcessed { [weak self, weak conn] sendErr in
                    guard let self = self, let conn = conn else { return }
                    guard self.sessionID == sid, !self.isStopped, self.connection === conn else { return }
                    if sendErr != nil {
                        self.state = .disconnected
                        return
                    }
                    self.receiveLoop(on: conn, originalURL: urlString, sid: sid)
                })
            case .failed(_):
                if !self.isStopped && self.sessionID == sid {
                    self.state = .disconnected
                }
            default:
                break
            }
        }
        conn.start(queue: netQueue)
    }

    private func receiveLoop(on conn: NWConnection, originalURL: String, sid: UInt64) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn else { return }
            guard self.sessionID == sid, !self.isStopped, self.connection === conn else { return }
            if let data = data, !data.isEmpty {
                self.lastDataReceivedAt = Date()
                self.processIncomingBytes(data, originalURL: originalURL, sid: sid)
            }
            guard self.sessionID == sid, !self.isStopped, self.connection === conn else { return }
            if isComplete || error != nil {
                self.state = .disconnected
                return
            }
            self.receiveLoop(on: conn, originalURL: originalURL, sid: sid)
        }
    }

    private func processIncomingBytes(_ data: Data, originalURL: String, sid: UInt64) {
        guard sessionID == sid, !isStopped else { return }
        if !headerParsed {
            headerBuffer.append(data)
            let crlfcrlf = Data([13, 10, 13, 10])
            let lflf = Data([10, 10])
            var splitRange = headerBuffer.range(of: crlfcrlf)
            if splitRange == nil { splitRange = headerBuffer.range(of: lflf) }

            if let range = splitRange {
                let headerData = headerBuffer.subdata(in: 0..<range.lowerBound)
                let bodyRemainder = headerBuffer.subdata(in: range.upperBound..<headerBuffer.count)
                headerBuffer.removeAll()
                headerParsed = true

                let headerStr = Self.decodeString(from: headerData) ?? ""
                if handleHTTPHeader(headerStr, bodyPreview: bodyRemainder, originalURL: originalURL, sid: sid) {
                    if !bodyRemainder.isEmpty {
                        processBodyBytes(bodyRemainder, sid: sid)
                    }
                }
            } else if headerBuffer.count > 16384 {
                let rawBytes = headerBuffer
                headerBuffer.removeAll()
                headerParsed = true
                openCoreAudioStream(contentType: nil)
                state = .buffering(0)
                processBodyBytes(rawBytes, sid: sid)
            }
        } else {
            processBodyBytes(data, sid: sid)
        }
    }

    private func handleHTTPHeader(_ headerStr: String, bodyPreview: Data, originalURL: String, sid: UInt64) -> Bool {
        guard sessionID == sid, !isStopped else { return false }
        let lines = headerStr.components(separatedBy: .newlines)
        let statusLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var contentType: String?
        var location: String?

        for rawLine in lines.dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "location":
                location = val
            case "content-type":
                contentType = val.lowercased()
            case "icy-metaint":
                if let v = Int(val), v > 0 {
                    icyMetaInt = v
                    bytesUntilMeta = v
                }
            case "icy-name", "ice-name", "x-audiocast-name":
                if !val.isEmpty { currentStationName = val }
            case "icy-br", "ice-bitrate":
                if !val.isEmpty { currentBitrate = val }
            case "icy-genre", "ice-genre":
                if !val.isEmpty { currentGenre = val }
            default:
                break
            }
        }

        if (statusLine.contains(" 301") || statusLine.contains(" 302") || statusLine.contains(" 303") ||
            statusLine.contains(" 307") || statusLine.contains(" 308")),
           let loc = location, redirectCount < 5 {
            redirectCount += 1
            let nextURL: String
            if loc.lowercased().hasPrefix("http") {
                nextURL = loc
            } else if let base = URL(string: originalURL), let resolved = URL(string: loc, relativeTo: base)?.absoluteString {
                nextURL = resolved
            } else {
                nextURL = loc
            }
            cleanupStreamOnNetQueue()
            resolveAndConnect(urlString: nextURL, sid: sid)
            return false
        }

        if let ct = contentType,
           (ct.contains("scpls") || ct.contains("mpegurl") || ct.contains("x-ms-asf")) {
            let text = Self.decodeString(from: bodyPreview) ?? ""
            if let parsed = FSPlaylistParser.parsePlaylistContent(text, fallbackName: currentStationName) {
                if let t = parsed.title, !t.isEmpty { currentStationName = t }
                cleanupStreamOnNetQueue()
                connectToStream(urlString: parsed.url, sid: sid)
                return false
            }
        }

        if let ct = contentType, ct.contains("text/html"), !triedShoutcastSemicolon {
            triedShoutcastSemicolon = true
            var semiURL = originalURL
            if !semiURL.hasSuffix(";") {
                if semiURL.hasSuffix("/") {
                    semiURL += ";"
                } else {
                    semiURL += "/;"
                }
            }
            cleanupStreamOnNetQueue()
            connectToStream(urlString: semiURL, sid: sid)
            return false
        }

        notifyMetadata()
        openCoreAudioStream(contentType: contentType)
        state = .buffering(0)
        return true
    }

    private func processBodyBytes(_ data: Data, sid: UInt64) {
        guard sessionID == sid, !isStopped else { return }
        if icyMetaInt <= 0 {
            feedAudioBytes(data, sid: sid)
            return
        }

        var idx = data.startIndex
        let end = data.endIndex

        while idx < end {
            guard sessionID == sid, !isStopped else { return }
            if metaBytesRemaining >= 0 {
                let toRead = min(metaBytesRemaining, end - idx)
                if toRead > 0 {
                    metaBuffer.append(data[idx..<(idx + toRead)])
                    idx += toRead
                    metaBytesRemaining -= toRead
                }
                if metaBytesRemaining == 0 {
                    parseIcyMetadata(metaBuffer)
                    metaBuffer.removeAll()
                    metaBytesRemaining = -1
                    bytesUntilMeta = icyMetaInt
                }
            } else if bytesUntilMeta > 0 {
                let toRead = min(bytesUntilMeta, end - idx)
                let chunk = data[idx..<(idx + toRead)]
                feedAudioBytes(Data(chunk), sid: sid)
                idx += toRead
                bytesUntilMeta -= toRead
            } else {
                let lenByte = Int(data[idx])
                idx += 1
                let metaLen = lenByte * 16
                if metaLen == 0 {
                    bytesUntilMeta = icyMetaInt
                } else {
                    metaBytesRemaining = metaLen
                    metaBuffer.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    private func parseIcyMetadata(_ data: Data) {
        let prefixBytes = Data("StreamTitle='".utf8)
        let suffixSemiBytes = Data("';".utf8)
        let suffixQuoteBytes = Data("'".utf8)

        if let startRange = data.range(of: prefixBytes) {
            let afterStart = startRange.upperBound
            let remainder = data[afterStart..<data.endIndex]
            let endIdx: Data.Index
            if let semiRange = remainder.range(of: suffixSemiBytes) {
                endIdx = semiRange.lowerBound
            } else if let quoteRange = remainder.range(of: suffixQuoteBytes) {
                endIdx = quoteRange.lowerBound
            } else {
                endIdx = remainder.firstIndex(of: 0) ?? remainder.endIndex
            }
            let titleSlice = Data(data[afterStart..<endIdx])
            if let decoded = Self.decodeString(from: titleSlice) {
                let title = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    let changed = (title != currentStreamTitle)
                    currentStreamTitle = title
                    if changed {
                        notifyMetadata()
                    }
                }
            }
        }
    }

    private func notifyMetadata() {
        let st = currentStationName
        let ti = currentStreamTitle
        let br = currentBitrate
        let ge = currentGenre
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.soundMetadataDidChange(station: st, title: ti, bitrate: br, genre: ge)
        }
    }

    private func openCoreAudioStream(contentType: String?) {
        teardownCoreAudioOnNetQueue()
        var hint: AudioFileTypeID = kAudioFileMP3Type
        if let ct = contentType {
            if ct.contains("aac") || ct.contains("aacp") {
                hint = kAudioFileAAC_ADTSType
            } else if ct.contains("mp4") || ct.contains("m4a") {
                hint = kAudioFileM4AType
            } else if ct.contains("wav") {
                hint = kAudioFileWAVEType
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(
            selfPtr,
            { clientData, fileStream, propID, _ in
                let engine = Unmanaged<FSSoundEngine>.fromOpaque(clientData).takeUnretainedValue()
                engine.handleAudioFileStreamProperty(fileStream: fileStream, propID: propID)
            },
            { clientData, numBytes, numPackets, inputData, packetDescs in
                let engine = Unmanaged<FSSoundEngine>.fromOpaque(clientData).takeUnretainedValue()
                engine.handleAudioPackets(numBytes: numBytes, numPackets: numPackets, inputData: inputData, packetDescs: packetDescs)
            },
            hint,
            &audioFileStream
        )
    }

    private func feedAudioBytes(_ data: Data, sid: UInt64) {
        guard sessionID == sid, !isStopped, !data.isEmpty, let stream = audioFileStream else { return }
        totalAudioBytesReceived += data.count

        if !audioQueueStarted {
            let pct = min(100, Int((Double(totalAudioBytesReceived) / Double(prebufferTargetBytes)) * 100.0))
            state = .buffering(pct)
        }

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            AudioFileStreamParseBytes(stream, UInt32(data.count), base, [])
        }
    }

    fileprivate func handleAudioFileStreamProperty(fileStream: AudioFileStreamID, propID: AudioFileStreamPropertyID) {
        guard !isStopped, fileStream == audioFileStream, propID == kAudioFileStreamProperty_DataFormat else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_DataFormat, &size, &asbd)
        guard status == noErr, audioQueue == nil else { return }

        var q: AudioQueueRef?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let qStatus = AudioQueueNewOutput(
            &asbd,
            { _, queue, buffer in
                AudioQueueFreeBuffer(queue, buffer)
            },
            selfPtr,
            nil,
            nil,
            0,
            &q
        )
        if qStatus == noErr, let q = q {
            self.audioQueue = q
            AudioQueueSetParameter(q, kAudioQueueParam_Volume, volume)
        }
    }

    fileprivate func handleAudioPackets(
        numBytes: UInt32,
        numPackets: UInt32,
        inputData: UnsafeRawPointer,
        packetDescs: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard !isStopped, let q = audioQueue, numBytes > 0 else { return }

        if let descs = packetDescs {
            for i in 0..<Int(numPackets) {
                var d = descs[i]
                let offset = Int(d.mStartOffset)
                let pSize = Int(d.mDataByteSize)
                guard offset >= 0, pSize > 0, offset + pSize <= Int(numBytes) else { continue }
                if packetDataBuffer.count + pSize > packetFlushThreshold && !packetDataBuffer.isEmpty {
                    flushQueuedPackets(to: q)
                }
                d.mStartOffset = Int64(packetDataBuffer.count)
                packetDataBuffer.append(inputData.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: pSize)
                self.packetDescs.append(d)
            }
            if packetDataBuffer.count >= packetFlushThreshold {
                flushQueuedPackets(to: q)
            }
        } else {
            var bufRef: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, numBytes, &bufRef) == noErr, let buf = bufRef {
                memcpy(buf.pointee.mAudioData, inputData, Int(numBytes))
                buf.pointee.mAudioDataByteSize = numBytes
                AudioQueueEnqueueBuffer(q, buf, 0, nil)
            }
        }

        if !audioQueueStarted && totalAudioBytesReceived >= prebufferTargetBytes {
            flushQueuedPackets(to: q)
            if AudioQueueStart(q, nil) == noErr {
                audioQueueStarted = true
                state = .buffering(100)
                state = .playing
                notifyMetadata()
            }
        }
    }

    private func flushQueuedPackets(to q: AudioQueueRef) {
        guard !packetDataBuffer.isEmpty else { return }
        var bufRef: AudioQueueBufferRef?
        let byteCount = UInt32(packetDataBuffer.count)
        let descCount = UInt32(packetDescs.count)
        if AudioQueueAllocateBuffer(q, byteCount, &bufRef) == noErr, let buf = bufRef {
            packetDataBuffer.copyBytes(to: buf.pointee.mAudioData.assumingMemoryBound(to: UInt8.self), count: Int(byteCount))
            buf.pointee.mAudioDataByteSize = byteCount
            packetDescs.withUnsafeBufferPointer { descPtr in
                _ = AudioQueueEnqueueBuffer(q, buf, descCount, descPtr.baseAddress)
            }
        }
        packetDataBuffer.removeAll(keepingCapacity: true)
        packetDescs.removeAll(keepingCapacity: true)
    }

    private func teardownCoreAudioOnNetQueue() {
        if let q = audioQueue {
            AudioQueueStop(q, true)
            AudioQueueDispose(q, true)
            audioQueue = nil
        }
        if let s = audioFileStream {
            AudioFileStreamClose(s)
            audioFileStream = nil
        }
        audioQueueStarted = false
    }

    static func decodeString(from data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let eucKr = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))
        if let s = NSString(data: data, encoding: eucKr) as String? { return s }
        let cp949 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
        if let s = NSString(data: data, encoding: cp949) as String? { return s }
        return String(data: data, encoding: .isoLatin1)
    }
}

// MARK: - FSText (Exact port of FStream scrolling/switching text 0x1000030c0)
final class FSText {
    let plugin: MyPlugin
    private var items: [String] = ["끊어짐"]
    private var currentIndex: Int = 0
    private var str1: String = "끊어짐"
    private var str2: String = ""
    private var powerStr: String = ""
    private var showPowerStr: Bool = false
    private var powerTimer: Timer?

    private var isVScrolling: Bool = false
    private var tdy: Int = 0
    private var isHScrolling: Bool = false
    private var tdx: Int = 0
    private var hBaseWidth: CGFloat = 0
    private var hCombinedStr: String = ""
    private var ticksSinceSwitch: Int = 0

    private var hScrollPauseTicks: Int = 0
    private var hScrollCyclesCompleted: Int = 0
    private var lastTitle: String?
    private var pendingJumpToTitle: Bool = false

    init(plugin: MyPlugin) {
        self.plugin = plugin
    }

    func setSingleStatus(_ status: String) {
        items = [status]
        currentIndex = 0
        str1 = status
        str2 = ""
        lastTitle = nil
        pendingJumpToTitle = false
        isVScrolling = false
        isHScrolling = false
        tdx = 0
        tdy = 0
        ticksSinceSwitch = 0
        hScrollPauseTicks = 0
        hScrollCyclesCompleted = 0
        updateHScrollState()
    }

    func setPlayingInfo(station: String?, title: String?, bitrate: String?) {
        let wasSingleStatus = (items.count <= 1 && !items.first!.hasPrefix("상태:"))
        var newItems: [String] = ["상태: 듣는중"]
        if let st = station, !st.isEmpty {
            newItems.append("채널: \(st)")
        }
        if let ti = title, !ti.isEmpty {
            newItems.append("제목: \(ti)")
        }
        items = newItems

        if wasSingleStatus {
            currentIndex = 0
            str1 = items[0]
            str2 = ""
            isVScrolling = false
            tdx = 0
            tdy = 0
            ticksSinceSwitch = 0
            lastTitle = title
            pendingJumpToTitle = false
            updateHScrollState()
            return
        }

        if currentIndex >= items.count {
            currentIndex = 0
        }

        if let ti = title, !ti.isEmpty, ti != lastTitle {
            lastTitle = ti
            pendingJumpToTitle = true
        }

        if !isVScrolling && str1 != items[currentIndex] {
            str1 = items[currentIndex]
            updateHScrollState()
        }
    }

    func showPowerString(_ text: String) {
        powerStr = text
        showPowerStr = true
        powerTimer?.invalidate()
        powerTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.showPowerStr = false
        }
    }

    func nextInfo() {
        guard items.count > 1, !isVScrolling else { return }
        let nextIdx = (currentIndex + 1) % items.count
        str1 = items[currentIndex]
        str2 = items[nextIdx]
        currentIndex = nextIdx
        isVScrolling = true
        isHScrolling = false
        tdy = 0
        tdx = 0
        ticksSinceSwitch = 0
        hScrollPauseTicks = 0
        hScrollCyclesCompleted = 0
    }

    private func updateHScrollState() {
        let attrs = plugin.style(withID: 0)
        let boxWidth = plugin.size(withID: 4).width
        let w = (str1 as NSString).size(withAttributes: attrs).width
        hScrollCyclesCompleted = 0
        if w > boxWidth {
            isHScrolling = true
            tdx = 0
            hScrollPauseTicks = 30 // 1.5s pause at start before scrolling
            let prefix = "\(str1) - "
            hBaseWidth = (prefix as NSString).size(withAttributes: attrs).width
            hCombinedStr = "\(str1) - \(str1)"
        } else {
            isHScrolling = false
            tdx = 0
            hScrollPauseTicks = 0
            hCombinedStr = str1
        }
    }

    func stepAnimation() -> Bool {
        if plugin.doSwitchPercent {
            plugin.doSwitchPercent = false
            updateHScrollState()
            return true
        }
        if showPowerStr {
            return true
        }
        if isVScrolling {
            tdy += 2
            if CGFloat(tdy) >= plugin.size(withID: 4).height {
                isVScrolling = false
                tdy = 0
                str1 = str2
                ticksSinceSwitch = 0
                updateHScrollState()
            }
            return true
        }

        if pendingJumpToTitle {
            pendingJumpToTitle = false
            if let titleIdx = items.firstIndex(where: { $0.hasPrefix("제목:") }),
               currentIndex != titleIdx {
                str1 = items[currentIndex]
                str2 = items[titleIdx]
                currentIndex = titleIdx
                isVScrolling = true
                isHScrolling = false
                tdy = 0
                tdx = 0
                ticksSinceSwitch = 0
                return true
            }
        }

        let isTitleItem = str1.hasPrefix("제목:")

        if isHScrolling {
            if hScrollPauseTicks > 0 {
                hScrollPauseTicks -= 1
                return false
            }
            tdx -= 1
            if CGFloat(-tdx) >= hBaseWidth {
                tdx = 0
                hScrollCyclesCompleted += 1
                let targetCycles = isTitleItem ? 2 : 1
                if hScrollCyclesCompleted >= targetCycles && items.count > 1 {
                    nextInfo()
                } else {
                    hScrollPauseTicks = 25 // 1.25s pause between scroll passes
                }
            }
            return true
        }

        ticksSinceSwitch += 1
        // Hold song title for 10 seconds (200 ticks @ 20Hz), other items for 3.5 seconds (70 ticks)
        let holdTicks = isTitleItem ? 200 : 70
        if items.count > 1 && ticksSinceSwitch >= holdTicks {
            nextInfo()
            return true
        }
        return false
    }

    var drawArea: NSRect {
        let p = plugin.position(withID: 4)
        let s = plugin.size(withID: 4)
        return NSMakeRect(p.x, p.y, s.width, s.height)
    }

    private func centerRect(for text: String, attributes: [NSAttributedString.Key: Any], inRect: NSRect, dx: Int, dy: Int) -> NSRect {
        let sz = (text as NSString).size(withAttributes: attributes)
        let x = inRect.origin.x + CGFloat(dx)
        let y = floor(inRect.origin.y + (inRect.size.height - sz.height) * 0.5 + CGFloat(dy))
        return NSMakeRect(x, y, ceil(sz.width) + 2.0, ceil(sz.height))
    }

    func draw() {
        let attrs = plugin.style(withID: 0)
        let area = drawArea
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath.clip(area)

        if showPowerStr {
            let r = centerRect(for: powerStr, attributes: attrs, inRect: area, dx: 0, dy: 0)
            (powerStr as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
        } else if isVScrolling {
            let h = Int(area.size.height)
            let r1 = centerRect(for: str1, attributes: attrs, inRect: area, dx: 0, dy: tdy)
            let r2 = centerRect(for: str2, attributes: attrs, inRect: area, dx: 0, dy: tdy - h)
            (str1 as NSString).draw(with: r1, options: [.usesLineFragmentOrigin], attributes: attrs)
            (str2 as NSString).draw(with: r2, options: [.usesLineFragmentOrigin], attributes: attrs)
        } else if isHScrolling {
            let r = centerRect(for: hCombinedStr, attributes: attrs, inRect: area, dx: tdx, dy: 0)
            (hCombinedStr as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
        } else {
            let r = centerRect(for: str1, attributes: attrs, inRect: area, dx: 0, dy: 0)
            (str1 as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
        }

        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - FSView (Main Skinned Content View, 300 x 72 pt)
final class FSView: NSView {
    static let winWidth: CGFloat = 300.0
    static let winHeight: CGFloat = 72.0

    let plugin: MyPlugin
    let fsText: FSText
    weak var controller: FStreamController?

    var hoverElement: Int = 0 // 0=none, 1=control, 2=popup(top), 3=volume(bottom)
    var pressedElement: Int = 0
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartWindowOrigin: NSPoint = .zero
    private var isDraggingWindow: Bool = false

    init(frame: NSRect, plugin: MyPlugin, fsText: FSText) {
        self.plugin = plugin
        self.fsText = fsText
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func hitTestElement(at pt: NSPoint) -> Int {
        for id in [1, 2, 3, 4] {
            let r = NSRect(origin: plugin.position(withID: id), size: plugin.size(withID: id))
            if NSPointInRect(pt, r) { return id }
        }
        let pillRect = NSRect(origin: plugin.position(withID: 0), size: plugin.size(withID: 0))
        if NSPointInRect(pt, pillRect) { return 0 }
        return -1
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let hit = max(0, hitTestElement(at: pt))
        let newHover = (1...3).contains(hit) ? hit : 0
        if newHover != hoverElement {
            hoverElement = newHover
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverElement != 0 {
            hoverElement = 0
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let hit = hitTestElement(at: pt)
        if hit == 1 {
            pressedElement = 1
            needsDisplay = true
        } else if hit == 2 {
            // ID 2 (top dome at (255, 36)) = FSPopup (Stations & Settings Menu)
            pressedElement = 2
            needsDisplay = true
            controller?.showStationsPopup(with: event, in: self)
            pressedElement = 0
            needsDisplay = true
        } else if hit == 3 {
            // ID 3 (bottom bowl at (255, 28)) = FSVolume (Volume Slider Popup)
            pressedElement = 3
            needsDisplay = true
            controller?.showVolumePopup(with: event, in: self)
            pressedElement = 0
            needsDisplay = true
        } else {
            isDraggingWindow = true
            dragStartMouseLocation = NSEvent.mouseLocation
            dragStartWindowOrigin = window?.frame.origin ?? .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isDraggingWindow, let win = window {
            let cur = NSEvent.mouseLocation
            let newOrigin = NSMakePoint(
                dragStartWindowOrigin.x + (cur.x - dragStartMouseLocation.x),
                dragStartWindowOrigin.y + (cur.y - dragStartMouseLocation.y)
            )
            win.setFrameOrigin(newOrigin)
        } else if pressedElement == 1 {
            let pt = convert(event.locationInWindow, from: nil)
            let inside = hitTestElement(at: pt) == 1
            hoverElement = inside ? 1 : 0
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let hit = hitTestElement(at: pt)
        if pressedElement == 1 {
            pressedElement = 0
            if hit == 1 {
                controller?.togglePlayStop()
            }
            needsDisplay = true
        } else if isDraggingWindow {
            isDraggingWindow = false
            let moved = hypot(NSEvent.mouseLocation.x - dragStartMouseLocation.x,
                              NSEvent.mouseLocation.y - dragStartMouseLocation.y)
            if moved < 3.0 && hit == 4 {
                fsText.nextInfo()
                needsDisplay = true
            }
            if let origin = window?.frame.origin {
                UserDefaults.standard.set(Double(origin.x), forKey: "winCoordX")
                UserDefaults.standard.set(Double(origin.y), forKey: "winCoordY")
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showStationsPopup(with: event, in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let ctrl = controller else { return }
        let delta = Float(event.scrollingDeltaY) * 0.01
        if abs(delta) > 0.001 {
            ctrl.setVolume(max(0.0, min(1.0, ctrl.volume + delta)))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let first = urls.first {
            if first.isFileURL {
                controller?.openFile(at: first.path)
            } else {
                controller?.playCustomURL(first.absoluteString, name: first.host ?? "Custom")
            }
            return true
        }
        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           str.lowercased().hasPrefix("http") {
            controller?.playCustomURL(str, name: "Custom")
            return true
        }
        return false
    }

    private func currentControlButtonImageID() -> Int {
        let state = controller?.streamState ?? .disconnected
        let isDown = (pressedElement == 1 && hoverElement == 1)
        let isHover = (hoverElement == 1 && !isDown)

        switch state {
        case .disconnected, .paused:
            return isDown ? 1 : (isHover ? 0 : 2)
        case .connecting, .buffering:
            if isDown { return 7 }
            if isHover { return 6 }
            return 15
        case .playing:
            return isDown ? 4 : (isHover ? 3 : 5)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        bounds.fill()

        // 1. Draw Pill Background with exact FStream active/inactive drop shadow (0x1000231ec)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        let isActive = NSApp?.isActive ?? true
        if isActive {
            shadow.shadowOffset = NSMakeSize(0.0, -7.0)
            shadow.shadowBlurRadius = 10.0
        } else {
            shadow.shadowOffset = NSMakeSize(0.0, -4.0)
            shadow.shadowBlurRadius = 5.0
        }
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.set()

        let bgID = plugin.isRecording ? 24 : 25
        if let bgImg = plugin.image(withID: bgID) {
            bgImg.draw(at: plugin.position(withID: 0), from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        // 2. Draw Left Control Button (ID 1 at (25, 27))
        let ctrlImgID = currentControlButtonImageID()
        if let ctrlImg = plugin.image(withID: ctrlImgID) {
            ctrlImg.draw(at: plugin.position(withID: 1), from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // 3. Draw Top Half-Circle Popup Button (ID 2 at (255, 36): images 18=normal, 20=hover, 19=down)
        let popImgID = (pressedElement == 2) ? 19 : ((hoverElement == 2) ? 20 : 18)
        if let popImg = plugin.image(withID: popImgID) {
            popImg.draw(at: plugin.position(withID: 2), from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // 4. Draw Bottom Half-Circle Volume Button (ID 3 at (255, 28): images 21=normal, 23=hover, 22=down)
        let volImgID = (pressedElement == 3) ? 22 : ((hoverElement == 3) ? 23 : 21)
        if let volImg = plugin.image(withID: volImgID) {
            volImg.draw(at: plugin.position(withID: 3), from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // 5. Draw Buffer Percentage (FSPercent at ID 5 (47, 24, 40, 22)) if visible
        if !plugin.hidePercent {
            let pctStr = "\(plugin.p100)%"
            let attrs = plugin.style(withID: 1)
            let pos = plugin.position(withID: 5)
            let box = plugin.size(withID: 5)
            let sz = (pctStr as NSString).size(withAttributes: attrs)
            let y = floor(pos.y + (box.height - sz.height) * 0.5)
            let r = NSMakeRect(pos.x, y, box.width, ceil(sz.height))
            (pctStr as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
        }

        // 6. Draw Status / Stream Text (FSText at ID 4)
        fsText.draw()
    }
}

// MARK: - FSWindows (Borderless Skinned Window, matches 0x100001aa0)
final class FSWindows: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Main Application Controller (MainManager)
final class FStreamController: NSObject, NSApplicationDelegate, NSMenuDelegate, FSSoundDelegate {
    let defaultStreamURL = "https://sky24.inlive.co.kr/live/listen.pls"
    let defaultStationName = "Sky24 음악방송"

    var plugin: MyPlugin!
    var fsText: FSText!
    var window: FSWindows!
    var fsView: FSView!
    let soundEngine = FSSoundEngine()

    var stations: [RadioStation] = []
    var selectedStationIndex: Int = 0
    var streamState: StreamState = .disconnected
    var volume: Float = 0.85
    // 0 = Dock icon only, 1 = Top menu bar icon only
    private var iconDisplayMode: Int = 0
    private var animTimer: Timer?
    private var reconnectTimer: Timer?
    private var shouldAutoResume: Bool = false
    private var isSystemSleeping: Bool = false
    private var watchdogTickCounter: Int = 0
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadPreferences()

        let savedStyle = UserDefaults.standard.object(forKey: "skinStyle") as? Int ?? 1
        plugin = MyPlugin(style: savedStyle)
        fsText = FSText(plugin: plugin)
        soundEngine.delegate = self
        soundEngine.volume = volume

        let winRect = NSMakeRect(200, 500, FSView.winWidth, FSView.winHeight)
        window = FSWindows(
            contentRect: winRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        // Disable macOS WindowServer's rim outline shadow; FSView draws the exact original NSShadow directly!
        window.hasShadow = false
        window.canHide = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false

        positionWindowSafely()

        if UserDefaults.standard.bool(forKey: "prefsMiscWinAbove") {
            window.level = .floating
        }

        fsView = FSView(frame: NSMakeRect(0, 0, FSView.winWidth, FSView.winHeight), plugin: plugin, fsText: fsText)
        fsView.controller = self
        window.contentView = fsView
        window.makeFirstResponder(fsView)
        window.makeKeyAndOrderFront(nil)

        setupMainMenu()
        applyIconDisplayMode()
        setupSleepWakeObservers()

        animTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
        RunLoop.main.add(animTimer!, forMode: .common)

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fsView.needsDisplay = true
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fsView.needsDisplay = true
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.positionWindowSafely()
            self?.fsView.needsDisplay = true
        }

        if CommandLine.arguments.contains("--autoplay") || UserDefaults.standard.bool(forKey: "autoPlayOnLaunch") {
            startPlaying()
        }
    }

    private func setupSleepWakeObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isSystemSleeping = true
            self.watchdogTickCounter = 0
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = nil
            if self.shouldAutoResume {
                // Cleanly close socket & CoreAudio on netQueue before sleep while keeping shouldAutoResume = true
                self.soundEngine.stop()
            }
        }
        wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.isSystemSleeping = false
            self.watchdogTickCounter = 0
            self.soundEngine.lastDataReceivedAt = Date()
            guard self.shouldAutoResume else { return }
            self.fsText.setSingleStatus("연결중")
            self.fsView.needsDisplay = true
            self.scheduleAutoReconnect(after: 2.5)
        }
    }

    private func scheduleAutoReconnect(after delay: TimeInterval) {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, self.shouldAutoResume, !self.isSystemSleeping else { return }
            self.startPlaying()
        }
    }

    private func defaultTopLeftOrigin() -> NSPoint {
        let winSize = NSSize(width: FSView.winWidth, height: FSView.winHeight)
        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        let vis = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = vis.minX + 24.0
        let y = max(vis.minY, vis.maxY - winSize.height - 24.0)
        return NSPoint(x: x, y: y)
    }

    private func positionWindowSafely(forceDefaultTopLeft: Bool = false) {
        let winSize = NSSize(width: FSView.winWidth, height: FSView.winHeight)
        let defOrigin = defaultTopLeftOrigin()

        if forceDefaultTopLeft {
            window.setFrameOrigin(defOrigin)
            UserDefaults.standard.set(Double(defOrigin.x), forKey: "winCoordX")
            UserDefaults.standard.set(Double(defOrigin.y), forKey: "winCoordY")
            return
        }

        guard let savedX = UserDefaults.standard.object(forKey: "winCoordX") as? Double,
              let savedY = UserDefaults.standard.object(forKey: "winCoordY") as? Double else {
            // 최초 실행: 화면 좌측 상단에 배치
            window.setFrameOrigin(defOrigin)
            UserDefaults.standard.set(Double(defOrigin.x), forKey: "winCoordX")
            UserDefaults.standard.set(Double(defOrigin.y), forKey: "winCoordY")
            return
        }

        let candidateOrigin = NSPoint(x: savedX, y: savedY)
        let candidateRect = NSRect(origin: candidateOrigin, size: winSize)

        // 현재 연결된 화면들 중 최소 60x30 이상 교차하여 실제로 보이는지 검사
        var isVisibleOnAnyScreen = false
        for screen in NSScreen.screens {
            let intersection = candidateRect.intersection(screen.visibleFrame)
            if !intersection.isNull && intersection.width >= 60.0 && intersection.height >= 30.0 {
                isVisibleOnAnyScreen = true
                break
            }
        }

        if isVisibleOnAnyScreen {
            window.setFrameOrigin(candidateOrigin)
        } else {
            // 외장 모니터 분리 등으로 화면 밖으로 벗어난 경우: 현재 활성 화면의 좌측 상단으로 이동
            window.setFrameOrigin(defOrigin)
            UserDefaults.standard.set(Double(defOrigin.x), forKey: "winCoordX")
            UserDefaults.standard.set(Double(defOrigin.y), forKey: "winCoordY")
        }
    }

    @objc func resetWindowPositionToTopLeft() {
        positionWindowSafely(forceDefaultTopLeft: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        fsView.needsDisplay = true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        positionWindowSafely()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first {
            openFile(at: first)
        }
    }

    private func loadPreferences() {
        if let savedVol = UserDefaults.standard.object(forKey: "prefAudioVolume") as? Float {
            volume = max(0.0, min(1.0, savedVol))
        }
        iconDisplayMode = UserDefaults.standard.object(forKey: "iconDisplayMode") as? Int ?? 0
        if let data = UserDefaults.standard.data(forKey: "savedStations"),
           let decoded = try? JSONDecoder().decode([RadioStation].self, from: data),
           !decoded.isEmpty {
            stations = decoded
        } else {
            stations = [
                RadioStation(name: defaultStationName, url: defaultStreamURL)
            ]
            saveStations()
        }
        selectedStationIndex = min(
            max(0, UserDefaults.standard.integer(forKey: "selectedStationIndex")),
            stations.count - 1
        )
    }

    private func saveStations() {
        if let data = try? JSONEncoder().encode(stations) {
            UserDefaults.standard.set(data, forKey: "savedStations")
        }
    }

    @objc func togglePlayStop() {
        switch streamState {
        case .disconnected:
            startPlaying()
        case .connecting, .buffering:
            stopPlaying()
        case .playing:
            shouldAutoResume = false
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            soundEngine.togglePause()
        case .paused:
            shouldAutoResume = true
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            soundEngine.togglePause()
        }
    }

    @objc func startPlaying() {
        guard !stations.isEmpty else { return }
        shouldAutoResume = true
        isSystemSleeping = false
        watchdogTickCounter = 0
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        let idx = min(max(0, selectedStationIndex), stations.count - 1)
        let st = stations[idx]
        soundEngine.play(urlString: st.url, stationName: st.name)
    }

    @objc func stopPlaying() {
        shouldAutoResume = false
        watchdogTickCounter = 0
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        soundEngine.stop()
    }

    func playCustomURL(_ url: String, name: String) {
        if let existing = stations.firstIndex(where: { $0.url.caseInsensitiveCompare(url) == .orderedSame }) {
            selectedStationIndex = existing
        } else {
            stations.insert(RadioStation(name: name, url: url), at: 0)
            selectedStationIndex = 0
            saveStations()
        }
        UserDefaults.standard.set(selectedStationIndex, forKey: "selectedStationIndex")
        startPlaying()
    }

    func openFile(at path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = FSSoundEngine.decodeString(from: data) else { return }
        let fileTitle = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if let parsed = FSPlaylistParser.parsePlaylistContent(text, fallbackName: fileTitle) {
            playCustomURL(parsed.url, name: parsed.title ?? fileTitle)
        }
    }

    func setVolume(_ newVolume: Float) {
        volume = max(0.0, min(1.0, newVolume))
        soundEngine.volume = volume
        UserDefaults.standard.set(volume, forKey: "prefAudioVolume")
        let pct = Int(round(volume * 100.0))
        fsText.showPowerString("소리크기 : \(pct)%")
        fsView.needsDisplay = true
    }

    private func tickAnimation() {
        var needsRedraw = false
        switch streamState {
        case .connecting, .buffering:
            plugin.stepWaveAnimation()
            needsRedraw = true
        default:
            break
        }
        if fsText.stepAnimation() {
            needsRedraw = true
        }
        if needsRedraw {
            fsView.needsDisplay = true
        }

        // Stream stall watchdog: check every 2 seconds (40 ticks) if audio stream silently stalled
        watchdogTickCounter += 1
        if watchdogTickCounter >= 40 {
            watchdogTickCounter = 0
            if shouldAutoResume && !isSystemSleeping {
                let elapsed = Date().timeIntervalSince(soundEngine.lastDataReceivedAt)
                switch streamState {
                case .connecting:
                    if elapsed > 18.0 {
                        startPlaying()
                    }
                case .playing, .buffering:
                    if elapsed > 12.0 {
                        startPlaying()
                    }
                default:
                    break
                }
            }
        }
    }

    func soundStateDidChange(_ state: StreamState) {
        self.streamState = state
        switch state {
        case .disconnected:
            plugin.hidePercent = true
            plugin.doSwitchPercent = true
            if shouldAutoResume {
                fsText.setSingleStatus("연결중")
                if !isSystemSleeping {
                    scheduleAutoReconnect(after: 2.5)
                }
            } else {
                fsText.setSingleStatus("끊어짐")
            }
        case .connecting:
            plugin.hidePercent = true
            plugin.doSwitchPercent = true
            fsText.setSingleStatus("연결중")
        case .buffering(let pct):
            plugin.setBufferPercent(pct)
            fsText.setSingleStatus("버퍼링중")
        case .playing:
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            let idx = min(max(0, selectedStationIndex), stations.count - 1)
            let fallbackName = stations.isEmpty ? defaultStationName : stations[idx].name
            let stName = soundEngine.currentStationName.isEmpty ? fallbackName : soundEngine.currentStationName
            fsText.setPlayingInfo(station: stName, title: soundEngine.currentStreamTitle, bitrate: nil)
        case .paused:
            fsText.setSingleStatus("상태: 잠시멈춤")
        }
        fsView.needsDisplay = true
    }

    func soundMetadataDidChange(station: String?, title: String?, bitrate: String?, genre: String?) {
        if case .playing = streamState {
            let stName = (station?.isEmpty == false) ? station : soundEngine.currentStationName
            let sTitle = (title?.isEmpty == false) ? title : soundEngine.currentStreamTitle
            fsText.setPlayingInfo(station: stName, title: sTitle, bitrate: nil)
            fsView.needsDisplay = true
        }
    }

    func soundErrorDidOccur(_ message: String) {
        fsText.setSingleStatus("끊어짐")
        fsView.needsDisplay = true
    }

    func showVolumePopup(with event: NSEvent, in view: NSView) {
        let menu = NSMenu(title: "Volume")
        let item = NSMenuItem(title: "slider", action: nil, keyEquivalent: "")
        let container = NSView(frame: NSMakeRect(0, 0, 116, 26))
        let slider = NSSlider(frame: NSMakeRect(8, 3, 100, 20))
        slider.minValue = 0.0
        slider.maxValue = 100.0
        slider.doubleValue = Double(volume * 100.0)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeSliderChanged(_:))
        container.addSubview(slider)
        item.view = container
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        setVolume(Float(sender.doubleValue / 100.0))
    }

    func showStationsPopup(with event: NSEvent, in view: NSView) {
        let menu = buildFStreamMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func buildFStreamMenu() -> NSMenu {
        let menu = NSMenu(title: "FStream")
        menu.delegate = self
        populateFStreamMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateFStreamMenu(menu)
    }

    private func populateFStreamMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        switch streamState {
        case .disconnected:
            let playItem = NSMenuItem(title: "방송 듣기", action: #selector(startPlaying), keyEquivalent: " ")
            playItem.target = self
            menu.addItem(playItem)
        case .connecting, .buffering:
            let stopItem = NSMenuItem(title: "그만 듣기", action: #selector(stopPlaying), keyEquivalent: ".")
            stopItem.target = self
            menu.addItem(stopItem)
        case .playing:
            let pauseItem = NSMenuItem(title: "잠시 멈추기", action: #selector(togglePlayStop), keyEquivalent: " ")
            pauseItem.target = self
            menu.addItem(pauseItem)
            let stopItem = NSMenuItem(title: "그만 듣기", action: #selector(stopPlaying), keyEquivalent: ".")
            stopItem.target = self
            menu.addItem(stopItem)
        case .paused:
            let resumeItem = NSMenuItem(title: "다시 듣기", action: #selector(togglePlayStop), keyEquivalent: " ")
            resumeItem.target = self
            menu.addItem(resumeItem)
            let stopItem = NSMenuItem(title: "그만 듣기", action: #selector(stopPlaying), keyEquivalent: ".")
            stopItem.target = self
            menu.addItem(stopItem)
        }

        if iconDisplayMode == 1 {
            let showWinItem = NSMenuItem(title: "메인 윈도우 앞으로 가져오기", action: #selector(bringMainWindowToFront), keyEquivalent: "")
            showWinItem.target = self
            menu.addItem(showWinItem)
        }

        menu.addItem(.separator())

        let quickOpenItem = NSMenuItem(title: "간단히 연결하기...", action: #selector(showQuickOpenDialog), keyEquivalent: "o")
        quickOpenItem.target = self
        menu.addItem(quickOpenItem)

        let addStationItem = NSMenuItem(title: "즐겨찾기 추가...", action: #selector(showAddStationDialog), keyEquivalent: "n")
        addStationItem.target = self
        menu.addItem(addStationItem)

        let skinMenu = NSMenu(title: "모양새 및 설정")
        let blueItem = NSMenuItem(title: "FStream > Blue", action: #selector(selectBlueSkin), keyEquivalent: "")
        blueItem.target = self
        blueItem.state = (plugin.style == 1) ? .on : .off
        skinMenu.addItem(blueItem)

        let yellowItem = NSMenuItem(title: "FStream > Yellow", action: #selector(selectYellowSkin), keyEquivalent: "")
        yellowItem.target = self
        yellowItem.state = (plugin.style == 0) ? .on : .off
        skinMenu.addItem(yellowItem)

        skinMenu.addItem(.separator())

        let dockOnlyItem = NSMenuItem(title: "독(Dock)에만 아이콘 표시", action: #selector(selectDockOnlyMode), keyEquivalent: "")
        dockOnlyItem.target = self
        dockOnlyItem.state = (iconDisplayMode == 0) ? .on : .off
        skinMenu.addItem(dockOnlyItem)

        let menuBarOnlyItem = NSMenuItem(title: "상단 메뉴바에만 아이콘 표시", action: #selector(selectMenuBarOnlyMode), keyEquivalent: "")
        menuBarOnlyItem.target = self
        menuBarOnlyItem.state = (iconDisplayMode == 1) ? .on : .off
        skinMenu.addItem(menuBarOnlyItem)

        skinMenu.addItem(.separator())

        let alwaysOnTopItem = NSMenuItem(title: "항상 위에 표시", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        alwaysOnTopItem.target = self
        alwaysOnTopItem.state = (window.level == .floating) ? .on : .off
        skinMenu.addItem(alwaysOnTopItem)

        let autoPlayItem = NSMenuItem(title: "시작 시 자동 재생", action: #selector(toggleAutoPlay), keyEquivalent: "")
        autoPlayItem.target = self
        autoPlayItem.state = UserDefaults.standard.bool(forKey: "autoPlayOnLaunch") ? .on : .off
        skinMenu.addItem(autoPlayItem)

        skinMenu.addItem(.separator())

        let resetPosItem = NSMenuItem(title: "창 위치를 화면 좌측 상단으로 이동", action: #selector(resetWindowPositionToTopLeft), keyEquivalent: "")
        resetPosItem.target = self
        skinMenu.addItem(resetPosItem)

        let skinParent = NSMenuItem(title: "모양새 및 설정", action: nil, keyEquivalent: "")
        skinParent.submenu = skinMenu
        menu.addItem(skinParent)

        if !stations.isEmpty {
            menu.addItem(.separator())
            for (idx, st) in stations.enumerated() {
                let item = NSMenuItem(title: st.name, action: #selector(selectStationFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = idx
                item.state = (idx == selectedStationIndex) ? .on : .off
                item.toolTip = st.url
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "FStream 끝내기", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    @objc private func bringMainWindowToFront() {
        positionWindowSafely()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func selectDockOnlyMode() {
        guard iconDisplayMode != 0 else { return }
        iconDisplayMode = 0
        UserDefaults.standard.set(0, forKey: "iconDisplayMode")
        applyIconDisplayMode()
    }

    @objc private func selectMenuBarOnlyMode() {
        guard iconDisplayMode != 1 else { return }
        iconDisplayMode = 1
        UserDefaults.standard.set(1, forKey: "iconDisplayMode")
        applyIconDisplayMode()
    }

    private func applyIconDisplayMode() {
        if iconDisplayMode == 1 {
            // Top menu bar icon only (hide Dock icon)
            if statusItem == nil {
                setupStatusBarItem()
            }
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.window.orderFrontRegardless()
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            // Dock icon only (remove Top menu bar icon)
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            NSApp.setActivationPolicy(.regular)
            setupMainMenu()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @objc private func selectStationFromMenu(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < stations.count else { return }
        selectedStationIndex = idx
        UserDefaults.standard.set(idx, forKey: "selectedStationIndex")
        startPlaying()
    }

    @objc private func selectBlueSkin() {
        plugin.setStyle(1)
        UserDefaults.standard.set(1, forKey: "skinStyle")
        fsView.needsDisplay = true
    }

    @objc private func selectYellowSkin() {
        plugin.setStyle(0)
        UserDefaults.standard.set(0, forKey: "skinStyle")
        fsView.needsDisplay = true
    }

    @objc private func toggleAlwaysOnTop() {
        let newState = (window.level != .floating)
        window.level = newState ? .floating : .normal
        UserDefaults.standard.set(newState, forKey: "prefsMiscWinAbove")
    }

    @objc private func toggleAutoPlay() {
        let cur = UserDefaults.standard.bool(forKey: "autoPlayOnLaunch")
        UserDefaults.standard.set(!cur, forKey: "autoPlayOnLaunch")
    }

    @objc func showQuickOpenDialog() {
        let alert = NSAlert()
        alert.messageText = "간단히 연결하기"
        alert.informativeText = "재생할 스트림 또는 플레이리스트(.pls, .m3u) URL을 입력하세요:"
        alert.addButton(withTitle: "연결")
        alert.addButton(withTitle: "취소")

        let input = NSTextField(frame: NSMakeRect(0, 0, 340, 24))
        let curURL = stations.indices.contains(selectedStationIndex) ? stations[selectedStationIndex].url : defaultStreamURL
        input.stringValue = curURL
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                let name = (url == defaultStreamURL) ? defaultStationName : (URL(string: url)?.host ?? "WebRadio")
                playCustomURL(url, name: name)
            }
        }
    }

    @objc func showAddStationDialog() {
        let alert = NSAlert()
        alert.messageText = "즐겨찾기 채널 추가"
        alert.informativeText = "채널 이름과 스트림 URL(.pls, .m3u 등)을 입력하세요:"
        alert.addButton(withTitle: "추가 및 재생")
        alert.addButton(withTitle: "취소")

        let container = NSView(frame: NSMakeRect(0, 0, 340, 58))
        let nameField = NSTextField(frame: NSMakeRect(0, 32, 340, 24))
        nameField.placeholderString = "채널 이름 (예: Sky24 음악방송)"
        nameField.stringValue = defaultStationName
        let urlField = NSTextField(frame: NSMakeRect(0, 0, 340, 24))
        urlField.placeholderString = "스트림 URL"
        urlField.stringValue = defaultStreamURL
        container.addSubview(nameField)
        container.addSubview(urlField)
        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                playCustomURL(url, name: name.isEmpty ? "채널" : name)
            }
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "FStream에 관하여", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quickItem = NSMenuItem(title: "간단히 연결하기...", action: #selector(showQuickOpenDialog), keyEquivalent: "o")
        quickItem.target = self
        appMenu.addItem(quickItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "FStream 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "FStream 끝내기", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let controlMenuItem = NSMenuItem(title: "제어", action: nil, keyEquivalent: "")
        controlMenuItem.submenu = buildFStreamMenu()
        mainMenu.addItem(controlMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            if let imgPath = Bundle.main.path(forResource: "menuStatus", ofType: "png"),
               let img = NSImage(contentsOfFile: imgPath) {
                btn.image = img
            } else {
                btn.title = "♫"
            }
        }
        item.menu = buildFStreamMenu()
        self.statusItem = item
    }
}

// MARK: - Application Entry Point
let app = NSApplication.shared
let savedIconMode = UserDefaults.standard.object(forKey: "iconDisplayMode") as? Int ?? 0
app.setActivationPolicy(savedIconMode == 1 ? .accessory : .regular)
let delegate = FStreamController()
app.delegate = delegate
app.run()
