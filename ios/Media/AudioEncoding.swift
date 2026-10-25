import AVFoundation

/// Query the encoder with the same PCM format that AudioPump supplies. Container
/// compatibility alone does not establish which AAC bit rates a device supports.
struct AudioEncoding {
    let bitRate: Int
    let supportedBitRates: [Int]
    var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
         AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: bitRate]
    }
    static func supported() throws -> AudioEncoding {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]),
              let converter = AVAudioConverter(from: pcm, to: aac) else {
            throw AppError.message("この端末でAAC音声を出力できません。")
        }
        let rates = (converter.applicableEncodeBitRates ?? []).map(\.intValue).filter { $0 > 0 }.sorted()
        guard let selected = rates.last(where: { $0 <= 384_000 }) else {
            throw AppError.message("48kHz・ステレオのAAC出力設定を確認できません。")
        }
        return AudioEncoding(bitRate: selected, supportedBitRates: rates)
    }
}
