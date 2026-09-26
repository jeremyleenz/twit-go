import SwiftUI
import UIKit
import TWiTShared

@main
struct TWiTGoApp: SwiftUI.App {
    @UIApplicationDelegateAdaptor(NativeMediaAppDelegate.self) private var nativeMediaDelegate

    init() {
        IosMediaRuntime.shared.install(engine: NativeMediaEngine.shared)
    }

    var body: some Scene {
        WindowGroup {
            SharedContentView()
        }
    }
}

private struct SharedContentView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
