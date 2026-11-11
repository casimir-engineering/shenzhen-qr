// ShenzhenQR: point any camera at a QR code (or any barcode / 2D code) and act on it.
// One file, AppKit + AVFoundation + Vision, no dependencies. Built by build.sh.
import AppKit
import AVFoundation
import Vision

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

    static func joinWiFi(ssid: String, password: String) -> String? {
        DispatchQueue.global().async {
            let message: String
            if let dev = wifiDevice() {
                var args = ["-setairportnetwork", dev, ssid]
                if !password.isEmpty { args.append(password) }
                let r = run("/usr/sbin/networksetup", args)
                let said = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                message = r.status == 0 && said.isEmpty ? "Joined “\(ssid)”" : "Couldn’t join “\(ssid)”: \(said.isEmpty ? "error \(r.status)" : said)"
            } else {
                message = "This Mac has no Wi-Fi"
            }
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

func decode(_ handler: VNImageRequestHandler) -> VNBarcodeObservation? {
    let request = VNDetectBarcodesRequest()   // every symbology Vision knows
    try? handler.perform([request])
    return request.results?.first { ($0.payloadStringValue ?? "").isEmpty == false }
}

// MARK: - Camera

final class Scanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "scan")
    private var busy = false, frame = 0
    var onCode: ((String, VNBarcodeSymbology) -> Void)?

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func use(_ device: AVCaptureDevice) {
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
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frame += 1
        guard frame % 3 == 0, !busy, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        busy = true
        if let code = decode(VNImageRequestHandler(cvPixelBuffer: pixels, options: [:])), let text = code.payloadStringValue {
            let symbology = code.symbology
            DispatchQueue.main.async { self.onCode?(text, symbology) }
        }
        busy = false
    }
}

final class PreviewView: NSView {
    let layerPreview: AVCaptureVideoPreviewLayer
    init(session: AVCaptureSession) {
        layerPreview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layerPreview.videoGravity = .resizeAspect
        layer?.addSublayer(layerPreview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); layerPreview.frame = bounds }
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
    let kindLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let textView = NSTextView()
    let buttons = NSStackView()
    var preview: PreviewView!
    var lastCode = "", lastCodeAt = Date.distantPast
    var cameras: [AVCaptureDevice] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        if Installer.offerMove() { return }
        Installer.ejectInstallerDisk()
        buildWindow()
        scanner.onCode = { [weak self] text, symbology in self?.found(text, symbology) }
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

        let top = NSStackView(views: [NSTextField(labelWithString: "Camera:"), cameraMenu, NSView()])
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
    func renderScreenshot(scene: String, out: String) {
        offscreen = true
        NSApp.appearance = NSAppearance(named: .aqua)
        buildWindow()
        window.setContentSize(NSSize(width: 560, height: 640))
        let image = NSImage(contentsOfFile: scene)!
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = preview.bounds
        imageView.autoresizingMask = [.width, .height]
        preview.addSubview(imageView)
        cameraMenu.addItem(withTitle: "FaceTime HD Camera")
        if let code = decode(VNImageRequestHandler(url: URL(fileURLWithPath: scene), options: [:])),
           let text = code.payloadStringValue {
            textView.string = text
            kindLabel.stringValue = "\(symbologyName(code.symbology)) · \(Payload.kind(text))"
            refreshActions()
            setStatus("")
        }
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        imageView.frame = preview.bounds
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
        let saved = UserDefaults.standard.string(forKey: "camera")
        let index = cameras.firstIndex { $0.uniqueID == saved } ?? 0
        cameraMenu.selectItem(at: index)
        scanner.use(cameras[index])
    }

    @objc func cameraChosen() {
        let i = cameraMenu.indexOfSelectedItem
        guard cameras.indices.contains(i) else { return }
        UserDefaults.standard.set(cameras[i].uniqueID, forKey: "camera")
        scanner.use(cameras[i])
    }

    func noCameraAccess() {
        statusLabel.stringValue = "Camera access is off"
        setButtons([CodeAction(title: "Allow in System Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            return nil
        }])
    }

    func found(_ text: String, _ symbology: VNBarcodeSymbology) {
        // The same code stays in view: keep what's in the field (it may have been edited).
        if text == lastCode, Date().timeIntervalSince(lastCodeAt) < 3 { lastCodeAt = Date(); return }
        let repeated = text == lastCode
        lastCode = text; lastCodeAt = Date()
        if repeated && textView.string != text { return }
        textView.string = text
        kindLabel.stringValue = "\(symbologyName(symbology)) · \(Payload.kind(text))"
        setStatus("")
        NSSound(named: "Tink")?.play()
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

// MARK: - Entry

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--decode" {
    // Reads codes from image files and prints what the app would show; touches nothing.
    for path in args.dropFirst(2) {
        guard let code = decode(VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])),
              let text = code.payloadStringValue else { print("\(path)\tnone"); continue }
        let actions = Payload.actions(text).map(\.title).joined(separator: " | ")
        print("\(path)\t\(symbologyName(code.symbology))\t\(Payload.kind(text))\t[\(actions)]\t\(text.debugDescription)")
    }
    exit(0)
}

if args.count == 4, args[1] == "--screenshot" {
    _ = NSApplication.shared
    AppDelegate().renderScreenshot(scene: args[3], out: args[2])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
menu.addItem(appItem); menu.addItem(editItem)
let appMenu = NSMenu()
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
