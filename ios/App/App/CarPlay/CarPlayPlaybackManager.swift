//
//  CarPlayPlaybackManager.swift
//  App
//
//  Created for CarPlay integration.
//

import AVFoundation
import Foundation
import MediaPlayer

@available(iOS 14.0, *)
class CarPlayPlaybackManager {

    private static var nowPlayingPollTimer: Timer?

    static func playServerItem(libraryItemId: String, episodeId: String? = nil) {
        AbsLogger.info(message: "playServerItem called for \(libraryItemId)")

        // If this item is already playing, just navigate to Now Playing
        if let currentSession = PlayerHandler.getPlaybackSession(),
           currentSession.libraryItemId == libraryItemId,
           (episodeId == nil || currentSession.episodeId == episodeId) {
            AbsLogger.info(message: "Item already playing, pushing Now Playing")
            CarPlaySceneDelegate.shared?.pushNowPlaying()
            return
        }

        let playbackRate = PlayerSettings.main().playbackRate
        AbsLogger.info(message: "Starting playback session, rate=\(playbackRate)")

        ApiClient.startPlaybackSession(libraryItemId: libraryItemId, episodeId: episodeId, forceTranscode: false) { session in
            AbsLogger.info(message: "API callback received, session.id='\(session.id)' displayTitle='\(session.displayTitle ?? "NIL")' duration=\(session.duration)")

            guard !session.id.isEmpty else {
                AbsLogger.error(message: "ERROR: Empty session ID!")
                return
            }

            session.serverConnectionConfigId = Store.serverConfig?.id
            session.serverAddress = Store.serverConfig?.address

            do {
                try session.save()
                AbsLogger.info(message: "Session saved, calling startPlayback")
                PlayerHandler.startPlayback(sessionId: session.id, playWhenReady: true, playbackRate: playbackRate)
                scheduleNowPlayingPush()
            } catch {
                AbsLogger.error(message: "ERROR saving session: \(error)")
            }
        }
    }

    static func playLocalItem(localLibraryItemId: String, episodeId: String? = nil) {
        // If this item is already playing, just navigate to Now Playing
        if let currentSession = PlayerHandler.getPlaybackSession(),
           currentSession.localLibraryItem?.id == localLibraryItemId,
           (episodeId == nil || currentSession.episodeId == episodeId) {
            CarPlaySceneDelegate.shared?.pushNowPlaying()
            return
        }

        let playbackRate = PlayerSettings.main().playbackRate

        guard let localItem = Database.shared.getLocalLibraryItem(localLibraryItemId: localLibraryItemId) else {
            AbsLogger.error(message: "CarPlay: Local item not found: \(localLibraryItemId)")
            return
        }

        let episode = localItem.getPodcastEpisode(episodeId: episodeId)
        let playbackSession = localItem.getPlaybackSession(episode: episode)

        do {
            try playbackSession.save()
            PlayerHandler.startPlayback(sessionId: playbackSession.id, playWhenReady: true, playbackRate: playbackRate)
            scheduleNowPlayingPush()
        } catch {
            AbsLogger.error(message: "CarPlay: Failed to save local playback session: \(error)")
        }
    }

    // MARK: - Now Playing Push

    /// Polls until audio is confirmed outputting, then pushes the Now Playing template.
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

            NSLog("[CARPLAY-DEBUG] Poll tick elapsed=\(String(format: "%.1f", elapsed))s isActuallyPlaying=\(isActuallyPlaying) hasInfo=\(hasNowPlayingInfo) playbackState=\(playbackState.rawValue)")

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
