import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import os

private let title = "Dictado Local"
private let build = "1" // `construir` sustituye la revisión.
private let metrics = Logger(subsystem: "org.lavf.dictadolocal", category: "motor")

private func fourCC(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

struct Settings: Codable {
    var tecla: String
    var modificadores: [String]
    var modo: String
    /// Opcional en Ajustes.json. Aviso de copiado encendido por defecto.
    var aviso_copiado: Bool? = nil

    var copiedNoticeOn: Bool { aviso_copiado ?? true }

    static let standard = Settings(tecla: "D", modificadores: ["control", "option"], modo: "limpio")

    /// Código de tecla y modificadores de Carbon para RegisterEventHotKey.
    var hotkey: (UInt32, UInt32)? {
        let codes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
                     kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                     kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                     kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                     kVK_ANSI_Y, kVK_ANSI_Z]
        let available: [String: Int] = ["control": controlKey, "option": optionKey, "command": cmdKey, "shift": shiftKey]
        guard let upper = tecla.uppercased().first,
              let index = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").firstIndex(of: upper),
              tecla.count == 1, !modificadores.isEmpty,
              modificadores.allSatisfy({ available[$0.lowercased()] != nil }) else { return nil }
        let mask = modificadores.reduce(0) { $0 | available[$1.lowercased()]! }
        return (UInt32(codes[index]), UInt32(mask))
    }

    var label: String { (modificadores.map { $0.capitalized } + [tecla.uppercased()]).joined(separator: "+") }
}

/// Convierte cualquier formato de entrada a PCM de 16 kHz, mono, Int16. Lo usan el micrófono y el modo de prueba.
final class Resampler {
    static let limit = 16_000 * 2 * 600
    private let input: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter
    private(set) var data = Data()
    private(set) var failed = false
    var full: Bool { data.count >= Self.limit }

    init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, input.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: target) else { return nil }
        self.input = input
        self.target = target
        self.converter = converter
    }

    func append(_ source: AVAudioPCMBuffer) {
        guard !failed, !full, source.frameLength > 0 else { return }
        let size = AVAudioFrameCount(ceil(Double(source.frameLength) * 16000 / input.sampleRate)) + 64
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: size) else {
            failed = true
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, let samples = buffer.int16ChannelData?[0] else {
            failed = true
            return
        }
        let count = min(Int(buffer.frameLength) * 2, Self.limit - data.count)
        data.append(UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: count)
    }

    static func decode(file url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard let resampler = Resampler(from: file.processingFormat),
              let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
            throw CocoaError(.featureUnsupported)
        }
        while file.framePosition < file.length, !resampler.full {
            try file.read(into: chunk)
            if chunk.frameLength == 0 { break }
            resampler.append(chunk)
        }
        if resampler.failed { throw CocoaError(.fileReadCorruptFile) }
        return resampler.data
    }
}

/// Graba con AVCaptureSession solo el micrófono integrado del Mac. La entrada del sistema no cambia y no se abre
/// ningún otro micrófono: unos auriculares Bluetooth conectados siguen sonando en A2DP y las llamadas los usan como
/// siempre. Si no hay micrófono integrado, se usa la entrada del sistema. El audio llega ya en PCM 16 kHz mono Int16.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.lavf.dictadolocal.audio")
    private let lock = NSLock()
    private var data = Data()
    private var active = false
    private var onLimit: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    static func microphone() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        return found.first { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn }
            ?? AVCaptureDevice.default(for: .audio)
    }

    func start(onLimit: @escaping () -> Void, onInterrupt: @escaping () -> Void) throws {
        guard let device = Self.microphone() else { throw CocoaError(.featureUnsupported) }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CocoaError(.featureUnsupported)
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        lock.lock()
        data = Data()
        active = true
        self.onLimit = onLimit
        lock.unlock()
        // Si el micrófono se desconecta o la sesión falla, se procesa lo grabado.
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { _ in onInterrupt() })
        }
        session.startRunning()
        guard session.isRunning else {
            _ = stop()
            throw CocoaError(.featureUnsupported)
        }
        metrics.info("Micrófono: \(device.localizedName, privacy: .public)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var chunk = Data(count: length)
        let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == kCMBlockBufferNoErr else { return }
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        data.append(chunk.prefix(Resampler.limit - data.count))
        if data.count >= Resampler.limit {
            active = false
            if let onLimit { DispatchQueue.main.async(execute: onLimit) }
        }
    }

    func stop() -> Data? {
        lock.lock()
        active = false
        lock.unlock()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if session.isRunning { session.stopRunning() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        queue.sync {}
        lock.lock()
        defer { lock.unlock() }
        onLimit = nil
        return data
    }
}

struct Reply: Decodable {
    let text: String?
    let notice: String?
    let state: String?
    let error: Bool?
    let tipo: String?
    let recorte_muestras: Int?
    let segmentos_escritura: Int?
    let palabras_bucle: Int?
    let s_whisper: Double?
    let s_limpieza: Double?
}

final class SpeechWorker {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var received = Data()
    private var errorTail = Data()
    private let writes = DispatchQueue(label: "org.lavf.dictadolocal.entrada")
    private let onStop: () -> Void

    /// Busca el Python del motor junto a la app y, si la app se movió, en la ruta grabada al compilar.
    static func python() -> URL? {
        let manager = FileManager.default
        let local = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("proyecto/.venv/bin/python")
        if manager.isExecutableFile(atPath: local.path) { return local }
        if let fixed = Bundle.main.object(forInfoDictionaryKey: "LADictadoPython") as? String,
           manager.isExecutableFile(atPath: fixed) { return URL(fileURLWithPath: fixed) }
        return nil
    }

    init(onReply: @escaping (Reply) -> Void, onStop: @escaping () -> Void) throws {
        self.onStop = onStop
        guard let python = Self.python(), let script = Bundle.main.resourceURL?.appendingPathComponent("pipeline.py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        process.executableURL = python
        process.arguments = ["-B", script.path, "--worker"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Solo se guarda la cola de stderr (tracebacks de Python) para el registro si el motor muere.
        let tailLock = NSLock()
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            tailLock.lock()
            self.errorTail = (self.errorTail + chunk).suffix(400)
            tailLock.unlock()
        }
        process.terminationHandler = { [weak self] finished in
            tailLock.lock()
            let tail = String(decoding: self?.errorTail ?? Data(), as: UTF8.self)
            tailLock.unlock()
            metrics.error("Motor terminado, código \(finished.terminationStatus, privacy: .public). \(tail, privacy: .public)")
            DispatchQueue.main.async(execute: onStop)
        }
        try process.run()
        metrics.notice("Motor iniciado con \(python.path, privacy: .public)")
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.received.append(chunk)
            while let newline = self.received.firstIndex(of: 10) {
                let line = self.received.prefix(upTo: newline)
                if let reply = try? JSONDecoder().decode(Reply.self, from: line) {
                    DispatchQueue.main.async { onReply(reply) }
                }
                self.received.removeSubrange(...newline)
            }
        }
    }

    func send(_ data: Data, mode: String) {
        writes.async {
            do {
                let header = try JSONSerialization.data(withJSONObject: ["bytes": data.count, "mode": mode])
                try self.input.fileHandleForWriting.write(contentsOf: header + Data([10]))
                try self.input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                DispatchQueue.main.async(execute: self.onStop)
            }
        }
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

enum Status {
    case idle, recording, transcribing, cleaning, done, error

    var label: String {
        switch self {
        case .idle: return "En espera"
        case .recording: return "Grabando"
        case .transcribing: return "Transcribiendo"
        case .cleaning: return "Limpiando"
        case .done: return "Listo"
        case .error: return "Error"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "record.circle.fill"
        case .transcribing: return "waveform"
        case .cleaning: return "text.badge.checkmark"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.circle"
        }
    }
}

/// Enciende `ollama serve` como proceso hijo si no responde, y lo apaga al salir solo si lo encendió la app.
/// No instala nada en el arranque del Mac.
final class OllamaServer {
    private let binary = "/opt/homebrew/bin/ollama"
    private var child: Process?
    private var checking = false

    func ensureRunning() {
        guard !checking, FileManager.default.isExecutableFile(atPath: binary) else { return }
        checking = true
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let alive = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if !alive { self.start() }
            }
        }.resume()
    }

    private func start() {
        if let child, child.isRunning { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11434"
        environment["OLLAMA_FLASH_ATTENTION"] = "1"
        environment["OLLAMA_KV_CACHE_TYPE"] = "q8_0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            child = process
            metrics.notice("Ollama encendido por la app, PID \(process.processIdentifier, privacy: .public)")
        } catch {
            metrics.error("No se pudo encender Ollama")
        }
    }

    func stop() {
        guard let child, child.isRunning else { return }
        child.terminate()
        child.waitUntilExit()
        metrics.notice("Ollama apagado al salir")
    }
}

struct TestRequest {
    let file: URL
    let mode: String
}

final class Dictation: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var settings = Settings.standard
    private var mode = "limpio"
    private var configurationError = false
    private var audio: AudioCapture?
    private var worker: SpeechWorker?
    private var generation = 0
    private var hotkeyRef: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyRegistered = false
    private var focus: pid_t?
    private var timer: Timer?
    private var watchdog: DispatchWorkItem?
    private var notification: NSPanel?
    private var lastPermissions: String?
    private var clipboardRestore: (() -> Void)?
    private var clipboardJob = UUID()
    private let test: TestRequest?
    private let testBoard = NSPasteboard(name: NSPasteboard.Name("org.lavf.dictadolocal.prueba"))
    private static let copiedNotice = "Dictado copiado. Pégalo con Cmd+V."
    private let ollama = OllamaServer()
    private var status = Status.idle { didSet { statusChanged(from: oldValue) } }

    init(test: TestRequest?) {
        self.test = test
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()
        if let test {
            runTest(test)
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        ollama.ensureRunning()
        registerHotkey()
        syncPermissions()
        updateMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.syncPermissions() }
        if configurationError { warn("Ajustes.json no es válido. Se usa Control+Option+D.") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardRestore?()
        worker = nil
        ollama.stop()
        if let hotkeyRef { UnregisterEventHotKey(hotkeyRef) }
        setEscape(false)
    }

    private func loadSettings() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Ajustes.json")
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let configured = try? JSONDecoder().decode(Settings.self, from: data),
               configured.hotkey != nil, ["limpio", "crudo"].contains(configured.modo) {
                settings = configured
            } else {
                configurationError = true
            }
        }
        mode = test?.mode ?? settings.modo
    }

    // MARK: Atajo global (Carbon). No necesita Accesibilidad ni Monitorización de entrada.

    private func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr else { return read }
            let owner = Unmanaged<Dictation>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { owner.hotkeyPressed(id.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
        let (code, modifiers) = settings.hotkey ?? Settings.standard.hotkey!
        let result = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: fourCC("DLoc"), id: 1),
                                         GetApplicationEventTarget(), 0, &hotkeyRef)
        hotkeyRegistered = result == noErr
        metrics.notice("Revisión \(build, privacy: .public) · atajo \(self.settings.label, privacy: .public) · RegisterEventHotKey=\(result, privacy: .public)")
        if !hotkeyRegistered {
            warn("No se pudo registrar \(settings.label). Usa «Dictar» en el menú del micrófono.")
        }
    }

    private func setEscape(_ on: Bool) {
        if on, escapeRef == nil {
            let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: fourCC("DLoc"), id: 2),
                                             GetApplicationEventTarget(), 0, &escapeRef)
            if result != noErr { metrics.error("Escape no registrado: \(result, privacy: .public)") }
        } else if !on, let escapeRef {
            UnregisterEventHotKey(escapeRef)
            self.escapeRef = nil
        }
    }

    fileprivate func hotkeyPressed(_ id: UInt32) {
        metrics.notice("Atajo recibido \(id, privacy: .public) en estado \(self.status.label, privacy: .public)")
        if id == 1 { toggle() }
        if id == 2, status == .recording { cancel() }
    }

    private func syncPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        let permissions = "Micrófono=\(microphone), Accesibilidad=\(accessibility), Monitorización=\(CGPreflightListenEventAccess())"
        if permissions != lastPermissions {
            lastPermissions = permissions
            metrics.notice("Revisión \(build, privacy: .public) · \(permissions, privacy: .public)")
            if test == nil { updateMenu() }
        }
    }

    // MARK: Menú y estados

    private func statusChanged(from old: Status) {
        guard old != status else { return }
        metrics.notice("Estado \(self.status.label, privacy: .public)")
        if test != nil {
            FileHandle.standardError.write(Data("estado: \(status.label)\n".utf8))
        } else {
            updateMenu()
        }
    }

    private func add(_ menu: NSMenu, _ label: String, _ action: Selector) {
        let entry = menu.addItem(withTitle: label, action: action, keyEquivalent: "")
        entry.target = self
    }

    private func updateMenu() {
        guard let item else { return }
        item.button?.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.label)
        item.button?.toolTip = "\(title) · \(status.label)"
        let menu = NSMenu()
        menu.addItem(withTitle: status.label, action: nil, keyEquivalent: "")
        if status == .recording {
            add(menu, "Terminar dictado", #selector(toggle))
            add(menu, "Cancelar dictado (Esc)", #selector(cancel))
        } else if status != .transcribing, status != .cleaning {
            add(menu, hotkeyRegistered ? "Dictar (\(settings.label))" : "Dictar", #selector(toggle))
        }
        add(menu, "Modo \(mode) · cambiar", #selector(switchMode))
        add(menu, settings.copiedNoticeOn ? "Aviso de copiado: sí · desactivar" : "Aviso de copiado: no · activar",
            #selector(switchCopiedNotice))
        menu.addItem(withTitle: AXIsProcessTrusted() ? "Entrega: pega en el cursor" : "Entrega: portapapeles (Cmd+V)",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Permisos…", #selector(showPermissions))
        add(menu, "Salir", #selector(quit))
        item.menu = menu
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func switchMode() {
        mode = mode == "limpio" ? "crudo" : "limpio"
        settings.modo = mode
        saveSettings()
    }

    @objc private func switchCopiedNotice() {
        settings.aviso_copiado = !settings.copiedNoticeOn
        saveSettings()
    }

    /// Guarda en Ajustes.json, junto a la app: es la única carpeta de ajustes.
    private func saveSettings() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Ajustes.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch {
            warn("No se pudo guardar Ajustes.json.")
        }
        updateMenu()
    }

    @objc private func showPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let ax = AXIsProcessTrusted()
        let alert = NSAlert()
        alert.messageText = "Permisos de \(title) · revisión \(build)"
        alert.informativeText = """
        Micrófono (\(mic == .authorized ? "concedido" : "pendiente")): imprescindible, captura tu voz.
        Accesibilidad (\(ax ? "concedida" : "pendiente")): opcional. Con ella el texto se pega solo en el cursor; sin ella queda en el portapapeles para pegarlo con Cmd+V.
        El atajo \(settings.label) no necesita permisos.
        Se conceden en Ajustes del Sistema → Privacidad y seguridad.
        """
        alert.addButton(withTitle: "Solicitar los que faltan")
        alert.addButton(withTitle: "Cerrar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if mic == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.requestAccessibility() }
            }
        } else {
            requestAccessibility()
        }
    }

    private func requestAccessibility() {
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        syncPermissions()
    }

    // MARK: Dictado

    @objc private func toggle() {
        if status == .recording {
            finish()
            return
        }
        guard status != .transcribing, status != .cleaning else { return }
        focus = NSWorkspace.shared.frontmostApplication?.processIdentifier
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.toggle() } }
            }
            return
        default:
            status = .error
            showPermissions()
            return
        }
        let capture = AudioCapture()
        do {
            try capture.start(onLimit: { [weak self] in
                if self?.status == .recording { self?.finish() }
            }, onInterrupt: { [weak self] in
                if self?.status == .recording { self?.finish() }
            })
            audio = capture
            setEscape(true)
            status = .recording
            // Mientras hablas da tiempo a que Ollama arranque si se cayó.
            if mode == "limpio" { ollama.ensureRunning() }
        } catch {
            status = .error
            warn("No se pudo iniciar la captura del micrófono.")
        }
    }

    @objc private func cancel() {
        setEscape(false)
        guard let audio else { return }
        _ = audio.stop()
        self.audio = nil
        status = .idle
    }

    private func finish() {
        setEscape(false)
        guard let audio else { return }
        let pcm = audio.stop()
        self.audio = nil
        process(pcm)
    }

    private func process(_ pcm: Data?) {
        guard let pcm, pcm.count >= 3200 else {
            status = .error
            warn("No se pudo capturar audio.")
            finishTest(nil)
            return
        }
        status = .transcribing
        do {
            if worker == nil {
                generation += 1
                let current = generation
                worker = try SpeechWorker(onReply: { [weak self] reply in
                    if self?.generation == current { self?.handle(reply) }
                }, onStop: { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.generation += 1
                    self.worker = nil
                    self.watchdog?.cancel()
                    if self.status == .transcribing || self.status == .cleaning {
                        self.status = .error
                        self.warn("El motor de dictado se cerró. Vuelve a intentarlo.")
                        self.finishTest(nil)
                    }
                })
            }
            armWatchdog(seconds: 90 + Double(pcm.count) / 32_000 / 2)
            worker?.send(pcm, mode: mode)
        } catch {
            status = .error
            warn("No se encontró el motor local (proyecto/.venv). Comprueba la carpeta de la entrega.")
            finishTest(nil)
        }
    }

    /// Si Whisper u Ollama se cuelgan, se mata el motor y la app vuelve a aceptar dictados.
    private func armWatchdog(seconds: Double) {
        watchdog?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.status == .transcribing || self.status == .cleaning else { return }
            metrics.error("Motor sin respuesta tras \(seconds, privacy: .public) s")
            self.generation += 1
            self.worker = nil
            self.status = .error
            self.warn("El motor tardó demasiado y se reinició. Vuelve a intentarlo.")
            self.finishTest(nil)
        }
        watchdog = job
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: job)
    }

    private func handle(_ reply: Reply) {
        if reply.state == "limpieza" {
            status = .cleaning
            return
        }
        watchdog?.cancel()
        if let trimmed = reply.recorte_muestras, let scripts = reply.segmentos_escritura,
           let repeats = reply.palabras_bucle, let whisper = reply.s_whisper, let cleaning = reply.s_limpieza {
            metrics.notice("Muestras recortadas \(trimmed, privacy: .public), segmentos descartados \(scripts, privacy: .public), palabras repetidas \(repeats, privacy: .public), Whisper s \(whisper, privacy: .public), limpieza s \(cleaning, privacy: .public), aviso \(reply.notice ?? "", privacy: .public)")
        }
        if let kind = reply.tipo { metrics.error("Fallo del motor: \(kind, privacy: .public)") }
        guard let text = reply.text, !text.isEmpty else {
            status = reply.error == true ? .error : .idle
            warn(reply.error == true ? "Falló el motor de dictado. Mira el registro." : "No se detectó voz.")
            finishTest(nil)
            return
        }
        status = .done
        var messages: [String] = []
        if reply.notice == "ollama" { messages.append("Ollama no respondió. Se usó el dictado crudo.") }
        if reply.notice == "proteccion" { messages.append("Se descartó la limpieza para preservar el dictado.") }
        let board = test == nil ? NSPasteboard.general : testBoard
        if let message = paste(text, on: board), message != Self.copiedNotice || settings.copiedNoticeOn {
            messages.append(message)
        }
        if !messages.isEmpty { warn(messages.joined(separator: " ")) }
        finishTest(text)
    }

    // MARK: Entrega del texto

    private func isSecureField(pid: pid_t) -> Bool {
        if IsSecureEventInputEnabled() { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var field: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &field) == .success,
              let field, CFGetTypeID(field) == AXUIElementGetTypeID() else { return false }
        let element = unsafeDowncast(field, to: AXUIElement.self)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success
            && (value as? String) == (kAXSecureTextFieldSubrole as String)
    }

    /// Con Accesibilidad pega en el cursor y restaura el portapapeles; sin ella deja el texto copiado y avisa.
    private func paste(_ text: String, on board: NSPasteboard) -> String? {
        clipboardRestore?()
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let hasFocus = test == nil && current != nil && current == focus
        let secure = hasFocus && current.map(isSecureField) == true
        let canPost = hasFocus && !secure && AXIsProcessTrusted() && CGPreflightPostEventAccess()
        let snapshot: [[(NSPasteboard.PasteboardType, Data)]] = canPost ? (board.pasteboardItems ?? []).map { original in
            original.types.compactMap { type in original.data(forType: type).map { (type, $0) } }
        } : []
        board.clearContents()
        guard board.setString(text, forType: .string) else { return "No se pudo escribir en el portapapeles." }
        if canPost {
            // Los gestores de portapapeles ignoran este contenido pasajero.
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        if secure { return "Campo seguro. Dictado copiado: pégalo con Cmd+V." }
        guard canPost,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == current,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return Self.copiedNotice
        }
        let change = board.changeCount
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        let job = UUID()
        clipboardJob = job
        clipboardRestore = { [weak self] in
            self?.clipboardRestore = nil
            guard board.changeCount == change else { return }
            let items = snapshot.compactMap { entries -> NSPasteboardItem? in
                guard !entries.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            board.clearContents()
            if !items.isEmpty { board.writeObjects(items) }
        }
        // Chrome y las apps Electron leen el portapapeles con retraso: se espera 1 s antes de restaurar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.clipboardJob == job { self?.clipboardRestore?() }
        }
        return nil
    }

    private func warn(_ text: String) {
        if test != nil {
            FileHandle.standardError.write(Data("aviso: \(text)\n".utf8))
            return
        }
        notification?.orderOut(nil)
        let width: CGFloat = 340
        let height: CGFloat = 76
        let area = NSScreen.main?.visibleFrame ?? .zero
        let panel = NSPanel(contentRect: CGRect(x: area.maxX - width - 18, y: area.maxY - height - 12,
                                                width: width, height: height),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = title
        panel.level = .floating
        panel.ignoresMouseEvents = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = CGRect(x: 13, y: 8, width: width - 26, height: height - 18)
        panel.contentView?.addSubview(label)
        notification = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if self?.notification === panel { self?.notification = nil }
        }
    }

    // MARK: Modo de prueba: mismo camino que un dictado, con el audio de un archivo y un portapapeles privado.

    private func runTest(_ request: TestRequest) {
        metrics.notice("Prueba por archivo, revisión \(build, privacy: .public), modo \(request.mode, privacy: .public)")
        FileHandle.standardError.write(Data("prueba: revisión \(build), modo \(request.mode), python \(SpeechWorker.python()?.path ?? "NO ENCONTRADO")\n".utf8))
        let started = Date()
        do {
            let pcm = try Resampler.decode(file: request.file)
            FileHandle.standardError.write(Data(String(format: "prueba: decodificado %d bytes (%.1f s de audio) en %.2f s\n",
                                                       pcm.count, Double(pcm.count) / 32_000, Date().timeIntervalSince(started)).utf8))
            process(pcm)
        } catch {
            FileHandle.standardError.write(Data("prueba: no se pudo decodificar el archivo\n".utf8))
            exit(2)
        }
    }

    private func finishTest(_ text: String?) {
        guard test != nil else { return }
        let copied = testBoard.string(forType: .string)
        testBoard.clearContents()
        guard let text else { exit(1) }
        FileHandle.standardError.write(Data("prueba: portapapeles privado \(copied == text ? "coincide" : "NO coincide")\n".utf8))
        print(text)
        exit(copied == text ? 0 : 3)
    }
}

signal(SIGPIPE, SIG_IGN)
var request: TestRequest?
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--probar-archivo"), index + 1 < arguments.count {
    let modeIndex = arguments.firstIndex(of: "--modo")
    let mode = modeIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "limpio"
    guard ["limpio", "crudo"].contains(mode) else {
        FileHandle.standardError.write(Data("Modo no válido: usa limpio o crudo\n".utf8))
        exit(2)
    }
    request = TestRequest(file: URL(fileURLWithPath: arguments[index + 1]), mode: mode)
}
let app = NSApplication.shared
app.setActivationPolicy(request == nil ? .accessory : .prohibited)
let delegate = Dictation(test: request)
app.delegate = delegate
app.run()
