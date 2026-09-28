import AVFoundation
import CoreAudio



final class AudioRecorder: @unchecked Sendable {


    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var inputSampleRate: Double = 48000


    var onSpectrum: (@Sendable (Float, [Float]) -> Void)?   // (整体 RMS, N 个频段幅度)→ 悬浮窗均衡器
    private var analyzer: SpectrumAnalyzer?                  // FFT 频段提取器(拿到格式后建,音频线程串行用)


    var onChunk16k: (@Sendable ([Int16]) -> Void)?







    var onFirstBuffer: (@Sendable () -> Void)?
    private var gotFirstBuffer = false


    private var streamConverter: AVAudioConverter?
    private let out16k = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000, channels: 1, interleaved: true)!

    static var microphonePermission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var microphoneGranted: Bool {
        microphonePermission == .authorized
    }

    static func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch microphonePermission {
        case .authorized:
            completion(true)
        case .denied, .restricted:
            completion(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        @unknown default:
            completion(false)
        }
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            requestPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws {
        gotFirstBuffer = false        // 每次开录都要重新等"第一个 buffer",别沿用上一轮的
        let wantVPIO = UserDefaults.standard.bool(forKey: "noiseReduction")   // 智能降噪 = VPIO 语音处理
        do {
            try startEngine(useVPIO: wantVPIO)
        } catch {



            NSLog("VoiceFlow: 录音启动失败(第1次)→ \(Self.micDiagnostics()) 错误=\(error)")
            usleep(180_000)   // 给音频 HAL 180ms 从过渡态缓过来(立即重试常撞同一个坏态)。失败路径,短暂阻塞可接受。
            rebuildEngine()
            do {

                try startEngine(useVPIO: false)
                if wantVPIO {
                    NSLog("VoiceFlow: ★关掉智能降噪(VPIO)后录音成功 —— VPIO 就是元凶,建议默认别开★")
                }
            } catch {
                NSLog("VoiceFlow: 录音启动失败(重试后仍失败,已关 VPIO)→ \(Self.micDiagnostics())")
                throw NSError(domain: "VoiceFlow.AudioRecorder", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "麦克风打不开。\(Self.micDiagnostics())"])
            }
        }
    }




    static func micDiagnostics() -> String {
        func prop<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var value = initial
            var size = UInt32(MemoryLayout<T>.size)
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
            return value
        }
        let dev = prop(AudioObjectID(kAudioObjectSystemObject),
                       kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(kAudioObjectUnknown))
        guard dev != kAudioObjectUnknown else { return "无默认输入设备(麦克风被拔了/系统没识别到)" }
        let name = prop(dev, kAudioObjectPropertyName, "" as CFString) as String
        let rate = prop(dev, kAudioDevicePropertyNominalSampleRate, Float64(0))
        let running = prop(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) != 0
        let nr = UserDefaults.standard.bool(forKey: "noiseReduction")
        return "输入设备=[\(name)] 采样率=\(rate) 被别的进程占用=\(running ? "★是★" : "否") 智能降噪=\(nr ? "★开★" : "关")"
    }


    private func rebuildEngine() {
        engine.inputNode.removeTap(onBus: 0)   // best-effort 清理,无 tap 时是安全 no-op
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()               // 全新实例 → 下面 startEngine() 重新拿当前硬件的输入格式
        streamConverter = nil
    }

    private func startEngine(useVPIO: Bool) throws {
        lock.lock(); samples.removeAll(); lock.unlock()

        let input = engine.inputNode


        try? input.setVoiceProcessingEnabled(useVPIO)
        let format = input.inputFormat(forBus: 0)


        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "VoiceFlow.AudioRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "输入设备格式无效(采样率 \(format.sampleRate))"])
        }
        inputSampleRate = format.sampleRate
        streamConverter = AVAudioConverter(from: format, to: out16k)  // 流式重采样到 16k
        analyzer = SpectrumAnalyzer(sampleRate: format.sampleRate)    // 均衡器的"真频谱"来源

        input.removeTap(onBus: 0)  // 防"在已有 tap 上重复装"崩溃(nullptr == Tap()):上次若没卸干净(延迟启动撞上取消 → 孤儿 tap)先卸;无 tap 时是安全 no-op
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let ptr = channels[0]

            self.lock.lock()
            self.samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: n))
            let isFirst = !self.gotFirstBuffer
            if isFirst { self.gotFirstBuffer = true }
            self.lock.unlock()
            if isFirst, let cb = self.onFirstBuffer {   // 麦克风真出声了 → 通知上层放开口信号
                DispatchQueue.main.async { cb() }
            }

            var sum: Float = 0
            for i in 0..<n { sum += ptr[i] * ptr[i] }
            let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
            if let cb = self.onSpectrum {
                let bands = self.analyzer?.analyze(ptr, count: n) ?? []   // 音频线程内同步算,ptr 此刻有效
                DispatchQueue.main.async { cb(rms, bands) }
            }
            self.emit16k(buffer)  // 实时重采样到 16k 并送出,供流式转写
        }
        engine.prepare()
        try engine.start()
    }




    func prewarm() {
        guard Self.microphoneGranted else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        inputSampleRate = format.sampleRate
        streamConverter = AVAudioConverter(from: format, to: out16k)
        engine.prepare()
    }





    func shutdown() {



        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }


    func stopAndWriteWAV() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock(); let captured = samples; samples.removeAll(); lock.unlock()
        guard !captured.isEmpty else { return nil }
        return Self.writeWAV(samples: captured, fromRate: inputSampleRate, toRate: 16000)
    }


    private func emit16k(_ input: AVAudioPCMBuffer) {
        guard let converter = streamConverter, let cb = onChunk16k else { return }
        let ratio = out16k.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: out16k, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        cb(samples)
    }

    private static func writeWAV(samples: [Float], fromRate: Double, toRate: Double) -> URL? {
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toRate, channels: 1, interleaved: false),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        let capacity = AVAudioFrameCount(Double(samples.count) * toRate / fromRate + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var provided = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return inBuf
        }
        if convError != nil { return nil }

        guard let url = try? TemporaryAudioFiles.shared.create() else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: toRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: outBuf)
            return url
        } catch {
            TemporaryAudioFiles.shared.release(url)
            NSLog("VoiceFlow: write wav failed \(error)")
            return nil
        }
    }
}
