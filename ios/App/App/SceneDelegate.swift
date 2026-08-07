//
//  SceneDelegate.swift
//  App
//
//  Window scene delegate for main app UI.
//

import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        NotificationCenter.default.post(name: .capacitorOpenURL, object: [
            "url": url,
            "options": [:] as [UIApplication.OpenURLOptionsKey: Any]
        ])
    }
}
