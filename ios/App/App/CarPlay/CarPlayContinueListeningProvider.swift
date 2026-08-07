//
//  CarPlayContinueListeningProvider.swift
//  App
//
//  Created for CarPlay integration.
//

import CarPlay
import Foundation

@available(iOS 14.0, *)
class CarPlayContinueListeningProvider {
    private let interfaceController: CPInterfaceController

    lazy var template: CPListTemplate = {
        let template = CPListTemplate(title: "Continue Listening", sections: [])
        template.tabImage = UIImage(systemName: "clock.arrow.circlepath")
        return template
    }()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func reload() {
        guard Store.serverConfig != nil else {
            template.updateSections([])
            template.emptyViewTitleVariants = ["Not Connected"]
            template.emptyViewSubtitleVariants = ["Open the app to sign in"]
            return
        }

        let group = DispatchGroup()
        var fetchedItems: [ItemInProgress]?  // nil means API call failed
        var fetchedProgress: [MediaProgress] = []

        group.enter()
        ApiClient.getItemsInProgress { items in
            fetchedItems = items  // empty array = success but no items; populated = success with items
            group.leave()
        }

        group.enter()
        ApiClient.getUserMediaProgress { progressList in
            fetchedProgress = progressList
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            self?.updateTemplate(with: fetchedItems, progressList: fetchedProgress)
        }
    }

    private func updateTemplate(with items: [ItemInProgress]?, progressList: [MediaProgress]) {
        guard let items = items else {
            // API call failed (nil) — don't overwrite existing items if we have them
            if template.sections.isEmpty {
                template.emptyViewTitleVariants = ["Unable to Load"]
                template.emptyViewSubtitleVariants = ["Check connection and try again"]
            }
            AbsLogger.info(message: "ContinueListening: API returned nil, keeping existing data")
            return
        }

        if items.isEmpty {
            template.updateSections([])
            template.emptyViewTitleVariants = ["Nothing in Progress"]
            template.emptyViewSubtitleVariants = ["Start listening to an audiobook"]
            return
        }

        let progressByItem = Dictionary(progressList.map { ($0.libraryItemId, $0) }, uniquingKeysWith: { first, _ in first })

        let listItems: [CPListItem] = items.map { item in
            let progress: Double
            if let episodeId = item.episodeId {
                progress = progressList.first(where: { $0.libraryItemId == item.id && $0.episodeId == episodeId })?.progress ?? item.progress
            } else {
                progress = progressByItem[item.id]?.progress ?? item.progress
            }
            let progressPercent = Int(progress * 100)
            let detail: String
            if let author = item.authorName {
                detail = "\(author) · \(progressPercent)% complete"
            } else {
                detail = "\(progressPercent)% complete"
            }

            let listItem = CPListItem(text: item.displayTitle, detailText: detail)
            listItem.accessoryType = .disclosureIndicator

            let itemId = item.id
            let episodeId = item.episodeId
            listItem.handler = { [weak self] _, completion in
                self?.handleItemSelected(libraryItemId: itemId, episodeId: episodeId)
                completion()
            }

            CarPlayImageLoader.shared.loadCoverArt(for: item.id) { image in
                if let image = image {
                    listItem.setImage(image)
                }
            }

            return listItem
        }

        let section = CPListSection(items: listItems)
        template.updateSections([section])
    }

    private func handleItemSelected(libraryItemId: String, episodeId: String?) {
        CarPlayPlaybackManager.playServerItem(libraryItemId: libraryItemId, episodeId: episodeId)
    }
}
