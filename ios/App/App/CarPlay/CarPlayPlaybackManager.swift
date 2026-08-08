//
//  CarPlayPlaybackManager.swift
//  App
//
//  Created for CarPlay integration.
//

import Foundation

/// Thin CarPlay-named facade over PlaybackLauncher, which holds the actual
/// webview-free playback logic shared with Siri.
@available(iOS 14.0, *)
class CarPlayPlaybackManager {

    static func playServerItem(libraryItemId: String, episodeId: String? = nil) {
        PlaybackLauncher.playServerItem(libraryItemId: libraryItemId, episodeId: episodeId)
    }

    static func playLocalItem(localLibraryItemId: String, episodeId: String? = nil) {
        PlaybackLauncher.playLocalItem(localLibraryItemId: localLibraryItemId, episodeId: episodeId)
    }
}
