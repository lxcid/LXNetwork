import Foundation

enum Dispatch {
    case Current
    case Sync
    case Async
}

extension Dispatch {
    func execute(on queue: DispatchQueue, flags: DispatchWorkItemFlags = [], execute work: () -> Void) {
        switch self {
        case .Current:
            work()
        case .Sync:
            queue.sync(flags: flags, execute: work)
        case .Async:
            queue.async(flags: flags, execute: work)
        }
    }
}
