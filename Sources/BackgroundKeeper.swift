import AVFoundation
import UIKit

/// Keeps the process alive once the screen goes off.
///
/// iOS suspends an app a few seconds after the display sleeps, which is why a
/// night of charging produced sixty seconds of samples followed by a six-hour
/// hole. Background refresh alone cannot close that: the system schedules it by
/// habit, and a phone charging untouched overnight has no habit to draw on.
///
/// A silent audio stream is the one channel an app can hold open by itself. iOS
/// lets the audio session keep running through a screen lock -- that is how music
/// apps play with the display off -- and a running session keeps the process out
/// of the suspended state. It costs a little battery, so it is started and
/// stopped with the recording rather than left on.
///
/// This is not App Store compliant. Under TrollStore it is simply a feature.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private var interruptionObserver: NSObjectProtocol?

    private(set) var audioRunning = false
    private(set) var screenHeld = false

    private init() {}

    /// Whether to run the silent audio stream at all.
    ///
    /// Off by default. An audio session claiming `.playback` takes the audio route
    /// for itself, so with it running the phone cannot play music or a video
    /// without this app being the thing holding the channel -- and the media keys
    /// start pointing at a stream nobody can hear. That is a bad trade now that the
    /// scene hook keeps the process alive anyway: the hook is free and invisible,
    /// the session is neither.
    ///
    /// It stays available because the hook is undocumented and could stop working
    /// on some iOS build, and because a caller may want a second channel. It is a
    /// fallback to switch on deliberately, not something to impose.
    var useAudio: Bool {
        get { UserDefaults.standard.bool(forKey: "useAudio") }
        set {
            UserDefaults.standard.set(newValue, forKey: "useAudio")
            if newValue {
                startAudio()
            } else {
                tearDownAudio()
            }
        }
    }

    /// Whether to also disable the idle timer. Off by default: a screen left on
    /// all night is a burn-in risk on OLED.
    var keepScreenOn: Bool {
        get { UserDefaults.standard.bool(forKey: "keepScreenOn") }
        set {
            UserDefaults.standard.set(newValue, forKey: "keepScreenOn")
            applyScreen()
        }
    }

    func start() {
        if useAudio { startAudio() }
        applyScreen()
    }

    func stop() {
        tearDownAudio()
        UIApplication.shared.isIdleTimerDisabled = false
        screenHeld = false
    }

    /// Called when the app comes back to the foreground. An interruption or a
    /// route change can leave the engine stopped while `audioRunning` still reads
    /// true, and a dead engine is worse than none: the app looks protected and is
    /// not.
    func verify() {
        guard useAudio else {
            applyScreen()
            return
        }
        guard audioRunning, engine?.isRunning != true else {
            applyScreen()
            return
        }
        restartAudio()
    }

    // MARK: - Silent audio

    private func startAudio() {
        guard !audioRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .playback rather than .ambient: ambient is silenced by the ring switch
            // and is the first thing the system reaps when it wants resources back.
            //
            // .mixWithOthers so that turning this on does not take the audio route
            // away from whatever else is playing. Exclusive playback is the mode the
            // scheduler respects most, but an app that silences the user's music to
            // keep itself awake is not worth the extra reliability.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[ChargeDiag] audio session refused: \(error.localizedDescription)")
            return
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        let engine = AVAudioEngine()
        let node = AVAudioSourceNode(format: format) { _, _, _, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            // One sample nudged off zero per buffer. A stream of pure digital
            // silence is an easy thing for the scheduler to notice; this is
            // -120 dBFS, which is not.
            if let first = buffers.first,
               let data = first.mData?.assumingMemoryBound(to: Float.self) {
                data[0] = 1.0e-6
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            NSLog("[ChargeDiag] audio engine refused to start: \(error.localizedDescription)")
            engine.detach(node)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        self.engine = engine
        self.node = node
        audioRunning = true
        observeInterruptions()
    }

    private func tearDownAudio() {
        guard audioRunning else { return }
        audioRunning = false
        if let engine {
            engine.stop()
            if let node { engine.detach(node) }
        }
        engine = nil
        node = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restartAudio() {
        tearDownAudio()
        startAudio()
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended else { return }
            Task { @MainActor in
                BackgroundKeeper.shared.verify()
            }
        }
    }

    // MARK: - Screen

    private func applyScreen() {
        let hold = keepScreenOn
        UIApplication.shared.isIdleTimerDisabled = hold
        screenHeld = hold
    }
}
