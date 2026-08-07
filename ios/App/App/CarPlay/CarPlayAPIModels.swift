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

    private enum CodingKeys: String, CodingKey {
        case id, name, mediaType
    }
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

    var title: String? { media?.metadata?.title }
    var authorName: String? { media?.metadata?.authorName }
}

struct LibraryItemMedia: Decodable {
    let metadata: LibraryItemMetadata?
}

struct LibraryItemMetadata: Decodable {
    let title: String?
    let authorName: String?
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
