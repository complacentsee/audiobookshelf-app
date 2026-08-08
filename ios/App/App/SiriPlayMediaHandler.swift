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

    /// Server search budget inside resolveMediaItems. Timing out degrades to local-only.
    private static let serverSearchTimeout: TimeInterval = 4.0
    /// Cosmetic cover fetch for a server-only top match; never worth more than this.
    private static let artworkGrace: TimeInterval = 1.0
    /// How long handle() waits for a server stream to start before answering .inProgress.
    private static let serverHandleDeadline: TimeInterval = 8.0
    /// A book the user is partway through outranks a same-score cold book.
    private static let inProgressBoost = 15
    /// artistName arriving in its own intent slot confirming the candidate's author.
    private static let artistMatchBoost = 10
    /// The server matched this item on something the local scorer cannot see (series,
    /// narrator, subtitle); keep it as a low-ranked alternative rather than dropping it.
    private static let serverMatchFloorScore = 20
    /// Siri auto-plays the first item; the rest render as tap-to-switch alternatives.
    private static let maxResults = 3

    /// One scored candidate from either source. Everything is a plain value copied out of
    /// the Realm object at scoring time: candidates live across async gaps (server search,
    /// artwork fetch) and a live LocalLibraryItem can be invalidated by a concurrent
    /// delete before it is read again.
    private struct Candidate {
        let id: String
        let title: String
        let author: String?
        let isLocal: Bool
        /// The server-side id of a downloaded copy (LocalLibraryItem.libraryItemId).
        let serverLibraryItemId: String?
        let localCoverUrl: URL?
        var score: Int
    }

    // MARK: - INPlayMediaIntentHandling

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // mediaName can arrive nil or mangled -- Siri strips words it thinks are structural
        // ("playlist", "album") and sometimes drops the phrase entirely. A no-title request
        // ("continue playing / resume my book / play Audiobookshelf") is a resume: pick up
        // the most recently played book instead of failing.
        guard let query = intent.mediaSearch?.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            AbsLogger.info(message: "Siri: no mediaName (resumePlayback=\(String(describing: intent.resumePlayback))), resolving continue-listening")
            Self.resolveContinueListening(completion: completion)
            return
        }
        let artistName = intent.mediaSearch?.artistName

        // Intents callbacks arrive on a background queue; keep Realm access on main like
        // the rest of the app. Every continuation below also lands on main (Alamofire,
        // group.notify, deadlines), so this whole resolve is single-queue and race-free.
        DispatchQueue.main.async {
            let localCandidates = Self.scoredLocalCandidates(query: query, artistName: artistName)

            // The server matches each field by substring, so the " by "-split title-only
            // variant must be sent as its own query or "<title> by <author>" phrases would
            // miss every non-downloaded book.
            let serverQueries = Self.searchQueries(for: query).map { $0.q }
            ApiClient.searchAllLibraries(queries: serverQueries, timeout: Self.serverSearchTimeout) { serverResults in
                let merged = Self.mergeAndRank(local: localCandidates, server: serverResults, query: query, artistName: artistName)
                guard !merged.isEmpty else {
                    AbsLogger.error(message: "Siri: no match for '\(query)' (\(localCandidates.count) local, \(serverResults.count) server results)")
                    completion([INPlayMediaMediaItemResolutionResult.unsupported()])
                    return
                }
                Self.resolutionResults(for: Array(merged.prefix(Self.maxResults)), query: query, completion: completion)
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
            if itemId.hasPrefix(Self.localIdPrefix) {
                let started = PlaybackLauncher.playLocalItem(localLibraryItemId: itemId)
                completion(INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil))
                return
            }

            // Server ids can reach handle() for books that are also downloaded (donations
            // and Listen Now suggestions predate a download; resolve remaps, but only for
            // its own results). A playable local copy always wins over streaming.
            if let localTwin = Database.shared.getLocalLibraryItem(byServerLibraryItemId: itemId),
               PlaybackLauncher.isPlayable(localTwin) {
                AbsLogger.info(message: "Siri: server id \(itemId) has playable local copy \(localTwin.id), playing locally")
                let started = PlaybackLauncher.playLocalItem(localLibraryItemId: localTwin.id)
                completion(INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil))
                return
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

    private static func scoredLocalCandidates(query: String, artistName: String?) -> [Candidate] {
        let queries = searchQueries(for: query)
        guard !queries.isEmpty else { return [] }
        let artist = normalizedArtist(artistName)
        let inProgressIds = localInProgressIds()

        var candidates: [Candidate] = []
        for item in Database.shared.getLocalLibraryItems() where item.isBook {
            guard let rawTitle = item.media?.metadata?.title,
                  var score = Self.score(queries: queries, artist: artist, rawTitle: rawTitle,
                                         rawAuthor: item.media?.metadata?.authorDisplayName) else { continue }
            // Validate files on disk for scored contenders only, so a hollowed-out download
            // never wins but the whole library isn't stat'ed on every query.
            guard PlaybackLauncher.isPlayable(item) else { continue }
            if inProgressIds.contains(item.id) {
                score += inProgressBoost
            }
            candidates.append(Candidate(
                id: item.id,
                title: rawTitle,
                author: cleanAuthor(item.media?.metadata?.authorDisplayName),
                isLocal: true,
                serverLibraryItemId: item.libraryItemId,
                localCoverUrl: item.coverUrl,
                score: score
            ))
        }
        return candidates
    }

    private static func mergeAndRank(local: [Candidate], server: [LibraryItemResult], query: String, artistName: String?) -> [Candidate] {
        let queries = searchQueries(for: query)
        let artist = normalizedArtist(artistName)
        // A playable downloaded copy beats its own server twin (instant + works offline).
        // An unplayable local copy was never scored, so its server twin survives here.
        let downloadedServerIds = Set(local.compactMap { $0.serverLibraryItemId })
        let serverInProgressIds = SiriMediaContext.inProgressLibraryItemIds
        let localInProgressIds = Self.localInProgressIds()

        var merged = local
        for result in server {
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
                merged.append(Candidate(
                    id: localTwin.id,
                    title: localTwin.media?.metadata?.title ?? result.title ?? "Unknown",
                    author: cleanAuthor(localTwin.media?.metadata?.authorDisplayName ?? result.authorName),
                    isLocal: true,
                    serverLibraryItemId: result.id,
                    localCoverUrl: localTwin.coverUrl,
                    score: score
                ))
                continue
            }

            if serverInProgressIds.contains(result.id) {
                score += inProgressBoost
            }
            merged.append(Candidate(
                id: result.id,
                title: result.title ?? "Unknown",
                author: cleanAuthor(result.authorName),
                isLocal: false,
                serverLibraryItemId: nil,
                localCoverUrl: nil,
                score: score
            ))
        }

        // Deterministic order: score, then local before server (instant + offline), then a
        // stable title/id tie-break so ambiguous queries pick the same book every time.
        return merged.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.isLocal != $1.isLocal { return $0.isLocal }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
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

    /// Books mid-listen: for books LocalMediaProgress.id == localLibraryItemId.
    private static func localInProgressIds() -> Set<String> {
        return Set(Database.shared.getAllLocalMediaProgress()
            .filter { $0.progress > 0 && !$0.isFinished }
            .map { $0.localLibraryItemId })
    }

    // MARK: - Continue listening

    /// "Continue playing on Audiobookshelf" with no title. Priority: the current (possibly
    /// paused) session, then the most recently played unfinished downloaded book, then the
    /// server's items-in-progress (already ordered most-recent first). Books only until
    /// phase 3. handle() unpauses a current session via the already-playing short-circuit.
    private static func resolveContinueListening(completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        DispatchQueue.main.async {
            // 1. The session already loaded in the player, even if paused.
            if let session = PlayerHandler.getPlaybackSession(), session.episodeId == nil,
               let id = session.localLibraryItem?.id ?? session.libraryItemId {
                AbsLogger.info(message: "Siri: continue-listening resolved current session '\(session.displayTitle ?? "?")' (\(id))")
                let item = INMediaItem(
                    identifier: id,
                    title: session.displayTitle,
                    type: .audioBook,
                    artwork: artwork(atFileURL: session.localLibraryItem?.coverUrl),
                    artist: cleanAuthor(session.displayAuthor)
                )
                completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
                return
            }

            // 2. Most recently played unfinished downloaded book -- instant and offline-safe.
            let recentLocal = Database.shared.getAllLocalMediaProgress()
                .filter { $0.progress > 0 && !$0.isFinished && $0.localEpisodeId == nil }
                .sorted { $0.lastUpdate > $1.lastUpdate }
            for progress in recentLocal {
                guard let item = Database.shared.getLocalLibraryItem(localLibraryItemId: progress.localLibraryItemId),
                      item.isBook, PlaybackLauncher.isPlayable(item) else { continue }
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
                guard let first = (items ?? []).first(where: { ($0.mediaType ?? "book") == "book" }) else {
                    AbsLogger.error(message: "Siri: continue-listening found nothing in progress")
                    fire([INPlayMediaMediaItemResolutionResult.unsupported()])
                    return
                }
                AbsLogger.info(message: "Siri: continue-listening resolved server '\(first.displayTitle)' (\(first.id))")
                let mediaItem = INMediaItem(
                    identifier: first.id,
                    title: first.displayTitle,
                    type: .audioBook,
                    artwork: nil,
                    artist: cleanAuthor(first.authorName)
                )
                fire(INPlayMediaMediaItemResolutionResult.successes(with: [mediaItem]))
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
                    type: .audioBook,
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
        CarPlayImageLoader.shared.loadCoverArt(for: top.id) { image in
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
