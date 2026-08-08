//
//  SiriMediaContext.swift
//  App
//
//  Feeds SiriKit the app's media context outside of any live request: a library-size
//  INMediaUserContext (so Siri considers the app for media requests at all), INVocabulary
//  title/author strings (speech recognition quality), and INUpcomingMediaManager
//  suggestions (Listen Now / Siri Suggestions). Also caches the server's items-in-progress
//  ids so SiriPlayMediaHandler can boost partially-read books while ranking.
//

import Foundation
import Intents

@available(iOS 14.0, *)
class SiriMediaContext {

    /// Server library item ids with listening in progress, refreshed alongside the
    /// vocabulary. Read by SiriPlayMediaHandler on the main queue during ranking.
    private(set) static var inProgressLibraryItemIds: Set<String> = []

    /// Most recent in-progress episode per podcast library item id. Fallback for
    /// SiriPlayMediaHandler's episode pick when its fresh items-in-progress fetch misses
    /// the deadline: up to an hour stale, but losing the user's spot to the newest
    /// episode would be worse. Main queue only, like the rest of the state.
    private(set) static var inProgressRecentEpisodes: [String: (episodeId: String, title: String?)] = [:]

    /// INVocabulary is replace-per-type and silently truncates; keep lists modest.
    private static let vocabularyCap = 100
    private static let upcomingSuggestionsCap = 10
    private static let staleRefreshInterval: TimeInterval = 3600
    private static let libraryPageSize = 50

    private static var lastRefresh: Date?
    private static var serverConfigObserver: NSObjectProtocol?

    /// This pipeline has no request deadline (nothing user-facing waits on it), so a
    /// refresh's callbacks can land up to Alamofire's 60s timeout later -- long after a
    /// logout/server switch has triggered a newer refresh and cleared everything. Each
    /// callback checks it still belongs to the latest refresh before touching state, or a
    /// stale response would resurrect the old account's vocabulary and suggestions.
    /// Main-queue only, like the rest of the state.
    private static var refreshGeneration = 0

    /// Call once from didFinishLaunching: registers the connect/login/logout observer
    /// (Store.serverConfigDidChange fires on every native config change) and runs the
    /// first refresh.
    static func initialize() {
        guard serverConfigObserver == nil else { return }
        serverConfigObserver = NotificationCenter.default.addObserver(forName: Store.serverConfigDidChange, object: nil, queue: .main) { _ in
            refresh()
        }
        refresh()
    }

    /// Throttled refresh for applicationDidBecomeActive. No-ops until initialize() has
    /// run its first refresh, and at most once per hour after that.
    static func refreshIfStale() {
        guard let last = lastRefresh else { return }
        if Date().timeIntervalSince(last) >= staleRefreshInterval {
            refresh()
        }
    }

    /// Main queue only (Realm access; all ApiClient callbacks land back on main).
    static func refresh() {
        lastRefresh = Date()
        refreshGeneration += 1
        let generation = refreshGeneration

        guard Store.serverConfig != nil else {
            // Logged out: withdraw everything server-derived. Downloaded items remain
            // playable through the resolve path, but suggesting vocabulary for an account
            // that is gone would leave stale titles in Siri's recognizer.
            inProgressLibraryItemIds = []
            inProgressRecentEpisodes = [:]
            INVocabulary.shared().removeAllVocabularyStrings()
            INUpcomingMediaManager.shared.setSuggestedMediaIntents(NSOrderedSet())
            updateUserContext(numberOfLibraryItems: downloadedItems().count)
            AbsLogger.info(message: "SiriMediaContext: no server config, cleared Siri context")
            return
        }

        ApiClient.getLibraries { libraries in
            guard generation == refreshGeneration else { return }
            let statsTotal = libraries.compactMap { $0.stats?.totalItems }.reduce(0, +)
            updateUserContext(numberOfLibraryItems: statsTotal > 0 ? statsTotal : downloadedItems().count)
            refreshVocabularyAndSuggestions(libraries: libraries, generation: generation)
        }
    }

    // MARK: - INMediaUserContext

    private static func updateUserContext(numberOfLibraryItems: Int) {
        let context = INMediaUserContext()
        context.numberOfLibraryItems = numberOfLibraryItems
        // Every book the account can see is playable -- there is no upsell tier.
        context.subscriptionStatus = .subscribed
        context.becomeCurrent()
    }

    // MARK: - Vocabulary + suggestions

    private static func refreshVocabularyAndSuggestions(libraries: [CarPlayLibrary], generation: Int) {
        ApiClient.getItemsInProgress { itemsInProgress in
            guard generation == refreshGeneration else { return }
            let inProgress = itemsInProgress ?? []
            inProgressLibraryItemIds = Set(inProgress.map { $0.id })

            // First entry per item wins: the server orders items-in-progress most recent
            // first, and one show can appear once per in-progress episode.
            var recentEpisodes: [String: (episodeId: String, title: String?)] = [:]
            for item in inProgress where (item.mediaType ?? "book") == "podcast" {
                guard let episodeId = item.episodeId, recentEpisodes[item.id] == nil else { continue }
                recentEpisodes[item.id] = (episodeId, item.episodeTitle)
            }
            inProgressRecentEpisodes = recentEpisodes
            updateUpcomingSuggestions(inProgress)

            let inProgressBooks = inProgress.filter { ($0.mediaType ?? "book") == "book" }
            let inProgressShows = inProgress.filter { ($0.mediaType ?? "book") == "podcast" }
            let downloaded = downloadedItems()
            let downloadedBooks = downloaded.filter { $0.isBook }

            // Importance-descending, the order INVocabulary weighs them: what the user is
            // midway through, then what they chose to download, then library breadth.
            // Podcast SHOW titles only -- episode titles churn too fast for the 100-string
            // cap and shows are what people say to Siri.
            let priorityTitles = [
                inProgressBooks.compactMap { $0.title },
                downloadedBooks.compactMap { $0.media?.metadata?.title }
            ]
            let priorityAuthors = [
                inProgressBooks.compactMap { $0.authorName },
                downloadedBooks.compactMap { $0.media?.metadata?.authorDisplayName }
            ]
            let priorityShowTitles = [
                inProgressShows.compactMap { $0.title },
                downloaded.filter { $0.isPodcast }.compactMap { $0.media?.metadata?.title }
            ]

            guard !libraries.isEmpty else {
                setVocabulary(titleGroups: priorityTitles, authorGroups: priorityAuthors, showTitleGroups: priorityShowTitles)
                return
            }

            let group = DispatchGroup()
            var libraryTitles = Array(repeating: [String](), count: libraries.count)
            var libraryAuthors = Array(repeating: [String](), count: libraries.count)
            var libraryShowTitles = Array(repeating: [String](), count: libraries.count)
            for (index, library) in libraries.enumerated() {
                group.enter()
                ApiClient.getLibraryItems(libraryId: library.id, limit: libraryPageSize, page: 0) { response in
                    let results = response?.results ?? []
                    if library.mediaType == "podcast" {
                        libraryShowTitles[index] = results.compactMap { $0.title }
                    } else {
                        libraryTitles[index] = results.compactMap { $0.title }
                        libraryAuthors[index] = results.compactMap { $0.authorName }
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard generation == refreshGeneration else { return }
                setVocabulary(titleGroups: priorityTitles + libraryTitles,
                              authorGroups: priorityAuthors + libraryAuthors,
                              showTitleGroups: priorityShowTitles + libraryShowTitles)
            }
        }
    }

    private static func setVocabulary(titleGroups: [[String]], authorGroups: [[String]], showTitleGroups: [[String]]) {
        let titles = orderedDedupe(titleGroups)
        let authors = orderedDedupe(authorGroups)
        let showTitles = orderedDedupe(showTitleGroups)
        let vocabulary = INVocabulary.shared()

        guard !titles.isEmpty || !authors.isEmpty || !showTitles.isEmpty else {
            vocabulary.removeAllVocabularyStrings()
            return
        }
        // setVocabularyStrings REPLACES the previous set for that type, so each refresh
        // sends the full list.
        if !titles.isEmpty {
            vocabulary.setVocabularyStrings(NSOrderedSet(array: titles), of: .mediaAudiobookTitle)
        }
        if !authors.isEmpty {
            vocabulary.setVocabularyStrings(NSOrderedSet(array: authors), of: .mediaAudiobookAuthorName)
        }
        if !showTitles.isEmpty {
            vocabulary.setVocabularyStrings(NSOrderedSet(array: showTitles), of: .mediaShowTitle)
        }
        AbsLogger.info(message: "SiriMediaContext: vocabulary set (\(titles.count) titles, \(authors.count) authors, \(showTitles.count) shows)")
    }

    /// First occurrence wins, so callers pass groups most-important first (INVocabulary
    /// weighs strings in descending order of importance).
    private static func orderedDedupe(_ groups: [[String]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in groups.joined() {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strings over 1024 UTF-16 units are silently discarded by INVocabulary;
            // "Unknown" is the models' missing-metadata placeholder, not a real title.
            guard !value.isEmpty,
                  value.utf16.count <= 1024,
                  value.caseInsensitiveCompare("Unknown") != .orderedSame else { continue }
            if seen.insert(value.lowercased()).inserted {
                result.append(value)
            }
            if result.count >= vocabularyCap { break }
        }
        return result
    }

    // MARK: - INUpcomingMediaManager

    private static func updateUpcomingSuggestions(_ inProgressItems: [ItemInProgress]) {
        INUpcomingMediaManager.shared.setPredictionMode(.default, for: .audioBook)
        INUpcomingMediaManager.shared.setPredictionMode(.default, for: .podcastEpisode)

        let intents = inProgressItems.prefix(upcomingSuggestionsCap).compactMap { item -> INPlayMediaIntent? in
            let isPodcast = (item.mediaType ?? "book") == "podcast"
            let mediaItem: INMediaItem
            if isPodcast {
                // Composite id so handle() resumes the exact episode; a podcast entry
                // without its in-progress episode cannot be routed, so skip it.
                guard let episodeId = item.episodeId else { return nil }
                mediaItem = INMediaItem(
                    identifier: item.id + SiriPlayMediaHandler.episodeIdSeparator + episodeId,
                    title: item.displayTitle,
                    type: .podcastEpisode,
                    artwork: nil,
                    artist: item.title
                )
            } else {
                mediaItem = INMediaItem(
                    identifier: item.id,
                    title: item.displayTitle,
                    type: .audioBook,
                    artwork: nil,
                    artist: item.authorName
                )
            }
            return INPlayMediaIntent(
                mediaItems: [mediaItem],
                mediaContainer: nil,
                playShuffled: false,
                playbackRepeatMode: .none,
                resumePlayback: true,
                playbackQueueLocation: .now,
                playbackSpeed: nil,
                mediaSearch: nil
            )
        }
        INUpcomingMediaManager.shared.setSuggestedMediaIntents(NSOrderedSet(array: Array(intents)))
    }

    // MARK: - Helpers

    private static func downloadedItems() -> [LocalLibraryItem] {
        return Database.shared.getLocalLibraryItems()
    }
}
