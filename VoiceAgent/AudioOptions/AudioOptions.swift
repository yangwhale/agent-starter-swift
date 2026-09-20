import Combine
import LiveKit
import SwiftUI

/// Selects which implementation handles microphone voice processing
/// (echo cancellation, noise suppression, and auto gain control).
///
/// `nonisolated` 是必须的：这个类型要被 `CCStore`（nonisolated）读写，
/// 而工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不写就会被
/// 隐式推成 `@MainActor`，隔离域对不上。
///
/// 带 `String` 原始值是为了能进 UserDefaults —— 这项设置现在是全局的，
/// 要跨启动保留（见 `CCStore.voiceProcessing`）。
nonisolated enum VoiceProcessingMode: String, CaseIterable, Identifiable {
    /// Prefer Apple voice processing when available and fall back to
    /// WebRTC software processing. This is the SDK default.
    case automatic
    /// Use Apple voice processing only. Applying fails when it is not available.
    case platform
    /// Use WebRTC software processing. Turns off Apple voice processing
    /// for the microphone.
    case software

    var id: Self {
        self
    }
}

/// Stores the selected audio options and applies them to the local microphone.
///
/// A selection made before connecting is applied as soon as the microphone
/// track is created, so it takes effect when the microphone is published.
/// Changing the selection during a call updates the live track.
///
/// To guarantee that the very first captured frames already use custom
/// processing options, pass them as room defaults instead. See the comment
/// on `RoomOptions` in `VoiceAgentApp`.
final class AudioOptions: ObservableObject {
    @Published private(set) var voiceProcessingMode: VoiceProcessingMode = CCStore.voiceProcessing

    /// The last error from applying the selection, if any.
    @Published private(set) var applyError: Swift.Error?

    private let localMedia: LocalMedia
    private var cancellable: AnyCancellable?

    init(localMedia: LocalMedia) {
        self.localMedia = localMedia
        // Apply the stored selection whenever a new microphone track appears,
        // e.g. when pre-connect audio starts capturing.
        cancellable = localMedia.$microphoneTrack
            .map { $0 as? LocalAudioTrack }
            .removeDuplicates { $0 === $1 }
            .compactMap(\.self)
            .sink { [weak self] track in
                guard let self, voiceProcessingMode != .automatic else { return }
                apply(to: track)
            }

        // ⚠️ 这里原来自己订阅 `CloseCrabConfig.shared.$voiceProcessing`。
        //    config 转 @Observable 之后没有 `$` 投影了，而且**多播也不该
        //    由每个实例各订一份** —— 现在改由 `CCRooms` 统一分发：
        //    它本来就持有全部槽位，一个订阅者扇出，比 N 个订阅者干净。
        //    新建的槽位不会漏：`voiceProcessingMode` 初值就是从 CCStore 读的。
    }

    /// The selected mode as SDK processing options.
    /// All processing components stay enabled, only the implementation changes.
    var processingOptions: AudioProcessingOptions {
        switch voiceProcessingMode {
        case .automatic:
            AudioProcessingOptions()
        case .platform:
            AudioProcessingOptions(
                echoCancellationMode: .platform,
                autoGainControlMode: .platform,
                noiseSuppressionMode: .platform
            )
        case .software:
            AudioProcessingOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                highpassFilter: false,
                echoCancellationMode: .software,
                autoGainControlMode: .software,
                noiseSuppressionMode: .software
            )
        }
    }

    /// Applies the given mode to the local microphone.
    /// Without a track the selection is stored and applied on the next publish.
    func apply(_ mode: VoiceProcessingMode) {
        voiceProcessingMode = mode
        applyError = nil
        guard let track = localMedia.microphoneTrack as? LocalAudioTrack else { return }
        apply(to: track)
    }

    private func apply(to track: LocalAudioTrack) {
        do {
            try track.setAudioProcessingOptions(processingOptions)
            applyError = nil
        } catch {
            applyError = error
        }
    }
}
