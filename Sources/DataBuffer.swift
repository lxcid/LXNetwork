import Foundation

final class DataBuffer {
    enum OutResult {
        case NoOperation
        case Consume(bytes: Int)
    }
    
    typealias OutHandler = (data: Data) -> OutResult
    typealias CompletionHandler = () -> Void
    
    let serialQueue: DispatchQueue
    var data: Data
    
    init(serialQueue optSerialQueue: DispatchQueue? = nil) {
        self.serialQueue = optSerialQueue ?? DispatchQueue(label: "com.lxcid.network.databuffer", attributes: [ .serial ], target: nil)
        self.data = Data()
    }
    
    func asyncIn(data: Data, completionHandler: CompletionHandler? = nil) {
        self.serialQueue.async {
            self.in(data: data)
            completionHandler?()
        }
    }
    
    func asyncOut(handler: OutHandler, completionHandler: CompletionHandler? = nil) {
        self.serialQueue.async {
            self.out(handler: handler)
            completionHandler?()
        }
    }
    
    func `in`(data: Data) {
        if #available(OSX 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
            dispatchPrecondition(condition: .onQueue(self.serialQueue))
        }
        self.data.append(data)
    }
    
    func out(handler: OutHandler) {
        if #available(OSX 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
            dispatchPrecondition(condition: .onQueue(self.serialQueue))
        }
        let result = handler(data: self.data)
        switch result {
        case .NoOperation:
            break // noop
        case .Consume(bytes: let bytes):
            self.data = self.data.subdata(in: Range(uncheckedBounds: (0, bytes)))
        }
    }
}
