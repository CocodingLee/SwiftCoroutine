//
//  DispatchQueue+Coroutine.swift
//  SwiftCoroutine iOS
//
//  Created by Alex Belozierov on 01.12.2019.
//  Copyright © 2019 Alex Belozierov. All rights reserved.
//

import Foundation

extension DispatchQueue {

    open func coroutine(group: DispatchGroup? = nil, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute work: @escaping () throws -> Void) {
        Coroutine.new(block: work) {
            self.async(group: group, qos: qos, flags: flags, execute: $0)
        }.start()
    }
    
    open func coroutine<T>(group: DispatchGroup? = nil, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute work: @escaping () throws -> T) -> CoFuture<T> {
        let item = CoPromise<T>()
        coroutine(group: group, qos: qos, flags: flags) { item.perform(work) }
        return item
    }
    
    open func switchTo(group: DispatchGroup? = nil, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = []) {
        guard let coroutine = Thread.current.currentCoroutine
            else { fatalError() }
        coroutine.suspendAndResume { self.async(group: group, qos: qos, flags: flags, execute: $0) }
    }

}

@inline(__always)
public func coroutine(on queue: DispatchQueue = .__current, execute work: @escaping () throws -> Void) {
    queue.coroutine(execute: work)
}

@inline(__always)
public func coroutine<T>(on queue: DispatchQueue = .__current, execute work: @escaping () throws -> T) -> CoFuture<T> {
    queue.coroutine(execute: work)
}
