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
    let _state: Atomic<State>
    var state: State {
        get { return self._state.value }
    }
    
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
        self._state = Atomic(value: State.initialState)
        
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
        self._closeReadWriteStreams()
    }
    
    func asyncSend(data: Data) throws {
        guard self.state.isReady else {
            throw Error.NotOpened
        }
        self.writePipe.asyncIn(data: data)
    }
    
    func flush() throws {
        guard self.state.isReady else {
            throw Error.NotOpened
        }
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
    
    func _openReadWriteStreams() throws {
        guard CFReadStreamOpen(readStream) else {
            throw Error.NoReadStream
        }
        guard CFWriteStreamOpen(writeStream) else {
            throw Error.NoWriteStream
        }
    }
    
    func _closeReadWriteStreams() {
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
}

extension TCPSession {
    enum State : StateType {
        case Initial
        case Opening
        case Opened
        case Closing
        case Closed
        
        enum InputEvent {
            case Open
            case Opened
            case Close(ErrorProtocol?)
            case Closed
        }
        
        enum OutputCommand {
            case None
            case Open
            case Close
        }
        
        func handleEvent(event: InputEvent) -> (State, OutputCommand)? {
            switch (self, event) {
            case (.Initial, .Open):
                return (.Opening, .Open)
            case (.Opening, .Opened):
                return (.Opened, .None)
            case (let state, .Close(_)) where state != .Closed:
                return (.Closing, .Close)
            case (.Closing, .Closed):
                return (.Closed, .None)
            default:
                return nil
            }
        }
        
        static let initialState = State.Initial
        
        var isReady: Bool {
            return self == .Opened
        }
    }
    
    func stateMachine(_ inputEvent: State.InputEvent) -> Atomic<State>.TransactionHandler {
        return { (currentValue: State) -> Operation<State> in
            guard let (newState, outputCommand) = currentValue.handleEvent(event: inputEvent) else {
                return .None
            }
            return Operation<TCPSession.State>.Set(newState) {
                self.handleCommand(outputCommand)
            }
        }
    }
    
    func sendEvent(_ inputEvent: State.InputEvent, dispatch: Dispatch = .Async) {
        self._state.transaction(dispatch: dispatch, execute: self.stateMachine(inputEvent))
    }
    
    func handleCommand(_ outputCommand: State.OutputCommand) {
        switch (outputCommand) {
        case .None:
            break // noop
        case .Open:
            do {
                try self._openReadWriteStreams()
                self.sendEvent(.Opened, dispatch: .Current)
            } catch {
                self.sendEvent(.Close(error), dispatch: .Current)
            }
        case .Close:
            self._closeReadWriteStreams()
            self.sendEvent(.Close(nil), dispatch: .Current)
        }
    }
    
    func open() {
        self.sendEvent(.Open, dispatch: .Sync)
    }
}

extension TCPSession {
    enum Error : ErrorProtocol {
        case NoReadStream
        case NoWriteStream
        case NotOpened
        
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
        // noop
    } else if event.contains(.errorOccurred) {
        print("read: error occurred")
    } else if event.contains(.endEncountered) {
        session.sendEvent(.Close(nil))
    }
}

func writeCB(_ writeStream: CFWriteStream?, _ event: CFStreamEventType, _ optContext: UnsafeMutablePointer<Void>?) {
    guard let context = optContext else {
        return
    }
    let session = Unmanaged<TCPSession>.fromOpaque(context).takeUnretainedValue()
    if event.contains(.canAcceptBytes) {
        do { try session.flush() } catch {}
    } else if event.contains(.openCompleted) {
        // noop
    } else if event.contains(.errorOccurred) {
        print("write: error occurred")
    }
    // TODO: (stan@trifia.com) I believe write stream does not inform us whether the TCP connection is closed.
    // So end encountered condition is not implemented here. Have to read the docs to confirm…
}
