import Foundation

enum Dispatch {
    case current
    case sync
    case async
}

extension Dispatch {
    func execute(on queue: DispatchQueue, flags: DispatchWorkItemFlags = [], execute work: () -> Void) {
        switch self {
        case .current:
            work()
        case .sync:
            queue.sync(flags: flags, execute: work)
        case .async:
            queue.async(flags: flags, execute: work)
        }
    }
}
