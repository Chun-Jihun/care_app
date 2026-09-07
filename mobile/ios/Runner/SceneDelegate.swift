import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    private var privacyCover: UIView?
    override func sceneWillResignActive(_ scene: UIScene) {
        if privacyCover == nil, let window = window {
            let cover = UIView(frame: window.bounds)
            cover.backgroundColor = UIColor(red: 0.97, green: 0.98, blue: 0.95, alpha: 1)
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(cover)
            privacyCover = cover
        }
        super.sceneWillResignActive(scene)
    }
    override func sceneDidBecomeActive(_ scene: UIScene) {
        super.sceneDidBecomeActive(scene)
        privacyCover?.removeFromSuperview()
        privacyCover = nil
    }
}
