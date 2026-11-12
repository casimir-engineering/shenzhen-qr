// ShenzhenQR: point any camera at a QR code (or any barcode / 2D code) and act on it.
// One file, AppKit + AVFoundation + Vision, no dependencies. Built by build.sh.
import AppKit
import AVFoundation
import Vision
import VisionKit
import Security
import CryptoKit
import CoreImage.CIFilterBuiltins
import CoreWLAN
import CoreLocation
import UniformTypeIdentifiers

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

/// The code type's name, saying UPC-A for a 12-digit EAN-13 number.
func codeName(_ d: Detection) -> String {
    d.symbology == .ean13 && d.text.count == 12 ? "UPC-A" : symbologyName(d.symbology)
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
    var printed = false             // read from the digits printed under the bars, not from the bars
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

/// Barcode numbers read from the digits printed under the bars, for when the bars themselves are too blurred: a
/// line of 13 (EAN-13), 12 (UPC-A) or 8 (EAN-8) digits whose check digit is right. A 12-digit line that isn't a UPC-A
/// number is an EAN-13 whose first digit, printed apart, wasn't read: the check digit allows only one, so it's put back.
func printedBarcodes(_ lines: [TextLine]) -> [Detection] {
    func checks(_ d: [Int]) -> Bool {          // EAN/UPC: weights 3,1,3,1… from the right, after the check digit
        let body = d.dropLast().reversed().enumerated().map { $0.offset % 2 == 0 ? $0.element * 3 : $0.element }
        return (10 - body.reduce(0, +) % 10) % 10 == d.last!
    }
    var out: [Detection] = []
    for line in lines {
        // The digits only, when the line is nothing but digits and spaces (as printed under a barcode).
        let t = line.text.replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty, t.allSatisfy(\.isASCII), t.allSatisfy(\.isNumber) else { continue }
        var d = t.compactMap { $0.wholeNumberValue }
        var symbology: VNBarcodeSymbology
        switch d.count {
        case 13 where checks(d): symbology = .ean13
        case 12 where checks(d): symbology = .ean13; d.insert(0, at: 0)    // UPC-A is EAN-13 with a leading 0
        case 12:
            guard let first = (0...9).first(where: { checks([$0] + d) }) else { continue }
            d.insert(first, at: 0); symbology = .ean13
        case 8 where checks(d): symbology = .ean8
        default: continue
        }
        let text = d.map(String.init).joined()
        out.append(Detection(text: d.count == 13 && d[0] == 0 && t.count == 12 ? String(text.dropFirst()) : text,
                             symbology: symbology, corners: line.corners, confidence: line.confidence, printed: true))
    }
    return out
}

/// Codes in a still picture, trying harder than for a camera frame: if nothing is read as it is, then grey with
/// more contrast and sharpened, then twice as big. Last, barcode numbers from their printed digits.
func detectInPhoto(_ image: CGImage, types: [VNBarcodeSymbology]? = nil, region: CGRect? = nil) -> [Detection] {
    detectInPhoto(CIImage(cgImage: image), types: types, region: region)
}

func detectInPhoto(_ ci: CIImage, types: [VNBarcodeSymbology]? = nil, region: CGRect? = nil) -> [Detection] {
    let gray = ci.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 1.5])
    let variants = [ci,
                    gray.applyingFilter("CIUnsharpMask", parameters: ["inputRadius": 4, "inputIntensity": 1.2]),
                    gray.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 2])
                        .applyingFilter("CIUnsharpMask", parameters: ["inputRadius": 8, "inputIntensity": 1.2])]
    for v in variants {
        // Positions are fractions of the picture, so they hold for the enlarged one too.
        let found = detect(VNImageRequestHandler(ciImage: v, options: [:]), types: types, region: region)
        if !found.isEmpty { return found }
    }
    let printed = printedBarcodes(recognizeText(VNImageRequestHandler(ciImage: ci, options: [:]), region: region))
    return printed.filter { types?.contains($0.symbology) ?? true }
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
            let size = Settings.parseSize(resolution), format = size.flatMap { Settings.format(device, $0) }
            if format == nil { session.sessionPreset = .high }
            session.commitConfiguration()
            // A chosen size: the device's format, set after the configuration (a preset applied at commit would
            // replace it). The session then follows the device.
            if let format, (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format
                device.unlockForConfiguration()
            }
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
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

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
            if d.printed { path.setLineDash([6, 4], count: 2, phase: 0) }
            NSColor.systemGreen.withAlphaComponent(chosen ? 0.22 : 0.12).setFill()
            path.fill()
            NSColor.systemGreen.setStroke()
            path.lineWidth = chosen ? 4 : 2
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    /// Clicks reach the markers only; elsewhere they go to what's under (the photo's selectable text). Double-clicks
    /// on the camera picture still come here, for the zoom.
    var passThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        if detections.contains(where: { outline($0).contains(p) }) { return self }
        return passThrough ? nil : super.hitTest(point)
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

// MARK: - Pictures from outside the camera: pasted, dropped on the window, or opened

enum Picture {
    static func isPicture(_ type: NSPasteboard.PasteboardType) -> Bool { UTType(type.rawValue)?.conforms(to: .image) ?? false }
    static func isPicture(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension))?
            .conforms(to: .image) ?? false
    }
    static func files(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    /// Pictures a drag promises to write: a screenshot's thumbnail, a picture dragged out of a browser or of Photos.
    static func promises(_ board: NSPasteboard) -> [NSFilePromiseReceiver] {
        ((board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []).filter {
            $0.fileTypes.contains { (UTType($0) ?? UTType(filenameExtension: $0))?.conforms(to: .image) ?? false }
        }
    }

    /// A picture file, turned the way its orientation says.
    static func load(_ url: URL) -> CGImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true]).flatMap { cgImage($0, region: nil) }
    }
    static func load(_ data: Data) -> CGImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true]).flatMap { cgImage($0, region: nil) }
    }

    /// Whether the clipboard or a drag holds a picture: a picture file, or a picture itself. Looks at types only.
    /// A copied file also carries its icon, which isn't what was copied: with files, only they count.
    static func holdsPicture(_ board: NSPasteboard) -> Bool {
        let files = files(board)
        return files.isEmpty ? (board.types ?? []).contains(where: isPicture) : files.contains(where: isPicture)
    }

    static func read(_ board: NSPasteboard) -> CGImage? {
        let files = files(board)
        if !files.isEmpty { return files.lazy.compactMap(load).first }
        return (board.types ?? []).lazy.filter(isPicture).compactMap { board.data(forType: $0).flatMap(load) }.first
    }

    /// Whether ⌘V reads the clipboard's picture rather than pasting its text. With the cursor in a text field, what was
    /// copied decides: text from a spreadsheet or a word processor comes with a picture of itself after the text, a
    /// picture from a browser comes with its address after the picture.
    static func pastesAsPicture(_ board: NSPasteboard, intoText: Bool) -> Bool {
        guard holdsPicture(board) else { return false }
        let types = board.types ?? []
        guard intoText, files(board).isEmpty, let text = types.firstIndex(of: .string),
              let picture = types.firstIndex(where: isPicture) else { return true }
        return picture < text
    }
}

/// Shown around the window while a picture is dragged over it.
final class DropRing: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        layer?.borderWidth = 3; layer?.cornerRadius = 8
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The window's content: a picture dragged onto it, anywhere, is read. From Finder (a file), from a browser or another
/// app (the picture itself), or a screenshot's thumbnail (a file it promises to write).
final class DropView: NSView {
    /// The picture that was dropped (nil when it couldn't be opened as one), and its file's name when it was a file.
    var onPicture: ((CGImage?, String?) -> Void)?
    let ring = DropRing()

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.wantsLayer = true; ring.isHidden = true
        registerForDraggedTypes([.fileURL] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
                                + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }
    required init?(coder: NSCoder) { fatalError() }

    static func holdsPicture(_ sender: NSDraggingInfo) -> Bool {
        Picture.holdsPicture(sender.draggingPasteboard) || !Picture.promises(sender.draggingPasteboard).isEmpty
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let picture = Self.holdsPicture(sender)
        ring.isHidden = !picture
        return picture ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { ring.isHidden ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { ring.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { ring.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ring.isHidden = true
        let board = sender.draggingPasteboard
        if Picture.holdsPicture(board) {
            let image = Picture.read(board)             // read now: the drag's contents go away with it
            let name = Picture.files(board).first?.lastPathComponent
            DispatchQueue.main.async { self.onPicture?(image, name) }
            return true
        }
        guard let promise = Picture.promises(board).first else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShenzhenQR-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var first = true
        promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
            guard first else { return }
            first = false
            self.onPicture?(error == nil ? Picture.load(url) : nil, url.lastPathComponent)
            try? FileManager.default.removeItem(at: folder)
        }
        return true
    }
}

extension NSView {
    /// Picture views take drags for themselves, and refuse them when they can't be changed: a picture dropped on the
    /// photo or on the Create preview would go nowhere. Without that, the drop reaches the window's content.
    func leaveDropsToWindow() {
        if self is NSImageView { unregisterDraggedTypes() }
        subviews.forEach { $0.leaveDropsToWindow() }
    }
}

/// A text field of the window. A picture dragged onto it is read like one dropped anywhere else on the window, in
/// place of its file name being typed in; text dragged onto it goes in as usual.
final class FieldTextView: NSTextView {
    private var pictureDrag = false
    private var drop: DropView? { window?.contentView as? DropView }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pictureDrag = drop != nil && DropView.holdsPicture(sender)
        return pictureDrag ? drop!.draggingEntered(sender) : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pictureDrag ? .copy : super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if pictureDrag { pictureDrag = false; drop?.draggingExited(sender) } else { super.draggingExited(sender) }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        if pictureDrag { pictureDrag = false; drop?.draggingEnded(sender) } else { super.draggingEnded(sender) }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pictureDrag ? true : super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pictureDrag ? drop?.performDragOperation(sender) ?? false : super.performDragOperation(sender)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if pictureDrag { pictureDrag = false } else { super.concludeDragOperation(sender) }
    }
}

// MARK: - Window

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSToolbarDelegate {
    static weak var shared: AppDelegate?
    let scanner = Scanner()
    var window: NSWindow!
    let cameraMenu = NSPopUpButton()
    let resolutionMenu = NSPopUpButton()
    var frameSize: CGSize?
    let kindLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let textView = FieldTextView()
    let buttons = NSStackView()
    var preview: PreviewView!
    var lastCode = "", lastCodeAt = Date.distantPast
    var cameras: [AVCaptureDevice] = []
    var markerTimer: Timer?
    let photoButton = NSButton(title: "Photo", image: NSImage(systemSymbolName: "camera", accessibilityDescription: nil)!,
                               target: nil, action: nil)
    let openButton = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Open Picture")!,
                              target: nil, action: nil)
    var photoView: NSImageView?, photoOverlay: ImageAnalysisOverlayView?
    var settingsWindow: SettingsWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        if Installer.offerMove() { return }
        Installer.ejectInstallerDisk()
        buildWindow()
        Updater.shared.start()
        scanner.onCodes = { [weak self] codes, size in self?.found(codes, size: size) }
        scanner.onSize = { [weak self] size in
            self?.frameSize = size; self?.refreshResolutionMenu()
            if self?.photoView == nil { self?.fitToPicture(size) }
        }
        scanner.region = { _ in zoomRegion(Settings.zoom) }
        preview.markers.onPick = { [weak self] d in self?.show(d) }
        preview.markers.onDoubleClick = { [weak self] in self?.setZoom(Settings.zoom > 1.05 ? 1 : 2.5) }
        preview.onZoom = { [weak self] z in self?.setZoom(z) }
        preview.zoom = Settings.zoom
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, MainActor.assumeIsolated({ self.escape(event) }) else { return event }
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        // Opened on a picture (Open With in Finder, or a picture dropped on the icon): it shows from the start, and the
        // camera stays off until Back to Camera.
        if let urls = openAtLaunch { openAtLaunch = nil; MainActor.assumeIsolated { openPictures(urls) } }
        if photoView == nil { askForCamera() }
        else if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { reloadCameras() }   // the menu only
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadCameras() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    var cameraAsked = false
    /// Starts the camera, asking for access the first time. Not done while the app shows a picture it was opened on.
    func askForCamera() {
        cameraAsked = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: reloadCameras()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.reloadCameras() : self.noCameraAccess() }
            }
        default: noCameraAccess()
        }
    }

    // MARK: Pictures from outside the camera

    var openAtLaunch: [URL]?
    /// Pictures opened from Finder (Open With, or dropped on the app's icon). At launch this comes before the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard window != nil else { openAtLaunch = urls; return }
        MainActor.assumeIsolated { openPictures(urls) }
    }

    /// The first of them that is a picture.
    @MainActor func openPictures(_ urls: [URL]) {
        guard let first = urls.first else { return }
        showPicture(urls.lazy.compactMap(Picture.load).first, name: first.lastPathComponent)
    }

    /// File › Open Picture…
    @MainActor @objc func openPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Open"
        window.makeKeyAndOrderFront(nil)
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self.openPictures([url]) }
        }
    }

    /// ⌘V: a picture on the clipboard is read; anything else is pasted where the cursor is, as usual.
    @MainActor @objc func pasteAnything(_ sender: Any?) {
        let board = NSPasteboard.general
        let intoText = (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
        guard Picture.pastesAsPicture(board, intoText: intoText) else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
            return
        }
        showPicture(Picture.read(board), name: Picture.files(board).first?.lastPathComponent)
    }

    /// A picture that was pasted, dropped on the window or opened is read as a photo is: its codes are outlined and
    /// its text can be selected. From the Create tab too, which then gives way to Scan. nil: it couldn't be opened.
    @MainActor func showPicture(_ image: CGImage?, name: String? = nil) {
        guard let image else {
            let problem = name.map { "“\($0)” can’t be opened as a picture" } ?? "That picture can’t be opened"
            if scanView.isHidden { createView.say(problem, error: true) } else { setStatus(problem) }
            return
        }
        showPhoto(image, called: "picture")
        if scanView.isHidden { showTab(0) }          // the camera stays off: a picture is shown
        fitToPicture(CGSize(width: image.width, height: image.height))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)   // shortened, rather than widening the window
        statusLabel.stringValue = "Point the camera at a code, or paste or drop a picture"

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
        openButton.target = self; openButton.action = #selector(openPicture)
        openButton.toolTip = "Open a picture and read the codes and text in it (⌘O)"
        let top = NSStackView(views: [NSTextField(labelWithString: "Camera:"), cameraMenu, NSView(), resolutionMenu, openButton, photoButton])
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
        // Two tabs in the top bar: Scan (the camera) and Create (making codes).
        let container = DropView()
        container.onPicture = { [weak self] image, name in MainActor.assumeIsolated { self?.showPicture(image, name: name) } }
        createView = CreateView()
        for v in [stack, createView!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: container.topAnchor), v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor), v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        scanView = stack
        container.ring.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(container.ring)            // over everything else
        NSLayoutConstraint.activate([
            container.ring.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            container.ring.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            container.ring.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            container.ring.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])
        window.contentView = container
        container.leaveDropsToWindow()
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers = [Self.tabsItem]
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        showTab(offscreen ? 0 : Settings.defaults.integer(forKey: "tab"))
        if offscreen { return }
        if !window.setFrameUsingName("main") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    var offscreen = false
    var scanView: NSView!, createView: CreateView!
    let tabs = NSSegmentedControl(labels: ["Scan", "Create"], trackingMode: .selectOne, target: nil, action: nil)
    static let tabsItem = NSToolbarItem.Identifier("tabs")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tabsItem] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tabsItem] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        tabs.target = self; tabs.action = #selector(tabChosen)
        tabs.segmentStyle = .automatic
        item.view = tabs
        item.label = "Scan or Create"
        return item
    }

    @objc func tabChosen() { showTab(tabs.selectedSegment) }

    /// The window's height set so the picture (the camera's, or one that was pasted, dropped or opened) fills the
    /// preview, without black bars; the width and the top edge stay where they are. A very wide picture keeps the
    /// preview's least height, a very tall one stops at the screen's.
    func fitToPicture(_ size: CGSize, screenshot: Bool = false) {
        guard !offscreen || screenshot, size.width > 0, !scanView.isHidden, let window, !window.inLiveResize else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let want = max(220, (preview.frame.width * size.height / size.width).rounded())
        let delta = want - preview.frame.height
        guard abs(delta) > 1 else { return }
        var frame = window.frame
        frame.size.height += delta
        frame.origin.y -= delta
        if let screen = window.screen?.visibleFrame, frame.minY < screen.minY {   // keep it on the screen
            frame.origin.y = screen.minY
            frame.size.height = min(frame.height, screen.height)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    /// Scan runs the camera; Create stops it, so the camera light goes off while making codes.
    func showTab(_ index: Int) {
        let create = index == 1
        tabs.selectedSegment = create ? 1 : 0
        scanView.isHidden = create
        createView.isHidden = !create
        if !offscreen { Settings.defaults.set(create ? 1 : 0, forKey: "tab") }
        if create { scanner.stop() } else if !cameras.isEmpty, photoView == nil { startCamera() }
        window.makeFirstResponder(create ? createView.textView : nil)
    }

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
        fitToPicture(ci.extent.size, screenshot: true)        // as the app does when the camera starts
        content.layoutSubtreeIfNeeded()
        preview.layout()
        let frame = content.superview ?? content          // the whole window, its top bar with the tabs included
        frame.layoutSubtreeIfNeeded(); frame.displayIfNeeded()
        let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        frame.cacheDisplay(in: frame.bounds, to: rep)
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
        // Not behind a picture the camera wasn't running for.
        if !scanView.isHidden, photoView == nil || scanner.session.isRunning { startCamera() }
    }

    func startCamera() {
        guard scanView?.isHidden != true else { return }   // the Create tab keeps the camera off
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

    var photoCodes: [Detection] = [], photoText: String?, photoLines: [TextLine] = []
    var photoNoun = "photo"         // "picture" for one that didn't come from the camera

    @MainActor func showPhoto(_ image: CGImage, called noun: String = "photo") {
        photoOverlay?.removeFromSuperview(); photoView?.removeFromSuperview()     // a picture pasted over another
        photoNoun = noun; photoLines = []; photoCodesRead = false; codeDismissed = false
        scanner.paused = true
        markerTimer?.invalidate()
        // The markers now outline codes on the photo: its own size, no zoom or mirroring, clicks elsewhere go to
        // the photo's text.
        let markers = preview.markers
        markers.detections = []; markers.selected = nil
        markers.imageSize = CGSize(width: image.width, height: image.height)
        markers.zoom = 1; markers.mirrored = false; markers.passThrough = true
        preview.zoomBar.isHidden = true
        preview.layerPreview.isHidden = true
        let view = NSImageView(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.frame = preview.bounds
        view.autoresizingMask = [.width, .height]
        preview.addSubview(view, positioned: .below, relativeTo: markers)
        // Live Text, laid over the image view it tracks.
        let overlay = ImageAnalysisOverlayView()
        overlay.trackingImageView = view
        overlay.preferredInteractionTypes = .automatic
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)
        view.leaveDropsToWindow()
        photoView = view; photoOverlay = overlay
        photoCodes = []; photoText = nil
        photoButton.title = "Back to Camera"
        photoButton.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
        lastCode = ""
        textView.string = ""; kindLabel.stringValue = ""; setButtons([])
        setStatus("Reading the \(noun)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let codes = detectInPhoto(image)
            let lines = recognizeText(VNImageRequestHandler(cgImage: image, options: [:]))
            DispatchQueue.main.async {
                guard self.photoOverlay === overlay else { return }
                self.photoLines = lines
                self.addPhotoCodes(codes)
                self.addTranscriptCodes()
                self.photoCodesRead = true
                self.fillPhotoField()
                self.photoStatus()
            }
        }
        Task { @MainActor in
            let config = ImageAnalyzer.Configuration([.text])
            let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: config)
            guard self.photoOverlay === overlay else { return }
            overlay.analysis = analysis
            view.leaveDropsToWindow()               // Live Text adds its own buttons
            let text = analysis?.transcript ?? ""
            self.photoText = text
            self.addTranscriptCodes()
            self.fillPhotoField()
            self.photoStatus()
        }
    }

    var photoCodesRead = false
    var codeDismissed = false       // Esc took the picture's code out of the field: don't put it back
    /// What the field gets once the photo is read, unless a code was clicked meanwhile: the photo's text. A picture
    /// from outside the camera that holds a code gets that code, the biggest one, as when the camera sees it; its
    /// text can still be selected on it. Numbers read from printed digits wait for a click.
    func fillPhotoField() {
        guard lastCode.isEmpty else { return }
        if photoNoun == "picture" {
            guard photoCodesRead else { return }
            if !codeDismissed, let code = photoCodes.first(where: { !$0.printed }) { show(code); return }
        }
        guard var text = photoText else { return }
        if photoHasNoText { text = "" }
        textView.string = text
        let kind = Payload.kind(text)
        kindLabel.stringValue = text.isEmpty ? "" : kind == "Text" ? "Text in the \(photoNoun)" : "Text in the \(photoNoun) · \(kind)"
        refreshActions()
    }

    func addPhotoCodes(_ codes: [Detection]) {
        let new = codes.filter { c in !photoCodes.contains { $0.text == c.text } }
        photoCodes += new
        preview.markers.detections = photoCodes
    }

    /// Live Text can read a barcode's printed digits better than the other reading: take a barcode number from its
    /// text too, outlined on the line of the photo whose digits match it best.
    func addTranscriptCodes() {
        guard let text = photoText, !photoLines.isEmpty else { return }
        let digitsOf = { (t: String) in t.filter { $0.isASCII && $0.isNumber } }
        let candidates = printedBarcodes(text.split(separator: "\n").map {
            TextLine(text: String($0), confidence: 1, corners: [.zero, .zero, .zero, .zero])
        })
        var placed: [Detection] = []
        for c in candidates {
            // The line sharing the longest run of digits with the number (at least 5).
            func shared(_ a: String, _ b: String) -> Int {
                let a = Array(a), b = Array(b); var best = 0
                for i in a.indices { for j in b.indices {
                    var k = 0
                    while i + k < a.count, j + k < b.count, a[i + k] == b[j + k] { k += 1 }
                    best = max(best, k)
                } }
                return best
            }
            let match = photoLines.map { ($0, shared(digitsOf($0.text), c.text)) }.max { $0.1 < $1.1 }
            guard let (line, n) = match, n >= 5 else { continue }
            placed.append(Detection(text: c.text, symbology: c.symbology, corners: line.corners, confidence: c.confidence, printed: true))
        }
        addPhotoCodes(placed)
    }

    /// Reading a code's pattern as text gives a few stray characters: text counts when some of it is outside the codes.
    var photoHasNoText: Bool {
        let boxes = photoCodes.filter { !$0.printed }.map { $0.box.insetBy(dx: -0.02, dy: -0.02) }
        return !boxes.isEmpty && !photoLines.contains { line in
            let x = line.corners.map(\.x).reduce(0, +) / 4, y = line.corners.map(\.y).reduce(0, +) / 4
            return !boxes.contains { $0.contains(CGPoint(x: x, y: y)) }
        }
    }

    /// What can be done on the photo, once it's read.
    func photoStatus() {
        guard let text = photoText, photoCodesRead || photoNoun == "photo" else { return }
        let others = photoCodes.contains { $0.text != lastCode }
        let noText = text.isEmpty || photoHasNoText
        switch (noText, photoCodes.isEmpty, lastCode.isEmpty) {
        case (true, true, _): setStatus("No text or code found in the \(photoNoun)")
        case (false, true, _): setStatus("Select text on the \(photoNoun), or edit it below")
        case (true, false, true): setStatus("Click the outlined code to use it")
        case (false, false, true): setStatus("Select text on the \(photoNoun), or click a code to use it")
        // A code is in the field already.
        case (true, false, false): setStatus(others ? "Click another code to use it" : "")
        case (false, false, false): setStatus(others ? "Select text on the \(photoNoun), or click another code" : "Text on the \(photoNoun) can be selected")
        }
    }

    /// Esc on a photo or picture: with a code in the field, back to the picture's text; then back to the camera.
    /// False when Esc isn't ours: no picture is shown, a sheet or another window has it, or text is being composed.
    @MainActor func escape(_ event: NSEvent) -> Bool {
        guard photoView != nil, event.window === window, window.attachedSheet == nil, !scanView.isHidden,
              !textView.hasMarkedText() else { return false }
        guard !lastCode.isEmpty else { closePhoto(); return true }
        lastCode = ""; codeDismissed = true
        preview.markers.selected = nil
        textView.string = ""; kindLabel.stringValue = ""; setButtons([])
        fillPhotoField()
        photoStatus()
        return true
    }

    func closePhoto() {
        photoOverlay?.removeFromSuperview(); photoView?.removeFromSuperview()
        photoOverlay = nil; photoView = nil; photoCodes = []; photoText = nil; photoLines = []
        let markers = preview.markers
        markers.detections = []; markers.passThrough = false; markers.zoom = preview.zoom
        markers.mirrored = preview.layerPreview.connection?.isVideoMirrored ?? false
        if let frameSize { markers.imageSize = frameSize }
        preview.layerPreview.isHidden = false
        preview.zoomBar.isHidden = false
        photoButton.title = "Photo"
        photoButton.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        lastCode = ""; lastCodeAt = .distantPast
        setStatus("")
        scanner.paused = false
        // The camera is off when the picture came while it was (the app opened on it, or it was pasted in Create).
        if !cameraAsked { askForCamera() } else if !scanner.session.isRunning { startCamera() }
        if let frameSize { fitToPicture(frameSize) }
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
        kindLabel.stringValue = d.printed ? "\(codeName(d)) · read from the printed digits"
                                          : "\(codeName(d)) · \(Payload.kind(d.text))"
        if photoView == nil { setStatus("") }
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

extension AppDelegate: NSMenuItemValidation {
    /// Paste: when the clipboard holds a picture, or there is a text field to paste into.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(pasteAnything(_:)) else { return true }
        return Picture.holdsPicture(.general) || NSApp.target(forAction: #selector(NSText.paste(_:)), to: nil, from: item) != nil
    }
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
    static let commands: Set<String> = ["scan", "camera", "cameras", "photo", "ocr", "make", "create", "parse", "run", "settings", "types", "update", "wifi", "--verify-update", "help",
                                        "--help", "-h", "--version", "--screenshot"]

    static let help = """
    ShenzhenQR reads QR codes and barcodes, from pictures or from a camera.

    Usage:
      shenzhenqr scan [options] <picture>...  Read the codes in pictures (PNG, JPEG, HEIC, TIFF…; - reads standard input)
      shenzhenqr camera [options]             Read codes from a camera and print each new one, until Ctrl-C
      shenzhenqr cameras                      List the cameras and the picture sizes each one has
      shenzhenqr photo [options] <file>       Take a photo with a camera and save it (.png or .jpg); --ocr prints its text
      shenzhenqr ocr [options] <picture>...   Read the text in pictures, line by line (- reads standard input)
      shenzhenqr make [options] <text>        Make a code as a PNG, saved in Downloads (- reads the text from standard input)
                                                --type <t>        qr (default), datamatrix, aztec, pdf417, code128, ean13, upca, ean8
                                                --out <file|dir>  where to save it (- writes the PNG to standard output)
                                                --size <px>       width in pixels (default 1024), whole pixels per module
                                                --margin <n>      quiet zone in modules (default: the type's standard)
                                                --correction <c>  qr: L, M (default), Q, H; aztec: a percentage (23);
                                                                  pdf417: auto or 0 to 8
                                                --color <#RRGGBB>, --background <#RRGGBB|transparent>
                                                --shape square|rectangle (datamatrix), --height <modules> (barcodes),
                                                --no-digits (ean13, upca, ean8: no digits under the bars), --copy
      shenzhenqr wifi [--current | --ssid <name> [--password <p>] [--security wpa|wep|none] [--hidden]] [make options]
                                              A Wi-Fi code as a QR PNG in Downloads: phones that scan it join the network.
                                              --current uses this Mac's network and password (macOS asks for Location
                                              and your Mac's password first); --print gives its text only
      shenzhenqr parse <text>                 Say what a code's text is and what can be done with it
      shenzhenqr run <text> [<action>]        Do one of those things: a number or the start of its name
                                              (shenzhenqr run "WIFI:S:Lab;P:pw;;" join)
      shenzhenqr settings [<name> <value>]    Show the settings, or change one (shared with the app):
                                                resolution  auto or a size the camera has, such as 1920x1080
                                                cores       frames or pictures read at the same time (default 4)
                                                zoom        the window's zoom into the middle, 1 to 5 (camera uses it too)
                                                camera      a camera's name or ID, or auto
      shenzhenqr types                        List the code types
      shenzhenqr update [--check]             Install the newest version of ShenzhenQR, or only say if there is one

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

    Pictures are read harder than camera frames: cleaned up when nothing is read at first, and, when a barcode's bars
    are too blurred, its number is read from the digits printed under it (only when its check digit is right).

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
        var make = MakeOptions(), out: String?
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
            case "--type":
                let t = value(a).lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
                o.make.kind = CodeKind(rawValue: t == "dm" ? "datamatrix" : t)
                    ?? failed("--type is " + CodeKind.allCases.map(\.rawValue).joined(separator: ", "))
            case "--out": o.out = value(a)
            case "--size":
                guard let n = Int(value(a)), (16...20000).contains(n) else { fail("--size is a width in pixels, 16 to 20000") }
                o.make.size = n
            case "--margin":
                guard let n = Int(value(a)), (0...100).contains(n) else { fail("--margin is a number of modules, 0 to 100") }
                o.make.margin = n
            case "--correction":
                let c = value(a).uppercased()
                o.make.correction = c == "AUTO" ? "auto" : c
            case "--color": o.make.foreground = parseColor(value(a)) ?? failed("--color is #RRGGBB, such as #000000")
            case "--background":
                let v = value(a)
                o.make.background = v.lowercased() == "transparent" ? nil : parseColor(v) ?? failed("--background is #RRGGBB or transparent")
            case "--shape":
                switch value(a).lowercased() {
                case "square": o.make.shape = .square
                case "rectangle", "rect": o.make.shape = .rectangle
                default: fail("--shape is square or rectangle")
                }
            case "--height":
                guard let n = Int(value(a)), n > 0 else { fail("--height is a bar height in modules") }
                o.make.barHeight = n
            case "--no-digits": o.make.label = false
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
            "type": codeName(d) == "UPC-A" ? "upca" : symbologyKey(d.symbology), "type_name": codeName(d),
            "text": d.text, "kind": Payload.kind(d.text), "actions": Payload.actions(d.text).map(\.title),
            "image": ["width": Int(size.width), "height": Int(size.height)],
            "box": ["x": Int((b.minX * size.width).rounded()), "y": Int((b.minY * size.height).rounded()),
                    "width": Int((b.width * size.width).rounded()), "height": Int((b.height * size.height).rounded())],
            "corners": ["top_left": px(d.corners[0]), "top_right": px(d.corners[1]),
                        "bottom_right": px(d.corners[2]), "bottom_left": px(d.corners[3])],
            "confidence": num(Double(d.confidence), 3),
            "read_from": d.printed ? "printed digits" : "code",
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
        print("\(source): \(codeName(d))\(d.printed ? " (read from the printed digits)" : "") · \(Payload.kind(d.text)) · at x \(x), y \(y), \(w) × \(h) px of \(Int(size.width)) × \(Int(size.height))")
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
                let codes = detectInPhoto(image, types: o.types, region: part)
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

    /// update --check: says whether a newer version is out. update: installs it in place of this app.
    static func update(_ o: Options) -> Never {
        let checkOnly = o.rest.first == "--check" || o.rest.first == "check"
        let release: Update.Release?
        do { release = try Update.latestRelease(conditional: false) } catch { fail(String(describing: error), 1) }
        guard let release, Update.compare(release.version, Update.currentVersion) > 0 else {
            if o.json { print(jsonString(["installed": Update.currentVersion, "available": NSNull()])) }
            else { print("ShenzhenQR \(Update.currentVersion) is the latest version.") }
            exit(0)
        }
        if checkOnly {
            if o.json { print(jsonString(["installed": Update.currentVersion, "available": release.version])) }
            else { print("ShenzhenQR \(release.version) is available — you have \(Update.currentVersion). shenzhenqr update installs it.") }
            exit(0)
        }
        if Update.cantUpdateHere { fail("ShenzhenQR runs from a disk image here. Move it to your Applications folder first.", 1) }
        let staging: URL
        do { staging = try Update.stagingFolder() } catch { fail(String(describing: error), 1) }
        defer { try? FileManager.default.removeItem(at: staging) }
        FileHandle.standardError.write("Downloading ShenzhenQR \(release.version)…\n".data(using: .utf8)!)
        var request = URLRequest(url: release.url, timeoutInterval: 60)
        request.setValue("ShenzhenQR/\(Update.currentVersion) (macOS; +https://github.com/\(Update.repo))", forHTTPHeaderField: "User-Agent")
        let (data, response, error) = URLSession(configuration: .ephemeral).syncData(request)
        guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= Update.maxDownload
        else { fail("The update could not be downloaded.", 1) }
        let dmg = staging.appendingPathComponent(Update.asset)
        do { try data.write(to: dmg) } catch { fail("The downloaded update could not be saved.", 1) }
        let app: URL
        do { app = try Update.prepare(dmg: dmg, release: release, staging: staging) } catch { fail(String(describing: error), 1) }
        // Swap: a running ShenzhenQR keeps the version it started with until it reopens.
        let target = appBundle.bundleURL, old = URL(fileURLWithPath: target.path + ".old")
        try? FileManager.default.removeItem(at: old)
        guard rename(target.path, old.path) == 0 else { fail("ShenzhenQR couldn’t be replaced in \(target.deletingLastPathComponent().path).", 1) }
        guard rename(app.path, target.path) == 0, Update.verify(target, notarized: false, app: true) == nil else {
            try? FileManager.default.removeItem(at: target); _ = rename(old.path, target.path)
            fail("The update could not be installed; ShenzhenQR \(Update.currentVersion) is kept.", 1)
        }
        LSRegisterURL(target as CFURL, true)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Update.bundleID).contains { $0.processIdentifier != getpid() }
        print("Installed ShenzhenQR \(release.version)." + (running ? " The open ShenzhenQR window uses it once you quit and reopen it." : ""))
        exit(0)
    }

    /// make: a code as a PNG, saved in Downloads unless --out says otherwise (- writes it to standard output).
    static func make(_ o: Options) -> Never {
        var m = o.make
        let text = o.rest.first == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                                         .trimmingCharacters(in: .newlines) : o.rest.joined(separator: " ")
        guard !text.isEmpty else { fail("What should the code hold? shenzhenqr make [--type qr] <text>") }
        m.text = text
        if let c = m.correction, !m.kind.corrections.isEmpty, !m.kind.corrections.contains(where: { $0.key == c }) {
            fail("--correction for \(m.kind.title) is " + m.kind.corrections.map(\.key).joined(separator: ", "))
        }
        let rendered: (image: CGImage, text: String)
        do { rendered = try renderCode(m) } catch { fail(makeProblem(error, kind: m.kind, shape: m.shape), 1) }
        let data = pngData(rendered.image)
        if o.out == "-" { FileHandle.standardOutput.write(data); exit(0) }
        let url: URL
        if let out = o.out {
            var u = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { u = freeFileName(defaultFileBase(m.kind), in: u) }
            else if u.pathExtension.lowercased() != "png" { u.appendPathExtension("png") }
            url = u
        } else {
            url = freeFileName(defaultFileBase(m.kind), in: downloadsFolder)
        }
        do { try data.write(to: url) } catch { fail("Couldn’t save \(url.path): \(error.localizedDescription)", 1) }
        if o.copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: .png)
        }
        if o.json {
            print(jsonString(["file": url.path, "type": m.kind.rawValue, "text": rendered.text,
                              "width": rendered.image.width, "height": rendered.image.height]))
        } else {
            print(url.path)
        }
        exit(0)
    }

    /// wifi: a Wi-Fi code, as a QR PNG like make (or its text with --print): the network given, or this Mac's.
    static func wifi(_ args: ArraySlice<String>) -> Never {
        var ssid: String?, password = "", security = WiFiSecurity.wpa, hidden = false, current = false, printOnly = false
        var rest: [String] = [], it = args.makeIterator()
        func value(_ f: String) -> String { it.next() ?? failed("\(f) needs a value") }
        while let a = it.next() {
            switch a {
            case "--current": current = true
            case "--ssid", "--name": ssid = value(a)
            case "--password": password = value(a)
            case "--security":
                switch value(a).lowercased() {
                case "wpa", "wpa2", "wpa3": security = .wpa
                case "wep": security = .wep
                case "none", "open", "nopass": security = .none
                default: fail("--security is wpa, wep or none")
                }
            case "--hidden": hidden = true
            case "--print": printOnly = true
            default: rest.append(a)      // make's options
            }
        }
        if current {
            let permission = CurrentWiFi.Permission(), done = DispatchSemaphore(value: 0)
            var allowed = false
            DispatchQueue.main.async { permission.request { allowed = $0; done.signal() } }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            guard allowed else {
                fail("macOS shows the Wi-Fi name only to apps allowed to use Location: allow your terminal app in System Settings › Privacy & Security › Location Services", 3)
            }
            guard let net = CurrentWiFi.network() else { fail("This Mac isn’t connected to a Wi-Fi network", 1) }
            ssid = ssid ?? net.ssid; security = net.security
            if security != .none, password.isEmpty {
                FileHandle.standardError.write("macOS asks for your Mac’s password before sharing the Wi-Fi password…\n".data(using: .utf8)!)
                password = CurrentWiFi.password(net.ssid) ?? failed("The Wi-Fi password wasn’t shared: give it with --password", 1)
            }
        }
        guard let ssid, !ssid.isEmpty else { fail("Which network? shenzhenqr wifi --ssid <name> [--password <p>], or --current") }
        let text = wifiPayload(ssid: ssid, password: password, security: security, hidden: hidden)
        if printOnly { print(text); exit(0) }
        var o = parse(ArraySlice(rest))
        o.make.kind = .qr
        o.rest = [text]
        if o.out == nil { o.out = freeFileName(defaultFileBase(.qr, wifi: ssid), in: downloadsFolder).path }
        make(o)
    }

    static func types() -> Never {
        for s in VNDetectBarcodesRequest().supportedSymbologiesOrEmpty { print("\(symbologyKey(s))\t\(symbologyName(s))") }
        exit(0)
    }

    static func main(_ args: [String]) -> Never {
        active = true
        if args[1] == "--verify-update", args.count == 4 {
            // Test: runs the updater's checks on a local disk image, as if it were release `args[3]`.
            let dmg = URL(fileURLWithPath: args[2])
            let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? 0
            let r = Update.Release(tag: "v" + args[3], version: args[3], url: dmg, size: size, digest: nil, notes: "")
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            do { let app = try Update.prepare(dmg: dmg, release: r, staging: staging); print("passes: \(app.lastPathComponent)") }
            catch { print("refused: \(error)") }
            exit(0)
        }
        if args[1] == "wifi" { wifi(args.dropFirst(2)) }
        if args[1] == "update" {
            // update takes its own words: update, update --check, --json
            var o = Options(); o.json = args.contains("--json"); o.rest = args.dropFirst(2).filter { $0 != "--json" }
            update(o)
        }
        let o = parse(args.dropFirst(2))
        switch args[1] {
        case "scan": scan(o)
        case "camera": camera(o)
        case "cameras": listCameras()
        case "make", "create": make(o)
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
            if args[3] == "create" {
                // The Create tab, Advanced open when asked.
                NSApp.appearance = NSAppearance(named: .aqua)
                let d = AppDelegate(); d.offscreen = true
                d.buildWindow(); d.window.setContentSize(NSSize(width: 560, height: 640))
                d.showTab(1)
                if args.count > 4 {
                    if args.count > 6, args[6] == "advanced" { d.createView.advancedButton.state = .on; d.createView.toggleAdvanced() }
                    if let k = CodeKind(rawValue: args[4]) { d.createView.kindMenu.selectItem(at: CodeKind.allCases.firstIndex(of: k)!); d.createView.kindChanged() }
                    if args.count > 5, args[5].hasPrefix("wifi=") {
                        d.createView.contentMode.selectedSegment = 1; d.createView.modeChanged()
                        d.createView.ssidField.stringValue = String(args[5].dropFirst(5)); d.createView.passwordField.stringValue = "hello-shenzhen"
                        d.createView.changed()
                    } else if args.count > 5 { d.createView.textView.string = args[5]; d.createView.changed() }
                }
                let view = d.window.contentView!.superview ?? d.window.contentView!
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
                exit(0)
            }
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
                while d.photoText == nil || d.photoLines.isEmpty && Date() < deadline - 15, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
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

// MARK: - Making codes

// Data Matrix and EAN/UPC encoders (checked by reading every symbol size back with Vision).
// Barcode encoders: Data Matrix ECC 200 and EAN-13 / UPC-A / EAN-8. Pure Swift, no imports needed.

// MARK: - Shared types

/// A 2D symbol as modules, row 0 at the top; true = dark. No quiet zone.
struct ModuleMatrix {
    let width: Int
    let height: Int
    let dark: [Bool] // row-major
    subscript(x: Int, y: Int) -> Bool { dark[y * width + x] }
}

/// `.automatic` picks the smallest symbol (fewest modules) of either shape; ties go to square.
enum DataMatrixShape { case square, rectangle, automatic }
enum EncoderError: Error { case tooLong, invalidCharacters(String), invalidCheckDigit(expected: Int) }

// MARK: - Data Matrix ECC 200 (ISO/IEC 16022)

/// One ECC 200 symbol size (ISO/IEC 16022, table 7).
private struct DMSymbol {
    let rows, cols: Int             // whole symbol, in modules
    let regionRows, regionCols: Int // one data region, without its finder/timing border
    let dataCodewords, eccCodewords, blocks: Int
    init(_ r: Int, _ c: Int, _ rr: Int, _ rc: Int, _ d: Int, _ e: Int, _ b: Int) {
        (rows, cols, regionRows, regionCols, dataCodewords, eccCodewords, blocks) = (r, c, rr, rc, d, e, b)
    }
}

private let dmSymbols: [DMSymbol] = [
    // square: one region
    .init(10, 10, 8, 8, 3, 5, 1), .init(12, 12, 10, 10, 5, 7, 1), .init(14, 14, 12, 12, 8, 10, 1),
    .init(16, 16, 14, 14, 12, 12, 1), .init(18, 18, 16, 16, 18, 14, 1), .init(20, 20, 18, 18, 22, 18, 1),
    .init(22, 22, 20, 20, 30, 20, 1), .init(24, 24, 22, 22, 36, 24, 1), .init(26, 26, 24, 24, 44, 28, 1),
    // square: 2x2 regions
    .init(32, 32, 14, 14, 62, 36, 1), .init(36, 36, 16, 16, 86, 42, 1), .init(40, 40, 18, 18, 114, 48, 1),
    .init(44, 44, 20, 20, 144, 56, 1), .init(48, 48, 22, 22, 174, 68, 1), .init(52, 52, 24, 24, 204, 84, 2),
    // square: 4x4 regions
    .init(64, 64, 14, 14, 280, 112, 2), .init(72, 72, 16, 16, 368, 144, 4), .init(80, 80, 18, 18, 456, 192, 4),
    .init(88, 88, 20, 20, 576, 224, 4), .init(96, 96, 22, 22, 696, 272, 4), .init(104, 104, 24, 24, 816, 336, 6),
    // square: 6x6 regions
    .init(120, 120, 18, 18, 1050, 408, 6), .init(132, 132, 20, 20, 1304, 496, 8), .init(144, 144, 22, 22, 1558, 620, 10),
    // rectangular
    .init(8, 18, 6, 16, 5, 7, 1), .init(8, 32, 6, 14, 10, 11, 1), .init(12, 26, 10, 24, 16, 14, 1),
    .init(12, 36, 10, 16, 22, 18, 1), .init(16, 36, 14, 16, 32, 24, 1), .init(16, 48, 14, 22, 49, 28, 1),
]

/// ASCII encodation: digit pairs → 130+nn, ASCII c → c+1, bytes ≥128 → Upper Shift (235) then byte−127.
private func dmASCII(_ bytes: [UInt8]) -> [Int] {
    func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
    var out: [Int] = []
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if i + 1 < bytes.count, isDigit(b), isDigit(bytes[i + 1]) {
            out.append(130 + Int(b - 48) * 10 + Int(bytes[i + 1] - 48)); i += 2
        } else if b < 128 {
            out.append(Int(b) + 1); i += 1
        } else {
            out += [235, Int(b) - 127]; i += 1
        }
    }
    return out
}

// GF(256) with the Data Matrix field polynomial x^8+x^5+x^3+x^2+1 (0x12D).
private let gfExp: [Int] = {
    var e = [Int](repeating: 0, count: 512), x = 1
    for i in 0..<255 { e[i] = x; e[i + 255] = x; x <<= 1; if x & 0x100 != 0 { x ^= 0x12D } }
    return e
}()
private let gfLog: [Int] = {
    var l = [Int](repeating: 0, count: 256)
    for i in 0..<255 { l[gfExp[i]] = i }
    return l
}()
private func gfMul(_ a: Int, _ b: Int) -> Int { a == 0 || b == 0 ? 0 : gfExp[gfLog[a] + gfLog[b]] }

/// Reed–Solomon check codewords: remainder of data(x)·xⁿ divided by the generator
/// g(x) = (x − α¹)(x − α²)…(x − αⁿ), computed with a shift register.
private func rsCheck(_ data: [Int], _ n: Int) -> [Int] {
    var g = [1] // generator coefficients, highest power first
    for i in 1...n {
        var next = g + [0]
        for j in 1..<next.count { next[j] ^= gfMul(g[j - 1], gfExp[i]) }
        g = next
    }
    var rem = [Int](repeating: 0, count: n)
    for d in data {
        let f = d ^ rem[0]
        rem.removeFirst(); rem.append(0)
        for j in 0..<n { rem[j] ^= gfMul(f, g[j + 1]) }
    }
    return rem
}

/// ECC 200 module placement (ISO/IEC 16022 Annex F) into the mapping matrix (all data regions joined,
/// borders removed). Each codeword is an 8-module "utah" shape; shapes are laid along alternating diagonal
/// sweeps (up-right, then down-left), four special corner shapes handle sizes the sweep can't tile, and
/// modules that fall off one edge wrap around to the opposite edge.
private func dmPlace(_ cw: [Int], rows nrow: Int, cols ncol: Int) -> [Bool] {
    var cell = [Int8](repeating: -1, count: nrow * ncol) // -1 = not placed yet
    func module(_ r: Int, _ c: Int, _ k: Int, _ bit: Int) { // bit 0 = most significant
        var r = r, c = c
        if r < 0 { r += nrow; c += 4 - ((nrow + 4) % 8) }
        if c < 0 { c += ncol; r += 4 - ((ncol + 4) % 8) }
        cell[r * ncol + c] = Int8((cw[k] >> (7 - bit)) & 1)
    }
    func utah(_ r: Int, _ c: Int, _ k: Int) {
        let p = [(r - 2, c - 2), (r - 2, c - 1), (r - 1, c - 2), (r - 1, c - 1), (r - 1, c), (r, c - 2), (r, c - 1), (r, c)]
        for (i, (pr, pc)) in p.enumerated() { module(pr, pc, k, i) }
    }
    func corner(_ k: Int, _ p: [(Int, Int)]) { for (i, (pr, pc)) in p.enumerated() { module(pr, pc, k, i) } }
    let (R, C) = (nrow, ncol)
    var k = 0, r = 4, c = 0
    repeat {
        if r == R && c == 0 {
            corner(k, [(R-1, 0), (R-1, 1), (R-1, 2), (0, C-2), (0, C-1), (1, C-1), (2, C-1), (3, C-1)]); k += 1
        }
        if r == R - 2 && c == 0 && C % 4 != 0 {
            corner(k, [(R-3, 0), (R-2, 0), (R-1, 0), (0, C-4), (0, C-3), (0, C-2), (0, C-1), (1, C-1)]); k += 1
        }
        if r == R - 2 && c == 0 && C % 8 == 4 {
            corner(k, [(R-3, 0), (R-2, 0), (R-1, 0), (0, C-2), (0, C-1), (1, C-1), (2, C-1), (3, C-1)]); k += 1
        }
        if r == R + 4 && c == 2 && C % 8 == 0 {
            corner(k, [(R-1, 0), (R-1, C-1), (0, C-3), (0, C-2), (0, C-1), (1, C-3), (1, C-2), (1, C-1)]); k += 1
        }
        repeat { // sweep up-right
            if r < R && c >= 0 && cell[r * C + c] < 0 { utah(r, c, k); k += 1 }
            r -= 2; c += 2
        } while r >= 0 && c < C
        r += 1; c += 3
        repeat { // sweep down-left
            if r >= 0 && c < C && cell[r * C + c] < 0 { utah(r, c, k); k += 1 }
            r += 2; c -= 2
        } while r < R && c >= 0
        r += 3; c += 1
    } while r < R || c < C
    // Sizes that leave the bottom-right 2x2 unused get a fixed diagonal pattern there.
    if cell[R * C - 1] < 0 { cell[R * C - 1] = 1; cell[R * C - C - 2] = 1 }
    return cell.map { $0 == 1 }
}

/// Data Matrix ECC 200 (ISO/IEC 16022). Bytes: the text's UTF-8 bytes; values above 127 use the Upper Shift (235) codeword.
/// ASCII encodation with digit-pair compression. Picks the smallest symbol of the requested shape that fits.
func encodeDataMatrix(_ text: String, shape: DataMatrixShape) throws -> ModuleMatrix {
    // Readers take Data Matrix bytes as Latin-1: use it when the text fits (é, ü…), UTF-8 bytes otherwise.
    let latin1 = text.unicodeScalars.allSatisfy { $0.value <= 0xFF }
    var cw = dmASCII(latin1 ? text.unicodeScalars.map { UInt8($0.value) } : Array(text.utf8))
    let allowed = dmSymbols.filter {
        switch shape {
        case .square: return $0.rows == $0.cols
        case .rectangle: return $0.rows != $0.cols
        case .automatic: return true
        }
    }
    guard let sym = allowed.filter({ $0.dataCodewords >= cw.count })
        .min(by: { $0.rows * $0.cols < $1.rows * $1.cols }) else { throw EncoderError.tooLong }

    // Pad: first 129, then 129 + a pseudo-random value from the 1-based position (253-state randomising).
    if cw.count < sym.dataCodewords { cw.append(129) }
    while cw.count < sym.dataCodewords {
        let v = 129 + (149 * (cw.count + 1)) % 253 + 1
        cw.append(v > 254 ? v - 254 : v)
    }

    // Interleaving: the whole stream (data, then check codewords) is dealt round-robin, so position p
    // belongs to block p % blocks. Data codeword i goes to block i % blocks; block b's j-th check codeword
    // lands at the j-th position after the data whose p % blocks == b. Only 144x144 (1558 data codewords,
    // 10 blocks: 8 of 156 + 2 of 155) has data not a multiple of the block count, so its check codewords
    // start with block 8, not block 0.
    let nb = sym.blocks, eccPer = sym.eccCodewords / nb, nd = cw.count
    cw += [Int](repeating: 0, count: sym.eccCodewords)
    for b in 0..<nb {
        let check = rsCheck(stride(from: b, to: nd, by: nb).map { cw[$0] }, eccPer)
        for (j, v) in check.enumerated() { cw[nd + j * nb + (b - nd % nb + nb) % nb] = v }
    }

    let (rr, rc) = (sym.regionRows, sym.regionCols)
    let mapCols = sym.cols / (rc + 2) * rc
    let bits = dmPlace(cw, rows: sym.rows / (rr + 2) * rr, cols: mapCols)

    // Lay the mapping matrix into regions, each framed by its finder (solid left and bottom edges)
    // and timing pattern (alternating top and right edges).
    var dark = [Bool](repeating: false, count: sym.rows * sym.cols)
    for y in 0..<sym.rows {
        for x in 0..<sym.cols {
            let (ry, iy, rx, ix) = (y / (rr + 2), y % (rr + 2), x / (rc + 2), x % (rc + 2))
            let v: Bool
            if ix == 0 || iy == rr + 1 { v = true }
            else if iy == 0 { v = x % 2 == 0 }
            else if ix == rc + 1 { v = y % 2 == 1 }
            else { v = bits[(ry * rr + iy - 1) * mapCols + rx * rc + ix - 1] }
            dark[y * sym.cols + x] = v
        }
    }
    return ModuleMatrix(width: sym.cols, height: sym.rows, dark: dark)
}

// MARK: - EAN-13 / UPC-A / EAN-8

/// Bars as a Bool per module (true = bar), guard patterns included, no quiet zones.
/// `guardModules` are the modules drawn longer when digits are printed under the code: the start, centre
/// and end guards, plus (UPC-A only) the first and last digit, which UPC-A prints full height.
struct LinearBarcode { let text: String; let modules: [Bool]; let guardModules: Set<Int> }
enum LinearKind { case ean13, upcA, ean8 }

private let eanL = [0x0D, 0x19, 0x13, 0x3D, 0x23, 0x31, 0x2F, 0x3B, 0x37, 0x0B] // 7-bit L (odd) codes
/// EAN-13 first digit → which of the 6 left digits use G (even) codes, MSB = first digit.
private let eanParity = [0x00, 0x0B, 0x0D, 0x0E, 0x13, 0x19, 0x1C, 0x15, 0x16, 0x1A]

/// EAN-13 / UPC-A / EAN-8. `digits`: 12 or 13 for EAN-13, 11 or 12 for UPC-A, 7 or 8 for EAN-8; with the
/// longer length the last digit is checked. `text` is the full digit string with check digit
/// (12 digits for UPC-A). Non-digits → invalidCharacters(those characters); too many digits → tooLong;
/// too few → invalidCharacters(the input).
func encodeEAN(_ digits: String, kind: LinearKind) throws -> LinearBarcode {
    let bad = digits.filter { !($0.asciiValue.map { (48...57).contains($0) } ?? false) }
    if !bad.isEmpty { throw EncoderError.invalidCharacters(String(bad)) }
    let d = digits.map { Int($0.asciiValue! - 48) }
    let full = kind == .ean13 ? 13 : kind == .upcA ? 12 : 8
    if d.count > full { throw EncoderError.tooLong }
    if d.count < full - 1 { throw EncoderError.invalidCharacters(digits) }

    // Check digit: weights 3,1,3,… from the rightmost data digit.
    let body = d.count == full ? Array(d.dropLast()) : d
    let sum = body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 3 : 1) }
    let check = (10 - sum % 10) % 10
    if d.count == full && d.last != check { throw EncoderError.invalidCheckDigit(expected: check) }
    let all = body + [check]
    let sym = kind == .upcA ? [0] + all : all // UPC-A is EAN-13 with a leading 0

    var m: [Bool] = []
    var guards = Set<Int>()
    func add(_ bits: Int, _ n: Int, isGuard: Bool = false) {
        if isGuard { guards.formUnion(m.count..<(m.count + n)) }
        for i in (0..<n).reversed() { m.append((bits >> i) & 1 == 1) }
    }
    func rCode(_ v: Int) -> Int { ~eanL[v] & 0x7F }
    func gCode(_ v: Int) -> Int { // G = R code read backwards
        let r = rCode(v)
        return (0..<7).reduce(0) { $0 | ((r >> $1) & 1) << (6 - $1) }
    }

    let (left, right): (ArraySlice<Int>, ArraySlice<Int>)
    let parity: Int
    if kind == .ean8 { (left, right, parity) = (sym[0..<4], sym[4..<8], 0) }
    else { (left, right, parity) = (sym[1..<7], sym[7..<13], eanParity[sym[0]]) } // first digit is implied by parity
    add(0b101, 3, isGuard: true)
    for (i, v) in left.enumerated() { add((parity >> (left.count - 1 - i)) & 1 == 1 ? gCode(v) : eanL[v], 7) }
    add(0b01010, 5, isGuard: true)
    for v in right { add(rCode(v), 7) }
    add(0b101, 3, isGuard: true)
    if kind == .upcA { guards.formUnion(3..<10); guards.formUnion(85..<92) }
    return LinearBarcode(text: all.map(String.init).joined(), modules: m, guardModules: guards)
}


enum CodeKind: String, CaseIterable {
    case qr, datamatrix, aztec, pdf417, code128, ean13, upca, ean8
    var title: String {
        switch self {
        case .qr: "QR code"; case .datamatrix: "Data Matrix"; case .aztec: "Aztec code"; case .pdf417: "PDF417"
        case .code128: "Code 128"; case .ean13: "EAN-13"; case .upca: "UPC-A"; case .ean8: "EAN-8"
        }
    }
    var linear: Bool { [.code128, .ean13, .upca, .ean8].contains(self) }
    var retail: Bool { [.ean13, .upca, .ean8].contains(self) }
    /// The standard quiet zone, in modules: left and right (and top and bottom for 2D codes).
    var standardMargin: (left: Int, right: Int) {
        switch self {
        case .qr, .datamatrix: (4, 4); case .aztec, .pdf417: (2, 2); case .code128: (10, 10)
        case .ean13: (11, 7); case .upca: (9, 9); case .ean8: (7, 7)
        }
    }
    /// What can be put in it, said when it can't.
    var hint: String {
        switch self {
        case .ean13: "EAN-13 takes 12 digits (the 13th, the check digit, is added) or 13 digits"
        case .upca: "UPC-A takes 11 digits (the 12th, the check digit, is added) or 12 digits"
        case .ean8: "EAN-8 takes 7 digits (the 8th, the check digit, is added) or 8 digits"
        case .code128: "Code 128 takes letters, digits and symbols from the ASCII set, not accents or other scripts"
        default: "This is too much text for a \(title)"
        }
    }
    var corrections: [(key: String, title: String)] {
        switch self {
        case .qr: [("L", "Low (7%)"), ("M", "Medium (15%)"), ("Q", "Quartile (25%)"), ("H", "High (30%)")]
        case .aztec: [10, 23, 33, 50, 75].map { ("\($0)", "\($0)%") }
        case .pdf417: [("auto", "Automatic")] + (0...8).map { ("\($0)", "Level \($0)") }
        default: []
        }
    }
    var standardCorrection: String { switch self { case .qr: "M"; case .aztec: "23"; case .pdf417: "auto"; default: "" } }
}

struct MakeOptions {
    var kind = CodeKind.qr
    var text = ""
    var size = 1024                 // width in pixels, rounded down to whole pixels per module
    var margin: Int?                // quiet zone in modules; nil: the standard one
    var correction: String?         // nil: the standard one
    var foreground = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    var background: CGColor? = CGColor(red: 1, green: 1, blue: 1, alpha: 1)   // nil: transparent
    var shape = DataMatrixShape.square
    var barHeight: Int?             // 1D codes, in modules; nil: the standard one
    var label = true                // EAN/UPC: the digits under the bars
}

enum Symbol {
    case matrix(ModuleMatrix)
    case bars(LinearBarcode)
}

/// A CoreImage generator's output as modules, without the border it adds.
func modules(_ image: CIImage, border: Int) -> ModuleMatrix {
    let cg = CIContext().createCGImage(image, from: image.extent)!
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide - 2 * border, h = rep.pixelsHigh - 2 * border
    var dark = [Bool](); dark.reserveCapacity(w * h)
    for y in 0..<h { for x in 0..<w { dark.append((rep.colorAt(x: x + border, y: y + border)?.brightnessComponent ?? 1) < 0.5) } }
    return ModuleMatrix(width: w, height: h, dark: dark)
}

func makeSymbol(_ o: MakeOptions) throws -> Symbol {
    let correction = o.correction ?? o.kind.standardCorrection
    let data = Data(o.text.utf8)
    guard !o.text.isEmpty else { throw EncoderError.invalidCharacters("") }
    switch o.kind {
    case .qr:
        let f = CIFilter.qrCodeGenerator(); f.message = data; f.correctionLevel = correction
        guard let img = f.outputImage else { throw EncoderError.tooLong }
        return .matrix(modules(img, border: 1))
    case .aztec:
        let f = CIFilter.aztecCodeGenerator(); f.message = data; f.correctionLevel = Float(correction) ?? 23
        guard let img = f.outputImage else { throw EncoderError.tooLong }
        return .matrix(modules(img, border: 2))
    case .pdf417:
        let f = CIFilter.pdf417BarcodeGenerator(); f.message = data
        if let level = Float(correction) { f.correctionLevel = level }
        guard let img = f.outputImage else { throw EncoderError.tooLong }
        return .matrix(modules(img, border: 2))
    case .datamatrix:
        return .matrix(try encodeDataMatrix(o.text, shape: o.shape))
    case .code128:
        guard o.text.allSatisfy({ $0.isASCII }) else { throw EncoderError.invalidCharacters(o.text) }
        let f = CIFilter.code128BarcodeGenerator(); f.message = data; f.quietSpace = 0; f.barcodeHeight = 1
        guard let img = f.outputImage else { throw EncoderError.tooLong }
        let row = modules(img, border: 0)
        return .bars(LinearBarcode(text: o.text, modules: (0..<row.width).map { row[$0, 0] }, guardModules: []))
    case .ean13: return .bars(try encodeEAN(o.text.filter { !$0.isWhitespace }, kind: .ean13))
    case .upca: return .bars(try encodeEAN(o.text.filter { !$0.isWhitespace }, kind: .upcA))
    case .ean8: return .bars(try encodeEAN(o.text.filter { !$0.isWhitespace }, kind: .ean8))
    }
}

/// The code as a picture: whole pixels per module (crisp), at most `size` wide.
func renderCode(_ o: MakeOptions) throws -> (image: CGImage, text: String) {
    let symbol = try makeSymbol(o)
    let m: (left: Int, right: Int) = o.margin.map { (left: $0, right: $0) } ?? o.kind.standardMargin
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func context(_ w: Int, _ h: Int) -> CGContext {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let bg = o.background { c.setFillColor(bg); c.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        c.setFillColor(o.foreground)
        return c
    }
    switch symbol {
    case .matrix(let mm):
        let cols = mm.width + m.left + m.right, rows = mm.height + m.left + m.right
        let px = max(1, o.size / cols)
        let c = context(cols * px, rows * px)
        for y in 0..<mm.height { for x in 0..<mm.width where mm[x, y] {
            c.fill(CGRect(x: (x + m.left) * px, y: (rows - 1 - (y + m.left)) * px, width: px, height: px))
        } }
        return (c.makeImage()!, o.text)
    case .bars(let b):
        let n = b.modules.count, cols = n + m.left + m.right
        let px = max(1, o.size / cols)
        let standardHeight: Int = switch o.kind { case .ean13, .upca: 69; case .ean8: 55; default: max(30, n / 4) }
        let barRows = max(1, o.barHeight ?? standardHeight)
        let label = o.label && o.kind.retail
        let vertical = 2, below = label ? 11 : 0, guardExtra = label ? 5 : 0
        let rows = vertical + barRows + below + vertical
        let c = context(cols * px, rows * px)
        let top = (rows - vertical) * px                 // CoreGraphics counts from the bottom
        for i in 0..<n where b.modules[i] {
            let long = b.guardModules.contains(i) ? guardExtra : 0
            let height = (barRows + long) * px
            c.fill(CGRect(x: (m.left + i) * px, y: top - height, width: px, height: height))
        }
        if label { drawRetailDigits(b, kind: o.kind, into: c, px: px, left: m.left, baseline: (vertical + 1) * px, color: o.foreground) }   // digits fill the 11 modules under the bars
        return (c.makeImage()!, b.text)
    }
}

/// The digits under an EAN or UPC barcode, where they are printed by convention.
func drawRetailDigits(_ b: LinearBarcode, kind: CodeKind, into c: CGContext, px: Int, left: Int, baseline: Int, color: CGColor) {
    let digits = Array(b.text)
    var places: [(Character, Double, Double)] = []   // digit, centre in modules from the code's left edge, size factor
    switch kind {
    case .ean13:
        places.append((digits[0], -4.5, 1))
        for i in 0..<6 { places.append((digits[1 + i], 3 + 7 * Double(i) + 3.5, 1)) }
        for i in 0..<6 { places.append((digits[7 + i], 50 + 7 * Double(i) + 3.5, 1)) }
    case .upca:
        let t = digits.count == 13 ? Array(digits.dropFirst()) : digits
        places.append((t[0], -4.5, 0.75))
        for i in 1...5 { places.append((t[i], 3 + 7 * Double(i) + 3.5, 1)) }
        for i in 0..<5 { places.append((t[6 + i], 50 + 7 * Double(i) + 3.5, 1)) }
        places.append((t[11], 95 + 4.5, 0.75))
    case .ean8:
        for i in 0..<4 { places.append((digits[i], 3 + 7 * Double(i) + 3.5, 1)) }
        for i in 0..<4 { places.append((digits[4 + i], 36 + 7 * Double(i) + 3.5, 1)) }
    default: return
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    for (digit, centre, factor) in places {
        // Digits as tall as the guard bars' extra length plus a little: their tops stay clear of the shorter bars.
        let font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(10 * px) * factor, weight: .regular)
        let s = NSAttributedString(string: String(digit), attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .black])
        let w = s.size().width
        // draw(at:) places the line's bottom (descender included); put the digits' baseline on `baseline`.
        s.draw(at: NSPoint(x: (Double(left) + centre) * Double(px) - w / 2, y: Double(baseline) + Double(font.descender)))
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// What went wrong, for the person who typed the text.
func makeProblem(_ error: Error, kind: CodeKind, shape: DataMatrixShape = .square) -> String {
    switch error as? EncoderError {
    case .tooLong where kind == .datamatrix && shape == .rectangle: "This is too much text for a rectangular Data Matrix: choose Square"
    case .invalidCheckDigit(let expected): "The last digit should be \(expected): it’s the check digit of the others"
    case .invalidCharacters(let t) where t.isEmpty && kind == .qr: "Type the text to put in the code, or the Wi-Fi network’s name"
    case .invalidCharacters(let t) where t.isEmpty: "Type the text to put in the code"
    default: kind.hint
    }
}

func pngData(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

/// A name that's free in `folder`: "QR code 2026-11-11 at 21.40.12.png", then " 2", " 3"…
func freeFileName(_ base: String, in folder: URL) -> URL {
    var url = folder.appendingPathComponent(base + ".png"), n = 2
    while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(base) \(n).png"); n += 1 }
    return url
}

func defaultFileBase(_ kind: CodeKind, wifi: String? = nil) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    if let wifi { return "Wi-Fi \(wifi.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")) \(f.string(from: Date()))" }
    return "\(kind.title) \(f.string(from: Date()))"
}

var downloadsFolder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

/// "#RRGGBB" or "#RRGGBBAA".
func parseColor(_ text: String) -> CGColor? {
    var t = text.trimmingCharacters(in: .whitespaces); if t.hasPrefix("#") { t.removeFirst() }
    guard t.count == 6 || t.count == 8, let v = UInt64(t, radix: 16) else { return nil }
    let a = t.count == 8 ? Double(v & 0xFF) / 255 : 1, rgb = t.count == 8 ? v >> 8 : v
    return CGColor(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: a)
}

// MARK: - Wi-Fi codes

enum WiFiSecurity: String, CaseIterable {
    case wpa = "WPA", wep = "WEP", none = "nopass"
    var title: String { switch self { case .wpa: "WPA, WPA2 or WPA3"; case .wep: "WEP (old)"; case .none: "None (open network)" } }
}

/// The text phones read as "join this network": WIFI:T:WPA;S:name;P:password;; with \ ; , : " escaped.
func wifiPayload(ssid: String, password: String, security: WiFiSecurity, hidden: Bool) -> String {
    let esc = { (t: String) in t.reduce(into: "") { out, c in if "\\;,:\"".contains(c) { out.append("\\") }; out.append(c) } }
    var t = "WIFI:T:\(security.rawValue);S:\(esc(ssid));"
    if security != .none, !password.isEmpty { t += "P:\(esc(password));" }
    if hidden { t += "H:true;" }
    return t + ";"
}

/// The Wi-Fi network this Mac is on, and its password from the keychain. macOS gives the name only to apps allowed
/// to use Location, and shows its own prompt before handing out the password.
enum CurrentWiFi {
    struct Network { let ssid: String; let security: WiFiSecurity; var password: String? }

    static func security(_ s: CWSecurity) -> WiFiSecurity {
        switch s {
        case .none: .none
        case .WEP, .dynamicWEP: .wep
        default: .wpa
        }
    }

    /// nil when there is no Wi-Fi, it isn't connected, or Location isn't allowed (macOS then hides the name).
    static func network() -> Network? {
        guard let i = CWWiFiClient.shared().interface(), let ssid = i.ssid(), !ssid.isEmpty else { return nil }
        return Network(ssid: ssid, security: security(i.security()), password: nil)
    }

    /// The saved password; macOS asks the person first. nil if they decline or none is saved.
    static func password(_ ssid: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-D", "AirPort network password", "-a", ssid, "-w"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let pw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return p.terminationStatus == 0 && !pw.isEmpty ? pw : nil
    }

    /// Asks for Location when macOS hasn't asked yet; `done` gets whether it's allowed (on the main queue).
    final class Permission: NSObject, CLLocationManagerDelegate {
        let manager = CLLocationManager()
        var done: ((Bool) -> Void)?
        func request(_ done: @escaping (Bool) -> Void) {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorized: done(true)
            case .notDetermined:
                self.done = done
                manager.delegate = self
                manager.requestWhenInUseAuthorization()
            default: done(false)
            }
        }
        func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
            guard m.authorizationStatus != .notDetermined, let done else { return }
            self.done = nil
            DispatchQueue.main.async { done(m.authorizationStatus == .authorizedAlways || m.authorizationStatus == .authorized) }
        }
    }
}

/// The Create tab: type, text, size and where to save, with the rest under Advanced.
final class CreateView: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    let kindMenu = NSPopUpButton()
    let textView = FieldTextView()
    let preview = NSImageView()
    let sizeField = NSTextField(string: "1024")
    let folderControl = NSPathControl()
    let advancedButton = NSButton()
    let correctionMenu = NSPopUpButton(), marginMenu = NSPopUpButton(), shapeMenu = NSPopUpButton()
    let heightField = NSTextField(string: ""), labelBox = NSButton(checkboxWithTitle: "Digits under the barcode", target: nil, action: nil)
    let foreground = NSColorWell(), background = NSColorWell()
    let transparentBox = NSButton(checkboxWithTitle: "Transparent background", target: nil, action: nil)
    let nameField = NSTextField(string: "")
    let infoLabel = NSTextField(labelWithString: ""), statusLabel = NSTextField(labelWithString: "")
    let contentMode = NSSegmentedControl(labels: ["Text", "Wi-Fi network"], trackingMode: .selectOne, target: nil, action: nil)
    let ssidField = NSTextField(string: ""), passwordField = NSTextField(string: "")
    let securityMenu = NSPopUpButton(), hiddenBox = NSButton(checkboxWithTitle: "Hidden network", target: nil, action: nil)
    let currentButton = NSButton(title: "Use Current Wi-Fi", target: nil, action: nil)
    let permission = CurrentWiFi.Permission()
    let saveButton = NSButton(title: "Save PNG", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy Image", target: nil, action: nil)
    let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    var rows: [String: NSGridRow] = [:]
    var textRow: NSGridRow?, wifiRows: [NSGridRow] = []
    var wifiMode: Bool { kind == .qr && contentMode.selectedSegment == 1 }
    var lastSaved: URL?
    var current: CGImage?

    init() {
        super.init(frame: .zero)
        kindMenu.addItems(withTitles: CodeKind.allCases.map(\.title))
        kindMenu.target = self; kindMenu.action = #selector(kindChanged)
        textView.isRichText = false; textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = self; textView.autoresizingMask = [.width]; textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = "https://github.com/casimir-engineering/shenzhen-qr"
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor; preview.layer?.cornerRadius = 6
        sizeField.target = self; sizeField.action = #selector(changed)
        sizeField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        folderControl.pathStyle = .popUp
        folderControl.url = Settings.defaults.string(forKey: "makeFolder").map { URL(fileURLWithPath: $0) } ?? downloadsFolder
        folderControl.target = self; folderControl.action = #selector(folderChosen)
        folderControl.delegate = self

        advancedButton.bezelStyle = .disclosure; advancedButton.setButtonType(.pushOnPushOff); advancedButton.title = ""
        advancedButton.target = self; advancedButton.action = #selector(toggleAdvanced)
        let advancedLabel = NSTextField(labelWithString: "Advanced")
        marginMenu.addItem(withTitle: "Standard")
        marginMenu.addItems(withTitles: (0...20).map { "\($0) modules" })
        shapeMenu.addItems(withTitles: ["Square", "Rectangle"])
        heightField.placeholderString = "Standard"
        heightField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        foreground.color = .black; background.color = .white
        nameField.placeholderString = "\(CodeKind.qr.title) <date and time>"
        for c in [correctionMenu, marginMenu, shapeMenu] { c.target = self; c.action = #selector(changed) }
        for c in [heightField, nameField] as [NSTextField] { c.target = self; c.action = #selector(changed) }
        for c in [labelBox, transparentBox] { c.target = self; c.action = #selector(changed) }
        labelBox.state = .on
        for w in [foreground, background] { w.target = self; w.action = #selector(changed) }
        let colors = NSStackView(views: [foreground, NSTextField(labelWithString: "on"), background, transparentBox])
        let px = NSTextField(labelWithString: "modules")
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        // One grid, so the labels line up: the basic rows, Advanced, then its rows (shown when open and when they
        // apply to the type).
        contentMode.selectedSegment = 0
        contentMode.target = self; contentMode.action = #selector(modeChanged)
        ssidField.placeholderString = "Network name"; passwordField.placeholderString = "Password"
        for f in [ssidField, passwordField] { f.delegate = self; f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        securityMenu.addItems(withTitles: WiFiSecurity.allCases.map(\.title))
        securityMenu.target = self; securityMenu.action = #selector(changed)
        hiddenBox.target = self; hiddenBox.action = #selector(changed)
        currentButton.target = self; currentButton.action = #selector(useCurrentWiFi)
        let basic = NSGridView(views: [
            [NSTextField(labelWithString: "Type:"), kindMenu],
            [NSTextField(labelWithString: "Content:"), contentMode],
            [NSGridCell.emptyContentView, scroll],
            [NSTextField(labelWithString: "Network:"), NSStackView(views: [ssidField, currentButton])],
            [NSTextField(labelWithString: "Password:"), passwordField],
            [NSTextField(labelWithString: "Security:"), securityMenu],
            [NSGridCell.emptyContentView, hiddenBox],
            [NSTextField(labelWithString: "Width:"), NSStackView(views: [sizeField, NSTextField(labelWithString: "pixels"), infoLabel])],
            [NSTextField(labelWithString: "Save in:"), folderControl],
            [NSGridCell.emptyContentView, NSStackView(views: [advancedButton, advancedLabel])],
        ])
        textRow = basic.row(at: 2)
        wifiRows = (3...6).map { basic.row(at: $0) }
        let addRow = { (key: String, label: String, views: [NSView]) in
            let content = views.count == 1 ? views[0] : NSStackView(views: views)
            self.rows[key] = basic.addRow(with: [label.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: label), content])
        }
        addRow("correction", "Error correction:", [correctionMenu])
        addRow("margin", "Quiet zone:", [marginMenu])
        addRow("shape", "Shape:", [shapeMenu])
        addRow("height", "Bar height:", [heightField, px])
        addRow("label", "", [labelBox])
        addRow("colors", "Colors:", [colors])
        addRow("name", "File name:", [nameField])
        basic.column(at: 0).xPlacement = .trailing
        basic.column(at: 0).width = 118
        basic.rowSpacing = 8
        basic.row(at: 2).yPlacement = .top
        infoLabel.textColor = .secondaryLabelColor
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingMiddle
        saveButton.target = self; saveButton.action = #selector(save); saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = .command
        copyButton.target = self; copyButton.action = #selector(copyImage)
        revealButton.target = self; revealButton.action = #selector(reveal); revealButton.isHidden = true
        let bottom = NSStackView(views: [statusLabel, revealButton, NSView(), copyButton, saveButton])

        let stack = NSStackView(views: [preview, basic, bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            basic.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        // The preview shrinks to the window: left alone it asks for the PNG's full size, which made the window wide.
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            preview.setContentHuggingPriority(.defaultLow, for: o)
            preview.setContentCompressionResistancePriority(.init(1), for: o)
        }
        kindChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    var kind: CodeKind { CodeKind.allCases[max(0, kindMenu.indexOfSelectedItem)] }

    /// Advanced shows only what applies to this type, with its standard values.
    @objc func kindChanged() {
        let k = kind
        correctionMenu.removeAllItems()
        correctionMenu.addItems(withTitles: k.corrections.map(\.title))
        correctionMenu.selectItem(at: k.corrections.firstIndex { $0.key == k.standardCorrection } ?? 0)
        marginMenu.item(at: 0)?.title = "Standard (\(k.standardMargin.left == k.standardMargin.right ? "\(k.standardMargin.left)" : "\(k.standardMargin.left) and \(k.standardMargin.right)") modules)"
        marginMenu.selectItem(at: 0)
        showRows()
        nameField.placeholderString = "\(k.title) <date and time>"
        if k.retail, textView.string.contains(where: { !$0.isNumber && !$0.isWhitespace }) { textView.string = "" }
        changed()
    }

    @objc func toggleAdvanced() { showRows() }

    /// Advanced rows: shown when Advanced is open, each only for the types it applies to.
    func showRows() {
        // Wi-Fi codes are QR codes: phones read the network from those.
        basicRow(contentMode)?.isHidden = kind != .qr
        textRow?.isHidden = wifiMode
        for r in wifiRows { r.isHidden = !wifiMode }
        let open = advancedButton.state == .on, k = kind
        let applies: [String: Bool] = ["correction": !k.corrections.isEmpty, "shape": k == .datamatrix, "height": k.linear, "label": k.retail]
        for (key, row) in rows { row.isHidden = !open || applies[key] == false }
    }

    func textDidChange(_ notification: Notification) { changed() }
    func controlTextDidChange(_ obj: Notification) { changed() }

    func basicRow(_ view: NSView) -> NSGridRow? {
        guard let grid = view.superview as? NSGridView ?? view.superview?.superview as? NSGridView else { return nil }
        return grid.cell(for: view)?.row
    }

    @objc func modeChanged() { showRows(); changed() }

    /// Fills in the network this Mac is on and its password. macOS asks for Location first (it counts Wi-Fi names
    /// as location), then for the Mac's password before showing the Wi-Fi password.
    @objc func useCurrentWiFi() {
        permission.request { allowed in
            guard allowed else {
                let a = NSAlert()
                a.messageText = "ShenzhenQR can’t see the Wi-Fi name"
                a.informativeText = "macOS shows the name of your Wi-Fi network only to apps allowed to use Location. Allow ShenzhenQR in Location Services, then try again."
                a.addButton(withTitle: "Open Location Services"); a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
                return
            }
            guard let net = CurrentWiFi.network() else { self.say("This Mac isn’t connected to a Wi-Fi network", error: true); return }
            self.ssidField.stringValue = net.ssid
            self.securityMenu.selectItem(at: WiFiSecurity.allCases.firstIndex(of: net.security) ?? 0)
            self.hiddenBox.state = .off
            self.changed()
            guard net.security != .none else { return }
            self.say("macOS asks for your Mac’s password before sharing the Wi-Fi password…", error: false)
            DispatchQueue.global(qos: .userInitiated).async {
                let pw = CurrentWiFi.password(net.ssid)
                DispatchQueue.main.async {
                    if let pw { self.passwordField.stringValue = pw; self.changed() }
                    else { self.say("The password wasn’t shared: type it in", error: true) }
                }
            }
        }
    }

    func say(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        revealButton.isHidden = true
    }

    var options: MakeOptions {
        var o = MakeOptions()
        o.kind = kind
        o.text = wifiMode
            ? (ssidField.stringValue.isEmpty ? "" : wifiPayload(ssid: ssidField.stringValue, password: passwordField.stringValue,
                                                                security: WiFiSecurity.allCases[max(0, securityMenu.indexOfSelectedItem)],
                                                                hidden: hiddenBox.state == .on))
            : textView.string
        o.size = max(16, min(20000, sizeField.integerValue > 0 ? sizeField.integerValue : 1024))
        o.margin = marginMenu.indexOfSelectedItem > 0 ? marginMenu.indexOfSelectedItem - 1 : nil
        if !kind.corrections.isEmpty { o.correction = kind.corrections[max(0, correctionMenu.indexOfSelectedItem)].key }
        o.shape = shapeMenu.indexOfSelectedItem == 1 ? .rectangle : .square
        o.barHeight = heightField.integerValue > 0 ? heightField.integerValue : nil
        o.label = labelBox.state == .on
        o.foreground = foreground.color.usingColorSpace(.sRGB)?.cgColor ?? o.foreground
        o.background = transparentBox.state == .on ? nil : background.color.usingColorSpace(.sRGB)?.cgColor
        return o
    }

    @objc func changed() {
        nameField.placeholderString = wifiMode ? "Wi-Fi \(ssidField.stringValue.isEmpty ? "<network>" : ssidField.stringValue) <date and time>"
                                               : "\(kind.title) <date and time>"
        do {
            let (image, _) = try renderCode(options)
            current = image
            preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            infoLabel.stringValue = "\(image.width) × \(image.height)"
            statusLabel.stringValue = ""; statusLabel.textColor = .secondaryLabelColor
            saveButton.isEnabled = true; copyButton.isEnabled = true
        } catch {
            current = nil; preview.image = nil; infoLabel.stringValue = ""
            statusLabel.stringValue = makeProblem(error, kind: kind, shape: options.shape); statusLabel.textColor = .systemRed
            saveButton.isEnabled = false; copyButton.isEnabled = false
        }
        revealButton.isHidden = true
    }

    @objc func folderChosen() {
        if let url = folderControl.url { Settings.defaults.set(url.path, forKey: "makeFolder") }
    }

    @objc func save() {
        guard let image = current else { return }
        let folder = folderControl.url ?? downloadsFolder
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let base = defaultFileBase(kind, wifi: wifiMode ? ssidField.stringValue : nil)
        let url = freeFileName(name.isEmpty ? base : (name.hasSuffix(".png") ? String(name.dropLast(4)) : name), in: folder)
        do {
            try pngData(image).write(to: url)
            lastSaved = url
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Saved “\(url.lastPathComponent)” in \(folder.lastPathComponent)"
            revealButton.isHidden = false
        } catch {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = "Couldn’t save in \(folder.lastPathComponent): \(error.localizedDescription)"
        }
    }

    @objc func copyImage() {
        guard let image = current else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(pngData(image), forType: .png)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Image copied"
        revealButton.isHidden = true
    }

    @objc func reveal() { if let lastSaved { NSWorkspace.shared.activateFileViewerSelecting([lastSaved]) } }
}

extension CreateView: NSPathControlDelegate {
    /// The folder menu offers Choose… for any folder.
    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
        openPanel.canChooseDirectories = true; openPanel.canChooseFiles = false; openPanel.canCreateDirectories = true
        openPanel.prompt = "Choose"
    }
}

// MARK: - Updates (ShenzhenPDF's updater, in Swift)

/// Checks GitHub once a day (and on Check for Updates…), downloads ShenzhenQR.dmg, checks it is ours (Developer ID
/// team, notarized, hardened runtime, bundle ID, published version), then swaps the app in place and reopens it.
enum Update {
    static let repo = "casimir-engineering/shenzhen-qr"
    static let asset = "ShenzhenQR.dmg"
    static let team = "66LJ4BV7Q3"
    static let bundleID = "com.intuition.shenzhenqr"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    static let maxDownload = 64 * 1024 * 1024
    static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    static var d: UserDefaults { Settings.defaults }

    struct Release { let tag: String; let version: String; let url: URL; let size: Int; let digest: String?; let notes: String }

    enum Failure: Error, CustomStringConvertible {
        case message(String)
        var description: String { if case .message(let m) = self { return m }; return "" }
    }

    static var currentVersion: String { appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// "v1.2.3" or "1.2.3" as numbers; nil when not all numbers.
    static func numbers(_ v: String) -> [Int]? {
        let t = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let parts = t.split(separator: ".").map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.map { $0! }
    }
    static func compare(_ a: String, _ b: String) -> Int {
        guard let x = numbers(a), let y = numbers(b) else { return 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    static var autoUpdate: Bool {
        get { d.object(forKey: "autoUpdate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoUpdate") }
    }

    /// Where the app runs from can't be replaced: a disk image or a translocated copy.
    static var cantUpdateHere: Bool {
        let path = appBundle.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") || path.hasPrefix("/private/var/folders")
    }

    static func latestRelease(conditional: Bool) throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 15)
        request.setValue("ShenzhenQR/\(currentVersion) (macOS; +https://github.com/\(repo))", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if conditional, let etag = d.string(forKey: "updateETag") { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let (data, response, error) = URLSession(configuration: config).syncData(request)
        guard error == nil, let http = response as? HTTPURLResponse else { throw Failure.message("Could not reach the update server.") }
        if http.statusCode == 304 { return nil }
        guard http.statusCode == 200, let data else { throw Failure.message("The update server returned an unexpected response.") }
        if let etag = http.value(forHTTPHeaderField: "ETag") { d.set(etag, forKey: "updateETag") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = json["tag_name"] as? String,
              numbers(tag) != nil else { throw Failure.message("The update server response was malformed.") }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        guard let a = (json["assets"] as? [[String: Any]])?.first(where: { $0["name"] as? String == asset }),
              let link = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(tag: tag, version: version, url: link, size: a["size"] as? Int ?? 0,
                       digest: (a["digest"] as? String)?.replacingOccurrences(of: "sha256:", with: ""),
                       notes: json["body"] as? String ?? "")
    }

    /// A release worth offering: newer than this one and never older than the newest seen (no downgrades).
    static func offerable(_ r: Release) -> Bool {
        let highest = d.string(forKey: "highestVersionSeen") ?? currentVersion
        if compare(r.version, highest) > 0 { d.set(r.version, forKey: "highestVersionSeen") }
        return compare(r.version, currentVersion) > 0 && compare(r.version, highest) >= 0
    }

    /// The release notes for the prompt: up to the first ---, list items as •, plain text, at most 500 characters.
    static func shortNotes(_ body: String) -> String {
        var text = body.components(separatedBy: "\n---").first ?? body
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            while l.hasPrefix("#") { l = String(l.dropFirst()) }
            return l.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(text.unicodeScalars.filter { !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
                                                     && ($0.value >= 32 || $0 == "\n") })
        return text.count > 500 ? String(text.prefix(500)) + "\n…" : text
    }

    // MARK: Checking the download

    /// nil when the code at `url` is ours; otherwise why not (not shown, the user sees a general message).
    static func verify(_ url: URL, notarized: Bool, app: Bool) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return "unreadable" }
        var req: SecRequirement?
        guard SecRequirementCreateWithString((requirement + (notarized ? " and notarized" : "")) as CFString, [], &req) == errSecSuccess
        else { return "requirement" }
        let flags = app ? SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate) : []
        guard SecStaticCodeCheckValidityWithErrors(code, flags, req, nil) == errSecSuccess else { return "signature or notarization" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "signing information" }
        guard dict[kSecCodeInfoTeamIdentifier as String] as? String == team else { return "team" }
        if app {
            let codeFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            guard codeFlags & 0x10000 != 0 else { return "hardened runtime" }
            guard (dict[kSecCodeInfoPList as String] as? [String: Any])?["CFBundleIdentifier"] as? String == bundleID else { return "bundle" }
        }
        return nil
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: Data) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Checks the downloaded disk image and takes the app out of it, checked too, into `staging`. Returns the app.
    static func prepare(dmg: URL, release: Release, staging: URL) throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? -1
        if release.size > 0, size != release.size { throw Failure.message("The downloaded update was incomplete.") }
        if let digest = release.digest, let data = try? Data(contentsOf: dmg) {
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if hex != digest.lowercased() { throw Failure.message("The downloaded update appears to be corrupted.") }
        }
        guard verify(dmg, notarized: true, app: false) == nil else { throw Failure.message("The update could not be verified and was not installed.") }
        let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard attach.status == 0, let plist = try? PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any]
        else { throw Failure.message("The update disk image could not be opened.") }
        guard let mount = (plist["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first
        else { throw Failure.message("The update disk image had no mount point.") }
        defer { if run("/usr/bin/hdiutil", ["detach", mount]).status != 0 { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount]) } }
        let fm = FileManager.default
        let apps = ((try? fm.contentsOfDirectory(atPath: mount)) ?? []).filter { name in
            let path = (mount as NSString).appendingPathComponent(name)
            return name.hasSuffix(".app") && (try? fm.destinationOfSymbolicLink(atPath: path)) == nil
                && Bundle(path: path)?.bundleIdentifier == bundleID
        }
        guard apps.count == 1 else { throw Failure.message("The update disk image did not contain ShenzhenQR.") }
        let staged = staging.appendingPathComponent("ShenzhenQR.app")
        guard run("/usr/bin/ditto", [(mount as NSString).appendingPathComponent(apps[0]), staged.path]).status == 0
        else { throw Failure.message("The update could not be extracted.") }
        guard verify(staged, notarized: false, app: true) == nil else { throw Failure.message("The update could not be verified and was not installed.") }
        guard Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version
        else { throw Failure.message("The update did not match the published version.") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// A folder for the update beside the app, on its volume, so the swap is a rename.
    static func stagingFolder() throws -> URL {
        let parent = appBundle.bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure.message("ShenzhenQR can’t replace itself in “\(parent.lastPathComponent)”. Download the new version and drag it there instead.")
        }
        do { return try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true) }
        catch { throw Failure.message("Could not create a staging directory for the update.") }
    }

    /// Run as `ShenzhenQR --post-update <staged.app> <target.app> <pid>`, after the app quits: swaps the app (keeping
    /// the old one beside it until the next launch), checks it again, reopens it. Puts the old one back on failure.
    static func postUpdate(staged: URL, target: URL, pid: pid_t) -> Never {
        setsid()
        let fm = FileManager.default, old = URL(fileURLWithPath: target.path + ".old")
        func reopen(_ url: URL) {
            let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 20)
        }
        func giveUp() -> Never {
            try? fm.removeItem(at: staged)
            d.removeObject(forKey: "updatePendingVersion")
            reopen(target)
            exit(1)
        }
        for _ in 0..<40 where kill(pid, 0) == 0 { usleep(500_000) }       // wait up to 20 s for the app to quit
        guard kill(pid, 0) != 0, verify(staged, notarized: false, app: true) == nil else { giveUp() }
        usleep(500_000)
        try? fm.removeItem(at: old)
        guard rename(target.path, old.path) == 0 else { giveUp() }
        guard rename(staged.path, target.path) == 0 else { _ = rename(old.path, target.path); giveUp() }
        guard verify(target, notarized: false, app: true) == nil else {
            try? fm.removeItem(at: target); _ = rename(old.path, target.path); giveUp()
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
        LSRegisterURL(target as CFURL, true)
        reopen(target)
        exit(0)
    }

    /// At launch: says when an update just finished; removes the previous app kept from an update.
    static func afterLaunch() -> String? {
        let old = appBundle.bundlePath + ".old"
        var finished: String?
        if let pending = d.string(forKey: "updatePendingVersion") {
            d.removeObject(forKey: "updatePendingVersion")
            if compare(pending, currentVersion) == 0 { finished = pending; try? FileManager.default.removeItem(atPath: old) }
        } else if let made = (try? FileManager.default.attributesOfItem(atPath: old))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(made) > 3600 {
            try? FileManager.default.removeItem(atPath: old)
        }
        return finished
    }
}

extension URLSession {
    /// A request run to its end, for code already off the main thread.
    func syncData(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let done = DispatchSemaphore(value: 0)
        dataTask(with: request) { result = ($0, $1, $2); done.signal() }.resume()
        done.wait()
        return result
    }
}

/// The window side: daily checks, the prompt, the download with its progress panel, and the swap.
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()
    private let queue = DispatchQueue(label: "update", qos: .utility)
    private var busy = false, timer: Timer?
    private var panel: NSPanel?, heading = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    private var bar = NSProgressIndicator()
    private var task: URLSessionDownloadTask?, release: Update.Release?, staging: URL?, cancelled = false
    private var pendingPrompt: Update.Release?

    func start() {
        if let done = Update.afterLaunch() {
            let a = NSAlert(); a.messageText = "You’re now on ShenzhenQR \(done)."; a.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.dailyCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in self.dailyCheck() }
        timer?.tolerance = 600
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in self.dailyCheck() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if let r = self.pendingPrompt { self.pendingPrompt = nil; self.prompt(r, manual: false) }
        }
    }

    /// Once a day at most: the time is noted before asking, so a crash still counts as the day's check.
    func dailyCheck() {
        guard Update.autoUpdate, !busy, !Update.cantUpdateHere else { return }
        let last = Update.d.double(forKey: "lastUpdateCheck"), now = Date().timeIntervalSince1970
        guard last == 0 || now - last >= 86400 || now < last - 60 else { return }
        Update.d.set(now, forKey: "lastUpdateCheck")
        check(manual: false)
    }

    @objc func checkNow() { check(manual: true) }

    func check(manual: Bool) {
        if busy { if manual { say("An update is already in progress.") }; return }
        if Update.cantUpdateHere {
            if manual { say("To enable automatic updates, move ShenzhenQR to your Applications folder.") }
            return
        }
        busy = true
        queue.async {
            let result = Result { try Update.latestRelease(conditional: !manual) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .failure(let e): if manual { self.say(String(describing: e)) }
                case .success(let r):
                    guard let r, Update.offerable(r) else {
                        if manual { self.say("You’re up to date.", "ShenzhenQR \(Update.currentVersion) is the latest version.") }
                        return
                    }
                    if !manual {
                        if Update.d.string(forKey: "skippedUpdateVersion") == r.version { return }
                        if Update.d.string(forKey: "deferredUpdateVersion") == r.version,
                           Date().timeIntervalSince1970 < Update.d.double(forKey: "remindUpdateAfter") { return }
                        if !NSApp.isActive { self.pendingPrompt = r; return }
                    }
                    self.prompt(r, manual: manual)
                }
            }
        }
    }

    func prompt(_ r: Update.Release, manual: Bool) {
        let a = NSAlert()
        a.messageText = "A new version of ShenzhenQR is available"
        let notes = Update.shortNotes(r.notes)
        a.informativeText = "ShenzhenQR \(r.version) is available — you have \(Update.currentVersion). Would you like to install it now?"
            + (notes.isEmpty ? "" : "\n\n" + notes)
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Skip This Version")
        a.addButton(withTitle: "Later")
        switch a.runModal() {
        case .alertFirstButtonReturn: download(r)
        case .alertSecondButtonReturn: Update.d.set(r.version, forKey: "skippedUpdateVersion")
        default:
            Update.d.set(r.version, forKey: "deferredUpdateVersion")
            Update.d.set(Date().timeIntervalSince1970 + 7 * 86400, forKey: "remindUpdateAfter")
        }
    }

    func download(_ r: Update.Release) {
        guard r.url.scheme == "https" else { say("The update download URL was not secure."); return }
        let folder: URL
        do { folder = try Update.stagingFolder() } catch {
            let a = NSAlert(); a.alertStyle = .warning; a.messageText = "Software Update"; a.informativeText = String(describing: error)
            a.addButton(withTitle: "Open Download Page"); a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Update.releasesPage) }
            return
        }
        if let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           r.size > 0, free < Int64(r.size * 3) {
            say("There is not enough disk space to install the update."); return
        }
        busy = true; release = r; staging = folder; cancelled = false
        showPanel(r)
        var request = URLRequest(url: r.url, timeoutInterval: 60)
        request.setValue("ShenzhenQR/\(Update.currentVersion) (macOS; +https://github.com/\(Update.repo))", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        task = session.downloadTask(with: request)
        task?.resume()
    }

    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        completionHandler(request.url?.scheme == "https" && redirects <= 5 ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let ceiling = Int64(min(Update.maxDownload, (release?.size ?? 0) > 0 ? release!.size + 1 : Update.maxDownload))
        if totalBytesWritten > ceiling || totalBytesExpectedToWrite > Int64(Update.maxDownload) { downloadTask.cancel(); return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(release?.size ?? 0)
        if total > 0 { bar.isIndeterminate = false; bar.doubleValue = Double(totalBytesWritten) / Double(total) }
        detail.stringValue = String(format: "%.1f MB of %.1f MB", Double(totalBytesWritten) / 1e6, Double(total) / 1e6)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let staging, let release else { return }
        let dmg = staging.appendingPathComponent(Update.asset)
        do { try FileManager.default.moveItem(at: location, to: dmg) } catch { finish(error: "The downloaded update could not be saved."); return }
        detail.stringValue = "Verifying signature…"
        bar.isIndeterminate = true; bar.startAnimation(nil)
        queue.async {
            let result = Result { try Update.prepare(dmg: dmg, release: release, staging: staging) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let e): self.finish(error: String(describing: e))
                case .success(let app): self.detail.stringValue = "Preparing update…"; self.install(app, release)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if cancelled { finish(error: nil) } else { finish(error: (error as NSError).code == NSURLErrorCancelled
            ? "The downloaded update was incomplete." : "The update could not be downloaded.") }
    }

    func install(_ app: URL, _ r: Update.Release) {
        panel?.orderOut(nil)
        let a = NSAlert()
        a.messageText = "ShenzhenQR will close and reopen to finish updating."
        a.addButton(withTitle: "Install Now"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { finish(error: nil); return }
        Update.d.set(r.version, forKey: "updatePendingVersion")
        Update.d.synchronize()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: appBundle.executablePath!)
        helper.arguments = ["--post-update", app.path, appBundle.bundlePath, String(getpid())]
        do { try helper.run() } catch { Update.d.removeObject(forKey: "updatePendingVersion"); finish(error: "The update could not be extracted."); return }
        NSApp.terminate(nil)
    }

    @objc func cancelDownload() { cancelled = true; task?.cancel() }

    func finish(error: String?) {
        busy = false; panel?.orderOut(nil); panel = nil; task = nil
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
        if let error { say(error) }
    }

    func showPanel(_ r: Update.Release) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        p.title = "Software Update"
        heading.stringValue = "Downloading ShenzhenQR \(r.version)"
        heading.font = .boldSystemFont(ofSize: 13)
        detail.stringValue = "Starting…"; detail.textColor = .secondaryLabelColor
        bar = NSProgressIndicator(); bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = 0
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDownload))
        let stack = NSStackView(views: [heading, bar, detail, cancel])
        stack.orientation = .vertical; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 340).isActive = true
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        p.contentView = stack
        p.center(); p.makeKeyAndOrderFront(nil)
        panel = p
    }

    func say(_ title: String, _ text: String = "") {
        let a = NSAlert()
        if text.isEmpty && !title.hasPrefix("You’re") { a.alertStyle = .warning; a.messageText = "Software Update"; a.informativeText = title }
        else { a.messageText = title; a.informativeText = text }
        a.runModal()
    }

    @objc func toggleAutomatic(_ item: NSMenuItem) {
        Update.autoUpdate.toggle()
        item.state = Update.autoUpdate ? .on : .off
    }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.count == 5, args[1] == "--post-update", let pid = pid_t(args[4]) {
    Update.postUpdate(staged: URL(fileURLWithPath: args[2]), target: URL(fileURLWithPath: args[3]), pid: pid)
}
if args.count > 1, CLI.commands.contains(args[1]) { CLI.main(args) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu(), appItem = NSMenuItem(), fileItem = NSMenuItem(), editItem = NSMenuItem()
menu.addItem(appItem); menu.addItem(fileItem); menu.addItem(editItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Check for Updates…", action: #selector(Updater.checkNow), keyEquivalent: "").target = Updater.shared
let autoItem = appMenu.addItem(withTitle: "Automatically Check for Updates", action: #selector(Updater.toggleAutomatic(_:)), keyEquivalent: "")
autoItem.target = Updater.shared
autoItem.state = Update.autoUpdate ? .on : .off
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit ShenzhenQR", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let editMenu = NSMenu(title: "Edit")
for (t, s, k) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                  ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
    editMenu.addItem(withTitle: t, action: Selector(s), keyEquivalent: k)
}
// Paste reads a picture when the clipboard holds one, wherever the cursor is.
let pasteItem = editMenu.item(withTitle: "Paste")!
pasteItem.action = #selector(AppDelegate.pasteAnything(_:)); pasteItem.target = delegate
editItem.submenu = editMenu
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Open Picture…", action: #selector(AppDelegate.openPicture), keyEquivalent: "o").target = delegate
fileItem.submenu = fileMenu
app.mainMenu = menu
app.run()
