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
            // Logged out: withdraw everything server-derived. Downloaded books remain
            // playable through the resolve path, but suggesting vocabulary for an account
            // that is gone would leave stale titles in Siri's recognizer.
            inProgressLibraryItemIds = []
            INVocabulary.shared().removeAllVocabularyStrings()
            INUpcomingMediaManager.shared.setSuggestedMediaIntents(NSOrderedSet())
            updateUserContext(numberOfLibraryItems: downloadedBooks().count)
            AbsLogger.info(message: "SiriMediaContext: no server config, cleared Siri context")
            return
        }

        ApiClient.getLibraries { libraries in
            guard generation == refreshGeneration else { return }
            let bookLibraries = libraries.filter { $0.mediaType != "podcast" }
            let statsTotal = bookLibraries.compactMap { $0.stats?.totalItems }.reduce(0, +)
            updateUserContext(numberOfLibraryItems: statsTotal > 0 ? statsTotal : downloadedBooks().count)
            refreshVocabularyAndSuggestions(bookLibraries: bookLibraries, generation: generation)
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

    private static func refreshVocabularyAndSuggestions(bookLibraries: [CarPlayLibrary], generation: Int) {
        ApiClient.getItemsInProgress { itemsInProgress in
            guard generation == refreshGeneration else { return }
            let inProgressBooks = (itemsInProgress ?? []).filter { ($0.mediaType ?? "book") == "book" }
            inProgressLibraryItemIds = Set(inProgressBooks.map { $0.id })
            updateUpcomingSuggestions(inProgressBooks)

            let downloaded = downloadedBooks()

            // Importance-descending, the order INVocabulary weighs them: what the user is
            // midway through, then what they chose to download, then library breadth.
            let priorityTitles = [
                inProgressBooks.compactMap { $0.title },
                downloaded.compactMap { $0.media?.metadata?.title }
            ]
            let priorityAuthors = [
                inProgressBooks.compactMap { $0.authorName },
                downloaded.compactMap { $0.media?.metadata?.authorDisplayName }
            ]

            guard !bookLibraries.isEmpty else {
                setVocabulary(titleGroups: priorityTitles, authorGroups: priorityAuthors)
                return
            }

            let group = DispatchGroup()
            var libraryTitles = Array(repeating: [String](), count: bookLibraries.count)
            var libraryAuthors = Array(repeating: [String](), count: bookLibraries.count)
            for (index, library) in bookLibraries.enumerated() {
                group.enter()
                ApiClient.getLibraryItems(libraryId: library.id, limit: libraryPageSize, page: 0) { response in
                    let results = response?.results ?? []
                    libraryTitles[index] = results.compactMap { $0.title }
                    libraryAuthors[index] = results.compactMap { $0.authorName }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard generation == refreshGeneration else { return }
                setVocabulary(titleGroups: priorityTitles + libraryTitles, authorGroups: priorityAuthors + libraryAuthors)
            }
        }
    }

    private static func setVocabulary(titleGroups: [[String]], authorGroups: [[String]]) {
        let titles = orderedDedupe(titleGroups)
        let authors = orderedDedupe(authorGroups)
        let vocabulary = INVocabulary.shared()

        guard !titles.isEmpty || !authors.isEmpty else {
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
        AbsLogger.info(message: "SiriMediaContext: vocabulary set (\(titles.count) titles, \(authors.count) authors)")
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

    private static func updateUpcomingSuggestions(_ inProgressBooks: [ItemInProgress]) {
        INUpcomingMediaManager.shared.setPredictionMode(.default, for: .audioBook)

        let intents = inProgressBooks.prefix(upcomingSuggestionsCap).map { item -> INPlayMediaIntent in
            let mediaItem = INMediaItem(
                identifier: item.id,
                title: item.displayTitle,
                type: .audioBook,
                artwork: nil,
                artist: item.authorName
            )
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

    private static func downloadedBooks() -> [LocalLibraryItem] {
        return Database.shared.getLocalLibraryItems().filter { $0.isBook }
    }
}
