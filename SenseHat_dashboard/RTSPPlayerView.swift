import SwiftUI

enum RTSPPlaybackState: Equatable {
    case idle
    case opening
    case buffering
    case playing
    case paused
    case stopped
    case ended
    case error
    case unavailable

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .opening:
            return "Opening"
        case .buffering:
            return "Buffering"
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        case .stopped:
            return "Stopped"
        case .ended:
            return "Ended"
        case .error:
            return "Error"
        case .unavailable:
            return "Unavailable"
        }
    }
}

#if canImport(MobileVLCKit)
import MobileVLCKit

private enum RTSPPlayerConfiguration {
    static let noVideoOutputGracePeriodNanoseconds: UInt64 = 2_000_000_000
    static let reconnectDelayNanoseconds: UInt64 = 350_000_000
    static let maximumReconnectAttempts = 4
    static let playerOptions = [
        "--rtsp-tcp",
        "--no-audio",
        "--codec=avcodec",
        "--avcodec-hw=none"
    ]
    static let mediaOptions = [
        ":network-caching=120",
        ":live-caching=120"
    ]
}

struct RTSPPlayerView: UIViewRepresentable {
    let streamURL: String?
    let reloadToken: Int
    let onStateChange: @MainActor (RTSPPlaybackState, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        context.coordinator.attach(to: uiView)
        context.coordinator.onStateChange = onStateChange
        context.coordinator.updateStream(urlString: streamURL, reloadToken: reloadToken)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private lazy var library = VLCLibrary(options: RTSPPlayerConfiguration.playerOptions)
        private lazy var mediaPlayer = VLCMediaPlayer(library: library)
        private weak var containerView: PlayerContainerView?
        private var currentURL: String?
        private var currentReloadToken: Int?
        private var noVideoOutputTask: Task<Void, Never>?
        private var reconnectTask: Task<Void, Never>?
        private var hasReportedVideoOutput = false
        private var shouldRetryCurrentURL = false
        private var reconnectAttemptCount = 0
        var onStateChange: (@MainActor (RTSPPlaybackState, String) -> Void)?

        override init() {
            super.init()
            library.debugLogging = true
            library.debugLoggingLevel = 3
            mediaPlayer.delegate = self
            mediaPlayer.scaleFactor = 0
            mediaPlayer.drawable = nil
        }

        func attach(to view: PlayerContainerView) {
            guard containerView !== view else {
                return
            }

            containerView = view
            mediaPlayer.drawable = view
        }

        func updateStream(urlString: String?, reloadToken: Int) {
            let trimmedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let trimmedURL, !trimmedURL.isEmpty else {
                stop()
                currentURL = nil
                currentReloadToken = nil
                report(.idle, "Viewer ready for a stream URL.")
                return
            }

            guard let url = URL(string: trimmedURL) else {
                stop()
                currentURL = nil
                currentReloadToken = nil
                report(.error, "The stream URL could not be parsed by VLC.")
                return
            }

            let isSameURL = currentURL == trimmedURL
            let isSameReloadToken = currentReloadToken == reloadToken
            guard !(isSameURL && isSameReloadToken) else {
                return
            }

            currentURL = trimmedURL
            currentReloadToken = reloadToken
            reconnectAttemptCount = 0
            shouldRetryCurrentURL = true
            openStream(url: url, description: trimmedURL)
        }

        func stop() {
            shouldRetryCurrentURL = false
            currentReloadToken = nil
            resetPlaybackWithoutReporting()
            if currentURL != nil {
                report(.stopped, "Stream stopped.")
            }
        }

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            let targetDescription = currentURL ?? "the stream"

            switch mediaPlayer.state {
            case .opening:
                report(.opening, "Opening stream from \(targetDescription)")
            case .buffering:
                report(.buffering, "Buffering \(targetDescription)")
            case .esAdded:
                selectVideoTrackIfNeeded()
            case .playing:
                selectVideoTrackIfNeeded()
                if mediaPlayer.hasVideoOut {
                    reportVideoOutput(for: targetDescription)
                } else {
                    report(.playing, "Connected to \(targetDescription). Waiting for the first video frame.")
                    scheduleNoVideoOutputCheck(for: targetDescription)
                }
            case .paused:
                report(.paused, "Playback paused.")
            case .stopped:
                if !scheduleReconnectIfNeeded(for: targetDescription, afterError: false) {
                    report(.stopped, "Stream stopped.")
                }
            case .ended:
                report(.ended, "Stream ended.")
            case .error:
                if !scheduleReconnectIfNeeded(for: targetDescription, afterError: true) {
                    let errorDetails = currentLibraryErrorMessage
                        .map { " libVLC: \($0)" }
                        ?? ""
                    report(
                        .error,
                        "VLC could not play \(targetDescription). Check the RTSP URL, stream credentials, server reachability, and network access.\(errorDetails)"
                    )
                }
            default:
                break
            }
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            selectVideoTrackIfNeeded()

            guard mediaPlayer.hasVideoOut else {
                return
            }

            let targetDescription = currentURL ?? "the stream"
            reportVideoOutput(for: targetDescription)
        }

        private func selectVideoTrackIfNeeded() {
            guard mediaPlayer.currentVideoTrackIndex == -1 else {
                return
            }

            let candidateTracks = mediaPlayer.videoTrackIndexes.compactMap { value -> Int? in
                if let number = value as? NSNumber {
                    return number.intValue
                }

                return value as? Int
            }

            guard let firstRenderableTrack = candidateTracks.first(where: { $0 >= 0 }) else {
                return
            }

            mediaPlayer.currentVideoTrackIndex = Int32(firstRenderableTrack)
        }

        private func scheduleNoVideoOutputCheck(for targetDescription: String) {
            noVideoOutputTask?.cancel()
            noVideoOutputTask = Task { [weak self] in
                guard let self else {
                    return
                }

                try? await Task.sleep(nanoseconds: RTSPPlayerConfiguration.noVideoOutputGracePeriodNanoseconds)
                guard !Task.isCancelled else {
                    return
                }

                guard self.currentURL != nil else {
                    return
                }

                guard self.mediaPlayer.state == .playing, !self.mediaPlayer.hasVideoOut else {
                    return
                }

                let hasVideoTracks = !self.mediaPlayer.videoTrackIndexes.isEmpty
                let errorDetails = self.currentLibraryErrorMessage
                    .map { " libVLC: \($0)" }
                    ?? ""
                if self.scheduleReconnectIfNeeded(for: targetDescription, afterError: true) {
                    return
                }

                let message: String
                if hasVideoTracks {
                    message = "Playback started for \(targetDescription), but VLC still has no video output on this iPhone. RTSP-over-TCP and software decode are enabled, so the next checks are the camera codec/profile and iPhone Local Network access in Settings.\(errorDetails)"
                } else {
                    message = "Playback started for \(targetDescription), but VLC did not detect a video track on this device. Verify the camera is sending a supported video stream.\(errorDetails)"
                }

                self.report(.error, message)
            }
        }

        private func reportVideoOutput(for targetDescription: String) {
            noVideoOutputTask?.cancel()
            noVideoOutputTask = nil

            guard !hasReportedVideoOutput else {
                return
            }

            hasReportedVideoOutput = true
            report(.playing, "Rendering video from \(targetDescription)")
        }

        private func report(_ state: RTSPPlaybackState, _ message: String) {
            Task { @MainActor in
                onStateChange?(state, message)
            }
        }

        private func openStream(url: URL, description: String) {
            resetPlaybackWithoutReporting()
            report(.opening, reconnectAttemptCount == 0 ? "Opening stream from \(description)" : "Retrying stream from \(description) (\(reconnectAttemptCount + 1)/\(RTSPPlayerConfiguration.maximumReconnectAttempts + 1))")

            let media = VLCMedia(url: url)
            RTSPPlayerConfiguration.mediaOptions.forEach { option in
                media.addOption(option)
            }
            mediaPlayer.media = media
            mediaPlayer.play()
        }

        @discardableResult
        private func scheduleReconnectIfNeeded(for targetDescription: String, afterError: Bool) -> Bool {
            guard shouldRetryCurrentURL, !hasReportedVideoOutput, let currentURL else {
                return false
            }

            guard reconnectAttemptCount < RTSPPlayerConfiguration.maximumReconnectAttempts else {
                return false
            }

            reconnectTask?.cancel()
            reconnectAttemptCount += 1

            report(
                .opening,
                afterError
                    ? "RTSP open failed for \(targetDescription). Retrying shortly (\(reconnectAttemptCount)/\(RTSPPlayerConfiguration.maximumReconnectAttempts))."
                    : "RTSP stream stopped before video was ready. Retrying \(targetDescription) shortly (\(reconnectAttemptCount)/\(RTSPPlayerConfiguration.maximumReconnectAttempts))."
            )

            reconnectTask = Task { [weak self] in
                guard let self else {
                    return
                }

                try? await Task.sleep(nanoseconds: RTSPPlayerConfiguration.reconnectDelayNanoseconds)
                guard !Task.isCancelled, self.shouldRetryCurrentURL, self.currentURL == currentURL else {
                    return
                }

                guard let url = URL(string: currentURL) else {
                    return
                }

                self.openStream(url: url, description: currentURL)
            }

            return true
        }

        private func resetPlaybackWithoutReporting() {
            noVideoOutputTask?.cancel()
            noVideoOutputTask = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            hasReportedVideoOutput = false
            mediaPlayer.stop()
            mediaPlayer.media = nil
        }

        private var currentLibraryErrorMessage: String? {
            guard let message = VLCLibrary.currentErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty else {
                return nil
            }

            return message
        }
    }
}

final class PlayerContainerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#else

struct RTSPPlayerView: View {
    let streamURL: String?
    let reloadToken: Int
    let onStateChange: @MainActor (RTSPPlaybackState, String) -> Void

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 10) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text("MobileVLCKit is not installed.")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Add the `MobileVLCKit` pod and reopen the workspace to enable RTSP playback.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if let streamURL, !streamURL.isEmpty {
                    Text(streamURL)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .task(id: streamURL) {
            let message = streamURL?.isEmpty == false
                ? "MobileVLCKit is not installed. Run pod install and open the Xcode workspace to enable RTSP playback."
                : "MobileVLCKit is not installed yet."
            onStateChange(.unavailable, message)
        }
    }
}

#endif
