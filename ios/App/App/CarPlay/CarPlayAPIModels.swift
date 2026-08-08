//
//  CarPlayAPIModels.swift
//  App
//
//  Created for CarPlay integration.
//

import Foundation

// MARK: - Libraries

struct LibrariesResponse: Decodable {
    let libraries: [CarPlayLibrary]
}

struct CarPlayLibrary: Decodable {
    let id: String
    let name: String
    let mediaType: String?
    /// Present only when requested with ?include=stats (Siri's INMediaUserContext needs
    /// totalItems); CarPlay callers ignore it.
    let stats: LibraryStats?

    private enum CodingKeys: String, CodingKey {
        case id, name, mediaType, stats
    }
}

struct LibraryStats: Decodable {
    let totalItems: Int?
}

// MARK: - Library Items

struct LibraryItemsResponse: Decodable {
    let results: [LibraryItemResult]
    let total: Int
    let limit: Int
    let page: Int
}

struct LibraryItemResult: Decodable {
    let id: String
    let mediaType: String?
    let media: LibraryItemMedia?
    /// Episode-title search hits arrive as the podcast libraryItem with the matched
    /// episode spliced on under this key (same shape items-in-progress uses).
    let recentEpisode: ItemRecentEpisode?

    var title: String? { media?.metadata?.title }
    var authorName: String? { media?.metadata?.authorName ?? media?.metadata?.author }
}

struct LibraryItemMedia: Decodable {
    let metadata: LibraryItemMetadata?
}

struct LibraryItemMetadata: Decodable {
    let title: String?
    let authorName: String?
    /// Podcast metadata carries the author under "author"; books use "authorName".
    let author: String?
}

// MARK: - Search

/// api/libraries/{id}/search response. Book libraries answer under "book" (plus
/// series/authors/narrators arrays every client ignores); podcast libraries answer under
/// "podcast" (show title/author matches) and "episodes" (episode-title matches, each
/// libraryItem carrying the matched episode as recentEpisode). Search-result libraryItems
/// never embed a real episodes array -- the server empties it -- so episode listings
/// always require the expanded item fetch.
struct SearchResponse: Decodable {
    let book: [SearchResultEntry]?
    let podcast: [SearchResultEntry]?
    let episodes: [SearchResultEntry]?
}

struct SearchResultEntry: Decodable {
    let libraryItem: LibraryItemResult?
}

// MARK: - Items In Progress

struct ItemsInProgressResponse: Decodable {
    let libraryItems: [ItemInProgress]
}

struct ItemInProgress: Decodable {
    let id: String
    let mediaType: String?
    let media: LibraryItemMedia?
    let recentEpisode: ItemRecentEpisode?

    var title: String? { media?.metadata?.title }
    var authorName: String? { media?.metadata?.authorName }
    var progress: Double { 0 }
    var episodeId: String? { recentEpisode?.id }
    var episodeTitle: String? { recentEpisode?.title }

    var displayTitle: String {
        if let epTitle = episodeTitle {
            return epTitle
        }
        return title ?? "Unknown"
    }
}

struct ItemRecentEpisode: Decodable {
    let id: String?
    let title: String?
}
