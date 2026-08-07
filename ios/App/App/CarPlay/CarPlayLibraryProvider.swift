//
//  CarPlayLibraryProvider.swift
//  App
//
//  Created for CarPlay integration.
//

import CarPlay
import Foundation

@available(iOS 14.0, *)
class CarPlayLibraryProvider {
    private let interfaceController: CPInterfaceController

    lazy var template: CPListTemplate = {
        let template = CPListTemplate(title: "Library", sections: [])
        template.tabImage = UIImage(systemName: "books.vertical")
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

        ApiClient.getLibraries { [weak self] libraries in
            DispatchQueue.main.async {
                self?.updateTemplate(with: libraries)
            }
        }
    }

    private func updateTemplate(with libraries: [CarPlayLibrary]) {
        if libraries.isEmpty {
            template.updateSections([])
            template.emptyViewTitleVariants = ["No Libraries"]
            return
        }

        let listItems: [CPListItem] = libraries.map { library in
            let listItem = CPListItem(text: library.name, detailText: library.mediaType)
            listItem.accessoryType = .disclosureIndicator

            let libraryId = library.id
            let libraryName = library.name
            listItem.handler = { [weak self] _, completion in
                self?.showLibraryItems(libraryId: libraryId, libraryName: libraryName)
                completion()
            }

            return listItem
        }

        let section = CPListSection(items: listItems)
        template.updateSections([section])
    }

    private func showLibraryItems(libraryId: String, libraryName: String) {
        let itemsTemplate = CPListTemplate(title: libraryName, sections: [])
        itemsTemplate.emptyViewTitleVariants = ["Loading…"]

        interfaceController.pushTemplate(itemsTemplate, animated: true, completion: nil)

        ApiClient.getLibraryItems(libraryId: libraryId, limit: 100, page: 0) { [weak self] response in
            DispatchQueue.main.async {
                self?.updateItemsTemplate(itemsTemplate, with: response?.results ?? [])
            }
        }
    }

    private func updateItemsTemplate(_ template: CPListTemplate, with items: [LibraryItemResult]) {
        if items.isEmpty {
            template.updateSections([])
            template.emptyViewTitleVariants = ["No Items"]
            return
        }

        let listItems: [CPListItem] = items.map { item in
            let listItem = CPListItem(text: item.title ?? "Unknown", detailText: item.authorName)
            listItem.accessoryType = .disclosureIndicator

            let itemId = item.id
            listItem.handler = { _, completion in
                CarPlayPlaybackManager.playServerItem(libraryItemId: itemId)
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
}
