import UIKit
import Capacitor
import RealmSwift
import AVFoundation
import MediaPlayer
import Intents

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    lazy var window: UIWindow? = UIWindow(frame: UIScreen.main.bounds)
    var backgroundCompletionHandler: (() -> Void)?
    private let logger = AppLogger(category: "AppDelegate")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.

        let configuration = Realm.Configuration(
            schemaVersion: 21,
            migrationBlock: { [weak self] migration, oldSchemaVersion in
                if (oldSchemaVersion < 1) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["enableAltView"] = false
                    }
                }
                if (oldSchemaVersion < 4) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Reindexing server configs")
                    var indexCounter = 1
                    migration.enumerateObjects(ofType: ServerConnectionConfig.className()) { oldObject, newObject in
                        newObject?["index"] = indexCounter
                        indexCounter += 1
                    }
                }
                if (oldSchemaVersion < 5) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding lockOrientation setting")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["lockOrientation"] = "NONE"
                    }
                }
                if (oldSchemaVersion < 6) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding hapticFeedback setting")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["hapticFeedback"] = "LIGHT"
                    }
                }
                if (oldSchemaVersion < 15) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding languageCode setting")
                    migration.enumerateObjects(ofType: DeviceSettings.className()) { oldObject, newObject in
                        newObject?["languageCode"] = "en-us"
                    }
                }
                if (oldSchemaVersion < 16) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding chapterTrack setting")
                    migration.enumerateObjects(ofType: PlayerSettings.className()) { oldObject, newObject in
                        newObject?["chapterTrack"] = false
                    }
                }
                if (oldSchemaVersion < 17) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding downloadUsingCellular and streamingUsingCellular settings")
                    migration.enumerateObjects(ofType: PlayerSettings.className()) { oldObject, newObject in
                        newObject?["downloadUsingCellular"] = "ALWAYS"
                        newObject?["streamingUsingCellular"] = "ALWAYS"
                    }
                }
                if (oldSchemaVersion < 18) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding disableSleepTimerFadeOut settings")
                    migration.enumerateObjects(ofType: PlayerSettings.className()) { oldObject, newObject in
                        newObject?["disableSleepTimerFadeOut"] = false
                    }
                }
                if (oldSchemaVersion < 20) {
                    AbsLogger.info(message: "Realm schema version was \(oldSchemaVersion)... Adding version to ServerConnectionConfigs")
                    migration.enumerateObjects(ofType: ServerConnectionConfig.className()) { oldObject, newObject in
                        newObject?["version"] = ""
                    }
                }
                if (oldSchemaVersion < 21) {
                    // One-time wipe of accumulated logs that were freezing the app on load/clear
                    migration.deleteData(forType: LogEntry.className())
                }
            }
        )
        Realm.Configuration.defaultConfiguration = configuration

        // Establish the audio session up front so the system registers this as an audio
        // app. CarPlay only offers a Now Playing origin to apps with an active session,
        // so this has to happen at launch rather than when playback first starts.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            logger.error("Failed to set AVAudioSession category/activate: \(error)")
        }

        // CarPlay requires remote control events to be active before CPNowPlayingTemplate
        // is pushed, so claim them for the app's lifetime rather than per playback session.
        UIApplication.shared.beginReceivingRemoteControlEvents()

        // Siri media intents are handled in-app (application(_:handlerFor:)); ask for
        // authorization up front so "play <title> on Audiobookshelf" works on first try.
        if #available(iOS 14.0, *) {
            INPreferences.requestSiriAuthorization { [weak self] status in
                // AppLogger, not AbsLogger: this completion can fire on a background queue
                // before the webview/Database are warmed up.
                self?.logger.log("Siri authorization status: \(status.rawValue)")
            }
            // Deferred past launch: the first refresh opens Realm (Store.serverConfig) and
            // fans out network fetches -- none of that belongs inside didFinishLaunching.
            DispatchQueue.main.async {
                SiriMediaContext.initialize()
            }
        }

        return true
    }

    // MARK: - Siri

    /// In-app SiriKit media intent handling (iOS 14+, no extension target).
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if #available(iOS 14.0, *), intent is INPlayMediaIntent {
            return SiriPlayMediaHandler()
        }
        return nil
    }

    // MARK: - Scene Configuration

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let config = UISceneConfiguration(name: "CarPlay Configuration", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }

        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        config.storyboard = UIStoryboard(name: "Main", bundle: nil)
        return config
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
        AbsLogger.info(message: "Audiobookself is now in the background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
        AbsLogger.info(message: "Audiobookself is now in the foreground")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        AbsLogger.info(message: "Audiobookself is now active")
        if #available(iOS 14.0, *) {
            SiriMediaContext.refreshIfStale()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
        AbsLogger.info(message: "Audiobookself is terminating")
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Stores the completion handler for background downloads
        // The identifier of this method can be ignored at this time as we only have one background url session
        backgroundCompletionHandler = completionHandler
    }


}

