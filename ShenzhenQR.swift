// ShenzhenQR: point any camera at a QR code (or any barcode / 2D code) and act on it.
// One file, AppKit + AVFoundation + Vision, no dependencies. Built by build.sh.
import AppKit
import AVFoundation
import Vision
import VisionKit

// MARK: - What a code holds, and what can be done with it

struct CodeAction {
    let title: String
    let run: () -> String?   // returns a status line, or nil
}

enum Payload {
    static func unescape(_ s: Substring) -> String {
        var out = "", esc = false
        for c in s { if esc { out.append(c); esc = false } else if c == "\\" { esc = true } else { out.append(c) } }
        return out
    }

    /// "KEY:value;KEY:value;" fields as in WIFI: and MECARD:, honouring \; \: \, \\ escapes.
    static func fields(_ body: Substring) -> [(String, String)] {
        var result: [(String, String)] = [], cur = "", esc = false
        var parts: [String] = []
        for c in body {
            if esc { cur.append("\\"); cur.append(c); esc = false }
            else if c == "\\" { esc = true }
            else if c == ";" { parts.append(cur); cur = "" }
            else { cur.append(c) }
        }
        if !cur.isEmpty { parts.append(cur) }
        for p in parts {
            guard let i = p.firstIndex(of: ":") else { continue }
            result.append((p[..<i].uppercased(), unescape(p[p.index(after: i)...])))
        }
        return result
    }

    static func kind(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines), u = t.uppercased()
        if u.hasPrefix("WIFI:") { return "Wi-Fi network" }
        if u.hasPrefix("BEGIN:VCARD") || u.hasPrefix("MECARD:") { return "Contact" }
        if u.hasPrefix("BEGIN:VEVENT") || u.hasPrefix("BEGIN:VCALENDAR") { return "Event" }
        if u.hasPrefix("MAILTO:") || u.hasPrefix("MATMSG:") { return "Email" }
        if u.hasPrefix("TEL:") { return "Phone number" }
        if u.hasPrefix("SMSTO:") || u.hasPrefix("SMS:") { return "Text message" }
        if u.hasPrefix("GEO:") { return "Location" }
        if webURL(t) != nil { return "Web address" }
        if otherURL(t) != nil { return "Link" }
        return "Text"
    }

    static func webURL(_ t: String) -> URL? {
        let l = t.lowercased()
        if l.hasPrefix("http://") || l.hasPrefix("https://") { return URL(string: t) }
        // A bare address such as www.example.com or example.com/page
        if !t.contains(" "), !t.contains("\n"), !t.contains("@"),
           t.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://" + t)
        }
        return nil
    }

    static func otherURL(_ t: String) -> URL? {
        guard !t.contains(" "), !t.contains("\n"),
              t.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:\S+$"#, options: .regularExpression) != nil,
              let url = URL(string: t), NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { return nil }
        return url
    }

    static func actions(_ text: String) -> [CodeAction] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines), u = t.uppercased()
        let open: (URL) -> String? = { NSWorkspace.shared.open($0); return nil }
        if u.hasPrefix("WIFI:") {
            let f = Dictionary(fields(t.dropFirst(5)), uniquingKeysWith: { a, _ in a })
            guard let ssid = f["S"], !ssid.isEmpty else { return [] }
            var list = [CodeAction(title: "Join “\(ssid)”") { joinWiFi(ssid: ssid, password: f["P"] ?? "") }]
            if let p = f["P"], !p.isEmpty {
                list.append(CodeAction(title: "Copy Password") { copy(p); return "Password copied" })
            }
            return list
        }
        if u.hasPrefix("BEGIN:VCARD") || u.hasPrefix("MECARD:") {
            let vcard = u.hasPrefix("MECARD:") ? mecardToVCard(t) : t
            return [CodeAction(title: "Add to Contacts") { openTemp(vcard, name: "Contact.vcf", app: "com.apple.AddressBook") }]
        }
        if u.hasPrefix("BEGIN:VEVENT") || u.hasPrefix("BEGIN:VCALENDAR") {
            let ics = u.hasPrefix("BEGIN:VEVENT") ? "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n\(t)\r\nEND:VCALENDAR" : t
            return [CodeAction(title: "Add to Calendar") { openTemp(ics, name: "Event.ics", app: "com.apple.iCal") }]
        }
        if u.hasPrefix("MATMSG:") {
            let f = Dictionary(fields(t.dropFirst(7)), uniquingKeysWith: { a, _ in a })
            var c = URLComponents(); c.scheme = "mailto"; c.path = f["TO"] ?? ""
            c.queryItems = [URLQueryItem(name: "subject", value: f["SUB"]), URLQueryItem(name: "body", value: f["BODY"])]
                .filter { $0.value?.isEmpty == false }
            if let url = c.url { return [CodeAction(title: "Write Email") { open(url) }] }
        }
        if u.hasPrefix("SMSTO:") {
            let rest = t.dropFirst(6), parts = rest.split(separator: ":", maxSplits: 1)
            var c = URLComponents(); c.scheme = "sms"; c.path = String(parts.first ?? "")
            if parts.count > 1 { c.queryItems = [URLQueryItem(name: "body", value: String(parts[1]))] }
            if let url = c.url { return [CodeAction(title: "Send Message") { open(url) }] }
        }
        if u.hasPrefix("GEO:") {
            let coords = t.dropFirst(4).split(separator: "?").first.map(String.init) ?? ""
            let ll = coords.split(separator: ",").prefix(2).joined(separator: ",")
            if let url = URL(string: "https://maps.apple.com/?ll=\(ll)&q=\(ll)") {
                return [CodeAction(title: "Show in Maps") { open(url) }]
            }
        }
        if let url = webURL(t) { return [CodeAction(title: "Open in Browser") { open(url) }] }
        if let url = otherURL(t) {
            let title: String
            switch url.scheme?.lowercased() {
            case "mailto": title = "Write Email"
            case "tel": title = "Call"
            case "sms": title = "Send Message"
            case "facetime", "facetime-audio": title = "FaceTime"
            default:
                let app = NSWorkspace.shared.urlForApplication(toOpen: url)
                    .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                title = app.map { "Open in \($0)" } ?? "Open"
            }
            return [CodeAction(title: title) { open(url) }]
        }
        return []
    }

    static func mecardToVCard(_ t: String) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        for (k, v) in fields(t.dropFirst(7)) {
            switch k {
            case "N":
                let p = v.split(separator: ",", maxSplits: 1).map(String.init)
                lines.append("N:\(p[0]);\(p.count > 1 ? p[1] : "");;;")
                lines.append("FN:\(p.count > 1 ? p[1] + " " + p[0] : p[0])")
            case "TEL": lines.append("TEL:\(v)")
            case "EMAIL": lines.append("EMAIL:\(v)")
            case "URL": lines.append("URL:\(v)")
            case "ORG": lines.append("ORG:\(v)")
            case "NOTE": lines.append("NOTE:\(v)")
            case "ADR": lines.append("ADR:;;\(v);;;;")
            case "BDAY": lines.append("BDAY:\(v)")
            default: break
            }
        }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n")
    }

    static func openTemp(_ text: String, name: String, app: String) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        do { try text.write(to: file, atomically: true, encoding: .utf8) } catch { return "Couldn’t save it: \(error.localizedDescription)" }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
        return nil
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func wifiDevice() -> String? {
        let out = run("/usr/sbin/networksetup", ["-listallhardwareports"]).output
        var takeNext = false
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") { takeNext = line.contains("Wi-Fi") || line.contains("AirPort") }
            else if takeNext, line.hasPrefix("Device:") { return line.dropFirst(7).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    static func joinWiFiNow(ssid: String, password: String) -> String {
        guard let dev = wifiDevice() else { return "This Mac has no Wi-Fi" }
        var args = ["-setairportnetwork", dev, ssid]
        if !password.isEmpty { args.append(password) }
        let r = run("/usr/sbin/networksetup", args)
        let said = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && said.isEmpty ? "Joined “\(ssid)”" : "Couldn’t join “\(ssid)”: \(said.isEmpty ? "error \(r.status)" : said)"
    }

    static func joinWiFi(ssid: String, password: String) -> String? {
        if CLI.active { return joinWiFiNow(ssid: ssid, password: password) }
        DispatchQueue.global().async {
            let message = joinWiFiNow(ssid: ssid, password: password)
            DispatchQueue.main.async { AppDelegate.shared?.setStatus(message) }
        }
        return "Joining “\(ssid)”…"
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

func symbologyName(_ s: VNBarcodeSymbology) -> String {
    let names: [VNBarcodeSymbology: String] = [
        .qr: "QR code", .microQR: "Micro QR code", .aztec: "Aztec code", .pdf417: "PDF417", .microPDF417: "MicroPDF417",
        .dataMatrix: "Data Matrix", .ean13: "EAN-13", .ean8: "EAN-8", .upce: "UPC-E", .code128: "Code 128",
        .code39: "Code 39", .code93: "Code 93", .itf14: "ITF-14", .i2of5: "Interleaved 2 of 5", .codabar: "Codabar",
        .gs1DataBar: "GS1 DataBar", .gs1DataBarExpanded: "GS1 DataBar Expanded", .gs1DataBarLimited: "GS1 DataBar Limited",
    ]
    return names[s] ?? s.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
}

/// The short name the command line uses for a code type: qr, ean13, datamatrix…
func symbologyKey(_ s: VNBarcodeSymbology) -> String {
    s.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "").lowercased()
}

/// One code found in a picture or a camera frame. Positions are fractions of the picture, from its top-left corner.
struct Detection {
    let text: String
    let symbology: VNBarcodeSymbology
    let corners: [CGPoint]          // top-left, top-right, bottom-right, bottom-left
    let confidence: Float
    var box: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// The middle of the picture, 1/zoom of its width and height, as fractions from the top-left corner.
func zoomRegion(_ zoom: Double) -> CGRect? {
    guard zoom > 1.001 else { return nil }
    let side = 1 / zoom
    return CGRect(x: (1 - side) / 2, y: (1 - side) / 2, width: side, height: side)
}

/// Every code Vision reads in the picture, biggest first. `types` limits the code types (nil: all of them).
/// `region` (fractions of the picture from its top-left corner) reads only that part, closer up: smaller codes are
/// found there. Positions always come back as fractions of the whole picture.
func detect(_ handler: VNImageRequestHandler, types: [VNBarcodeSymbology]? = nil, region: CGRect? = nil) -> [Detection] {
    let request = VNDetectBarcodesRequest()
    if let types { request.symbologies = types }
    let roi = region?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    guard roi.width > 0, roi.height > 0 else { return [] }
    // Vision counts from the bottom-left corner, and answers within the region.
    request.regionOfInterest = CGRect(x: roi.minX, y: 1 - roi.maxY, width: roi.width, height: roi.height)
    do { try handler.perform([request]) } catch { return [] }
    var seen = Set<String>()
    let top = { (p: CGPoint) in CGPoint(x: roi.minX + p.x * roi.width, y: roi.minY + (1 - p.y) * roi.height) }
    return (request.results ?? []).compactMap { o -> Detection? in
        guard let text = o.payloadStringValue, !text.isEmpty else { return nil }
        let d = Detection(text: text, symbology: o.symbology,
                          corners: [top(o.topLeft), top(o.topRight), top(o.bottomRight), top(o.bottomLeft)],
                          confidence: o.confidence)
        // The same code can come back more than once; keep one per place.
        let key = "\(text)|\(Int(d.box.midX * 40))|\(Int(d.box.midY * 40))"
        return seen.insert(key).inserted ? d : nil
    }.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
}

/// A line of text read in a picture. Positions as in Detection.
struct TextLine {
    let text: String
    let confidence: Float
    let corners: [CGPoint]
}

/// The text Vision reads in the picture (or in `region` of it), line by line in reading order. Languages are found
/// by themselves (Chinese, English and the others Vision knows).
func recognizeText(_ handler: VNImageRequestHandler, region: CGRect? = nil) -> [TextLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let roi = region?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    guard roi.width > 0, roi.height > 0 else { return [] }
    request.regionOfInterest = CGRect(x: roi.minX, y: 1 - roi.maxY, width: roi.width, height: roi.height)
    do { try handler.perform([request]) } catch { return [] }
    let top = { (p: CGPoint) in CGPoint(x: roi.minX + p.x * roi.width, y: roi.minY + (1 - p.y) * roi.height) }
    return (request.results ?? []).compactMap { o in
        guard let best = o.topCandidates(1).first else { return nil }
        return TextLine(text: best.string, confidence: best.confidence,
                        corners: [top(o.topLeft), top(o.topRight), top(o.bottomRight), top(o.bottomLeft)])
    }
}

// MARK: - Settings

/// The app's bundle, also when the command line runs through a symlink (Bundle.main then knows no bundle).
let appBundle: Bundle = {
    if Bundle.main.bundleIdentifier != nil { return .main }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return .main }
    let exe = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    return Bundle(url: exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? .main
}()

enum Settings {
    /// The app's settings, shared with the command line.
    static let defaults: UserDefaults = Bundle.main.bundleIdentifier != nil ? .standard
        : UserDefaults(suiteName: appBundle.bundleIdentifier ?? "com.intuition.shenzhenqr") ?? .standard
    /// "auto", or a size such as "1920x1080". Older settings said 480p, 720p, 1080p or 4k.
    static var resolution: String {
        get { defaults.string(forKey: "resolution").flatMap { parseSize($0) != nil ? $0 : nil } ?? "auto" }
        set { defaults.set(newValue, forKey: "resolution") }
    }

    /// A size from "1920x1080", "1920×1080", "1920 x 1080" or 480p, 720p, 1080p, 4k; nil for "auto" or nonsense.
    static func parseSize(_ text: String) -> CGSize? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        let named: [String: CGSize] = ["480p": CGSize(width: 640, height: 480), "720p": CGSize(width: 1280, height: 720),
                                       "1080p": CGSize(width: 1920, height: 1080), "4k": CGSize(width: 3840, height: 2160)]
        if let n = named[t] { return n }
        let parts = t.split(whereSeparator: { $0 == "x" || $0 == "×" }).compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
    static func sizeText(_ s: CGSize) -> String { "\(Int(s.width)) × \(Int(s.height))" }

    /// The frame sizes a camera can give, biggest first.
    static func sizes(_ device: AVCaptureDevice) -> [CGSize] {
        var seen = Set<String>(), out: [CGSize] = []
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let size = CGSize(width: Int(d.width), height: Int(d.height))
            if seen.insert(sizeText(size)).inserted { out.append(size) }
        }
        return out.sorted { $0.width * $0.height > $1.width * $1.height }
    }

    /// The camera's format of that size with the highest frame rate.
    static func format(_ device: AVCaptureDevice, _ size: CGSize) -> AVCaptureDevice.Format? {
        device.formats.filter {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return Int(d.width) == Int(size.width) && Int(d.height) == Int(size.height)
        }.max { ($0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) < ($1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) }
    }
    static var maxCores: Int { max(4, ProcessInfo.processInfo.activeProcessorCount) }
    static var cores: Int {
        get { let v = defaults.integer(forKey: "cores"); return v > 0 ? min(v, maxCores) : 4 }
        set { defaults.set(newValue, forKey: "cores") }
    }
    static let maxZoom = 5.0
    /// The window's zoom into the middle of the camera picture (1 = none).
    static var zoom: Double {
        get { let z = defaults.double(forKey: "zoom"); return z >= 1 ? min(z, maxZoom) : 1 }
        set { defaults.set(min(max(newValue, 1), maxZoom), forKey: "zoom") }
    }
    static var camera: String? {
        get { defaults.string(forKey: "camera") }
        set { defaults.set(newValue, forKey: "camera") }
    }
}

// MARK: - Camera

final class Scanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "capture")
    private let workers = DispatchQueue(label: "decode", qos: .userInitiated, attributes: .concurrent)
    private var inFlight = 0, reportSize = true      // touched on `queue` only
    private var lastFrame: CVPixelBuffer?             // for a photo; touched on `queue` only
    var paused = false                                 // a photo is shown: read no codes
    var cores = Settings.cores                       // frames read at the same time
    /// The part of each frame to read, as fractions from its top-left corner (nil: all of it). Given the frame size.
    var region: ((CGSize) -> CGRect?)?
    var types: [VNBarcodeSymbology]?
    /// On the main queue: the codes in a frame (only frames that have some) and the frame's size in pixels.
    var onCodes: (([Detection], CGSize) -> Void)?
    /// On the main queue: the size of the frames, once after each change of camera or resolution.
    var onSize: ((CGSize) -> Void)?

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// `resolution`: "auto" or a size the camera has (Settings.sizes); another size counts as "auto".
    func use(_ device: AVCaptureDevice, resolution: String) {
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if session.outputs.isEmpty {
                let out = AVCaptureVideoDataOutput()
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
            }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
            session.sessionPreset = .high
            if let size = Settings.parseSize(resolution), let format = Settings.format(device, size),
               (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format          // the session follows the device's format from here
                device.unlockForConfiguration()
            }
            session.commitConfiguration()
            reportSize = true
            if !session.isRunning { session.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if reportSize { reportSize = false; DispatchQueue.main.async { self.onSize?(size) } }
        lastFrame = pixels
        guard !paused, inFlight < max(1, cores) else { return }   // a photo is shown, or every worker is busy
        inFlight += 1
        let types = self.types, part = region?(size)
        workers.async { [self] in
            let found = detect(VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]), types: types, region: part)
            queue.async { self.inFlight -= 1 }
            if !found.isEmpty { DispatchQueue.main.async { self.onCodes?(found, size) } }
        }
    }
}

extension Scanner {
    /// The latest camera frame as a picture, `region` of it only (fractions from the top-left corner).
    func photo(region: CGRect?) -> CGImage? { photo { _ in region }?.image }

    /// The same, with the region chosen from the frame's size; also returns the region and the frame size.
    func photo(region: (CGSize) -> CGRect?) -> (image: CGImage, region: CGRect?, size: CGSize)? {
        var frame: CVPixelBuffer?
        queue.sync { frame = lastFrame }
        guard let frame else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let part = region(size)
        return cgImage(CIImage(cvPixelBuffer: frame), region: part).map { ($0, part, size) }
    }
}

/// A picture, or the `region` of it (fractions from its top-left corner).
func cgImage(_ image: CIImage, region: CGRect?) -> CGImage? {
    var rect = image.extent
    if let r = region?.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), !r.isEmpty {
        rect = CGRect(x: rect.minX + r.minX * rect.width, y: rect.minY + (1 - r.maxY) * rect.height,
                      width: r.width * rect.width, height: r.height * rect.height).integral
    }
    return CIContext().createCGImage(image, from: rect)
}

/// Outlines each code where it was read, over the camera picture (or a still picture), shown at aspect fit.
final class MarkerView: NSView {
    var detections: [Detection] = [] { didSet { needsDisplay = true } }
    var selected: String? { didSet { needsDisplay = true } }
    var imageSize = CGSize(width: 16, height: 9)
    var mirrored = false
    var zoom = 1.0 { didSet { needsDisplay = true } }
    var onPick: ((Detection) -> Void)?
    var onDoubleClick: (() -> Void)?

    func fitRect() -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    func outline(_ d: Detection) -> NSBezierPath {
        let r = fitRect()
        let z = CGFloat(zoom), c = CGPoint(x: bounds.midX, y: bounds.midY)
        let points = d.corners.map { p in
            let q = CGPoint(x: r.minX + (mirrored ? 1 - p.x : p.x) * r.width, y: r.maxY - p.y * r.height)
            return CGPoint(x: c.x + (q.x - c.x) * z, y: c.y + (q.y - c.y) * z)   // zoomed about the middle
        }
        let path = NSBezierPath()
        path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }; path.close()
        // A barcode can come back as a thin line: give it some height.
        if path.bounds.height < 8 || path.bounds.width < 8 {
            return NSBezierPath(roundedRect: path.bounds.insetBy(dx: -6, dy: -6), xRadius: 4, yRadius: 4)
        }
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        for d in detections {
            let path = outline(d), chosen = d.text == selected
            NSColor.systemGreen.withAlphaComponent(chosen ? 0.22 : 0.12).setFill()
            path.fill()
            NSColor.systemGreen.setStroke()
            path.lineWidth = chosen ? 4 : 2
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        let p = convert(event.locationInWindow, from: nil)
        if let d = detections.first(where: { outline($0).contains(p) }) { onPick?(d) }
    }
}

final class PreviewView: NSView {
    let layerPreview: AVCaptureVideoPreviewLayer
    let markers = MarkerView()
    let zoomSlider = NSSlider(value: 1, minValue: 1, maxValue: Settings.maxZoom, target: nil, action: nil)
    let zoomLabel = NSTextField(labelWithString: "1×")
    let zoomBar = NSVisualEffectView()
    var stillImage: NSImageView?           // the README screenshot's picture, in place of the camera
    var zoom = 1.0 {
        didSet {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
            layerPreview.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
            CATransaction.commit()
            needsLayout = true
            markers.zoom = zoom
            zoomSlider.doubleValue = zoom
            zoomLabel.stringValue = String(format: zoom < 1.05 ? "1×" : "%.1f×", zoom)
        }
    }
    init(session: AVCaptureSession) {
        layerPreview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layerPreview.videoGravity = .resizeAspect
        layer?.addSublayer(layerPreview)
        markers.frame = bounds
        markers.autoresizingMask = [.width, .height]
        addSubview(markers)

        // The zoom control, at the bottom of the picture: − slider + and the factor.
        let minus = NSButton(title: "−", target: self, action: #selector(zoomOut))
        let plus = NSButton(title: "+", target: self, action: #selector(zoomIn))
        for b in [minus, plus] { b.isBordered = false; b.font = .systemFont(ofSize: 15, weight: .medium); b.contentTintColor = .white }
        zoomSlider.target = self; zoomSlider.action = #selector(slid)
        zoomSlider.controlSize = .small
        zoomSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        zoomLabel.textColor = .white
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let row = NSStackView(views: [minus, zoomSlider, plus, zoomLabel])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 8)
        zoomBar.material = .hudWindow; zoomBar.state = .active; zoomBar.blendingMode = .withinWindow
        zoomBar.appearance = NSAppearance(named: .darkAqua)
        zoomBar.wantsLayer = true; zoomBar.layer?.cornerRadius = 8
        zoomBar.toolTip = "Zoom into the middle: codes there are read closer up. Double-click the picture to zoom in or out."
        row.translatesAutoresizingMaskIntoConstraints = false
        zoomBar.addSubview(row)
        zoomBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomBar)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: zoomBar.topAnchor), row.bottomAnchor.constraint(equalTo: zoomBar.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: zoomBar.leadingAnchor), row.trailingAnchor.constraint(equalTo: zoomBar.trailingAnchor),
            zoomBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    var onZoom: ((Double) -> Void)?
    @objc func slid() { onZoom?((zoomSlider.doubleValue * 10).rounded() / 10) }
    @objc func zoomIn() { onZoom?(min(Settings.maxZoom, (zoom * 2 + 0.001).rounded(.down) / 2 + 0.5)) }
    @objc func zoomOut() { onZoom?(max(1, (zoom * 2 - 0.001).rounded(.up) / 2 - 0.5)) }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        // bounds and position, not frame: the layer is scaled for the zoom.
        layerPreview.bounds = CGRect(origin: .zero, size: bounds.size)
        layerPreview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        markers.frame = bounds
        stillImage?.frame = bounds.insetBy(dx: -bounds.width * (zoom - 1) / 2, dy: -bounds.height * (zoom - 1) / 2)
    }
}

// MARK: - Installing from the disk image

enum Installer {
    static let appName = "ShenzhenQR.app"

    /// Mounted ShenzhenQR disk images: the app and an Applications link at the root.
    static func installerVolumes() -> [URL] {
        let fm = FileManager.default
        return (fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).filter {
            $0.path.hasPrefix("/Volumes/")
                && fm.fileExists(atPath: $0.appendingPathComponent(appName).path)
                && (try? fm.destinationOfSymbolicLink(atPath: $0.appendingPathComponent("Applications").path)) == "/Applications"
        }
    }

    static func runningVolume() -> URL? {
        let bundle = Bundle.main.bundleURL.standardizedFileURL.path
        return installerVolumes().first { bundle.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Opened straight from the disk image: offer to copy it to Applications, open that copy and quit.
    /// Returns true when this instance is quitting.
    static func offerMove() -> Bool {
        guard runningVolume() != nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Move ShenzhenQR to Applications?"
        alert.informativeText = "ShenzhenQR is running from its disk image. Once it’s in Applications, the disk image is ejected."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let fm = FileManager.default, target = URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
        do {
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: target)
        } catch {
            let failed = NSAlert()
            failed.messageText = "ShenzhenQR couldn’t be moved to Applications"
            failed.informativeText = "Drag it onto the Applications folder instead. (\(error.localizedDescription))"
            failed.runModal()
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Running from Applications: eject any ShenzhenQR disk image still mounted, which also closes its Finder window.
    /// Retries for a few seconds, while a copy that was running from it quits.
    static func ejectInstallerDisk() {
        guard runningVolume() == nil else { return }
        let volumes = installerVolumes()
        guard !volumes.isEmpty else { return }
        DispatchQueue.global().async {
            for volume in volumes {
                for _ in 0..<10 {
                    if (try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)) != nil { break }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
    }
}

// MARK: - Window

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    static weak var shared: AppDelegate?
    let scanner = Scanner()
    var window: NSWindow!
    let cameraMenu = NSPopUpButton()
    let resolutionMenu = NSPopUpButton()
    var frameSize: CGSize?
    let kindLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let textView = NSTextView()
    let buttons = NSStackView()
    var preview: PreviewView!
    var lastCode = "", lastCodeAt = Date.distantPast
    var cameras: [AVCaptureDevice] = []
    var markerTimer: Timer?
    let photoButton = NSButton(title: "Photo", image: NSImage(systemSymbolName: "camera", accessibilityDescription: nil)!,
                               target: nil, action: nil)
    var photoView: NSImageView?, photoOverlay: ImageAnalysisOverlayView?
    var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        if Installer.offerMove() { return }
        Installer.ejectInstallerDisk()
        buildWindow()
        scanner.onCodes = { [weak self] codes, size in self?.found(codes, size: size) }
        scanner.onSize = { [weak self] size in self?.frameSize = size; self?.refreshResolutionMenu() }
        scanner.region = { _ in zoomRegion(Settings.zoom) }
        preview.markers.onPick = { [weak self] d in self?.show(d) }
        preview.markers.onDoubleClick = { [weak self] in self?.setZoom(Settings.zoom > 1.05 ? 1 : 2.5) }
        preview.onZoom = { [weak self] z in self?.setZoom(z) }
        preview.zoom = Settings.zoom
        NSApp.activate(ignoringOtherApps: true)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: reloadCameras()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.reloadCameras() : self.noCameraAccess() }
            }
        default: noCameraAccess()
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadCameras() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "ShenzhenQR"
        window.minSize = NSSize(width: 400, height: 460)
        window.setFrameAutosaveName("main")

        preview = PreviewView(session: scanner.session)
        cameraMenu.target = self; cameraMenu.action = #selector(cameraChosen)
        resolutionMenu.target = self; resolutionMenu.action = #selector(resolutionChosen)
        resolutionMenu.toolTip = "Camera resolution"
        refreshResolutionMenu()
        kindLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        kindLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = "Point the camera at a code"

        textView.isEditable = true; textView.isSelectable = true; textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        buttons.orientation = .horizontal; buttons.spacing = 8
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyText))
        let bottom = NSStackView(views: [buttons, NSView(), copyButton])
        bottom.orientation = .horizontal

        photoButton.target = self; photoButton.action = #selector(togglePhoto)
        photoButton.imagePosition = .imageLeading
        photoButton.toolTip = "Take a photo and read the text in it. You can then select text on the photo."
        let top = NSStackView(views: [NSTextField(labelWithString: "Camera:"), cameraMenu, NSView(), resolutionMenu, photoButton])
        top.orientation = .horizontal
        let header = NSStackView(views: [kindLabel, NSView(), statusLabel])
        header.orientation = .horizontal

        let stack = NSStackView(views: [top, preview, header, scroll, bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in [top, preview, header, scroll, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        if offscreen { return }
        if !window.setFrameUsingName("main") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    var offscreen = false

    /// The README's screenshot: the window as it looks after reading `scene`, a picture standing in for the camera.
    /// Drawn off screen; no camera, no clipboard.
    func renderScreenshot(scene: String, out: String, zoom: Double = 1) {
        offscreen = true
        NSApp.appearance = NSAppearance(named: .aqua)
        buildWindow()
        window.setContentSize(NSSize(width: 560, height: 640))
        let image = NSImage(contentsOfFile: scene)!
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = preview.bounds
        imageView.autoresizingMask = [.width, .height]
        preview.addSubview(imageView, positioned: .below, relativeTo: preview.markers)
        preview.stillImage = imageView
        preview.zoom = zoom
        cameraMenu.addItem(withTitle: "FaceTime HD Camera")
        let ci = CIImage(contentsOf: URL(fileURLWithPath: scene))!
        frameSize = ci.extent.size
        refreshResolutionMenu()
        let codes = detect(VNImageRequestHandler(ciImage: ci, options: [:]), region: zoomRegion(zoom))
        preview.markers.imageSize = ci.extent.size
        preview.markers.detections = codes
        if let d = codes.first { show(d, sound: false) }
        setStatus("")
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        preview.layout()
        content.displayIfNeeded()
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }

    func reloadCameras() {
        cameras = Scanner.cameras()
        cameraMenu.removeAllItems()
        cameraMenu.addItems(withTitles: cameras.map(\.localizedName))
        guard !cameras.isEmpty else { statusLabel.stringValue = "No camera found"; return }
        let index = cameras.firstIndex { $0.uniqueID == Settings.camera } ?? 0
        cameraMenu.selectItem(at: index)
        frameSize = nil
        refreshResolutionMenu()
        startCamera()
    }

    func startCamera() {
        let i = cameraMenu.indexOfSelectedItem
        guard cameras.indices.contains(i) else { return }
        scanner.cores = Settings.cores
        scanner.use(cameras[i], resolution: Settings.resolution)
        preview.markers.mirrored = preview.layerPreview.connection?.isVideoMirrored ?? false
    }

    @objc func cameraChosen() {
        let i = cameraMenu.indexOfSelectedItem
        guard cameras.indices.contains(i) else { return }
        Settings.camera = cameras[i].uniqueID
        frameSize = nil
        refreshResolutionMenu()
        settingsWindow?.reload()
        startCamera()
    }

    /// The Settings window changed something: use it now.
    func settingsChanged() {
        refreshResolutionMenu()
        if !cameras.isEmpty { frameSize = nil; refreshResolutionMenu(); startCamera() }
    }

    var currentCamera: AVCaptureDevice? {
        let i = cameraMenu.indexOfSelectedItem
        return cameras.indices.contains(i) ? cameras[i] : nil
    }

    /// Automatic, then every size the chosen camera has. The setting's index among them (Automatic when this camera
    /// doesn't have that size).
    func resolutionChoices() -> (choices: [(key: String, title: String)], selected: Int) {
        let sizes = currentCamera.map(Settings.sizes) ?? []
        let choices = [("auto", "Automatic")] + sizes.map { ("\(Int($0.width))x\(Int($0.height))", Settings.sizeText($0)) }
        let wanted = offscreen ? nil : Settings.parseSize(Settings.resolution)   // the screenshot shows the default
        let selected = wanted.flatMap { w in sizes.firstIndex(of: w).map { $0 + 1 } } ?? 0
        return (choices, selected)
    }

    func refreshResolutionMenu() {
        let (choices, selected) = resolutionChoices()
        resolutionMenu.removeAllItems()
        for (i, c) in choices.enumerated() {
            // Automatic says what the camera gives.
            resolutionMenu.addItem(withTitle: i == 0 && selected == 0 ? frameSize.map { "Automatic · " + Settings.sizeText($0) } ?? c.title : c.title)
        }
        resolutionMenu.selectItem(at: selected)
    }

    @objc func resolutionChosen() {
        Settings.resolution = resolutionChoices().choices[resolutionMenu.indexOfSelectedItem].key
        settingsWindow?.reload()
        settingsChanged()
    }

    /// Photo: freezes what the camera shows (the zoomed part only) and reads its text; the text on the photo can then
    /// be selected as in Preview. Again: back to the camera.
    @MainActor @objc func togglePhoto() {
        if photoView != nil { closePhoto(); return }
        guard let image = scanner.photo(region: zoomRegion(Settings.zoom)) else { setStatus("No picture from the camera yet"); return }
        showPhoto(image)
    }

    @MainActor func showPhoto(_ image: CGImage) {
        scanner.paused = true
        markerTimer?.invalidate()
        preview.markers.detections = []
        preview.markers.isHidden = true
        preview.zoomBar.isHidden = true
        preview.layerPreview.isHidden = true
        let view = NSImageView(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = preview.bounds
        view.autoresizingMask = [.width, .height]
        preview.addSubview(view, positioned: .below, relativeTo: preview.markers)
        let overlay = ImageAnalysisOverlayView()
        overlay.trackingImageView = view
        overlay.preferredInteractionTypes = .automatic
        overlay.frame = preview.bounds
        overlay.autoresizingMask = [.width, .height]
        preview.addSubview(overlay, positioned: .above, relativeTo: view)
        photoView = view; photoOverlay = overlay
        photoButton.title = "Back to Camera"
        photoButton.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        setStatus("Reading the text…")
        Task { @MainActor in
            let config = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: config)
            guard let analysis, self.photoOverlay === overlay else { return }
            overlay.analysis = analysis
            let text = analysis.transcript
            self.lastCode = ""
            self.textView.string = text
            let kind = Payload.kind(text)
            self.kindLabel.stringValue = text.isEmpty ? "" : kind == "Text" ? "Text in the photo" : "Text in the photo · \(kind)"
            self.setStatus(text.isEmpty ? "No text found in the photo" : "Select text on the photo, or edit it below")
            self.refreshActions()
        }
    }

    func closePhoto() {
        photoOverlay?.removeFromSuperview(); photoView?.removeFromSuperview()
        photoOverlay = nil; photoView = nil
        preview.layerPreview.isHidden = false
        preview.markers.isHidden = false
        preview.zoomBar.isHidden = false
        photoButton.title = "Photo"
        photoButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        lastCode = ""; lastCodeAt = .distantPast
        setStatus("")
        scanner.paused = false
    }

    func setZoom(_ z: Double) {
        Settings.zoom = z
        preview.zoom = Settings.zoom
        preview.markers.detections = []
    }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow() }
        settingsWindow?.reload()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func noCameraAccess() {
        statusLabel.stringValue = "Camera access is off"
        setButtons([CodeAction(title: "Allow in System Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            return nil
        }])
    }

    func found(_ codes: [Detection], size: CGSize) {
        if photoView != nil { return }
        preview.markers.imageSize = size
        preview.markers.mirrored = preview.layerPreview.connection?.isVideoMirrored ?? false
        preview.markers.detections = codes
        markerTimer?.invalidate()
        markerTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.preview.markers.detections = []
        }
        // The code in the field is still in view (it may have been edited, or picked among several): keep it.
        if codes.contains(where: { $0.text == lastCode }) { lastCodeAt = Date(); preview.markers.selected = lastCode; return }
        // It just slipped out of one frame: wait a moment before switching to another code.
        if !lastCode.isEmpty, Date().timeIntervalSince(lastCodeAt) < 1 { return }
        show(codes[0])
    }

    /// Puts a code in the field: the biggest one in view, or the one clicked on.
    func show(_ d: Detection, sound: Bool = true) {
        lastCode = d.text; lastCodeAt = Date()
        preview.markers.selected = d.text
        textView.string = d.text
        kindLabel.stringValue = "\(symbologyName(d.symbology)) · \(Payload.kind(d.text))"
        setStatus("")
        if sound { NSSound(named: "Tink")?.play() }
        refreshActions()
    }

    func textDidChange(_ n: Notification) {
        kindLabel.stringValue = textView.string.isEmpty ? "" : Payload.kind(textView.string)
        refreshActions()
    }

    func refreshActions() { setButtons(Payload.actions(textView.string)) }

    var actionList: [CodeAction] = []
    func setButtons(_ list: [CodeAction]) {
        actionList = list
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, a) in list.enumerated() {
            let b = NSButton(title: a.title, target: self, action: #selector(runAction(_:)))
            b.tag = i
            if i == 0 { b.keyEquivalent = "\r" }
            buttons.addArrangedSubview(b)
        }
    }

    @objc func runAction(_ sender: NSButton) {
        guard actionList.indices.contains(sender.tag) else { return }
        if let s = actionList[sender.tag].run() { setStatus(s) }
    }

    @objc func copyText() {
        Payload.copy(textView.string)
        setStatus("Copied to the clipboard")
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }
}

final class SettingsWindow: NSWindowController {
    let resolution = NSPopUpButton(), cores = NSPopUpButton()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "ShenzhenQR Settings"
        self.init(window: w)
        resolution.target = self; resolution.action = #selector(changed)
        cores.addItems(withTitles: (1...Settings.maxCores).map(String.init))
        cores.selectItem(at: Settings.cores - 1)
        cores.target = self; cores.action = #selector(changed)
        let note = NSTextField(wrappingLabelWithString:
            "How many camera frames are read at the same time. More finds codes sooner, above all at high resolutions, and uses more of the processor.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Camera resolution:"), resolution],
            [NSTextField(labelWithString: "Processor cores:"), cores],
            [NSGridCell.emptyContentView, note],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 250).isActive = true
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        w.contentView = content
        w.center()
        reload()
    }

    /// The sizes of the camera chosen in the window.
    func reload() {
        let (choices, selected) = AppDelegate.shared?.resolutionChoices() ?? ([("auto", "Automatic")], 0)
        resolution.removeAllItems()
        resolution.addItems(withTitles: choices.map(\.title))
        resolution.selectItem(at: selected)
        cores.selectItem(at: Settings.cores - 1)
    }

    @objc func changed() {
        let choices = AppDelegate.shared?.resolutionChoices().choices ?? [("auto", "Automatic")]
        Settings.resolution = choices[max(0, resolution.indexOfSelectedItem)].key
        Settings.cores = cores.indexOfSelectedItem + 1
        AppDelegate.shared?.settingsChanged()
    }
}

// MARK: - Command line

enum CLI {
    static var active = false
    static let commands: Set<String> = ["scan", "camera", "cameras", "photo", "ocr", "parse", "run", "settings", "types", "help",
                                        "--help", "-h", "--version", "--screenshot"]

    static let help = """
    ShenzhenQR reads QR codes and barcodes, from pictures or from a camera.

    Usage:
      shenzhenqr scan [options] <picture>...  Read the codes in pictures (PNG, JPEG, HEIC, TIFF…; - reads standard input)
      shenzhenqr camera [options]             Read codes from a camera and print each new one, until Ctrl-C
      shenzhenqr cameras                      List the cameras and the picture sizes each one has
      shenzhenqr photo [options] <file>       Take a photo with a camera and save it (.png or .jpg); --ocr prints its text
      shenzhenqr ocr [options] <picture>...   Read the text in pictures, line by line (- reads standard input)
      shenzhenqr parse <text>                 Say what a code's text is and what can be done with it
      shenzhenqr run <text> [<action>]        Do one of those things: a number or the start of its name
                                              (shenzhenqr run "WIFI:S:Lab;P:pw;;" join)
      shenzhenqr settings [<name> <value>]    Show the settings, or change one (shared with the app):
                                                resolution  auto or a size the camera has, such as 1920x1080
                                                cores       frames or pictures read at the same time (default 4)
                                                zoom        the window's zoom into the middle, 1 to 5 (camera uses it too)
                                                camera      a camera's name or ID, or auto
      shenzhenqr types                        List the code types

    Options:
      --json              One JSON object per code, on one line each
      --text              Only the codes' text, one after the other
      --first             Only the biggest code in each picture
      --types <list>      Only these code types, comma-separated (shenzhenqr types lists them): --types qr,ean13
      --cores <n>         Pictures or frames read at the same time (default: the settings, 4)
      --copy              Also copy the first code's text to the clipboard
      --region <x,y,w,h>  Read only this part: pixels from the top-left corner (100,50,400,300), or fractions of
                          the picture when all four are 1 or less (0.25,0.25,0.5,0.5). Smaller codes are found there.
      --zoom <factor>     Read only the middle, 1/factor of the width and height (2.5 reads the middle 40%)
      camera only:
      --camera <name|id>  The camera to use (default: the one chosen in the app)
      --resolution <r>    auto or a size the camera has, such as 1920x1080 (default: the settings)
      --ocr               photo only: print the text in the photo
      --once              Stop after the first code
      --timeout <s>       Give up after this many seconds
                          (the camera reads the middle at the app's zoom unless --zoom or --region says otherwise)

    Positions are in pixels from the picture's top-left corner: "box" is the rectangle around the code, "corners"
    its four corners (top-left, top-right, bottom-right, bottom-left, as the code is printed), always in the whole
    picture, also with --region or --zoom ("region" in --json says which part was read).

    Exit status: 0 a code was read, 1 none was, 2 the command was wrong, 3 the camera can't be used.
    The camera needs the terminal app to be allowed in System Settings › Privacy & Security › Camera.
    """

    struct Options {
        var json = false, text = false, first = false, copy = false, once = false, ocr = false
        var types: [VNBarcodeSymbology]?
        var cores = Settings.cores
        var camera: String?, resolution: String?
        var timeout: Double?
        var zoom: Double?
        var region: [Double]?           // x, y, width, height: pixels, or fractions when all are 1 or less
        var rest: [String] = []

        /// The part of a picture of this size to read, as fractions from its top-left corner (nil: all of it).
        func part(_ size: CGSize, defaultZoom: Double) -> CGRect? {
            if let r = region {
                let fractions = r.allSatisfy { $0 <= 1 }
                let (w, h) = fractions ? (1.0, 1.0) : (Double(size.width), Double(size.height))
                return CGRect(x: r[0] / w, y: r[1] / h, width: r[2] / w, height: r[3] / h)
            }
            return zoomRegion(zoom ?? defaultZoom)
        }
    }

    static func fail(_ message: String, _ code: Int32 = 2) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(code)
    }

    /// fail() where a value is expected (after ??).
    static func failed<T>(_ message: String, _ code: Int32 = 2) -> T { fail(message, code) }

    static func parse(_ args: ArraySlice<String>) -> Options {
        var o = Options(), it = args.makeIterator()
        func value(_ flag: String) -> String { it.next() ?? failed("\(flag) needs a value") }
        while let a = it.next() {
            switch a {
            case "--json": o.json = true
            case "--text": o.text = true
            case "--first": o.first = true
            case "--copy": o.copy = true
            case "--once": o.once = true
            case "--ocr": o.ocr = true
            case "--cores":
                guard let n = Int(value(a)), n >= 1 else { fail("--cores needs a number of 1 or more") }
                o.cores = n
            case "--types":
                let known = Dictionary(VNDetectBarcodesRequest().supportedSymbologiesOrEmpty.map { (symbologyKey($0), $0) },
                                       uniquingKeysWith: { a, _ in a })
                o.types = value(a).split(separator: ",").map { name in
                    let key = name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
                    return known[key] ?? failed("Unknown code type “\(name)”. shenzhenqr types lists them.")
                }
            case "--camera": o.camera = value(a)
            case "--zoom":
                guard let z = Double(value(a)), z >= 1, z <= 20 else { fail("--zoom needs a factor from 1 to 20, such as 2.5") }
                o.zoom = z
            case "--region":
                let parts = value(a).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4, parts.allSatisfy({ $0 >= 0 }), parts[2] > 0, parts[3] > 0 else {
                    fail("--region is x,y,width,height: pixels from the top-left corner (100,50,400,300), or fractions (0.25,0.25,0.5,0.5)")
                }
                o.region = parts
            case "--resolution":
                let r = value(a).lowercased()
                guard r == "auto" || Settings.parseSize(r) != nil else { fail("--resolution is auto or a size such as 1920x1080 (shenzhenqr cameras lists them)") }
                o.resolution = r
            case "--timeout":
                guard let t = Double(value(a)), t > 0 else { fail("--timeout needs a number of seconds") }
                o.timeout = t
            case "-": o.rest.append(a)
            default:
                if a.hasPrefix("--") { fail("Unknown option \(a). shenzhenqr help lists them.") }
                o.rest.append(a)
            }
        }
        return o
    }

    static func jsonString(_ v: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Where something is, in pixels from the picture's top-left corner: its box and corners, and the part read.
    static func geometry(_ corners: [CGPoint], size: CGSize, part: CGRect?) -> [String: Any] {
        let num = { (v: Double, digits: Int) in Decimal(string: String(format: "%.\(digits)f", v))! }
        let px = { (p: CGPoint) -> [Decimal] in [num(p.x * size.width, 1), num(p.y * size.height, 1)] }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let b = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let rect = { (r: CGRect) -> [String: Int] in
            ["x": Int((r.minX * size.width).rounded()), "y": Int((r.minY * size.height).rounded()),
             "width": Int((r.width * size.width).rounded()), "height": Int((r.height * size.height).rounded())]
        }
        return [
            "image": ["width": Int(size.width), "height": Int(size.height)],
            "box": rect(b),
            "corners": ["top_left": px(corners[0]), "top_right": px(corners[1]),
                        "bottom_right": px(corners[2]), "bottom_left": px(corners[3])],
            "region": part.map { rect($0) as Any } ?? NSNull(),
        ]
    }

    static func lineRecord(_ l: TextLine, size: CGSize, source: String, part: CGRect?) -> [String: Any] {
        var r = geometry(l.corners, size: size, part: part)
        r["source"] = source; r["text"] = l.text
        r["confidence"] = Decimal(string: String(format: "%.3f", Double(l.confidence)))!
        return r
    }

    static func record(_ d: Detection, size: CGSize, source: String, part: CGRect?) -> [String: Any] {
        // Decimal keeps JSON at the digits given (513.1, not 513.10000000000002).
        let num = { (v: Double, digits: Int) in Decimal(string: String(format: "%.\(digits)f", v))! }
        let px = { (p: CGPoint) -> [Decimal] in [num(p.x * size.width, 1), num(p.y * size.height, 1)] }
        let b = d.box
        return [
            "source": source,
            "type": symbologyKey(d.symbology), "type_name": symbologyName(d.symbology),
            "text": d.text, "kind": Payload.kind(d.text), "actions": Payload.actions(d.text).map(\.title),
            "image": ["width": Int(size.width), "height": Int(size.height)],
            "box": ["x": Int((b.minX * size.width).rounded()), "y": Int((b.minY * size.height).rounded()),
                    "width": Int((b.width * size.width).rounded()), "height": Int((b.height * size.height).rounded())],
            "corners": ["top_left": px(d.corners[0]), "top_right": px(d.corners[1]),
                        "bottom_right": px(d.corners[2]), "bottom_left": px(d.corners[3])],
            "confidence": num(Double(d.confidence), 3),
            "region": part.map { r -> Any in
                ["x": Int((r.minX * size.width).rounded()), "y": Int((r.minY * size.height).rounded()),
                 "width": Int((r.width * size.width).rounded()), "height": Int((r.height * size.height).rounded())]
            } ?? NSNull(),
        ]
    }

    static func printCode(_ d: Detection, size: CGSize, source: String, o: Options, part: CGRect?) {
        if o.json { print(jsonString(record(d, size: size, source: source, part: part))); return }
        if o.text { print(d.text); return }
        let b = d.box
        let x = Int((b.minX * size.width).rounded()), y = Int((b.minY * size.height).rounded())
        let w = Int((b.width * size.width).rounded()), h = Int((b.height * size.height).rounded())
        print("\(source): \(symbologyName(d.symbology)) · \(Payload.kind(d.text)) · at x \(x), y \(y), \(w) × \(h) px of \(Int(size.width)) × \(Int(size.height))")
        print(d.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"))
        let actions = Payload.actions(d.text).map(\.title)
        if !actions.isEmpty { print("  → " + actions.joined(separator: " · ")) }
    }

    static func loadImage(_ path: String) -> CIImage? {
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        if path == "-" { return CIImage(data: FileHandle.standardInput.readDataToEndOfFile(), options: options) }
        return CIImage(contentsOf: URL(fileURLWithPath: path), options: options)
    }

    static func scan(_ o: Options) -> Never {
        guard !o.rest.isEmpty else { fail("Which pictures? shenzhenqr scan <picture>...") }
        var results = [(size: CGSize, codes: [Detection], part: CGRect?)?](repeating: nil, count: o.rest.count)
        let lock = NSLock(), queue = OperationQueue()
        queue.maxConcurrentOperationCount = o.cores
        for (i, path) in o.rest.enumerated() {
            queue.addOperation {
                guard let image = loadImage(path) else { return }
                let part = o.part(image.extent.size, defaultZoom: 1)
                let codes = detect(VNImageRequestHandler(ciImage: image, options: [:]), types: o.types, region: part)
                lock.lock(); results[i] = (image.extent.size, codes, part); lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        var any = false, first: String?
        for (path, result) in zip(o.rest, results) {
            guard let result else { FileHandle.standardError.write("\(path): can’t be opened as a picture\n".data(using: .utf8)!); continue }
            if result.codes.isEmpty, !o.json, !o.text { FileHandle.standardError.write("\(path): no code found\n".data(using: .utf8)!) }
            for d in (o.first ? Array(result.codes.prefix(1)) : result.codes) {
                any = true; first = first ?? d.text
                printCode(d, size: result.size, source: path == "-" ? "stdin" : path, o: o, part: result.part)
            }
        }
        if o.copy, let first { Payload.copy(first) }
        exit(any ? 0 : 1)
    }

    static func listCameras() -> Never {
        let cams = Scanner.cameras()
        if cams.isEmpty { fail("No camera found", 3) }
        for c in cams {
            print("\(c.localizedName)\t\(c.uniqueID)\(c.uniqueID == Settings.camera ? "\t(chosen in the app)" : "")")
            print("  " + Settings.sizes(c).map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: " "))
        }
        exit(0)
    }

    static func pickCamera(_ wanted: String?) -> AVCaptureDevice {
        let cams = Scanner.cameras()
        guard !cams.isEmpty else { fail("No camera found", 3) }
        guard let wanted, wanted != "auto" else { return cams.first { $0.uniqueID == Settings.camera } ?? cams[0] }
        return cams.first { $0.uniqueID == wanted }
            ?? cams.first { $0.localizedName.localizedCaseInsensitiveContains(wanted) }
            ?? failed("No camera matches “\(wanted)”. shenzhenqr cameras lists them.", 3)
    }

    static func ocr(_ o: Options) -> Never {
        guard !o.rest.isEmpty else { fail("Which pictures? shenzhenqr ocr <picture>...") }
        var any = false
        for path in o.rest {
            guard let image = loadImage(path) else { FileHandle.standardError.write("\(path): can’t be opened as a picture\n".data(using: .utf8)!); continue }
            let part = o.part(image.extent.size, defaultZoom: 1)
            let lines = recognizeText(VNImageRequestHandler(ciImage: image, options: [:]), region: part)
            if lines.isEmpty, !o.json { FileHandle.standardError.write("\(path): no text found\n".data(using: .utf8)!) }
            if !lines.isEmpty { any = true }
            printLines(lines, size: image.extent.size, source: path == "-" ? "stdin" : path, part: part, o: o)
        }
        exit(any ? 0 : 1)
    }

    static func printLines(_ lines: [TextLine], size: CGSize, source: String, part: CGRect?, o: Options) {
        for l in lines {
            print(o.json ? jsonString(lineRecord(l, size: size, source: source, part: part)) : l.text)
        }
        if o.copy, !lines.isEmpty { Payload.copy(lines.map(\.text).joined(separator: "\n")) }
    }

    /// Opens the camera with the options' resolution, sets the scanner up with `configure`, and waits; the
    /// callbacks exit. --timeout gives up.
    static func withCamera(_ o: Options, configure: @escaping (AVCaptureDevice, Scanner) -> Void) -> Never {
        let device = pickCamera(o.camera)
        let resolution = o.resolution ?? Settings.resolution
        if let r = o.resolution, let size = Settings.parseSize(r), !Settings.sizes(device).contains(size) {
            fail("\(device.localizedName) has no \(Settings.sizeText(size)) picture. It has: "
                 + Settings.sizes(device).map(Settings.sizeText).joined(separator: ", "))
        }
        let start = {
            let scanner = Scanner()
            configure(device, scanner)
            scanner.use(device, resolution: resolution)
            objc_setAssociatedObject(device, "scanner", scanner, .OBJC_ASSOCIATION_RETAIN)
        }
        if let t = o.timeout { DispatchQueue.main.asyncAfter(deadline: .now() + t) { fail("Nothing within \(Int(t)) s", 1) } }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { start() } else { fail("The camera isn’t allowed for this terminal app", 3) }
                }
            }
        default:
            fail("The camera isn’t allowed for this terminal app. Allow it in System Settings › Privacy & Security › Camera.", 3)
        }
        dispatchMain()
    }

    /// A photo from the camera, saved as PNG or JPEG (by the name's extension); --ocr prints its text.
    static func photo(_ o: Options) -> Never {
        guard let out = o.rest.first else { fail("Where to save it? shenzhenqr photo <file.png|file.jpg>") }
        withCamera(o) { device, scanner in
            scanner.paused = true
            // Give the camera a moment to set its exposure, then take the latest frame.
            func take(_ tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 1.0 : 0.2)) {
                    guard let shot = scanner.photo(region: { o.part($0, defaultZoom: Settings.zoom) }) else {
                        if tries > 25 { fail("No picture from \(device.localizedName)", 3) }
                        take(tries + 1); return
                    }
                    let rep = NSBitmapImageRep(cgImage: shot.image)
                    let jpeg = ["jpg", "jpeg"].contains(URL(fileURLWithPath: out).pathExtension.lowercased())
                    let data = rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.9] : [:])!
                    do { try data.write(to: URL(fileURLWithPath: out)) } catch { fail("Couldn’t save \(out): \(error.localizedDescription)") }
                    FileHandle.standardError.write("Saved \(out) (\(shot.image.width) × \(shot.image.height))\n".data(using: .utf8)!)
                    if o.ocr {
                        let size = CGSize(width: shot.image.width, height: shot.image.height)
                        let lines = recognizeText(VNImageRequestHandler(cgImage: shot.image, options: [:]))
                        printLines(lines, size: size, source: out, part: nil, o: o)
                    }
                    exit(0)
                }
            }
            take(0)
        }
    }

    static func camera(_ o: Options) -> Never {
        withCamera(o) { device, scanner in
            scanner.cores = o.cores
            scanner.types = o.types
            scanner.region = { size in o.part(size, defaultZoom: Settings.zoom) }
            var last: [String: Date] = [:], copied = false
            scanner.onCodes = { codes, size in
                for d in (o.first ? Array(codes.prefix(1)) : codes) {
                    // Each code once while it stays in view.
                    let seen = last[d.text].map { Date().timeIntervalSince($0) < 3 } ?? false
                    last[d.text] = Date()
                    if seen { continue }
                    printCode(d, size: size, source: device.localizedName, o: o, part: o.part(size, defaultZoom: Settings.zoom))
                    fflush(stdout)
                    if o.copy, !copied { Payload.copy(d.text); copied = true }
                    if o.once { exit(0) }
                }
            }
            FileHandle.standardError.write("Reading codes from \(device.localizedName)… (Ctrl-C to stop)\n".data(using: .utf8)!)
        }
    }

    static func textArgument(_ o: Options) -> String {
        guard let t = o.rest.first else { fail("Which text? Give it as an argument, or - to read it from standard input") }
        if t == "-" { return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        return t
    }

    static func parseText(_ o: Options) -> Never {
        let text = textArgument(o)
        let actions = Payload.actions(text).map(\.title)
        if o.json {
            print(jsonString(["text": text, "kind": Payload.kind(text), "actions": actions]))
        } else {
            print(Payload.kind(text))
            for (i, a) in actions.enumerated() { print("  \(i + 1). \(a)") }
        }
        exit(0)
    }

    static func runAction(_ o: Options) -> Never {
        let text = textArgument(o), actions = Payload.actions(text)
        guard !actions.isEmpty else { fail("Nothing to do with this text (\(Payload.kind(text)))", 1) }
        guard o.rest.count > 1 else {
            for (i, a) in actions.enumerated() { print("\(i + 1). \(a.title)") }
            exit(0)
        }
        let wanted = o.rest[1]
        let words = { (t: String) in t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        let action = Int(wanted).flatMap { actions.indices.contains($0 - 1) ? actions[$0 - 1] : nil }
            ?? actions.first { $0.title.lowercased().hasPrefix(wanted.lowercased()) }
            ?? actions.first { words($0.title).contains { $0.hasPrefix(wanted.lowercased()) } }
            ?? failed("No action “\(wanted)”. They are: " + actions.enumerated().map { "\($0 + 1). \($1.title)" }.joined(separator: ", "))
        print(action.run() ?? "Done: \(action.title)")
        exit(0)
    }

    static func settings(_ o: Options) -> Never {
        if o.rest.isEmpty {
            let cam = Scanner.cameras().first { $0.uniqueID == Settings.camera }
            let note = Settings.parseSize(Settings.resolution).flatMap { size -> String? in
                guard let cam, !Settings.sizes(cam).contains(size) else { return nil }
                return "\t(\(cam.localizedName) has no \(Settings.sizeText(size)): it uses Automatic)"
            } ?? ""
            print("resolution\t\(Settings.resolution)\(note)")
            print("cores\t\(Settings.cores)")
            print("zoom\t\(Settings.zoom)")
            print("camera\t\(Settings.camera ?? "auto")\t\(cam?.localizedName ?? "the first camera found")")
            exit(0)
        }
        guard o.rest.count == 2 else { fail("shenzhenqr settings <name> <value>: resolution, cores, zoom or camera") }
        let value = o.rest[1]
        switch o.rest[0] {
        case "resolution":
            guard value.lowercased() == "auto" || Settings.parseSize(value) != nil else { fail("resolution is auto or a size such as 1920x1080 (shenzhenqr cameras lists them)") }
            Settings.resolution = Settings.parseSize(value).map { "\(Int($0.width))x\(Int($0.height))" } ?? "auto"
        case "cores":
            guard let n = Int(value), (1...Settings.maxCores).contains(n) else { fail("cores is a number from 1 to \(Settings.maxCores)") }
            Settings.cores = n
        case "camera":
            Settings.camera = value == "auto" ? nil : pickCamera(value).uniqueID
        case "zoom":
            guard let z = Double(value), (1...Settings.maxZoom).contains(z) else { fail("zoom is a factor from 1 to \(Int(Settings.maxZoom))") }
            Settings.zoom = z
        default: fail("No setting “\(o.rest[0])”: resolution, cores, zoom or camera")
        }
        exit(0)
    }

    static func types() -> Never {
        for s in VNDetectBarcodesRequest().supportedSymbologiesOrEmpty { print("\(symbologyKey(s))\t\(symbologyName(s))") }
        exit(0)
    }

    static func main(_ args: [String]) -> Never {
        active = true
        let o = parse(args.dropFirst(2))
        switch args[1] {
        case "scan": scan(o)
        case "camera": camera(o)
        case "cameras": listCameras()
        case "photo": photo(o)
        case "ocr": ocr(o)
        case "parse": parseText(o)
        case "run": runAction(o)
        case "settings": settings(o)
        case "types": types()
        case "--version":
            print("ShenzhenQR \(appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            exit(0)
        case "--screenshot":
            guard args.count >= 4 else { fail("--screenshot <out.png> <picture|settings> [zoom]") }
            _ = NSApplication.shared
            if args[3] == "settings" {
                NSApp.appearance = NSAppearance(named: .aqua)
                let view = SettingsWindow().window!.contentView!
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
                exit(0)
            }
            if args.count > 4, args[4] == "photo" {
                // The Photo view: the picture as if just taken, its text read, drawn once reading is done.
                let d = AppDelegate()
                d.offscreen = true
                NSApp.appearance = NSAppearance(named: .aqua)
                d.buildWindow()
                d.window.setContentSize(NSSize(width: 560, height: 640))
                let ci = CIImage(contentsOf: URL(fileURLWithPath: args[3]))!
                MainActor.assumeIsolated { d.showPhoto(cgImage(ci, region: nil)!) }
                let deadline = Date().addingTimeInterval(20)
                while d.statusLabel.stringValue == "Reading the text…", Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                let content = d.window.contentView!
                content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
                let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: rep)
                try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
                exit(0)
            }
            AppDelegate().renderScreenshot(scene: args[3], out: args[2], zoom: args.count > 4 ? Double(args[4]) ?? 1 : 1)
            exit(0)
        default:
            print(help)
            exit(0)
        }
    }
}

extension VNDetectBarcodesRequest {
    var supportedSymbologiesOrEmpty: [VNBarcodeSymbology] { (try? supportedSymbologies()) ?? [] }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.count > 1, CLI.commands.contains(args[1]) { CLI.main(args) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
menu.addItem(appItem); menu.addItem(editItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit ShenzhenQR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let editMenu = NSMenu(title: "Edit")
for (t, s, k) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                  ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
    editMenu.addItem(withTitle: t, action: Selector(s), keyEquivalent: k)
}
editItem.submenu = editMenu
app.mainMenu = menu
app.run()
