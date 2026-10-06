import Foundation

/// Scoped WeChat accessibility exposure. The original value is restored when the
/// session ends (including permission failures and cancellation). No text is read.
final class RecordingAccessibilityLease {
    private let adapter:EnhancedAXAdapter
    private var changed=false
    private init(_ adapter:EnhancedAXAdapter){self.adapter=adapter}
    static func begin(_ adapter:EnhancedAXAdapter)->RecordingAccessibilityLease? {
        let lease=RecordingAccessibilityLease(adapter)
        do {
            guard try adapter.validate(requireFront:true) == .same else{return nil}
            let original=try adapter.read()
            guard original.rc == 0,let value=original.value else{return nil}
            if value {return lease}
            let capability=try adapter.capability()
            guard capability.rc == 0,capability.writable else{return nil}
            lease.changed=true // Restore even if the setter partially changes then fails.
            guard try adapter.set(true) == 0,try adapter.validate(requireFront:true) == .same,
                  try adapter.read().value == true else{lease.restore();return nil}
            return lease
        } catch {lease.restore();return nil}
    }
    @discardableResult func restore()->Bool {
        guard changed else{return true};changed=false
        do {
            guard try adapter.validate(requireFront:false) == .same else{return false}
            let status=try adapter.set(false),read=try adapter.read()
            let verified=status == 0 && read.rc == 0 && read.value == false
            Log.write("recording-accessibility restoreVerified=\(verified) no-text-write=true")
            return verified
        } catch {Log.write("recording-accessibility restoreVerified=false no-text-write=true");return false}
    }
}
