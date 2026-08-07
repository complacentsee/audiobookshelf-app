//
//  CarPlayDownloadsProvider.swift
//  App
//
//  Created for CarPlay integration.
//

import CarPlay
import Foundation

@available(iOS 14.0, *)
class CarPlayDownloadsProvider {
    private let interfaceController: CPInterfaceController

    lazy var template: CPListTemplate = {
        let template = CPListTemplate(title: "Downloads", sections: [])
        template.tabImage = UIImage(systemName: "arrow.down.circle")
        return template
    }()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func reload() {
        let localItems = Database.shared.getLocalLibraryItems()

        if localItems.isEmpty {
            let emptySection = CPListSection(items: [])
            template.updateSections([emptySection])
            template.emptyViewTitleVariants = ["No Downloads"]
            template.emptyViewSubtitleVariants = ["Download audiobooks from your server"]
            return
        }

        let listItems: [CPListItem] = localItems.map { item in
            let title = item.media?.metadata?.title ?? "Unknown"
            let author = item.media?.metadata?.authorDisplayName
            let listItem = CPListItem(text: title, detailText: author)
            listItem.accessoryType = .disclosureIndicator

            let localItemId = item.id
            listItem.handler = { [weak self] _, completion in
                self?.handleItemSelected(localItemId: localItemId)
                completion()
            }

            CarPlayImageLoader.shared.loadLocalCoverArt(for: item) { image in
                if let image = image {
                    listItem.setImage(image)
                }
            }

            return listItem
        }

        let section = CPListSection(items: listItems)
        template.updateSections([section])
    }

    private func handleItemSelected(localItemId: String) {
        CarPlayPlaybackManager.playLocalItem(localLibraryItemId: localItemId)
    }
}
