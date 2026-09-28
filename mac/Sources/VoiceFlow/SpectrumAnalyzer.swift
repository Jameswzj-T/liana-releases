import Accelerate










final class SpectrumAnalyzer: @unchecked Sendable {
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let bandBins: [(lo: Int, hi: Int)]   // 每个频段覆盖的 FFT bin 区间(对数分布)
    let bandCount: Int



    init(sampleRate: Double, fftSize: Int = 2048, bands: Int = 6,
         minHz: Double = 110, maxHz: Double = 3200) {
        self.fftSize = fftSize
        self.log2n = vDSP_Length(round(log2(Double(fftSize))))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))   // 汉宁窗:抑制频谱泄漏
        self.window = w
        self.bandCount = bands

        let half = fftSize / 2
        let hzPerBin = sampleRate / Double(fftSize)
        var bins: [(Int, Int)] = []
        for b in 0..<bands {
            let f0 = minHz * pow(maxHz / minHz, Double(b) / Double(bands))
            let f1 = minHz * pow(maxHz / minHz, Double(b + 1) / Double(bands))
            let lo = max(1, min(half - 1, Int((f0 / hzPerBin).rounded())))
            let hi = max(lo + 1, min(half, Int((f1 / hzPerBin).rounded())))
            bins.append((lo, hi))
        }
        self.bandBins = bins
    }

    deinit { vDSP_destroy_fftsetup(setup) }


    func analyze(_ samples: UnsafePointer<Float>, count: Int) -> [Float] {

        var input = [Float](repeating: 0, count: fftSize)
        var windowed = [Float](repeating: 0, count: fftSize)
        let m = min(count, fftSize)
        input.withUnsafeMutableBufferPointer { ib in
            for i in 0..<m { ib[i] = samples[i] }
        }
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))   // input≠windowed,不触发独占访问陷阱


        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var mags = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftSize / 2))   // 交错实信号 → 分裂复数
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))      // |X|²
            }
        }


        var out = [Float](repeating: 0, count: bandCount)
        for (b, band) in bandBins.enumerated() {
            var sum: Float = 0
            for k in band.lo..<band.hi { sum += mags[k] }
            let rms = (sum / Float(band.hi - band.lo)).squareRoot()
            out[b] = rms * (1.0 + 0.1 * Float(b))   // 轻微高频提升(压缩主要靠 HUD 那边的 gamma 做)
        }
        return out
    }
}
