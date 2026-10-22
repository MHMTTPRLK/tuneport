// SPDX-License-Identifier: GPL-3.0-or-later
// Canlı çeviri için ses kaynakları
//
// - SystemAudioCapture: Mac'te çalan sesi (video, toplantı, film) ScreenCaptureKit ile yakalar.
//   Tuneport'un kendi sesi (ör. çevirinin seslendirilmesi) hariç tutulur.
// - MicrophoneCapture: Varsayılan mikrofonu dinler. Mikrofon koruması açıkken bu, Mac'in
//   dahili mikrofonudur; kulaklık düşük kaliteli moda geçmez.
//
// İki kaynak da sesi konuşma tanımanın sevdiği 16 kHz tek kanal biçimine çevirip iletir.

import Foundation
import AVFoundation
import ScreenCaptureKit

protocol AudioSource: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    func start() async throws
    func stop()
}

enum AudioSourceError: LocalizedError {
    case noDisplay
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return L("Screen recording permission is required to capture Mac audio")
        case .microphoneDenied: return L("Microphone permission is required")
        }
    }
}

/// Gelen sesi 16 kHz mono Float32'ye çeviren yardımcı
final class SpeechFormatConverter {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: SpeechFormatConverter.targetFormat)
        }
        guard let converter else { return nil }
        let ratio = SpeechFormatConverter.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: SpeechFormatConverter.targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

// MARK: - Mac sesi

final class SystemAudioCapture: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var stream: SCStream?
    private let converter = SpeechFormatConverter()
    private let queue = DispatchQueue(label: "tuneport.system-audio")

    func start() async throws {
        // İlk çağrıda macOS "Ekran Kaydı" izni ister (ses yakalamak için gerekli)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioSourceError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Görüntüye ihtiyacımız yok: en küçük boyut, saniyede bir kare
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = SystemAudioCapture.pcmBuffer(from: sampleBuffer),
              let converted = converter.convert(pcm) else { return }
        onBuffer?(converted)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Tuneport: sistem sesi yakalama durdu: %@", error.localizedDescription)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

// MARK: - Mikrofon

final class MicrophoneCapture: AudioSource {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let engine = AVAudioEngine()
    private let converter = SpeechFormatConverter()

    func start() async throws {
        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        guard granted else { throw AudioSourceError.microphoneDenied }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let converted = self.converter.convert(buffer) else { return }
            self.onBuffer?(converted)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
