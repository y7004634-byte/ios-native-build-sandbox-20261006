import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var controller: NativePortViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let launchURL = connectionOptions.urlContexts.first?.url
            ?? connectionOptions.userActivities.first?.webpageURL
        let controller = NativePortViewController(initialURL: launchURL, testMode: false)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.controller = controller
        self.window = window
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { controller?.handleIncomingURL(url) }
    }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL { controller?.handleIncomingURL(url) }
    }
    func sceneWillEnterForeground(_ scene: UIScene) { controller?.notifyLifecycle("willForeground") }
    func sceneDidBecomeActive(_ scene: UIScene) { controller?.notifyLifecycle("foreground") }
    func sceneWillResignActive(_ scene: UIScene) { controller?.notifyLifecycle("inactive") }
    func sceneDidEnterBackground(_ scene: UIScene) { controller?.notifyLifecycle("background") }
    func sceneDidDisconnect(_ scene: UIScene) {
        controller?.prepareForSceneDisconnect()
        controller = nil
        window?.rootViewController = nil
        window = nil
    }
}
