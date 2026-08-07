//
//  CarPlayImageLoader.swift
//  App
//
//  Created for CarPlay integration.
//

import Foundation
import UIKit

@available(iOS 14.0, *)
class CarPlayImageLoader {
    static let shared = CarPlayImageLoader()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 100
    }

    func loadCoverArt(for libraryItemId: String, completion: @escaping (UIImage?) -> Void) {
        let cacheKey = libraryItemId as NSString
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        guard let url = coverURL(for: libraryItemId) else {
            completion(nil)
            return
        }

        ApiClient.getData(from: url) { [weak self] image in
            if let image = image {
                self?.cache.setObject(image, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func loadLocalCoverArt(for localItem: LocalLibraryItem, completion: @escaping (UIImage?) -> Void) {
        let cacheKey = localItem.id as NSString
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        guard let url = localItem.coverUrl else {
            completion(nil)
            return
        }

        ApiClient.getData(from: url) { [weak self] image in
            if let image = image {
                self?.cache.setObject(image, forKey: cacheKey)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func coverURL(for libraryItemId: String) -> URL? {
        guard let config = Store.serverConfig else { return nil }

        let urlString: String
        if Store.isServerVersionGreaterThanOrEqualTo("2.17.0") {
            urlString = "\(config.address)/api/items/\(libraryItemId)/cover"
        } else {
            urlString = "\(config.address)/api/items/\(libraryItemId)/cover?token=\(config.token)"
        }

        return URL(string: urlString)
    }
}
