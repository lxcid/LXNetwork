import CoreFoundation
import Foundation

protocol TCPSessionDelegate : class {
    func session(_ session: TCPSession, didReceiveData data: Data) -> DataBuffer.OutResult
    func sessionDidOpen(_ session: TCPSession)
    func session(_ session: TCPSession, didCloseWithError error: Swift.Error?)
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
        self.readQueue = DispatchQueue(label: "com.lxcid.network.tcp.read", attributes: [], target: nil)
        self.writeQueue = DispatchQueue(label: "com.lxcid.network.tcp.write", attributes: [], target: nil)
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
            return delegate.session(strongSelf, didReceiveData: data)
        }
    }
    
    deinit {
        // NOTE: (stan@trifia.com) We do not attempt to ensure correctness of
        // the state at this stage as it would be futile. Unless in the future,
        // we want to allow other object to query the state of session outside
        // of its lifecycle, which can be useful.
        tearDownReadStream(self.readStream)
        tearDownWriteStream(self.writeStream)
    }
    
    func asyncSend(data: Data) throws {
        guard self.state.isOpened else {
            throw Error.NotOpened
        }
        self.writePipe.asyncIn(data: data)
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
    enum State : StateType {
        case initial
        case opening
        case opened
        case closing
        case closed(Swift.Error?)
        
        enum InputEvent {
            case open
            case opened
            case close(Swift.Error?)
            case closed(Swift.Error?)
        }
        
        enum OutputCommand {
            case none
            case open
            case opened
            case close(Swift.Error?)
            case closed(Swift.Error?)
        }
        
        func handleEvent(event: InputEvent) -> (State, OutputCommand)? {
            switch (self, event) {
            case (State.initial, InputEvent.open):
                return (State.opening, OutputCommand.open)
            case (State.opening, InputEvent.opened):
                return (State.opened, OutputCommand.opened)
            case (let state, InputEvent.close(let error)) where !state.willClose:
                return (State.closing, OutputCommand.close(error))
            case (State.closing, InputEvent.closed(let error)):
                return (State.closed(error), OutputCommand.closed(error))
            default:
                return nil
            }
        }
        
        static let initialState = State.initial
        
        var isOpened: Bool {
            if case State.opened = self {
                return true
            } else {
                return false
            }
        }
        
        var willClose: Bool {
            if case State.closed(_) = self {
                return true
            } else if case State.closing = self {
                return true
            } else {
                return false
            }
        }
    }
    
    func stateMachine(_ inputEvent: State.InputEvent) -> Atomic<State>.TransactionHandler {
        return { (currentValue: State) -> Operation<State> in
            guard let (newState, outputCommand) = currentValue.handleEvent(event: inputEvent) else {
                return .None
            }
            print("Changing State:", newState)
            return Operation<TCPSession.State>.Set(newState) {
                self.handleCommand(outputCommand)
            }
        }
    }
    
    func sendEvent(_ inputEvent: State.InputEvent, dispatch: Dispatch = .async) {
        self._state.transaction(dispatch: dispatch, execute: self.stateMachine(inputEvent))
    }
    
    func handleCommand(_ outputCommand: State.OutputCommand) {
        switch (outputCommand) {
        case .none:
            break // noop
        case .open:
            var isReadStreamOpened = false
            var isWriteStreamOpened = false
            let group = DispatchGroup()
            self.readQueue.async(group: group) {
                isReadStreamOpened = CFReadStreamOpen(self.readStream)
            }
            self.writeQueue.async(group: group) {
                isWriteStreamOpened = CFWriteStreamOpen(self.writeStream)
            }
            group.wait()
            if !isReadStreamOpened {
                self.sendEvent(.close(Error.NoReadStream), dispatch: .current)
            } else if !isWriteStreamOpened {
                self.sendEvent(.close(Error.NoWriteStream), dispatch: .current)
            } else {
                self.sendEvent(.opened, dispatch: .current)
            }
        case .opened:
            self.delegate?.sessionDidOpen(self)
        case .close(let error):
            let group = DispatchGroup()
            self.readQueue.async(group: group) {
                tearDownReadStream(self.readStream)
            }
            self.writeQueue.async(group: group) {
                tearDownWriteStream(self.writeStream)
            }
            group.wait()
            self.sendEvent(.closed(error), dispatch: .current)
        case .closed(let error):
            self.delegate?.session(self, didCloseWithError: error)
        }
    }
    
    func open() {
        self.sendEvent(.open, dispatch: .sync)
    }
    
    func close() {
        self.sendEvent(.close(nil), dispatch: .sync)
    }
}

extension TCPSession {
    enum Error : Swift.Error {
        case NoReadStream
        case NoWriteStream
        case NotOpened
        case Unknown
        
        case NotImplemented
    }
}

func readCB(_ optReadStream: CFReadStream?, _ event: CFStreamEventType, _ optContext: UnsafeMutablePointer<Void>?) {
    guard let readStream = optReadStream, let context = optContext else {
        return
    }
    let session = Unmanaged<TCPSession>.fromOpaque(context).takeUnretainedValue()
    if event.contains(.hasBytesAvailable) {
        var readCount = 0
        while (CFReadStreamHasBytesAvailable(readStream)) {
            let bufferCount = 1024
            var buffer = Data(count: bufferCount)
            let optData = buffer.withUnsafeMutableBytes { (bufferPtr: UnsafeMutablePointer<UInt8>) -> Data? in
                let numberOfBytesRead = CFReadStreamRead(readStream, bufferPtr, bufferCount)
                if numberOfBytesRead > 0 {
                    let range = Range(uncheckedBounds: (0, numberOfBytesRead))
                    let subdata = buffer.subdata(in: range)
                    buffer.resetBytes(in: range)
                    return subdata
                } else if numberOfBytesRead < 0 {
                    // -1 if either the stream is not open or an error occurs.
                    // We do not handle thsi case as we expect an errorOccurred
                    // callback to happen
                    return nil
                } else {
                    // 0 if the stream has reached its end
                    // We do not handle thsi case as we expect an errorOccurred
                    // callback to happen
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
        let error = CFReadStreamCopyError(readStream) as Swift.Error? ?? TCPSession.Error.Unknown
        session.sendEvent(.close(error))
    } else if event.contains(.endEncountered) {
        session.sendEvent(.close(nil))
    }
}

func writeCB(_ optWriteStream: CFWriteStream?, _ event: CFStreamEventType, _ optContext: UnsafeMutablePointer<Void>?) {
    guard let writeStream = optWriteStream, let context = optContext else {
        return
    }
    let session = Unmanaged<TCPSession>.fromOpaque(context).takeUnretainedValue()
    if event.contains(.canAcceptBytes) {
        session.writePipe.flush()
    } else if event.contains(.openCompleted) {
        // noop
    } else if event.contains(.errorOccurred) {
        let error = CFWriteStreamCopyError(writeStream) as Swift.Error? ?? TCPSession.Error.Unknown
        session.sendEvent(.close(error))
    }
    // TODO: (stan@trifia.com) I believe write stream does not inform us whether the TCP connection is closed.
    // So end encountered condition is not implemented here. Have to read the docs to confirm…
}

func tearDownReadStream(_ readStream: CFReadStream) {
    CFReadStreamSetClient(readStream, 0, nil, nil)
    CFReadStreamSetDispatchQueue(readStream, nil)
    CFReadStreamClose(readStream)
}

func tearDownWriteStream(_ writeStream: CFWriteStream) {
    CFWriteStreamSetClient(writeStream, 0, nil, nil)
    CFWriteStreamSetDispatchQueue(writeStream, nil)
    CFWriteStreamClose(writeStream)
}
