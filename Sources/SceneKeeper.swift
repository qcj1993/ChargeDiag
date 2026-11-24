import Foundation

/// Refuses to tell FrontBoard that this app has gone to the background.
///
/// iOS decides whether to suspend an app from its scene's foreground flag, and
/// that flag is reported by the app itself. Every state change goes out through
/// `FBSWorkspaceScenesClient -sceneID:updateWithSettingsDiff:transitionContext:
/// completion:`, carrying a diff of what changed. Dropping the updates whose diff
/// sets foreground to No means the system never learns of the transition, so it
/// never suspends the process, so the sampling timer keeps firing.
///
/// This is the trick Immortalizer uses, just aimed at our own process instead of
/// someone else's. That difference matters: the class and method are already in
/// our address space, so nothing has to be injected and no private entitlement is
/// needed -- a plain call into the Objective-C runtime is enough.
///
/// Three things are worth being honest about.
///
/// It is undocumented. A future iOS can rename the method and this stops working;
/// every lookup is guarded, and a miss leaves `installed` false instead of crashing.
///
/// It needs a declared background mode alongside it. An app with no mode at all is
/// suspended by a different route this hook never sees, which is why the audio
/// session stays in place rather than being replaced.
///
/// And it makes the app permanently believe it is active. That is the point, but it
/// also means the app will not gracefully shed work when the screen sleeps the way a
/// well-behaved one would.
final class SceneKeeper {
    static let shared = SceneKeeper()

    private(set) var installed = false
    private(set) var blocked = 0

    private init() {}

    /// Hooks the scene update path. Safe to call more than once.
    func install() {
        guard !installed else { return }
        installed = hook()
        if !installed {
            NSLog("[ChargeDiag] scene hook unavailable; falling back to the audio session")
        }
    }

    private func hook() -> Bool {
        guard let cls = NSClassFromString("FBSWorkspaceScenesClient") else { return false }
        let selector = NSSelectorFromString(
            "sceneID:updateWithSettingsDiff:transitionContext:completion:"
        )
        guard let method = class_getInstanceMethod(cls, selector) else { return false }

        let originalIMP = method_getImplementation(method)

        typealias Signature = @convention(c) (
            AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?
        ) -> Void
        let callOriginal = unsafeBitCast(originalIMP, to: Signature.self)

        let replacement: @convention(block) (
            AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?
        ) -> Void = { receiver, command, arg1, arg2, arg3, arg4 in
            if let diff = arg2, SceneKeeper.isGoingToBackground(String(describing: diff)) {
                SceneKeeper.shared.blocked += 1
                return
            }
            callOriginal(receiver, command, arg1, arg2, arg3, arg4)
        }

        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return true
    }

    /// Matches the spellings FrontBoard has used for a cleared foreground flag.
    private static func isGoingToBackground(_ description: String) -> Bool {
        description.contains("foreground = No")
            || description.contains("foreground = BSSettingFlagNo")
            || description.contains("foreground = NotSet")
    }
}
