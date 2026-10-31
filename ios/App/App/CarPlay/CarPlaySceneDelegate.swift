//
//  CarPlaySceneDelegate.swift
//  App
//
//  Created for CarPlay integration.
//

import CarPlay
import Foundation
import MediaPlayer
import AVFoundation
import Network

@available(iOS 14.0, *)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    static weak var shared: CarPlaySceneDelegate?

    private(set) var interfaceController: CPInterfaceController?
    private var continueListeningProvider: CarPlayContinueListeningProvider?
    private var libraryProvider: CarPlayLibraryProvider?
    private var downloadsProvider: CarPlayDownloadsProvider?
    private var coldStartRetryCount = 0
    private let maxColdStartRetries = 10
    private var dataLoadRetryCount = 0
    private let maxDataLoadRetries = 5
    private var hasAttemptedMidSessionRestore = false  // kept for cold-start edge case

    // In-car connectivity often arrives AFTER the CarPlay scene does (LTE handoff, VPN tunnel
    // coming up). The cold-start/data-load retries are finite, so without this the server lists
    // stay empty for the rest of the drive once they exhaust. Reload when the network path
    // becomes satisfied again.
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlaySceneDelegate.shared = self
        self.interfaceController = interfaceController

        // Register observer FIRST so we never miss serverConfigDidChange notifications
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAllProviders), name: Store.serverConfigDidChange, object: nil)

        // Continue-listening ordering is server state, and it changes whenever anything is played
        // or stopped -- including from the phone. Without these the CarPlay list keeps whatever
        // order it had at connect time and silently drifts out of step with the phone app.
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAllProvidersAfterProgressSync), name: NSNotification.Name(PlayerEvents.externalSessionStarted.rawValue), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadAllProvidersAfterProgressSync), name: NSNotification.Name(PlayerEvents.closed.rawValue), object: nil)

        // Restore server config from Realm before initial reload.
        // On cold start the active config index may be nil even though configs exist.
        restoreServerConfigIfNeeded()

        let continueProvider = CarPlayContinueListeningProvider(interfaceController: interfaceController)
        let libProvider = CarPlayLibraryProvider(interfaceController: interfaceController)
        let dlProvider = CarPlayDownloadsProvider(interfaceController: interfaceController)

        self.continueListeningProvider = continueProvider
        self.libraryProvider = libProvider
        self.downloadsProvider = dlProvider

        // Configure Now Playing template with rate and chapter buttons
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false
        nowPlaying.isAlbumArtistButtonEnabled = false
        updateNowPlayingButtons()
        nowPlaying.add(self)

        let tabBar = CPTabBarTemplate(templates: [
            continueProvider.template,
            libProvider.template,
            dlProvider.template
        ])
        // Refresh whenever a tab is selected. Continue-listening ordering lives on the server and
        // only changes once progress has been reported, so reloading at the moment playback starts
        // races ahead of the data -- looking at the tab is the point the list must be current.
        tabBar.delegate = self

        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)

        continueProvider.reload()
        libProvider.reload()
        dlProvider.reload()

        // If config still not available (Realm not ready yet), schedule async retries
        if Store.serverConfig == nil {
            scheduleColdStartRetryIfNeeded()
        } else {
            scheduleDataLoadRetryIfNeeded()
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.lastPathSatisfied {
                AbsLogger.info(message: "CarPlay: network path restored, reloading lists")
                self.reloadAllProviders()
            }
            self.lastPathSatisfied = satisfied
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.pathMonitor = monitor

        AbsLogger.info(message: "CarPlay scene didConnect, serverConfig=\(Store.serverConfig != nil ? "available" : "nil")")

        // If there's active playback when CarPlay connects, show Now Playing
        if PlayerHandler.getPlaybackSession() != nil, !PlayerHandler.paused {
            AbsLogger.info(message: "CarPlay: Active playback detected on connect, showing Now Playing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pushNowPlaying()
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        NotificationCenter.default.removeObserver(self)
        pathMonitor?.cancel()
        pathMonitor = nil
        CPNowPlayingTemplate.shared.remove(self)
        // A new scene may already have connected; don't clear its registration.
        if CarPlaySceneDelegate.shared === self {
            CarPlaySceneDelegate.shared = nil
        }
        self.interfaceController = nil
        self.continueListeningProvider = nil
        self.libraryProvider = nil
        self.downloadsProvider = nil
    }

    /// Playback start only reaches the continue-listening ordering after the server has been told
    /// about it, which happens on the first progress report rather than immediately. Reload once
    /// that has had a chance to land, otherwise the refetch returns the previous order.
    @objc private func reloadAllProvidersAfterProgressSync() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.reloadAllProviders()
        }
    }

    @objc private func reloadAllProviders() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            AbsLogger.info(message: "reloadAllProviders: refetching CarPlay lists")

            // If config was cleared mid-session (e.g. by a token refresh failure)
            // but configs still exist in Realm, try to restore once to avoid
            // showing "Not Connected" when the stored token is actually valid.
            if Store.serverConfig == nil, !self.hasAttemptedMidSessionRestore {
                self.hasAttemptedMidSessionRestore = true
                self.restoreServerConfigIfNeeded()
                // restoreServerConfigIfNeeded posts serverConfigDidChange which
                // will call reloadAllProviders again — skip this invocation.
                if Store.serverConfig != nil { return }
            }

            self.continueListeningProvider?.reload()
            self.libraryProvider?.reload()
            self.downloadsProvider?.reload()
        }
    }

    /// Synchronously restore server config from Realm if the active config index
    /// was cleared (e.g. by a previous token refresh failure) but configs still exist.
    /// Called before the initial provider reload so CarPlay can connect autonomously.
    private func restoreServerConfigIfNeeded() {
        guard Store.serverConfig == nil else {
            AbsLogger.info(message: "restoreServerConfig: config already available")
            return
        }

        let configs = Database.shared.getServerConnectionConfigs()
        if configs.count == 1 {
            AbsLogger.info(message: "restoreServerConfig: restoring single available server config")
            Store.serverConfig = configs[0]
        } else if !configs.isEmpty {
            AbsLogger.info(message: "restoreServerConfig: restoring first of \(configs.count) server configs")
            Store.serverConfig = configs[0]
        } else {
            AbsLogger.info(message: "restoreServerConfig: no configs in Realm")
        }
    }

    /// On cold start, Realm may not be ready immediately.
    /// Retry until config is available or max retries reached.
    private func scheduleColdStartRetryIfNeeded() {
        guard Store.serverConfig == nil, coldStartRetryCount < maxColdStartRetries else {
            if Store.serverConfig != nil {
                AbsLogger.info(message: "Cold start: serverConfig available")
                scheduleDataLoadRetryIfNeeded()
            }
            return
        }

        coldStartRetryCount += 1
        let delay = Double(coldStartRetryCount) * 0.5  // 0.5s, 1.0s, 1.5s, ...
        AbsLogger.info(message: "Cold start: serverConfig nil, scheduling retry \(coldStartRetryCount)/\(maxColdStartRetries) in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.restoreServerConfigIfNeeded()

            if Store.serverConfig != nil {
                AbsLogger.info(message: "Cold start retry \(self.coldStartRetryCount): serverConfig now available, reloading")
                self.reloadAllProviders()
                self.scheduleDataLoadRetryIfNeeded()
            } else {
                self.scheduleColdStartRetryIfNeeded()
            }
        }
    }

    /// Retry loading data if initial API calls fail (e.g., network not ready yet).
    private func scheduleDataLoadRetryIfNeeded() {
        guard dataLoadRetryCount < maxDataLoadRetries else { return }

        dataLoadRetryCount += 1
        let delay = Double(dataLoadRetryCount) * 2.0  // 2s, 4s, 6s, 8s, 10s
        AbsLogger.info(message: "Scheduling data load retry \(dataLoadRetryCount)/\(maxDataLoadRetries) in \(delay)s")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, Store.serverConfig != nil else { return }
            AbsLogger.info(message: "Data load retry \(self.dataLoadRetryCount): reloading providers")
            self.reloadAllProviders()
        }
    }

    // MARK: - Now Playing Buttons

    private func updateNowPlayingButtons() {
        var buttons: [CPNowPlayingButton] = []

        // Rate button — opens a speed selection list
        buttons.append(CPNowPlayingPlaybackRateButton { [weak self] _ in
            self?.showSpeedSelectionList()
        })

        // Chapter button — opens chapter list
        if #available(iOS 15.4, *) {
            let chapterImage = UIImage(systemName: "list.bullet") ?? UIImage()
            buttons.append(CPNowPlayingImageButton(image: chapterImage) { [weak self] _ in
                self?.showChapterList()
            })
        } else {
            buttons.append(CPNowPlayingButton(handler: { [weak self] _ in
                self?.showChapterList()
            }))
        }

        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    // MARK: - Speed Selection

    private func showSpeedSelectionList() {
        let currentRate = PlayerSettings.main().playbackRate
        let presets: [Float] = [0.5, 1.0, 1.2, 1.5, 1.7, 2.0, 3.0]

        let presetItems: [CPListItem] = presets.map { rate in
            let label = rate.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0fx", rate)
                : String(format: "%.1fx", rate)
            let item = CPListItem(text: label, detailText: nil)
            if abs(currentRate - rate) < 0.01 {
                item.accessoryType = .cloud  // checkmark-like indicator
            }
            item.handler = { [weak self] _, completion in
                self?.applyPlaybackSpeed(rate)
                completion()
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            return item
        }

        let slowerItem = CPListItem(text: "Slower (−0.1)", detailText: String(format: "Current: %.1fx", currentRate))
        slowerItem.handler = { [weak self] _, completion in
            let newRate = max(0.1, currentRate - 0.1)
            self?.applyPlaybackSpeed(newRate)
            completion()
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }

        let fasterItem = CPListItem(text: "Faster (+0.1)", detailText: String(format: "Current: %.1fx", currentRate))
        fasterItem.handler = { [weak self] _, completion in
            let newRate = min(4.0, currentRate + 0.1)
            self?.applyPlaybackSpeed(newRate)
            completion()
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }

        let presetSection = CPListSection(items: presetItems, header: "Presets", sectionIndexTitle: nil)
        let fineSection = CPListSection(items: [slowerItem, fasterItem], header: "Fine Tune", sectionIndexTitle: nil)

        let listTemplate = CPListTemplate(title: "Playback Speed", sections: [presetSection, fineSection])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    private func applyPlaybackSpeed(_ speed: Float) {
        let settings = PlayerSettings.main()
        try? settings.update {
            settings.playbackRate = speed
        }
        PlayerHandler.setPlaybackSpeed(speed: speed)
    }

    // MARK: - Chapter List

    private func showChapterList() {
        guard let session = PlayerHandler.getPlaybackSession() else {
            AbsLogger.info(message: "showChapterList: no active session")
            return
        }

        let chapters = Array(session.chapters)
        guard !chapters.isEmpty else {
            AbsLogger.info(message: "showChapterList: no chapters available")
            return
        }

        let currentTime = session.currentTime

        let listItems: [CPListItem] = chapters.enumerated().map { index, chapter in
            let duration = chapter.end - chapter.start
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60

            let isCurrent = chapter.start <= currentTime && chapter.end > currentTime
            let title = (isCurrent ? "▶ " : "") + (chapter.title ?? "Chapter \(index + 1)")

            let detailText: String
            if isCurrent {
                // Show current position within chapter
                let elapsed = currentTime - chapter.start
                let elapsedMin = Int(elapsed) / 60
                let elapsedSec = Int(elapsed) % 60
                detailText = String(format: "%d:%02d / %d:%02d", elapsedMin, elapsedSec, minutes, seconds)
            } else {
                detailText = String(format: "%d:%02d", minutes, seconds)
            }

            let item = CPListItem(text: title, detailText: detailText)
            if isCurrent {
                item.accessoryType = .disclosureIndicator
            }

            let chapterStart = chapter.start
            item.handler = { [weak self] _, completion in
                PlayerHandler.seek(amount: chapterStart)
                completion()
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
            }
            return item
        }

        let section = CPListSection(items: listItems)
        let listTemplate = CPListTemplate(title: "Chapters", sections: [section])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }

    // MARK: - Now Playing Navigation

    func pushNowPlaying() {
        guard let interfaceController = interfaceController else {
            AbsLogger.error(message: "pushNowPlaying: no interface controller!")
            return
        }
        let nowPlaying = CPNowPlayingTemplate.shared

        // Avoid pushing if already on the Now Playing screen
        if interfaceController.topTemplate is CPNowPlayingTemplate {
            AbsLogger.info(message: "pushNowPlaying: already on Now Playing screen")
            return
        }

        let infoCenter = MPNowPlayingInfoCenter.default()
        let info = infoCenter.nowPlayingInfo
        // NOTE: type(of:) on the Optional reports the *static* type (Optional<CPTemplate>) and tells
        // us nothing. Unwrap first so this logs the template actually on screen.
        let topName = interfaceController.topTemplate.map { String(describing: type(of: $0)) } ?? "nil"
        let cmd = MPRemoteCommandCenter.shared()
        AbsLogger.info(message: "pushNowPlaying: hasInfo=\(info != nil) keyCount=\(info?.count ?? 0) playbackState=\(infoCenter.playbackState.rawValue) topTemplate=\(topName) playEnabled=\(cmd.playCommand.isEnabled) pauseEnabled=\(cmd.pauseCommand.isEnabled) skipFwdEnabled=\(cmd.skipForwardCommand.isEnabled) audioSessionOther=\(AVAudioSession.sharedInstance().isOtherAudioPlaying)")
        if let info = info {
            AbsLogger.info(message: "pushNowPlaying info: title=\(info[MPMediaItemPropertyTitle] ?? "NIL") artist=\(info[MPMediaItemPropertyArtist] ?? "NIL") rate=\(info[MPNowPlayingInfoPropertyPlaybackRate] ?? "NIL")")
        }

        interfaceController.pushTemplate(nowPlaying, animated: true) { success, error in
            if let error = error {
                AbsLogger.error(message: "pushNowPlaying FAILED: \(error)")
            } else {
                AbsLogger.info(message: "pushNowPlaying result: success=\(success)")
            }
        }
    }
}

// MARK: - CPNowPlayingTemplateObserver

@available(iOS 14.0, *)
extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}

// MARK: - CPTabBarTemplateDelegate

extension CarPlaySceneDelegate: CPTabBarTemplateDelegate {
    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        AbsLogger.info(message: "tabBarTemplate didSelect -- refreshing lists")
        reloadAllProviders()
    }
}
