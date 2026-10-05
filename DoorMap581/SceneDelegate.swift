import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var rootController: RestoredAppleMapViewController?
    private var nativePortController: NativePortViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let launchURL = connectionOptions.urlContexts.first?.url
            ?? connectionOptions.userActivities.first?.webpageURL
        let args = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let forceHybridRollback = args.contains("--hybrid-rollback")
        #else
        let forceHybridRollback = false
        #endif
        if Bundle.main.bundleIdentifier == "com.door581.appletest" && !forceHybridRollback {
            let testMode = environment["DOOR_NATIVE_S2_UI_TEST"] == "1" || environment["DOOR_NATIVE_S3_UI_TEST"] == "1"
            let controller = NativePortViewController(initialURL: launchURL, testMode: testMode)
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = controller; window.makeKeyAndVisible()
            self.nativePortController = controller; self.window = window
            return
        }
        let controller = RestoredAppleMapViewController(initialDeepLink: launchURL)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        self.rootController = controller
        self.window = window
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        rootController?.handleIncomingURL(url)
        nativePortController?.handleIncomingURL(url)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let url = userActivity.webpageURL else { return }
        rootController?.handleIncomingURL(url)
        nativePortController?.handleIncomingURL(url)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        rootController?.notifyLifecycle("willForeground")
        nativePortController?.notifyLifecycle("willForeground")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        rootController?.notifyLifecycle("foreground")
        nativePortController?.notifyLifecycle("foreground")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        rootController?.notifyLifecycle("inactive")
        nativePortController?.notifyLifecycle("inactive")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        rootController?.notifyLifecycle("background")
        nativePortController?.notifyLifecycle("background")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        rootController?.prepareForSceneDisconnect()
        nativePortController?.prepareForSceneDisconnect(); nativePortController = nil
        window?.rootViewController = nil
        rootController = nil; window = nil
    }
}
