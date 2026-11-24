import Foundation

/// The original implementation, kept at file scope so the replacement can call
/// through without capturing anything.
private var sceneKeeperOriginal: IMP?

/// A plain counter, because the replacement runs on whatever thread FrontBoard
/// chose and `+=` on a stored Int is not atomic.
private final class SceneKeeperCounter {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private let sceneKeeperHits = SceneKeeperCounter()

/// Refuses to tell FrontBoard that this app has gone to the background.
///
/// iOS decides whether to suspend an app from its scene's foreground flag, and that
/// flag is reported by the app itself. Every change goes out through
/// `FBSWorkspaceScenesClient -sceneID:updateWithSettingsDiff:transitionContext:
/// completion:`, carrying a diff of what changed. Dropping the updates whose diff
/// clears the flag means the system never learns of the transition, so it never
/// suspends the process, so the sampling timer keeps firing with the screen off.
///
/// This is the trick Immortalizer uses, aimed at our own process instead of someone
/// else's. That difference matters: the class is already in our address space, so
/// nothing has to be injected and no private entitlement is needed.
///
/// It is also the riskiest thing in this app, so it is built to fail safely:
///
/// The replacement is a `@convention(c)` function rather than a block. A block
/// passed to `imp_implementationWithBlock` has to survive being called from a
/// thread Swift knows nothing about, and when that goes wrong the failure is a
/// crash on launch rather than a hook that does nothing.
///
/// The method's type encoding is checked before it is replaced. A signature that
/// does not return void with four object arguments is not the method this expects,
/// and hooking it anyway would pass the wrong arguments.
///
/// And a launch that dies with the hook installed is remembered. The first launch
/// marks the hook pending, the mark is cleared a few seconds later once the app has
/// survived, and a launch that finds the mark still set knows the hook was what
/// killed it -- so it never installs it again.
final class SceneKeeper {
    static let shared = SceneKeeper()

    private let pendingKey = "sceneHookPending"
    private let failedKey = "sceneHookFailed"

    private(set) var installed = false

    var blocked: Int { sceneKeeperHits.current }

    private init() {}

    /// Hooks the scene update path, unless an earlier launch proved that fatal.
    func install() {
        guard !installed else { return }
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: failedKey) {
            NSLog("[ChargeDiag] scene hook disabled: an earlier launch crashed with it")
            return
        }
        if defaults.bool(forKey: pendingKey) {
            // Last launch set the mark and never got to clear it.
            defaults.set(true, forKey: failedKey)
            defaults.removeObject(forKey: pendingKey)
            NSLog("[ChargeDiag] previous launch died with the scene hook; disabling it")
            return
        }

        guard hook() else { return }
        installed = true

        defaults.set(true, forKey: pendingKey)
        defaults.synchronize()

        // Survived long enough to trust it. Anything that crashes before this fires
        // leaves the mark in place and the hook gets dropped next launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            UserDefaults.standard.removeObject(forKey: self.pendingKey)
        }
    }

    private func hook() -> Bool {
        guard let cls = NSClassFromString("FBSWorkspaceScenesClient") else { return false }
        let selector = NSSelectorFromString(
            "sceneID:updateWithSettingsDiff:transitionContext:completion:"
        )
        guard let method = class_getInstanceMethod(cls, selector) else { return false }

        // v32@0:8@16@24@32@40 -- void return, self, _cmd, then four objects. Anything
        // else means the method changed shape and the arguments below would be wrong.
        let encoding = String(cString: method_getTypeEncoding(method))
        let objects = encoding.filter { $0 == "@" }.count
        guard encoding.hasPrefix("v"), objects >= 5 else {
            NSLog("[ChargeDiag] unexpected scene method encoding: \(encoding)")
            return false
        }

        sceneKeeperOriginal = method_getImplementation(method)
        typealias Replacement = @convention(c) (
            AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?
        ) -> Void
        let replacement = unsafeBitCast(sceneKeeperReplacement as Replacement, to: IMP.self)
        method_setImplementation(method, replacement)
        return true
    }
}

/// Must stay a top-level function: a closure that captures anything cannot be
/// converted to a C function pointer, and the conversion is what makes the calling
/// convention match what the runtime expects.
private func sceneKeeperReplacement(
    _ receiver: AnyObject,
    _ command: Selector,
    _ first: AnyObject?,
    _ second: AnyObject?,
    _ third: AnyObject?,
    _ fourth: AnyObject?
) {
    if let diff = second as? NSObject, isGoingToBackground(diff.description) {
        sceneKeeperHits.bump()
        return
    }
    guard let original = sceneKeeperOriginal else { return }
    typealias Original = @convention(c) (
        AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?
    ) -> Void
    unsafeBitCast(original, to: Original.self)(receiver, command, first, second, third, fourth)
}

/// Matches the spellings FrontBoard has used for a cleared foreground flag.
private func isGoingToBackground(_ description: String) -> Bool {
    description.contains("foreground = No")
        || description.contains("foreground = BSSettingFlagNo")
        || description.contains("foreground = NotSet")
}
