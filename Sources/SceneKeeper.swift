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
/// It is the riskiest thing in this app, so it is built to fail safely and to say
/// why it failed:
///
/// The replacement is a `@convention(c)` function rather than a block. A block
/// handed to `imp_implementationWithBlock` has to survive being called from a
/// thread Swift knows nothing about, and when that goes wrong the failure is a
/// crash on launch rather than a hook that quietly does nothing.
///
/// The method's type encoding is checked before it is replaced, because a signature
/// that does not return void with four object arguments would pass the wrong
/// arguments and corrupt the call.
///
/// A launch that dies with the hook installed is remembered, so a crash can happen
/// at most once rather than on every start.
///
/// And a failed lookup is retried for a few seconds. FrontBoard is not necessarily
/// loaded by the time the app finishes launching, so the first attempt can miss a
/// class that is there a moment later.
final class SceneKeeper {
    static let shared = SceneKeeper()

    private let pendingKey = "sceneHookPending"
    private let failedKey = "sceneHookFailed"
    private let maxAttempts = 5

    private(set) var installed = false
    /// Why installation failed, phrased for the UI. Nil once it succeeds.
    private(set) var failureReason: String?

    private var attempts = 0

    var blocked: Int { sceneKeeperHits.current }

    private init() {}

    func install() {
        guard !installed else { return }
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: failedKey) {
            failureReason = "上次启动崩溃，已永久禁用"
            return
        }
        if defaults.bool(forKey: pendingKey) {
            // The previous launch set the mark and never reached the point of
            // clearing it, which only happens if it died with the hook installed.
            defaults.set(true, forKey: failedKey)
            defaults.removeObject(forKey: pendingKey)
            failureReason = "上次启动崩溃，已永久禁用"
            return
        }

        attempt()
    }

    private func attempt() {
        attempts += 1

        guard let reason = hook() else {
            installed = true
            failureReason = nil
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: pendingKey)
            defaults.synchronize()
            // Survived long enough to trust it. A crash before this fires leaves the
            // mark behind and the hook is dropped on the next launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                UserDefaults.standard.removeObject(forKey: self.pendingKey)
            }
            return
        }

        if attempts < maxAttempts {
            // Reported as-is until the last attempt, so a transient miss during
            // launch does not look like a permanent failure.
            failureReason = "\(reason)（第 \(attempts) 次尝试）"
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempts) * 2) {
                guard !self.installed else { return }
                self.attempt()
            }
        } else {
            failureReason = "\(reason)（重试 \(attempts) 次均失败）"
        }
    }

    /// Returns the reason it could not hook, or nil on success.
    private func hook() -> String? {
        guard let cls = NSClassFromString("FBSWorkspaceScenesClient") else {
            return "类不存在"
        }
        let selector = NSSelectorFromString(
            "sceneID:updateWithSettingsDiff:transitionContext:completion:"
        )
        guard let method = class_getInstanceMethod(cls, selector) else {
            return "方法不存在"
        }
        guard let typeEncoding = method_getTypeEncoding(method) else {
            return "无类型编码"
        }

        // Real encoding on iOS 17: Vv48@0:8@16@24@32@?40 -- void return, self, _cmd,
        // then three objects and a completion block.
        //
        // Only the argument shape is checked. The return type is spelled V by this
        // runtime (oneway void) where the docs use v, so requiring a lowercase prefix
        // rejected a method that was exactly what it was looking for. What actually
        // matters is that there are four object arguments after self and _cmd; a
        // different count means the arguments below would land in the wrong place.
        let encoding = String(cString: typeEncoding)
        let objects = encoding.filter { $0 == "@" }.count
        guard objects >= 5 else {
            return "参数不符 \(encoding)"
        }

        sceneKeeperOriginal = method_getImplementation(method)
        typealias Replacement = @convention(c) (
            AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?
        ) -> Void
        let replacement = unsafeBitCast(sceneKeeperReplacement as Replacement, to: IMP.self)
        method_setImplementation(method, replacement)
        return nil
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
