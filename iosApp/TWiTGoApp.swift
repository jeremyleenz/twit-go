import SwiftUI
import UIKit
import TWiTShared

@main
struct TWiTGoApp: SwiftUI.App {
    var body: some Scene {
        WindowGroup {
            SharedContentView()
                .ignoresSafeArea()
        }
    }
}

private struct SharedContentView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
