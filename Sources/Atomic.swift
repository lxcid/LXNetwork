import Foundation

/// Atomic provides linearized get and set operations on value (denoted as T),
/// thus guaranteed isolation from concurrent access. This is achieved through
/// The use of concurrent queue which implements a multiple get, single set behavior.
///
/// Atomic is defined as class for the following reasons:
/// - Allowing properties of type Atomic be specified as constant,
///    preventing modification to the underlying constant.
/// - Async mutation of self is not possible in struct.
final class Atomic<T> {
    var _value: T
    let queue: DispatchQueue
    
    var value: T {
        get {
            if #available(OSX 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
                dispatchPrecondition(condition: .notOnQueue(self.queue))
            }
            return self.queue.sync { self._value }
        }
        set {
            self.queue.async(flags: [ .barrier ]) {
                self._value = newValue
            }
        }
    }
    
    init(value: T, queue optQueue: DispatchQueue? = nil) {
        self._value = value
        self.queue = optQueue ?? DispatchQueue(label: "com.lxcid.network.atomic", attributes: [ .concurrent ], target: nil)
    }
    
    /// `transaction` execute a transaction that may result in an operation.
    ///
    /// Sometimes you execute a get operation, and may followed by
    /// a set operation if condition are met.
    func transaction(transaction: (currentValue: T) -> Operation<T>) {
        self.queue.async(flags: [ .barrier ]) {
            let operation = transaction(currentValue: self._value)
            switch (operation) {
            case .None:
                break // noop
            case .Set(let newValue, let completionHandler):
                self._value = newValue
                completionHandler?()
            }
        }
    }
}

enum Operation<T> {
    case None
    /// (newValue, completionHandler)
    case Set(T, (@noescape () -> Void)?)
}
