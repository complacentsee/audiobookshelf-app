//
//  PlaybackLauncher.swift
//  App
//
//  Webview-free playback entry points, shared by CarPlay and Siri.
//

import AVFoundation
import Foundation
import MediaPlayer

@available(iOS 14.0, *)
class PlaybackLauncher {

    private static var nowPlayingPollTimer: Timer?

    /// `completion` reports whether playback actually started (true also covers the
    /// already-playing short-circuit), so callers with a user-facing contract (Siri's
    /// .success/.failure response) can answer honestly. CarPlay callers omit it.
    static func playServerItem(libraryItemId: String, episodeId: String? = nil, completion: ((Bool) -> Void)? = nil) {
        AbsLogger.info(message: "playServerItem called for \(libraryItemId)")

        // If this item is already loaded, unpause if needed and navigate to Now Playing.
        // "Play X" / "continue playing" on the current-but-paused session must resume it,
        // not silently report success.
        if let currentSession = PlayerHandler.getPlaybackSession(),
           currentSession.libraryItemId == libraryItemId,
           (episodeId == nil || currentSession.episodeId == episodeId) {
            AbsLogger.info(message: "Item already loaded (paused=\(PlayerHandler.paused)), resuming + pushing Now Playing")
            if PlayerHandler.paused {
                PlayerHandler.paused = false
            }
            CarPlaySceneDelegate.shared?.pushNowPlaying()
            completion?(true)
            return
        }

        let playbackRate = PlayerSettings.main().playbackRate
        AbsLogger.info(message: "Starting playback session, rate=\(playbackRate)")

        ApiClient.startPlaybackSession(libraryItemId: libraryItemId, episodeId: episodeId, forceTranscode: false) { session in
            AbsLogger.info(message: "API callback received, session.id='\(session.id)' displayTitle='\(session.displayTitle ?? "NIL")' duration=\(session.duration)")

            // ApiClient signals any failure as a callback with an empty session id.
            guard !session.id.isEmpty else {
                AbsLogger.error(message: "ERROR: Empty session ID!")
                completion?(false)
                return
            }

            session.serverConnectionConfigId = Store.serverConfig?.id
            session.serverAddress = Store.serverConfig?.address

            do {
                try session.save()
                AbsLogger.info(message: "Session saved, calling startPlayback")
                PlayerHandler.startPlayback(sessionId: session.id, playWhenReady: true, playbackRate: playbackRate)
                notifyWebviewOfExternalSession(session.id)
                scheduleNowPlayingPush()
                completion?(true)
            } catch {
                AbsLogger.error(message: "ERROR saving session: \(error)")
                completion?(false)
            }
        }
    }

    /// Returns true when playback was started (or the item was already playing), so callers
    /// with a user-facing contract (Siri's .success/.failure response) can report honestly.
    @discardableResult
    static func playLocalItem(localLibraryItemId: String, episodeId: String? = nil) -> Bool {
        // If this item is already loaded, unpause if needed and navigate to Now Playing
        // (see playServerItem).
        if let currentSession = PlayerHandler.getPlaybackSession(),
           currentSession.localLibraryItem?.id == localLibraryItemId,
           (episodeId == nil || currentSession.episodeId == episodeId) {
            if PlayerHandler.paused {
                PlayerHandler.paused = false
            }
            CarPlaySceneDelegate.shared?.pushNowPlaying()
            return true
        }

        let playbackRate = PlayerSettings.main().playbackRate

        guard let localItem = Database.shared.getLocalLibraryItem(localLibraryItemId: localLibraryItemId) else {
            AbsLogger.error(message: "PlaybackLauncher: Local item not found: \(localLibraryItemId)")
            return false
        }

        let episode = localItem.getPodcastEpisode(episodeId: episodeId)
        // A requested episode that is no longer downloaded must fail here: falling through
        // builds a whole-item session, and podcast items have no item-level tracks.
        if episodeId != nil, episode == nil {
            AbsLogger.error(message: "PlaybackLauncher: episode \(episodeId!) not found on \(localLibraryItemId)")
            return false
        }
        let playbackSession = localItem.getPlaybackSession(episode: episode)

        do {
            try playbackSession.save()
            PlayerHandler.startPlayback(sessionId: playbackSession.id, playWhenReady: true, playbackRate: playbackRate)
            notifyWebviewOfExternalSession(playbackSession.id)
            scheduleNowPlayingPush()
            return true
        } catch {
            AbsLogger.error(message: "PlaybackLauncher: Failed to save local playback session: \(error)")
            return false
        }
    }

    /// A single podcast episode is playable when its own audio file exists on disk as a
    /// regular file. Whole-item isPlayable would be wrong here: a podcast item fails that
    /// check as soon as ANY downloaded episode is hollowed out, which must not block the
    /// intact episodes.
    static func isEpisodePlayable(_ item: LocalLibraryItem, episodeId: String) -> Bool {
        guard let episode = item.getPodcastEpisode(episodeId: episodeId),
              let localFile = episode.audioTrack?.getLocalFile() else { return false }
        var isDirectory: ObjCBool = false
        let path = localFile.contentPath.path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            AbsLogger.error(message: "PlaybackLauncher: episode '\(episode.title)' of '\(item.media?.metadata?.title ?? item.id)' has missing/invalid audio file: \(localFile.filename ?? path)")
            return false
        }
        return true
    }

    /// A local item is only playable if its audio files actually exist on disk as regular files.
    /// Downloads can be hollowed out after the fact (observed: a device migration left hundreds of
    /// audio files as empty directories); handing such a path to AVPlayer fails with a generic
    /// "operation could not be completed" and the play attempt appears to do nothing at all.
    static func isPlayable(_ item: LocalLibraryItem) -> Bool {
        let audioFiles = item.localFiles.filter { $0.isAudioFile() }
        guard !audioFiles.isEmpty else { return false }
        for file in audioFiles {
            var isDirectory: ObjCBool = false
            let path = file.contentPath.path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                AbsLogger.error(message: "PlaybackLauncher: '\(item.media?.metadata?.title ?? item.id)' has missing/invalid audio file: \(file.filename ?? path)")
                return false
            }
        }
        return true
    }

    /// External-origin playback (CarPlay, Siri) bypasses AbsAudioPlayer, so the webview never hears
    /// about the session it started. Without this the phone app's player footer stays closed and
    /// cannot stop the playback.
    private static func notifyWebviewOfExternalSession(_ sessionId: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name(PlayerEvents.externalSessionStarted.rawValue),
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    // MARK: - Now Playing Push

    /// Polls until audio is confirmed outputting, then pushes the CarPlay Now Playing template.
    /// Safe no-op when CarPlay is not connected (CarPlaySceneDelegate.shared is nil).
    private static func scheduleNowPlayingPush() {
        nowPlayingPollTimer?.invalidate()
        var elapsed: TimeInterval = 0
        let interval: TimeInterval = 0.3
        let timeout: TimeInterval = 15.0

        nowPlayingPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            elapsed += interval

            // Use timeControlStatus (.playing) rather than rate > 0 to ensure
            // the AVPlayer is actually producing audio output, not just buffering.
            let isActuallyPlaying = PlayerHandler.isAudioActuallyPlaying
            let infoCenter = MPNowPlayingInfoCenter.default()
            let hasNowPlayingInfo = infoCenter.nowPlayingInfo != nil
            let playbackState = infoCenter.playbackState

            NSLog("[PLAYBACK-DEBUG] Poll tick elapsed=\(String(format: "%.1f", elapsed))s isActuallyPlaying=\(isActuallyPlaying) hasInfo=\(hasNowPlayingInfo) playbackState=\(playbackState.rawValue)")

            if isActuallyPlaying && hasNowPlayingInfo {
                timer.invalidate()
                nowPlayingPollTimer = nil
                AbsLogger.info(message: "Conditions met, pushing Now Playing template")
                CarPlaySceneDelegate.shared?.pushNowPlaying()
            } else if elapsed >= timeout {
                AbsLogger.info(message: "Timed out waiting for playback (\(String(format: "%.1f", elapsed))s), pushing anyway")
                timer.invalidate()
                nowPlayingPollTimer = nil
                CarPlaySceneDelegate.shared?.pushNowPlaying()
            }
        }
    }
}
