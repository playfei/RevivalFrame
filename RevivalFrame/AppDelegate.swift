//
//  AppDelegate.swift
//  RevivalFrame
//
//  Created by joe on 7/14/26.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NSLog("RevivalFrame startup: didFinishLaunching")
        application.isIdleTimerDisabled = true

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = .black
#if IPHONE_APP
        let storyboardName = "iPhoneMain"
#else
        let storyboardName = "Main"
#endif
        let storyboard = UIStoryboard(name: storyboardName, bundle: nil)
        guard let rootViewController = storyboard.instantiateInitialViewController() else {
            fatalError("Unable to load initial view controller from \(storyboardName).storyboard")
        }
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        self.window = window
        NSLog("RevivalFrame startup: %@ root view controller installed", storyboardName)

        return true
    }
}
