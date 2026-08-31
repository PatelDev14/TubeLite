import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        activateAudio()
        observeAudioInterruptions()

        // Create window manually (no SceneDelegate needed)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.backgroundColor = .black
        window?.makeKeyAndVisible()

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Keep audio session alive when app moves to background
        activateAudio()
        // Tell the web view to force-continue playback
        NotificationCenter.default.post(name: .forceKeepPlaying, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        activateAudio()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        activateAudio()
    }

    private func activateAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback is required for background / lock-screen audio
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func observeAudioInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Interrupted (phone call, Siri, etc.) — system paused us
            break
        case .ended:
            // Interruption over — reactivate and ask the web view to resume
            activateAudio()
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    NotificationCenter.default.post(name: .forceKeepPlaying, object: nil)
                }
            } else {
                NotificationCenter.default.post(name: .forceKeepPlaying, object: nil)
            }
        @unknown default:
            break
        }
    }
}

// Shared notification so ViewController can force the video to keep playing
extension Notification.Name {
    static let forceKeepPlaying = Notification.Name("forceKeepPlaying")
}
