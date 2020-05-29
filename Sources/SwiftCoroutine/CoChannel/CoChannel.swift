//
//  CoChannel.swift
//  SwiftCoroutine
//
//  Created by Alex Belozierov on 19.04.2020.
//  Copyright © 2020 Alex Belozierov. All rights reserved.
//

/// Channel is a non-blocking primitive for communication between a sender and a receiver.
/// Conceptually, a channel is similar to a queue that allows to suspend a coroutine on receive if it is empty or on send if it is full.
///
/// - Important: Always `close()` or `cancel()` a channel when you are done to resume all suspended coroutines by the channel.
///
/// ```
/// let channel = CoChannel<Int>(maxBufferSize: 1)
///
/// DispatchQueue.global().startCoroutine {
///    for i in 0..<100 {
///        try channel.awaitSend(i)
///    }
///    channel.close()
/// }
///
/// DispatchQueue.global().startCoroutine {
///     for i in channel.makeIterator() {
///         print("Receive", i)
///     }
///     print("Done")
/// }
/// ```
///
public final class CoChannel<Element> {
    
    private typealias ReceiveCallback = (Result<Element, CoChannelError>) -> Void
    private struct SendBlock { let element: Element, resumeBlock: ((CoChannelError?) -> Void)? }
    
    /// The maximum number of elements that can be stored in a channel.
    public let maxBufferSize: Int
    private var receiveCallbacks = FifoQueue<ReceiveCallback>()
    private var sendBlocks = FifoQueue<SendBlock>()
    private var completeBlocks = CallbackStack<CoChannelError?>()
    private var atomic = AtomicTuple()
    
    /// Initializes a channel.
    /// - Parameter maxBufferSize: The maximum number of elements that can be stored in a channel.
    public init(maxBufferSize: Int = .max) {
        self.maxBufferSize = maxBufferSize
    }
    
    /// Returns tuple of `Receiver` and `Sender`.
    @inlinable public var pair: (receiver: Receiver, sender: Sender) {
        (receiver, sender)
    }
    
    // MARK: - send
    
    /// A `CoChannel` wrapper that provides send-only functionality.
    @inlinable public var sender: Sender {
        Sender(channel: self)
    }
    
    /// Sends the element to this channel, suspending the coroutine while the buffer of this channel is full. Must be called inside a coroutine.
    /// - Parameter element: Value that will be sent to the channel.
    /// - Throws: CoChannelError when canceled or closed.
    public func awaitSend(_ element: Element) throws {
        switch atomic.update ({ count, state in
            if state != 0 { return (count, state) }
            return (count + 1, 0)
        }).old {
        case (_, 1):
            throw CoChannelError.closed
        case (_, 2):
            throw CoChannelError.canceled
        case (let count, _) where count < 0:
            receiveCallbacks.blockingPop()(.success(element))
        case (let count, _) where count < maxBufferSize:
            sendBlocks.push(.init(element: element, resumeBlock: nil))
        default:
            try Coroutine.await {
                sendBlocks.push(.init(element: element, resumeBlock: $0))
            }.map { throw $0 }
        }
    }
    
    /// Adds the future's value to this channel when it will be available.
    /// - Parameter future: `CoFuture`'s value that will be sent to the channel.
    public func sendFuture(_ future: CoFuture<Element>) {
        future.whenSuccess { [weak self] in
            guard let self = self else { return }
            let (count, state) = self.atomic.update { count, state in
                if state != 0 { return (count, state) }
                return (count + 1, 0)
            }.old
            guard state == 0 else { return }
            count < 0
                ? self.receiveCallbacks.blockingPop()(.success($0))
                : self.sendBlocks.push(.init(element: $0, resumeBlock: nil))
        }
    }
    
    /// Immediately adds the value to this channel, if this doesn’t violate its capacity restrictions, and returns true. Otherwise, just returns false.
    /// - Parameter element: Value that might be sent to the channel.
    /// - Returns:`true` if sent successfully or `false` if channel buffer is full or channel is closed or canceled.
    @discardableResult public func offer(_ element: Element) -> Bool {
        let (count, state) = atomic.update { count, state in
            if state != 0 || count >= maxBufferSize { return (count, state) }
            return (count + 1, 0)
        }.old
        if state != 0 { return false }
        if count < 0 {
            receiveCallbacks.blockingPop()(.success(element))
            return true
        } else if count < maxBufferSize {
            sendBlocks.push(.init(element: element, resumeBlock: nil))
            return true
        }
        return false
    }
    
    // MARK: - receive
    
    /// A `CoChannel` wrapper that provides receive-only functionality.
    public var receiver: Receiver {
        CoChannelReceiver(channel: self)
    }
    
    /// Retrieves and removes an element from this channel if it’s not empty, or suspends a coroutine while the channel is empty.
    /// - Throws: CoChannelError when canceled or closed.
    /// - Returns: Removed value from the channel.
    public func awaitReceive() throws -> Element {
        switch atomic.update({ count, state in
            if state == 0 { return (count - 1, 0) }
            return (Swift.max(0, count - 1), state)
        }).old {
        case (let count, let state) where count > 0:
            defer { if count == 1, state == 1 { finish() } }
            return getValue()
        case (_, 0):
            return try Coroutine.await { receiveCallbacks.push($0) }.get()
        case (_, 1):
            throw CoChannelError.closed
        default:
            throw CoChannelError.canceled
        }
    }
    
    /// Creates `CoFuture` with retrieved value from this channel.
    /// - Returns: `CoFuture` with a future value from the channel.
    public func receiveFuture() -> CoFuture<Element> {
        let promise = CoPromise<Element>()
        whenReceive(promise.complete)
        return promise
    }
    
    /// Retrieves and removes an element from this channel.
    /// - Returns: Element from this channel if its not empty, or returns nill if the channel is empty or is closed or canceled.
    public func poll() -> Element? {
        let (count, state) = atomic.update { count, state in
            (Swift.max(0, count - 1), state)
        }.old
        guard count > 0 else { return nil }
        defer { if count == 1, state == 1 { finish() } }
        return getValue()
    }
    
    /// Adds an observer callback to receive an element from this channel.
    /// - Parameter callback: The callback that is called when a value is received.
    public func whenReceive(_ callback: @escaping (Result<Element, CoChannelError>) -> Void) {
        switch atomic.update({ count, state in
            if state == 0 { return (count - 1, 0) }
            return (Swift.max(0, count - 1), state)
        }).old {
        case (let count, let state) where count > 0:
            callback(.success(getValue()))
            if count == 1, state == 1 { finish() }
        case (_, 0):
            receiveCallbacks.push(callback)
        case (_, 1):
            callback(.failure(.closed))
        default:
            callback(.failure(.canceled))
        }
    }

    /// Returns a number of elements in this channel.
    public var count: Int {
        Int(Swift.max(0, atomic.value.0))
    }
    
    /// Returns `true` if the channel is empty (contains no elements), which means no elements to receive.
    public var isEmpty: Bool {
        atomic.value.0 <= 0
    }
    
    private func getValue() -> Element {
        let block = sendBlocks.blockingPop()
        block.resumeBlock?(nil)
        return block.element
    }
    
    // MARK: - map
    
    /// Returns new `Receiver` that provides transformed values from this `CoChannel`.
    /// - Parameter transform: A mapping closure.
    /// - returns: A `Receiver` with transformed values.
    public func map<T>(_ transform: @escaping (Element) -> T) -> CoChannel<T>.Receiver {
        CoChannelMap(receiver: self, transform: transform)
    }
    
    // MARK: - close
    
    /// Closes this channel. No more send should be performed on the channel.
    /// - Returns: `true` if closed successfully or `false` if channel is already closed or canceled.
    @discardableResult public func close() -> Bool {
        let (count, state) = atomic.update { count, state in
            state == 0 ? (Swift.max(0, count), 1) : (count, state)
        }.old
        guard state == 0 else { return false }
        if count < 0 {
            for _ in 0..<count.magnitude {
                receiveCallbacks.blockingPop()(.failure(.closed))
            }
        } else if count > 0 {
            sendBlocks.forEach { $0.resumeBlock?(.closed) }
        } else {
            finish()
        }
        return true
    }
    
    /// Returns `true` if the channel is closed.
    public var isClosed: Bool {
        atomic.value.1 == 1
    }
    
    // MARK: - cancel
    
    /// Closes the channel and removes all buffered sent elements from it.
    public func cancel() {
        let count = atomic.update { _ in (0, 2) }.old.0
        if count < 0 {
            for _ in 0..<count.magnitude {
                receiveCallbacks.blockingPop()(.failure(.canceled))
            }
        } else if count > 0 {
            for _ in 0..<count {
                sendBlocks.blockingPop().resumeBlock?(.canceled)
            }
        }
        finish()
    }
    
    /// Returns `true` if the channel is canceled.
    public var isCanceled: Bool {
        atomic.value.1 == 2
    }
    
    /// Adds an observer callback that is called when the `CoChannel` is canceled.
    /// - Parameter callback: The callback that is called when the `CoChannel` is canceled.
    public func whenCanceled(_ callback: @escaping () -> Void) {
        whenFinished { if $0 == .canceled { callback() } }
    }
    
    // MARK: - complete
    
    /// Adds an observer callback that is called when the `CoChannel` is completed (closed, canceled or deinited).
    /// - Parameter callback: The callback that is called when the `CoChannel` is completed.
    public func whenComplete(_ callback: @escaping () -> Void) {
        whenFinished { _ in callback() }
    }
    
    private func whenFinished(_ callback: @escaping (CoChannelError?) -> Void) {
        if !completeBlocks.append(callback) { callback(channelError) }
    }
    
    private func finish() {
        completeBlocks.close()?.finish(with: channelError)
    }
    
    private var channelError: CoChannelError? {
        switch atomic.value.1 {
        case 1: return .closed
        case 2: return .canceled
        default: return nil
        }
    }

    deinit {
        receiveCallbacks.free()
        sendBlocks.free()
        finish()
    }
    
}

extension CoChannel {
    
    // MARK: - sequence
    
    /// Make an iterator which successively retrieves and removes values from the channel.
    ///
    /// If `next()` was called inside a coroutine and there are no more elements in the channel,
    /// then the coroutine will be suspended until a new element will be added to the channel or it will be closed or canceled.
    /// - Returns: Iterator for the channel elements.
    @inlinable public func makeIterator() -> AnyIterator<Element> {
        AnyIterator { Coroutine.isInsideCoroutine ? try? self.awaitReceive() : self.poll() }
    }
    
}
