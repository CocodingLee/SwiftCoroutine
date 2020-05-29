//
//  CoScopeTests.swift
//  SwiftCoroutine
//
//  Created by Alex Belozierov on 10.05.2020.
//  Copyright © 2020 Alex Belozierov. All rights reserved.
//

import XCTest
@testable import SwiftCoroutine

class CoScopeTests: XCTestCase {
    
    private class TestCancellable: CoCancellable {
        
        private var callback: (() -> Void)?
        private(set) var isCanceled = false
        private let lock = NSLock()
        
        func whenComplete(_ callback: @escaping () -> Void) {
            lock.lock()
            self.callback = callback
            lock.unlock()
        }
        
        func cancel() {
            lock.lock()
            callback?()
            callback = nil
            isCanceled = true
            lock.unlock()
        }
        
        deinit {
            cancel()
        }
        
    }

    func testCancellable() {
       measure {
           let scope = CoScope()
           DispatchQueue.concurrentPerform(iterations: 100_000) { _ in
               scope.add(TestCancellable())
           }
           scope.cancel()
           DispatchQueue.concurrentPerform(iterations: 100_000) { _ in
               scope.add(TestCancellable())
            }
        }
    }
    
    func testConcurrency() {
        let scope = CoScope()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50), execute: scope.cancel)
        DispatchQueue.concurrentPerform(iterations: 100_000) { index in
            let item = TestCancellable().added(to: scope)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(index % 100), execute: item.cancel)
        }
    }
    
    func testConcurrency2() {
        let exp = expectation(description: "testConcurrency2")
        exp.expectedFulfillmentCount = 1000
        let list = UnsafeMutableBufferPointer<CoFuture<Int>>.allocate(capacity: 100_000)
        _ = list.initialize(from: (0..<100_000).map { _ in CoPromise<Int>() })
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            let scope = CoScope()
            scope.whenComplete { exp.fulfill() }
            for i in 0..<100 {
                let future = list[i * 1000 + index].added(to: scope)
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(i), execute: future.cancel)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(index % 100), execute: scope.cancel)
        }
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(list.allSatisfy { $0.isCanceled })
        list.baseAddress?.deinitialize(count: 100_000).deallocate()
    }
    
    func testCancel() {
        let exp = expectation(description: "testCancel")
        exp.expectedFulfillmentCount = 2
        let scope = CoScope()
        let cancellable = TestCancellable()
        XCTAssertTrue(scope.isEmpty)
        scope.add(cancellable)
        XCTAssertFalse(scope.isEmpty)
        XCTAssertFalse(cancellable.isCanceled)
        cancellable.cancel()
        XCTAssertTrue(scope.isEmpty)
        scope.whenComplete { exp.fulfill() }
        scope.cancel()
        scope.whenComplete { exp.fulfill() }
        scope.cancel()
        XCTAssertTrue(cancellable.isCanceled)
        XCTAssertTrue(scope.isEmpty)
        wait(for: [exp], timeout: 1)
    }
    
    func testDeinit() {
        var scope: CoScope! = CoScope()
        let cancellable = TestCancellable()
        scope.add(cancellable)
        XCTAssertFalse(cancellable.isCanceled)
        scope = nil
        XCTAssertTrue(cancellable.isCanceled)
        XCTAssertNil(scope)
    }
    
    func testDeinit2() {
        var futures = [CoFuture<Int>]()
        let parent = CoScope()
        for _ in 0..<1000 {
            let scope = CoScope().added(to: parent)
            for _ in 0..<1000 {
                let future = CoPromise<Int>()
                futures.append(future)
                scope.add(future)
            }
            XCTAssertFalse(parent.isEmpty)
        }
        XCTAssertTrue(parent.isEmpty)
        XCTAssertTrue(futures.allSatisfy { $0.isCanceled })
    }

}
