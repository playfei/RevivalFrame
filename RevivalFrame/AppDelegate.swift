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
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window
        NSLog("RevivalFrame startup: root ViewController installed")

        return true
    }
}
