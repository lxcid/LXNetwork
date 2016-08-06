import CoreFoundation
import Foundation

protocol TCPSessionDelegate : class {
    func session(session: TCPSession, didReceiveData data: Data) -> DataBuffer.OutResult
}

final class TCPSession {
    let host: String
    let port: UInt32
    let readStream: CFReadStream
    let writeStream: CFWriteStream
    let readQueue: DispatchQueue
    let writeQueue: DispatchQueue
    var readPipe: DataPipe
    var writePipe: DataPipe
    
    weak var delegate: TCPSessionDelegate?
    
    init(host: String, port: UInt32, secure: Bool) throws {
        guard !secure else {
            throw Error.NotImplemented
        }
        var unmanagedReadStream: Unmanaged<CFReadStream>?
        var unmanagedWriteStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, host, UInt32(port), &unmanagedReadStream, &unmanagedWriteStream)
        guard let readStream = unmanagedReadStream?.takeRetainedValue() else {
            throw Error.NoReadStream
        }
        guard let writeStream = unmanagedWriteStream?.takeRetainedValue() else {
            throw Error.NoWriteStream
        }
        
        self.host = host
        self.port = port
        self.readStream = readStream
        self.writeStream = writeStream
        self.readQueue = DispatchQueue(label: "com.lxcid.network.tcp.read", attributes: [ .serial ], target: nil)
        self.writeQueue = DispatchQueue(label: "com.lxcid.network.tcp.write", attributes: [ .serial ], target: nil)
        self.readPipe = DataPipe(serialQueue: self.readQueue)
        self.writePipe = DataPipe(serialQueue: self.writeQueue)
        
        let commonStreamEvents: CFStreamEventType = [
            .openCompleted,
            .errorOccurred,
            .endEncountered
        ]
        var context = CFStreamClientContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        //context.retain = { Unmanaged<TCPSession>.fromOpaque($0!).retain().toOpaque() }
        //context.release = { Unmanaged<TCPSession>.fromOpaque($0!).release() }
        guard CFReadStreamSetClient(self.readStream, commonStreamEvents.union(.hasBytesAvailable).rawValue, readCB, &context) else {
            throw Error.NoReadStream
        }
        guard CFWriteStreamSetClient(self.writeStream, commonStreamEvents.union(.canAcceptBytes).rawValue, writeCB, &context) else {
            throw Error.NoWriteStream
        }
        CFReadStreamSetProperty(self.readStream, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        CFWriteStreamSetProperty(self.writeStream, CFStreamPropertyKey(kCFStreamPropertyShouldCloseNativeSocket), kCFBooleanTrue)
        CFReadStreamSetDispatchQueue(self.readStream, self.readQueue)
        CFWriteStreamSetDispatchQueue(self.writeStream, self.writeQueue)
        self.writePipe.outHandler = { [weak self] (data: Data) -> DataBuffer.OutResult in
            return self?.writePipeOutHandler(data: data) ?? .NoOperation
        }
        self.readPipe.outHandler = { [weak self] (data: Data) -> DataBuffer.OutResult in
            guard let strongSelf = self, let delegate = strongSelf.delegate else {
                return .NoOperation
            }
            return delegate.session(session: strongSelf, didReceiveData: data)
        }
    }
    
    deinit {
        self.disconnect()
    }
    
    func connect() throws {
        guard CFReadStreamOpen(readStream) else {
            throw Error.NoReadStream
        }
        guard CFWriteStreamOpen(writeStream) else {
            throw Error.NoWriteStream
        }
        print("connect")
    }
    
    func disconnect() {
        let commonStreamEvents: CFStreamEventType = [
            .openCompleted,
            .errorOccurred,
            .endEncountered
        ]
        CFReadStreamSetClient(self.readStream, commonStreamEvents.union(.hasBytesAvailable).rawValue, nil, nil)
        CFWriteStreamSetClient(self.writeStream, commonStreamEvents.union(.canAcceptBytes).rawValue, nil, nil)
        CFReadStreamSetDispatchQueue(self.readStream, nil)
        CFWriteStreamSetDispatchQueue(self.writeStream, nil)
        CFReadStreamClose(self.readStream)
        CFWriteStreamClose(self.writeStream)
    }
    
    func asyncSend(data: Data) {
        self.writePipe.asyncIn(data: data)
    }
    
    func flush() {
        self.writePipe.flush()
    }
    
    func writePipeOutHandler(data: Data) -> DataBuffer.OutResult {
        if #available(OSX 10.12, iOS 10.0, tvOS 10.0, watchOS 3.0, *) {
            dispatchPrecondition(condition: .onQueue(writeQueue))
        }
        var totalNumberOfBytesWritten = 0
        while (CFWriteStreamCanAcceptBytes(self.writeStream) && (totalNumberOfBytesWritten < data.count)) {
            let numberOfBytesWritten = data.withUnsafeBytes {
                return CFWriteStreamWrite(self.writeStream, $0.advanced(by: totalNumberOfBytesWritten), CFIndex(data.count - totalNumberOfBytesWritten))
            }
            if numberOfBytesWritten > 0 {
                totalNumberOfBytesWritten += numberOfBytesWritten
            } else if numberOfBytesWritten < 0 {
                // TODO: (stan@trifia.com) Encountered error. We should log…
            } else {
                // noop
            }
        }
        if totalNumberOfBytesWritten > 0 {
            return .Consume(bytes: totalNumberOfBytesWritten)
        } else {
            return .NoOperation
        }
    }
}

extension TCPSession {
    enum Error : ErrorProtocol {
        case NoReadStream
        case NoWriteStream
        
        case NotImplemented
    }
}

func readCB(_ readStream: CFReadStream?, _ event: CFStreamEventType, _ optContext: UnsafeMutablePointer<Void>?) {
    guard let context = optContext else {
        return
    }
    let session = Unmanaged<TCPSession>.fromOpaque(context).takeUnretainedValue()
    if event.contains(.hasBytesAvailable) {
        var readCount = 0
        while (CFReadStreamHasBytesAvailable(session.readStream)) {
            let bufferCount = 1024
            guard var buffer = Data(count: bufferCount) else {
                return
            }
            let optData = buffer.withUnsafeMutableBytes { (bufferPtr: UnsafeMutablePointer<UInt8>) -> Data? in
                let numberOfBytesRead = CFReadStreamRead(readStream, bufferPtr, bufferCount)
                if numberOfBytesRead > 0 {
                    let range = Range(uncheckedBounds: (0, numberOfBytesRead))
                    let subdata = buffer.subdata(in: range)
                    buffer.resetBytes(in: range)
                    return subdata
                } else if numberOfBytesRead < 0 {
                    // TODO: (stan@trifia.com) Encountered error. We should log…
                    print("read error: \(numberOfBytesRead)")
                    return nil
                } else {
                    print("read zero!")
                    return nil
                }
            }
            if let data = optData {
                session.readPipe.in(data: data, flush: false)
                readCount += 1
            }
        }
        if readCount > 0 {
            session.readPipe.flush()
        }
    } else if event.contains(.openCompleted) {
        print("read: open completed")
    } else if event.contains(.errorOccurred) {
        print("read: error occurred")
    } else if event.contains(.endEncountered) {
        print("read: end encountered")
    }
}

func writeCB(_ writeStream: CFWriteStream?, _ event: CFStreamEventType, _ optContext: UnsafeMutablePointer<Void>?) {
    guard let context = optContext else {
        return
    }
    let session = Unmanaged<TCPSession>.fromOpaque(context).takeUnretainedValue()
    if event.contains(.canAcceptBytes) {
        session.flush()
    } else if event.contains(.openCompleted) {
        print("write: open completed")
    } else if event.contains(.errorOccurred) {
        print("write: error occurred")
    } else if event.contains(.endEncountered) {
        print("write: end encountered")
    }
}
