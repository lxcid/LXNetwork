import Foundation

/// DataPipe wraps a DataBuffer, turning in operations into out (flush) events.
final class DataPipe {
    let dataBuffer: DataBuffer
    var outHandler: DataBuffer.OutHandler?
    
    var serialQueue: DispatchQueue {
        return self.dataBuffer.serialQueue
    }
    
    init(serialQueue optSerialQueue: DispatchQueue? = nil) {
        let serialQueue = optSerialQueue ?? DispatchQueue(label: "com.lxcid.network.datapipe", attributes: [ .serial ], target: nil)
        let dataBuffer = DataBuffer(serialQueue: serialQueue)
        self.dataBuffer = dataBuffer
    }
    
    func asyncIn(data: Data) {
        self.dataBuffer.asyncIn(data: data) {
            self.flush()
        }
    }
    
    func `in`(data: Data, flush: Bool = true) {
        self.dataBuffer.in(data: data)
        if flush {
            self.flush()
        }
    }
    
    func flush() {
        guard let outHandler = self.outHandler else {
            return
        }
        self.dataBuffer.out(handler: outHandler)
    }
    
    func asyncFlush() {
        self.serialQueue.async {
            self.flush()
        }
    }
    
    /// NOTE: (stan@trifia.com) Dispatch source was considered for coalescing out events,
    /// but because it only promise that at least an out event is enqueued but not ensuring
    /// all in operations are flush when the last out event is executed. This behavior
    /// might be surprising for developer.
    
    /// NOTE: (stan@trifia.com) We choose callback over delegate because delegate is
    /// inconvience when create more than one instance of DataPipe. Callback prevents the
    /// need for workaround in such situations.
}
