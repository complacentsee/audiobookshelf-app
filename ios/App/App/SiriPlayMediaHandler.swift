//
//  SiriPlayMediaHandler.swift
//  App
//
//  Handles "Hey Siri, play <title> on Audiobookshelf" (INPlayMediaIntent), in-app via
//  application(_:handlerFor:) -- no Intents extension target. Downloaded books resolve
//  locally and instantly; everything else races a server search with a hard deadline so
//  every Siri callback completes well inside Siri's ~10 second budget.
//

import Foundation
import Intents
import UIKit

@available(iOS 14.0, *)
class SiriPlayMediaHandler: NSObject, INPlayMediaIntentHandling {

    /// INMediaItem identifiers are item ids verbatim. LocalLibraryItem ids are intrinsically
    /// "local_<UUID>" (see LocalLibraryItem.id), while server library item ids are bare UUIDs,
    /// so the prefix doubles as the local-vs-server routing discriminator in handle().
    private static let localIdPrefix = "local_"

    /// Podcast episodes ride the same identifiers as "<itemId>::<episodeId>". "::" cannot
    /// appear in either id space, so its absence still means "book/whole item" and every
    /// donation or suggestion minted before podcasts existed keeps routing correctly. A
    /// trailing-empty episode part ("<itemId>::") marks a show whose episode pick missed
    /// resolve's deadline; handle() finishes the pick inside its own budget. Shared with
    /// SiriMediaContext and AbsAudioPlayer so donations and suggestions mint matching ids.
    static let episodeIdSeparator = "::"

    /// Server search budget inside resolveMediaItems. Timing out degrades to local-only.
    private static let serverSearchTimeout: TimeInterval = 4.0
    /// Extra budget for turning a server show match into a concrete episode (items-in-
    /// progress + progress rows + expanded item, all in parallel). Missing it is not
    /// fatal -- the candidate keeps its trailing separator and handle() redoes the pick.
    private static let episodePickTimeout: TimeInterval = 2.0
    /// Cosmetic cover fetch for a server-only top match; never worth more than this.
    private static let artworkGrace: TimeInterval = 1.0
    /// How long handle() waits for a server stream to start before answering .inProgress.
    private static let serverHandleDeadline: TimeInterval = 8.0
    /// A book the user is partway through outranks a same-score cold book.
    private static let inProgressBoost = 15
    /// artistName arriving in its own intent slot confirming the candidate's author.
    private static let artistMatchBoost = 10
    /// Siri classified the request as podcast- or audiobook-flavored. A boost rather than
    /// a filter: its type inference is wrong often enough that filtering would eat valid
    /// requests. Mirrored on both sides so an explicit "podcast"/"audiobook" in the
    /// utterance breaks same-name ties either way.
    private static let typeRequestBoost = 10
    /// The server matched this item on something the local scorer cannot see (series,
    /// narrator, subtitle); keep it as a low-ranked alternative rather than dropping it.
    private static let serverMatchFloorScore = 20
    /// Siri auto-plays the first item; the rest render as tap-to-switch alternatives.
    private static let maxResults = 3

    /// One scored candidate from either source. Everything is a plain value copied out of
    /// the Realm object at scoring time: candidates live across async gaps (server search,
    /// episode pick, artwork fetch) and a live LocalLibraryItem can be invalidated by a
    /// concurrent delete before it is read again.
    private struct Candidate {
        let id: String
        /// Siri UI title: the episode title for episode candidates, else the item title.
        let title: String
        /// Siri UI artist: the show title for episode candidates, else the author.
        let author: String?
        let isLocal: Bool
        /// The server-side id of a downloaded copy (LocalLibraryItem.libraryItemId).
        let serverLibraryItemId: String?
        let localCoverUrl: URL?
        let isPodcast: Bool
        let isEpisode: Bool
        var score: Int

        var mediaItemType: INMediaItemType {
            if isEpisode { return .podcastEpisode }
            return isPodcast ? .podcastShow : .audioBook
        }

        /// Item id for artwork lookups; covers belong to the item, never the episode.
        var itemId: String {
            guard let range = id.range(of: SiriPlayMediaHandler.episodeIdSeparator) else { return id }
            return String(id[..<range.lowerBound])
        }

        /// Show candidate (server or downloaded) still awaiting its episode pick
        /// ("<itemId>::").
        var needsEpisodePick: Bool {
            return isPodcast && !isEpisode && id.hasSuffix(SiriPlayMediaHandler.episodeIdSeparator)
        }
    }

    /// A resolved episode choice; plain values only (see Candidate).
    private struct EpisodePick {
        let episodeId: String
        let title: String
    }

    // MARK: - INPlayMediaIntentHandling

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // mediaName can arrive nil or mangled -- Siri strips words it thinks are structural
        // ("playlist", "album") and sometimes drops the phrase entirely. A no-title request
        // ("continue playing / resume my book / play Audiobookshelf") is a resume: pick up
        // the most recently played item instead of failing.
        guard let query = intent.mediaSearch?.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            AbsLogger.info(message: "Siri: no mediaName (resumePlayback=\(String(describing: intent.resumePlayback))), resolving continue-listening")
            Self.resolveContinueListening(completion: completion)
            return
        }
        let artistName = intent.mediaSearch?.artistName
        let requestedType = intent.mediaSearch?.mediaType

        // Intents callbacks arrive on a background queue; keep Realm access on main like
        // the rest of the app. Every continuation below also lands on main (Alamofire,
        // group.notify, deadlines), so this whole resolve is single-queue and race-free.
        DispatchQueue.main.async {
            let localCandidates = Self.scoredLocalCandidates(query: query, artistName: artistName, requestedType: requestedType)

            // The server matches each field by substring, so the " by "-split title-only
            // variant must be sent as its own query or "<title> by <author>" phrases would
            // miss every non-downloaded book.
            let serverQueries = Self.searchQueries(for: query).map { $0.q }
            ApiClient.searchAllLibraries(queries: serverQueries, timeout: Self.serverSearchTimeout) { serverResults in
                let merged = Self.mergeAndRank(local: localCandidates, server: serverResults, query: query, artistName: artistName, requestedType: requestedType)
                guard !merged.isEmpty else {
                    AbsLogger.error(message: "Siri: no match for '\(query)' (\(localCandidates.count) local, \(serverResults.count) server results)")
                    completion([INPlayMediaMediaItemResolutionResult.unsupported()])
                    return
                }
                Self.resolveDeferredEpisodePicks(for: Array(merged.prefix(Self.maxResults))) { candidates in
                    Self.resolutionResults(for: candidates, query: query, completion: completion)
                }
            }
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard let itemId = intent.mediaItems?.first?.identifier, !itemId.isEmpty else {
            AbsLogger.error(message: "Siri: handle() with no identifier")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        AbsLogger.info(message: "Siri: starting playback for \(itemId)")

        DispatchQueue.main.async {
            // Episode composites route first; everything without "::" keeps the phase-1/2
            // whole-item semantics, so pre-podcast donations and suggestions stay valid.
            if let separatorRange = itemId.range(of: Self.episodeIdSeparator) {
                let itemPart = String(itemId[..<separatorRange.lowerBound])
                let episodePart = String(itemId[separatorRange.upperBound...])
                Self.handleEpisode(itemId: itemPart, episodeId: episodePart.isEmpty ? nil : episodePart, completion: completion)
                return
            }

            if itemId.hasPrefix(Self.localIdPrefix) {
                let started = PlaybackLauncher.playLocalItem(localLibraryItemId: itemId)
                completion(INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil))
                return
            }

            // Server ids can reach handle() for books that are also downloaded (donations
            // and Listen Now suggestions predate a download; resolve remaps, but only for
            // its own results). A playable local copy always wins over streaming. Podcast
            // twins are excluded: playing a podcast item whole would glue every episode
            // into one session -- a bare podcast id goes through the episode pick instead.
            if let localTwin = Database.shared.getLocalLibraryItem(byServerLibraryItemId: itemId) {
                if localTwin.isBook, PlaybackLauncher.isPlayable(localTwin) {
                    AbsLogger.info(message: "Siri: server id \(itemId) has playable local copy \(localTwin.id), playing locally")
                    let started = PlaybackLauncher.playLocalItem(localLibraryItemId: localTwin.id)
                    completion(INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil))
                    return
                }
                if localTwin.isPodcast {
                    Self.handleEpisode(itemId: itemId, episodeId: nil, completion: completion)
                    return
                }
            }

            // Server stream: session create + save can outlive Siri's patience on a slow
            // network. Answer .inProgress at the deadline -- playback still starts when the
            // session lands, and .failure would make Siri apologize over audio that then
            // begins playing.
            var responded = false
            let respond: (INPlayMediaIntentResponseCode) -> Void = { code in
                guard !responded else { return }
                responded = true
                completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
            }
            let deadline = DispatchWorkItem {
                AbsLogger.info(message: "Siri: server playback start exceeded \(Self.serverHandleDeadline)s, answering .inProgress")
                respond(.inProgress)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.serverHandleDeadline, execute: deadline)

            PlaybackLauncher.playServerItem(libraryItemId: itemId) { started in
                deadline.cancel()
                respond(started ? .success : .failure)
            }
        }
    }

    /// Plays a podcast episode. A nil episodeId means resolve could not finish the episode
    /// pick inside its deadline (or a bare podcast id arrived from an old donation) -- redo
    /// the pick here under handle()'s longer budget. Main queue only.
    private static func handleEpisode(itemId: String, episodeId: String?, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        if itemId.hasPrefix(localIdPrefix) {
            // "local_X::" means resolve's server-informed pick never finished; the local
            // ordering is the designed offline fallback, and it is synchronous.
            var resolvedEpisodeId = episodeId
            if resolvedEpisodeId == nil,
               let item = Database.shared.getLocalLibraryItem(localLibraryItemId: itemId) {
                resolvedEpisodeId = pickLocalEpisode(item: item)?.episodeId
            }
            guard let resolvedEpisodeId = resolvedEpisodeId else {
                AbsLogger.error(message: "Siri: no playable local episode for \(itemId)")
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }
            let started = PlaybackLauncher.playLocalItem(localLibraryItemId: itemId, episodeId: resolvedEpisodeId)
            completion(INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil))
            return
        }

        // Everything below may hit the network (pick fetches and/or stream start), so the
        // whole path shares one .inProgress deadline (see handle()'s server branch).
        var responded = false
        let respond: (INPlayMediaIntentResponseCode) -> Void = { code in
            guard !responded else { return }
            responded = true
            completion(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
        let deadline = DispatchWorkItem {
            AbsLogger.info(message: "Siri: episode playback start exceeded \(serverHandleDeadline)s, answering .inProgress")
            respond(.inProgress)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + serverHandleDeadline, execute: deadline)

        let play: (String) -> Void = { episodeId in
            // The already-loaded session (even paused) wins over everything: resuming
            // beats restarting, and a freshly downloaded twin's saved position can lag
            // the live session. The matching launcher's short-circuit does the unpause.
            if let current = PlayerHandler.getPlaybackSession(), current.episodeId == episodeId,
               current.libraryItemId == itemId {
                if let localSessionItemId = current.localLibraryItem?.id {
                    let started = PlaybackLauncher.playLocalItem(localLibraryItemId: localSessionItemId, episodeId: episodeId)
                    deadline.cancel()
                    respond(started ? .success : .failure)
                    return
                }
                PlaybackLauncher.playServerItem(libraryItemId: itemId, episodeId: episodeId) { started in
                    deadline.cancel()
                    respond(started ? .success : .failure)
                }
                return
            }

            // A downloaded copy of this exact episode wins over streaming.
            if let twin = localTwinEpisode(serverItemId: itemId, episodeId: episodeId) {
                AbsLogger.info(message: "Siri: episode \(episodeId) of \(itemId) is downloaded (\(twin.localItemId)), playing locally")
                let started = PlaybackLauncher.playLocalItem(localLibraryItemId: twin.localItemId, episodeId: episodeId)
                deadline.cancel()
                respond(started ? .success : .failure)
                return
            }
            PlaybackLauncher.playServerItem(libraryItemId: itemId, episodeId: episodeId) { started in
                deadline.cancel()
                respond(started ? .success : .failure)
            }
        }

        if let episodeId = episodeId {
            play(episodeId)
            return
        }

        // Episode unknown: fresh pick. No !responded guard after the fetches -- if the
        // deadline already answered .inProgress, playback should still start (that is what
        // .inProgress promises).
        var itemsInProgress: [ItemInProgress]?
        var progressRows: [MediaProgress]?
        var expandedItem: LibraryItem?
        let group = DispatchGroup()
        group.enter()
        ApiClient.getItemsInProgress { items in
            itemsInProgress = items
            group.leave()
        }
        group.enter()
        ApiClient.getUserMediaProgress { rows in
            progressRows = rows
            group.leave()
        }
        group.enter()
        ApiClient.getLibraryItemWithProgress(libraryItemId: itemId, episodeId: nil) { item in
            expandedItem = item
            group.leave()
        }
        group.notify(queue: .main) {
            guard let pick = pickServerEpisode(libraryItemId: itemId, itemsInProgress: itemsInProgress, progressRows: progressRows, expandedItem: expandedItem) else {
                AbsLogger.error(message: "Siri: no playable episode found for \(itemId)")
                deadline.cancel()
                respond(.failure)
                return
            }
            AbsLogger.info(message: "Siri: picked episode '\(pick.title)' (\(pick.episodeId)) for \(itemId)")
            play(pick.episodeId)
        }
    }

    // MARK: - Matching

    /// Lowercase, diacritic-insensitive fuzzy match over title + author, mirroring the Android
    /// app's search semantics (MediaManager.getFromSearch: lowercase substring, local-first).
    ///
    /// Siri often leaves the artist clause inside mediaName ("project hail mary by andy weir");
    /// the part before the last " by " is retried as a title-only query, penalized so a real
    /// title containing " by " still wins outright.
    private static func searchQueries(for query: String) -> [(q: String, penalty: Int)] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }

        var queries: [(q: String, penalty: Int)] = [(q, 0)]
        if let byRange = q.range(of: " by ", options: .backwards) {
            let titleOnly = String(q[..<byRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !titleOnly.isEmpty {
                queries.append((titleOnly, 5))
            }
        }
        return queries
    }

    private static func podcastTypeBoost(_ requestedType: INMediaItemType?) -> Int {
        switch requestedType {
        case .podcastShow, .podcastEpisode, .podcastStation, .podcastPlaylist:
            return typeRequestBoost
        default:
            return 0
        }
    }

    private static func bookTypeBoost(_ requestedType: INMediaItemType?) -> Int {
        return requestedType == .audioBook ? typeRequestBoost : 0
    }

    private static func scoredLocalCandidates(query: String, artistName: String?, requestedType: INMediaItemType?) -> [Candidate] {
        let queries = searchQueries(for: query)
        guard !queries.isEmpty else { return [] }
        let artist = normalizedArtist(artistName)
        let inProgressIds = localInProgressIds()
        let serverInProgressIds = SiriMediaContext.inProgressLibraryItemIds
        let podcastBoost = podcastTypeBoost(requestedType)
        let bookBoost = bookTypeBoost(requestedType)

        // A show-title match and an episode-title match can resolve to the same episode;
        // keep whichever scored higher.
        var byId: [String: Candidate] = [:]
        let add: (Candidate) -> Void = { candidate in
            if let existing = byId[candidate.id], existing.score >= candidate.score { return }
            byId[candidate.id] = candidate
        }

        for item in Database.shared.getLocalLibraryItems() {
            if item.isBook {
                guard let rawTitle = item.media?.metadata?.title,
                      var score = Self.score(queries: queries, artist: artist, rawTitle: rawTitle,
                                             rawAuthor: item.media?.metadata?.authorDisplayName) else { continue }
                // Validate files on disk for scored contenders only, so a hollowed-out download
                // never wins but the whole library isn't stat'ed on every query.
                guard PlaybackLauncher.isPlayable(item) else { continue }
                if inProgressIds.contains(item.id) {
                    score += inProgressBoost
                }
                score += bookBoost
                add(Candidate(
                    id: item.id,
                    title: rawTitle,
                    author: cleanAuthor(item.media?.metadata?.authorDisplayName),
                    isLocal: true,
                    serverLibraryItemId: item.libraryItemId,
                    localCoverUrl: item.coverUrl,
                    isPodcast: false,
                    isEpisode: false,
                    score: score
                ))
                continue
            }

            guard item.isPodcast, let showTitle = item.media?.metadata?.title else { continue }
            let showAuthor = item.media?.metadata?.authorDisplayName

            // Show-title match. Unlike a book, the downloaded subset is not the show:
            // the episode the user actually wants may be in progress server-side and not
            // downloaded. So the episode choice is DEFERRED to the shared pick stage
            // (server-informed when online, pickLocalEpisode as the offline fallback);
            // requiring a playable local pick up front keeps the offline guarantee.
            if var score = Self.score(queries: queries, artist: artist, rawTitle: showTitle, rawAuthor: showAuthor),
               pickLocalEpisode(item: item) != nil {
                if inProgressIds.contains(item.id)
                    || (item.libraryItemId.map { serverInProgressIds.contains($0) } ?? false) {
                    score += inProgressBoost
                }
                score += podcastBoost
                add(Candidate(
                    id: item.id + episodeIdSeparator,
                    title: showTitle,
                    author: cleanAuthor(showAuthor),
                    isLocal: true,
                    serverLibraryItemId: item.libraryItemId,
                    localCoverUrl: item.coverUrl,
                    isPodcast: true,
                    isEpisode: false,
                    score: score
                ))
            }

            // Episode-title matches. Bounded: local items only hold downloaded episodes.
            // The show title fills the author slot so "<episode> by <show>" phrasing and
            // a show name spoken into the artist slot both land.
            guard let episodes = item.media?.episodes else { continue }
            for episode in episodes {
                guard var score = Self.score(queries: queries, artist: artist, rawTitle: episode.title, rawAuthor: showTitle) else { continue }
                guard PlaybackLauncher.isEpisodePlayable(item, episodeId: episode.id) else { continue }
                let progressId = "\(item.id)-\(episode.id)"
                if let row = Database.shared.getLocalMediaProgress(localMediaProgressId: progressId),
                   row.progress > 0, !row.isFinished {
                    score += inProgressBoost
                }
                score += podcastBoost
                add(Candidate(
                    id: item.id + episodeIdSeparator + episode.id,
                    title: episode.title,
                    author: showTitle,
                    isLocal: true,
                    serverLibraryItemId: item.libraryItemId,
                    localCoverUrl: item.coverUrl,
                    isPodcast: true,
                    isEpisode: true,
                    score: score
                ))
            }
        }
        return Array(byId.values)
    }

    private static func mergeAndRank(local: [Candidate], server: [LibraryItemResult], query: String, artistName: String?, requestedType: INMediaItemType?) -> [Candidate] {
        let queries = searchQueries(for: query)
        let artist = normalizedArtist(artistName)
        let podcastBoost = podcastTypeBoost(requestedType)
        let bookBoost = bookTypeBoost(requestedType)
        // A playable downloaded copy beats its own server twin (instant + works offline).
        // An unplayable local copy was never scored, so its server twin survives here.
        // Podcast show twins are safe to collapse too: the local show candidate defers to
        // the same server-informed episode pick the server candidate would have used.
        let downloadedServerIds = Set(local.compactMap { $0.serverLibraryItemId })
        let serverInProgressIds = SiriMediaContext.inProgressLibraryItemIds
        let localInProgressIds = Self.localInProgressIds()

        var merged = local
        for result in server {
            if (result.mediaType ?? "book") == "podcast" {
                // Episode-title match: the target is this specific episode, so it stays
                // even when the show also produced a local candidate.
                if let matchedEpisode = result.recentEpisode, let episodeId = matchedEpisode.id {
                    var score = Self.score(queries: queries, artist: artist, rawTitle: matchedEpisode.title, rawAuthor: result.title)
                        ?? serverMatchFloorScore
                    if SiriMediaContext.inProgressRecentEpisodes[result.id]?.episodeId == episodeId {
                        score += inProgressBoost
                    }
                    score += podcastBoost
                    let title = matchedEpisode.title ?? "Unknown"
                    if let twin = localTwinEpisode(serverItemId: result.id, episodeId: episodeId) {
                        merged.append(Candidate(
                            id: twin.localItemId + episodeIdSeparator + episodeId,
                            title: title,
                            author: result.title,
                            isLocal: true,
                            serverLibraryItemId: result.id,
                            localCoverUrl: twin.coverUrl,
                            isPodcast: true,
                            isEpisode: true,
                            score: score
                        ))
                    } else {
                        merged.append(Candidate(
                            id: result.id + episodeIdSeparator + episodeId,
                            title: title,
                            author: result.title,
                            isLocal: false,
                            serverLibraryItemId: nil,
                            localCoverUrl: nil,
                            isPodcast: true,
                            isEpisode: true,
                            score: score
                        ))
                    }
                    continue
                }

                // Show-title match. The episode is picked asynchronously afterwards
                // (resolveDeferredEpisodePicks); until then the id is "<itemId>::".
                guard !downloadedServerIds.contains(result.id) else { continue }
                var score = Self.score(queries: queries, artist: artist, rawTitle: result.title, rawAuthor: result.authorName)
                    ?? serverMatchFloorScore
                if serverInProgressIds.contains(result.id) {
                    score += inProgressBoost
                }
                score += podcastBoost
                merged.append(Candidate(
                    id: result.id + episodeIdSeparator,
                    title: result.title ?? "Unknown",
                    author: cleanAuthor(result.authorName),
                    isLocal: false,
                    serverLibraryItemId: nil,
                    localCoverUrl: nil,
                    isPodcast: true,
                    isEpisode: false,
                    score: score
                ))
                continue
            }

            guard !downloadedServerIds.contains(result.id) else { continue }
            guard (result.mediaType ?? "book") == "book" else { continue }
            var score = Self.score(queries: queries, artist: artist, rawTitle: result.title, rawAuthor: result.authorName)
                ?? serverMatchFloorScore

            // The server can match on fields the local scorer cannot see (subtitle,
            // series, narrator), so this hit may still be a downloaded book that produced
            // no local candidate. Remap it onto the playable local copy rather than
            // streaming a book that is sitting on disk.
            if let localTwin = Database.shared.getLocalLibraryItem(byServerLibraryItemId: result.id),
               localTwin.isBook, PlaybackLauncher.isPlayable(localTwin) {
                if serverInProgressIds.contains(result.id) || localInProgressIds.contains(localTwin.id) {
                    score += inProgressBoost
                }
                score += bookBoost
                merged.append(Candidate(
                    id: localTwin.id,
                    title: localTwin.media?.metadata?.title ?? result.title ?? "Unknown",
                    author: cleanAuthor(localTwin.media?.metadata?.authorDisplayName ?? result.authorName),
                    isLocal: true,
                    serverLibraryItemId: result.id,
                    localCoverUrl: localTwin.coverUrl,
                    isPodcast: false,
                    isEpisode: false,
                    score: score
                ))
                continue
            }

            if serverInProgressIds.contains(result.id) {
                score += inProgressBoost
            }
            score += bookBoost
            merged.append(Candidate(
                id: result.id,
                title: result.title ?? "Unknown",
                author: cleanAuthor(result.authorName),
                isLocal: false,
                serverLibraryItemId: nil,
                localCoverUrl: nil,
                isPodcast: false,
                isEpisode: false,
                score: score
            ))
        }

        // Deterministic order: score, then local before server (instant + offline), then a
        // stable title/id tie-break so ambiguous queries pick the same item every time.
        // The same episode can arrive from both sources (local scan + server episode match
        // diverted to the twin); the post-sort dedupe keeps the higher-ranked one.
        var seen = Set<String>()
        return merged.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }.filter { seen.insert($0.id).inserted }
    }

    private static func score(queries: [(q: String, penalty: Int)], artist: String?, rawTitle: String?, rawAuthor: String?) -> Int? {
        guard let rawTitle = rawTitle else { return nil }
        let title = normalize(rawTitle)
        // "Unknown" is the model's placeholder for missing metadata, not searchable text;
        // without this, queries like "know" fuzzy-match every metadata-less book.
        let rawAuthorNormalized = normalize(rawAuthor ?? "")
        let author = rawAuthorNormalized == "unknown" ? "" : rawAuthorNormalized

        var best: Int?
        for (candidate, penalty) in queries {
            if let s = Self.score(query: candidate, title: title, author: author) {
                best = max(best ?? Int.min, s - penalty)
            }
        }
        guard var result = best else { return nil }
        if let artist = artist, !author.isEmpty, author.contains(artist) {
            result += artistMatchBoost
        }
        return result
    }

    private static func score(query q: String, title: String, author: String) -> Int? {
        // Placeholder titles only match exactly, never fuzzily (see score(queries:...)).
        if title == "unknown" {
            return title == q ? 100 : nil
        }
        if title == q { return 100 }
        if title.hasPrefix(q) { return 80 }
        if title.contains(q) { return 60 }

        let tokens = q.split(separator: " ")
        if tokens.allSatisfy({ title.contains($0) }) {
            // Speech recognition reorders/adds words ("wool the omnibus" -> "Wool Omnibus")
            return 45
        }
        if !author.isEmpty, tokens.allSatisfy({ $0 == "by" || title.contains($0) || author.contains($0) }) {
            // "<title> by <author>" spoken as one phrase and delivered unsplit in mediaName
            return 40
        }
        if !author.isEmpty, author.contains(q) { return 30 }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedArtist(_ artistName: String?) -> String? {
        guard let artistName = artistName else { return nil }
        let artist = normalize(artistName)
        return artist.isEmpty ? nil : artist
    }

    /// Display author for the Siri UI; the "Unknown" placeholder reads better omitted.
    private static func cleanAuthor(_ author: String?) -> String? {
        guard let author = author, !author.isEmpty, author.caseInsensitiveCompare("unknown") != .orderedSame else { return nil }
        return author
    }

    /// Items mid-listen: LocalMediaProgress rows map to their localLibraryItemId, so for
    /// podcasts any in-progress episode marks the whole item.
    private static func localInProgressIds() -> Set<String> {
        return Set(Database.shared.getAllLocalMediaProgress()
            .filter { $0.progress > 0 && !$0.isFinished }
            .map { $0.localLibraryItemId })
    }

    // MARK: - Episode selection

    /// Ordering copied from the web client (LazyBookCard/item page): the in-progress
    /// episode first, else the newest unfinished, else the newest outright. publishedAt only
    /// exists on episodes decoded from the server, so downloaded episodes fall through to
    /// the server-assigned feed index.
    private static func newestFirst(_ a: PodcastEpisode, _ b: PodcastEpisode) -> Bool {
        if a.publishedAt != b.publishedAt { return (a.publishedAt ?? 0) > (b.publishedAt ?? 0) }
        return (a.index ?? 0) > (b.index ?? 0)
    }

    /// Picks the episode a show-level match should play from local data only.
    private static func pickLocalEpisode(item: LocalLibraryItem) -> EpisodePick? {
        guard let episodes = item.media?.episodes, !episodes.isEmpty else { return nil }

        // 1. The episode the user is midway through, most recently played first.
        let inProgressRows = Database.shared.getAllLocalMediaProgress()
            .filter { $0.localLibraryItemId == item.id && $0.localEpisodeId != nil && $0.progress > 0 && !$0.isFinished }
            .sorted { $0.lastUpdate > $1.lastUpdate }
        for row in inProgressRows {
            guard let episodeId = row.localEpisodeId,
                  let episode = item.getPodcastEpisode(episodeId: episodeId),
                  PlaybackLauncher.isEpisodePlayable(item, episodeId: episodeId) else { continue }
            return EpisodePick(episodeId: episode.id, title: episode.title)
        }

        // 2. Newest unfinished downloaded episode; 3. newest downloaded as a last resort.
        let finishedIds = Set(Database.shared.getAllLocalMediaProgress()
            .filter { $0.localLibraryItemId == item.id && $0.isFinished }
            .compactMap { $0.localEpisodeId })
        let playable = episodes.sorted(by: newestFirst)
            .filter { PlaybackLauncher.isEpisodePlayable(item, episodeId: $0.id) }
        let pick = playable.first(where: { !finishedIds.contains($0.id) }) ?? playable.first
        return pick.map { EpisodePick(episodeId: $0.id, title: $0.title) }
    }

    /// Picks the episode a server show match should play from whatever fetches completed.
    /// Nil inputs are fetches that missed their deadline, not empty results.
    private static func pickServerEpisode(libraryItemId: String, itemsInProgress: [ItemInProgress]?, progressRows: [MediaProgress]?, expandedItem: LibraryItem?) -> EpisodePick? {
        // 1. In-progress episode; the server orders items-in-progress most recent first.
        if let entry = itemsInProgress?.first(where: { $0.id == libraryItemId }),
           let episodeId = entry.recentEpisode?.id {
            return EpisodePick(episodeId: episodeId, title: entry.displayTitle)
        }
        // The fetch missed its deadline: SiriMediaContext's hourly cache is stale but
        // still better than dropping the user's spot for the newest episode.
        if itemsInProgress == nil, let cached = SiriMediaContext.inProgressRecentEpisodes[libraryItemId] {
            return EpisodePick(episodeId: cached.episodeId, title: cached.title ?? "Unknown")
        }

        // 2. Newest unfinished; 3. newest outright (web client parity).
        guard let episodes = expandedItem?.media?.episodes, !episodes.isEmpty else { return nil }
        let finishedIds = Set((progressRows ?? [])
            .filter { $0.libraryItemId == libraryItemId && $0.isFinished }
            .compactMap { $0.episodeId })
        let ordered = episodes.sorted(by: newestFirst)
        let pick = ordered.first(where: { !finishedIds.contains($0.id) }) ?? ordered.first
        return pick.map { EpisodePick(episodeId: $0.id, title: $0.title) }
    }

    /// Maps a server episode onto its downloaded, playable local twin, if any. iOS keeps
    /// server episode ids verbatim on local copies, so the lookup is direct.
    private static func localTwinEpisode(serverItemId: String, episodeId: String) -> (localItemId: String, coverUrl: URL?)? {
        guard let twin = Database.shared.getLocalLibraryItem(byServerLibraryItemId: serverItemId),
              twin.isPodcast,
              PlaybackLauncher.isEpisodePlayable(twin, episodeId: episodeId) else { return nil }
        return (twin.id, twin.coverUrl)
    }

    /// Turns "<itemId>::" show candidates (server AND downloaded shows -- both defer)
    /// into concrete episodes. One shared deadline covers the items-in-progress,
    /// progress-rows, and per-show expanded-item fetches. Downloaded shows fall back to
    /// pickLocalEpisode when the server data never arrives (offline); server candidates
    /// whose pick is still unresolved keep the trailing separator for handle() to finish.
    private static func resolveDeferredEpisodePicks(for candidates: [Candidate], completion: @escaping ([Candidate]) -> Void) {
        let pending = candidates.enumerated().filter { $0.element.needsEpisodePick }
        guard !pending.isEmpty else {
            completion(candidates)
            return
        }

        var itemsInProgress: [ItemInProgress]?
        var progressRows: [MediaProgress]?
        var expandedById: [String: LibraryItem] = [:]

        var fired = false
        let finish = {
            guard !fired else { return }
            fired = true
            var updated = candidates
            for (index, candidate) in pending {
                let itemId = candidate.itemId
                let showTitle = candidate.title
                let serverItemId = candidate.isLocal ? candidate.serverLibraryItemId : itemId

                var pick = serverItemId.flatMap {
                    Self.pickServerEpisode(libraryItemId: $0, itemsInProgress: itemsInProgress, progressRows: progressRows, expandedItem: expandedById[$0])
                }
                // Offline/slow fallback for downloaded shows: the local ordering is
                // guaranteed to produce something (scoring required a playable pick).
                if pick == nil, candidate.isLocal,
                   let localItem = Database.shared.getLocalLibraryItem(localLibraryItemId: itemId) {
                    pick = pickLocalEpisode(item: localItem)
                }
                guard let pick = pick else {
                    AbsLogger.info(message: "Siri: episode pick unresolved for \(itemId), deferring to handle()")
                    continue
                }

                // Route to a downloaded copy of the picked episode when one exists; a
                // server-side pick of a not-downloaded episode streams even for a
                // downloaded show (the user's spot beats offline preference).
                if candidate.isLocal,
                   let localItem = Database.shared.getLocalLibraryItem(localLibraryItemId: itemId),
                   PlaybackLauncher.isEpisodePlayable(localItem, episodeId: pick.episodeId) {
                    updated[index] = Candidate(
                        id: itemId + episodeIdSeparator + pick.episodeId,
                        title: pick.title,
                        author: showTitle,
                        isLocal: true,
                        serverLibraryItemId: serverItemId,
                        localCoverUrl: candidate.localCoverUrl,
                        isPodcast: true,
                        isEpisode: true,
                        score: candidate.score
                    )
                } else if let serverItemId = serverItemId, let twin = localTwinEpisode(serverItemId: serverItemId, episodeId: pick.episodeId) {
                    updated[index] = Candidate(
                        id: twin.localItemId + episodeIdSeparator + pick.episodeId,
                        title: pick.title,
                        author: showTitle,
                        isLocal: true,
                        serverLibraryItemId: serverItemId,
                        localCoverUrl: twin.coverUrl,
                        isPodcast: true,
                        isEpisode: true,
                        score: candidate.score
                    )
                } else if let serverItemId = serverItemId {
                    updated[index] = Candidate(
                        id: serverItemId + episodeIdSeparator + pick.episodeId,
                        title: pick.title,
                        author: showTitle,
                        isLocal: false,
                        serverLibraryItemId: nil,
                        localCoverUrl: nil,
                        isPodcast: true,
                        isEpisode: true,
                        score: candidate.score
                    )
                }
            }
            // A deferred show can resolve to the same episode an episode-title match
            // already produced; Siri must never see two items with one identifier.
            var seenIds = Set<String>()
            completion(updated.filter { seenIds.insert($0.id).inserted })
        }
        let deadline = DispatchWorkItem {
            AbsLogger.info(message: "Siri: episode pick exceeded \(episodePickTimeout)s")
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + episodePickTimeout, execute: deadline)

        let group = DispatchGroup()
        group.enter()
        ApiClient.getItemsInProgress { items in
            itemsInProgress = items
            group.leave()
        }
        group.enter()
        ApiClient.getUserMediaProgress { rows in
            progressRows = rows
            group.leave()
        }
        for (_, candidate) in pending {
            guard let serverItemId = candidate.isLocal ? candidate.serverLibraryItemId : candidate.itemId else { continue }
            group.enter()
            ApiClient.getLibraryItemWithProgress(libraryItemId: serverItemId, episodeId: nil) { item in
                if let item = item {
                    expandedById[serverItemId] = item
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            deadline.cancel()
            finish()
        }
    }

    // MARK: - Continue listening

    /// "Continue playing on Audiobookshelf" with no title. Priority: the current (possibly
    /// paused) session, then the most recently played unfinished download (book or
    /// episode), then the server's items-in-progress (already ordered most-recent first).
    /// handle() unpauses a current session via the already-playing short-circuit.
    private static func resolveContinueListening(completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        DispatchQueue.main.async {
            // 1. The session already loaded in the player, even if paused.
            if let session = PlayerHandler.getPlaybackSession(),
               let itemPart = session.localLibraryItem?.id ?? session.libraryItemId {
                let isEpisode = session.episodeId != nil
                let id = isEpisode ? itemPart + episodeIdSeparator + session.episodeId! : itemPart
                AbsLogger.info(message: "Siri: continue-listening resolved current session '\(session.displayTitle ?? "?")' (\(id))")
                let item = INMediaItem(
                    identifier: id,
                    title: session.displayTitle,
                    type: isEpisode ? .podcastEpisode : .audioBook,
                    artwork: artwork(atFileURL: session.localLibraryItem?.coverUrl),
                    artist: isEpisode ? (session.mediaMetadata?.title ?? cleanAuthor(session.displayAuthor)) : cleanAuthor(session.displayAuthor)
                )
                completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
                return
            }

            // 2. Most recently played unfinished download -- instant and offline-safe.
            let recentLocal = Database.shared.getAllLocalMediaProgress()
                .filter { $0.progress > 0 && !$0.isFinished }
                .sorted { $0.lastUpdate > $1.lastUpdate }
            for progress in recentLocal {
                guard let item = Database.shared.getLocalLibraryItem(localLibraryItemId: progress.localLibraryItemId) else { continue }
                if let episodeId = progress.localEpisodeId {
                    guard item.isPodcast,
                          let episode = item.getPodcastEpisode(episodeId: episodeId),
                          PlaybackLauncher.isEpisodePlayable(item, episodeId: episodeId) else { continue }
                    AbsLogger.info(message: "Siri: continue-listening resolved local episode '\(episode.title)' (\(item.id)::\(episodeId))")
                    let mediaItem = INMediaItem(
                        identifier: item.id + episodeIdSeparator + episodeId,
                        title: episode.title,
                        type: .podcastEpisode,
                        artwork: artwork(atFileURL: item.coverUrl),
                        artist: item.media?.metadata?.title
                    )
                    completion(INPlayMediaMediaItemResolutionResult.successes(with: [mediaItem]))
                    return
                }
                guard item.isBook, PlaybackLauncher.isPlayable(item) else { continue }
                AbsLogger.info(message: "Siri: continue-listening resolved local '\(item.media?.metadata?.title ?? "?")' (\(item.id))")
                let mediaItem = INMediaItem(
                    identifier: item.id,
                    title: item.media?.metadata?.title,
                    type: .audioBook,
                    artwork: artwork(atFileURL: item.coverUrl),
                    artist: cleanAuthor(item.media?.metadata?.authorDisplayName)
                )
                completion(INPlayMediaMediaItemResolutionResult.successes(with: [mediaItem]))
                return
            }

            // 3. Server items-in-progress, under the usual Siri-owned deadline.
            var fired = false
            let fire: ([INPlayMediaMediaItemResolutionResult]) -> Void = { results in
                guard !fired else { return }
                fired = true
                completion(results)
            }
            let deadline = DispatchWorkItem {
                AbsLogger.error(message: "Siri: continue-listening server fetch exceeded \(serverSearchTimeout)s")
                fire([INPlayMediaMediaItemResolutionResult.unsupported()])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + serverSearchTimeout, execute: deadline)
            ApiClient.getItemsInProgress { items in
                deadline.cancel()
                for item in items ?? [] {
                    let mediaType = item.mediaType ?? "book"
                    if mediaType == "podcast" {
                        // Podcast entries always carry the in-progress episode; one
                        // without it cannot be routed, so fall through to the next entry.
                        guard let episodeId = item.episodeId else { continue }
                        AbsLogger.info(message: "Siri: continue-listening resolved server episode '\(item.displayTitle)' (\(item.id)::\(episodeId))")
                        let mediaItem = INMediaItem(
                            identifier: item.id + episodeIdSeparator + episodeId,
                            title: item.displayTitle,
                            type: .podcastEpisode,
                            artwork: nil,
                            artist: item.title
                        )
                        fire(INPlayMediaMediaItemResolutionResult.successes(with: [mediaItem]))
                        return
                    }
                    guard mediaType == "book" else { continue }
                    AbsLogger.info(message: "Siri: continue-listening resolved server '\(item.displayTitle)' (\(item.id))")
                    let mediaItem = INMediaItem(
                        identifier: item.id,
                        title: item.displayTitle,
                        type: .audioBook,
                        artwork: nil,
                        artist: cleanAuthor(item.authorName)
                    )
                    fire(INPlayMediaMediaItemResolutionResult.successes(with: [mediaItem]))
                    return
                }
                AbsLogger.error(message: "Siri: continue-listening found nothing in progress")
                fire([INPlayMediaMediaItemResolutionResult.unsupported()])
            }
        }
    }

    // MARK: - Resolution results

    /// successes(with:) auto-plays the FIRST item; the rest appear in the Siri UI as
    /// tap-to-switch alternatives. Artwork is fetched for the top item only.
    private static func resolutionResults(for candidates: [Candidate], query: String, completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        guard let top = candidates.first else {
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }
        AbsLogger.info(message: "Siri: query '\(query)' matched '\(top.title)' (\(top.id)), \(candidates.count) candidate(s)")

        let finish: (INImage?) -> Void = { topArtwork in
            let mediaItems = candidates.enumerated().map { index, candidate in
                INMediaItem(
                    identifier: candidate.id,
                    title: candidate.title,
                    type: candidate.mediaItemType,
                    artwork: index == 0 ? topArtwork : nil,
                    artist: candidate.author
                )
            }
            completion(INPlayMediaMediaItemResolutionResult.successes(with: mediaItems))
        }

        if top.isLocal {
            finish(Self.artwork(atFileURL: top.localCoverUrl))
            return
        }

        var fired = false
        let fire: (INImage?) -> Void = { image in
            guard !fired else { return }
            fired = true
            finish(image)
        }
        let deadline = DispatchWorkItem { fire(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + artworkGrace, execute: deadline)
        CarPlayImageLoader.shared.loadCoverArt(for: top.itemId) { image in
            deadline.cancel()
            fire(image.flatMap { Self.inImage(from: $0) })
        }
    }

    // MARK: - Artwork

    /// Local covers are files on disk (LocalLibraryItem.coverUrl); INImage(url:) only supports
    /// remote fetches reliably, so decode the file directly.
    private static func artwork(atFileURL url: URL?) -> INImage? {
        guard let url = url,
              url.isFileURL,
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return inImage(from: image)
    }

    /// Covers can be multi-MB, and INImage payloads cross XPC to the Siri UI -- downscale
    /// to thumbnail size first.
    private static func inImage(from image: UIImage) -> INImage? {
        let maxSide: CGFloat = 256
        let largestSide = max(image.size.width, image.size.height)
        guard largestSide > 0 else { return nil }
        let scale = min(1, maxSide / largestSide)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = scaled.jpegData(compressionQuality: 0.8) else { return nil }
        return INImage(imageData: data)
    }
}
