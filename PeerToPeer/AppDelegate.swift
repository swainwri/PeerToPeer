//
//  AppDelegate.swift
//  PeerToPeer
//
//  Created by Steve Wainwright on 06/04/2025.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        setupSandbox()
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }

    private func setupSandbox() {
        
        let dirPaths: [String] = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        // Get the documents directory
        var docsDirURL = URL(fileURLWithPath:dirPaths[0])
        
        docsDirURL = URL(fileURLWithPath:dirPaths[0]).appendingPathComponent("Exports")
        if !FileManager.default.changeCurrentDirectoryPath(docsDirURL.absoluteString) {
            // Directory does not exist – take appropriate action
            do {
                try FileManager.default.createDirectory(at: docsDirURL, withIntermediateDirectories: true, attributes: nil)
            }
            catch let error as NSError {
                print("Can't create the Documents/Exports folder\n\(error.localizedFailureReason ?? "unknown")")
                exit(-1)
                // Failed to create directory
            }
            if let path = Bundle.main.resourceURL?.path {
                docsDirURL = URL(fileURLWithPath:dirPaths[0]).appendingPathComponent("Exports")
                let files = ["Combo Chart.csv", "Combo Chart.xlsx", "image.png"]
                var url: URL, saved_url: URL
                
                for filename: String in files {
                    url = URL(fileURLWithPath: path).appendingPathComponent(filename)
                    saved_url = docsDirURL.appendingPathComponent(filename)
                    do {
                        try FileManager.default.copyItem(at: url, to: saved_url)
                    }
                    catch let error as NSError {
                        print("Can't copy resource to the Documents/Export folder\n\(error.localizedFailureReason ?? "unknown")")
                    }
                }
            }
        }
        
        docsDirURL = URL(fileURLWithPath:dirPaths[0]).appendingPathComponent("Imports")
        if !FileManager.default.changeCurrentDirectoryPath(docsDirURL.absoluteString) {
            // Directory does not exist – take appropriate action
            do {
                try FileManager.default.createDirectory(at: docsDirURL, withIntermediateDirectories: true, attributes: nil)
            }
            catch let error as NSError {
                print("Can't create the Documents/Imports folder\n\(error.localizedFailureReason ?? "unknown")")
                exit(-1)
                // Failed to create directory
            }
        }
        
        if let path = Bundle.main.resourceURL?.path {
            docsDirURL = URL(fileURLWithPath:dirPaths[0]).appendingPathComponent("Logos")
            if !FileManager.default.changeCurrentDirectoryPath(docsDirURL.absoluteString) {
                // Directory does not exist – take appropriate action
                do {
                    try FileManager.default.createDirectory(at: docsDirURL, withIntermediateDirectories: true, attributes: nil)
                }
                catch let error as NSError {
                    print("Can't create the Documents/Logos folder\n\(error.localizedFailureReason ?? "unknown")")
                    exit(-1)
                    // Failed to create directory
                }
                
                var url: URL, saved_url: URL
                let files: [String] = ["whichtoolface.jpg"]
                for filename: String in files {
                    url = URL(fileURLWithPath: path).appendingPathComponent(filename)
                    saved_url = docsDirURL.appendingPathComponent(filename)
                    do {
                        try FileManager.default.copyItem(at: url, to: saved_url)
                    }
                    catch let error as NSError {
                        print("Can't copy resource to the Documents/Logos folder\n\(error.localizedFailureReason ?? "unknown")")
                    }
                }
            }
        }
    }
}

