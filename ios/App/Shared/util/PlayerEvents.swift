//
//  PlayerEvents.swift
//  App
//
//  Created by Rasmus Krämer on 14.04.22.
//

import Foundation

enum PlayerEvents: String {
    case update = "com.audiobookshelf.app.player.update"
    case closed = "com.audiobookshelf.app.player.closed"
    case sleepSet = "com.audiobookshelf.app.player.sleep.set"
    case sleepEnded = "com.audiobookshelf.app.player.sleep.ended"
    case failed = "com.audiobookshelf.app.player.failed"
    case localProgress = "com.audiobookshelf.app.player.localProgress"
    /// Playback was started natively rather than by the webview -- currently only by CarPlay.
    /// The webview drives its own UI off the events AbsAudioPlayer emits in startPlaybackSession,
    /// so without this it never learns a session began: the player footer stays closed and the
    /// phone app cannot pause or stop what it does not know is playing.
    /// userInfo: ["sessionId": String]
    case externalSessionStarted = "com.audiobookshelf.app.player.externalSessionStarted"
}
