import SwiftUI
import UIKit

@main
struct TWiTGoApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(MediaProbeAppDelegate.self) private var mediaProbeDelegate

    init() { _ = DownloadProbeManager.shared }

    var body: some Scene {
        WindowGroup {
            MediaProbeView()
        }
    }
}
