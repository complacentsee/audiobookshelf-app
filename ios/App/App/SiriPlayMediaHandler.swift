//
//  SiriPlayMediaHandler.swift
//  App
//
//  Handles "Hey Siri, play <title> on Audiobookshelf" (INPlayMediaIntent), in-app via
//  application(_:handlerFor:) -- no Intents extension target. Phase 1: downloaded books only.
//
//  Every Siri callback must complete well inside Siri's ~10 second budget; everything here is
//  local Realm + filesystem work, so that is comfortably met.
//

import Foundation
import Intents
import UIKit

@available(iOS 14.0, *)
class SiriPlayMediaHandler: NSObject, INPlayMediaIntentHandling {

    /// INMediaItem identifiers are LocalLibraryItem ids verbatim. Those are intrinsically
    /// "local_<UUID>" (see LocalLibraryItem.id), while server library item ids are bare UUIDs,
    /// so the prefix doubles as the local-vs-server routing discriminator for phase 2.
    private static let localIdPrefix = "local_"

    // MARK: - INPlayMediaIntentHandling

    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        // mediaName can arrive nil or mangled -- Siri strips words it thinks are structural
        // ("playlist", "album") and sometimes drops the phrase entirely.
        guard let query = intent.mediaSearch?.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            AbsLogger.error(message: "Siri: no usable mediaName (mediaSearch=\(String(describing: intent.mediaSearch)))")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        // Intents callbacks arrive on a background queue; keep Realm access on main like
        // the rest of the app.
        DispatchQueue.main.async {
            let candidates = Database.shared.getLocalLibraryItems().filter { $0.isBook }

            // Validate files on disk only for actual contenders, best first, so a hollowed-out
            // download never wins but the whole library isn't stat'ed on every query.
            let ranked = Self.rankedMatches(for: query, in: candidates)
            guard let match = ranked.first(where: { PlaybackLauncher.isPlayable($0) }) else {
                AbsLogger.error(message: "Siri: no playable local match for '\(query)' among \(candidates.count) books")
                completion([INPlayMediaMediaItemResolutionResult.unsupported()])
                return
            }

            let title = match.media?.metadata?.title ?? "Unknown"
            AbsLogger.info(message: "Siri: query '\(query)' matched '\(title)' (\(match.id))")

            let mediaItem = INMediaItem(
                identifier: match.id,
                title: title,
                type: .audioBook,
                artwork: Self.artwork(for: match),
                artist: match.media?.metadata?.authorDisplayName
            )
            completion([INPlayMediaMediaItemResolutionResult.success(with: mediaItem)])
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard let localLibraryItemId = intent.mediaItems?.first?.identifier,
              localLibraryItemId.hasPrefix(Self.localIdPrefix) else {
            AbsLogger.error(message: "Siri: handle() with unexpected identifier: \(intent.mediaItems?.first?.identifier ?? "nil")")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        AbsLogger.info(message: "Siri: starting playback for \(localLibraryItemId)")

        DispatchQueue.main.async {
            let started = PlaybackLauncher.playLocalItem(localLibraryItemId: localLibraryItemId)
            completion(INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil))
        }
    }

    // MARK: - Matching

    /// Lowercase, diacritic-insensitive fuzzy match over title + author, mirroring the Android
    /// app's search semantics (MediaManager.getFromSearch: lowercase substring, local-first).
    /// Returns matches best-first so the caller can walk down until one passes disk validation.
    static func rankedMatches(for query: String, in items: [LocalLibraryItem]) -> [LocalLibraryItem] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }

        // Siri often leaves the artist clause inside mediaName ("project hail mary by andy
        // weir"); retry the part before the last " by " as a title-only query, penalized so a
        // real title containing " by " still wins outright.
        var queries: [(q: String, penalty: Int)] = [(q, 0)]
        if let byRange = q.range(of: " by ", options: .backwards) {
            let titleOnly = String(q[..<byRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !titleOnly.isEmpty {
                queries.append((titleOnly, 5))
            }
        }

        var scored: [(score: Int, item: LocalLibraryItem)] = []
        for item in items {
            guard let rawTitle = item.media?.metadata?.title else { continue }
            let title = normalize(rawTitle)
            let rawAuthor = normalize(item.media?.metadata?.authorDisplayName ?? "")
            // "Unknown" is the model's placeholder for missing metadata, not searchable text;
            // without this, queries like "know" fuzzy-match every metadata-less book.
            let author = rawAuthor == "unknown" ? "" : rawAuthor

            var best: Int?
            for (candidate, penalty) in queries {
                if let s = Self.score(query: candidate, title: title, author: author) {
                    best = max(best ?? Int.min, s - penalty)
                }
            }
            if let best = best {
                scored.append((best, item))
            }
        }

        // Realm enumeration order is unspecified; a stable title/id tie-break keeps ambiguous
        // queries picking the same book every time.
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let t0 = $0.item.media?.metadata?.title ?? ""
            let t1 = $1.item.media?.metadata?.title ?? ""
            if t0 != t1 { return t0 < t1 }
            return $0.item.id < $1.item.id
        }.map { $0.item }
    }

    private static func score(query q: String, title: String, author: String) -> Int? {
        // Placeholder titles only match exactly, never fuzzily (see rankedMatches).
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

    // MARK: - Artwork

    /// Local covers are files on disk (LocalLibraryItem.coverUrl); INImage(url:) only supports
    /// remote fetches reliably, so decode the file directly. Embedded covers can be multi-MB,
    /// and INImage payloads cross XPC to the Siri UI -- downscale to thumbnail size first.
    private static func artwork(for item: LocalLibraryItem) -> INImage? {
        guard let url = item.coverUrl,
              url.isFileURL,
              let image = UIImage(contentsOfFile: url.path) else { return nil }

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
