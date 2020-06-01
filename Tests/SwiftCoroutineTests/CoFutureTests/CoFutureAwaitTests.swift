//
//  CoFutureAwaitTests.swift
//  SwiftCoroutine
//
//  Created by Alex Belozierov on 17.03.2020.
//  Copyright © 2020 Alex Belozierov. All rights reserved.
//

import XCTest
@testable import SwiftCoroutine

class CoFutureAwaitTests: XCTestCase {

    func testAwait() {
        let exp = expectation(description: "testAwait")
        let promise = CoPromise<Int>()
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) {
            promise.success(1)
        }
        DispatchQueue.main.startCoroutine {
            XCTAssertEqual(try promise.await(), 1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testConcurrency() {
        let array = UnsafeMutableBufferPointer<Int>.allocate(capacity: 100_000)
        let exp = expectation(description: "testConcurrency")
        exp.expectedFulfillmentCount = array.count
        let queue = DispatchQueue.global()
        DispatchQueue.concurrentPerform(iterations: array.count) { index in
            let promise = CoPromise<Int>()
            queue.asyncAfter(deadline: .now() + .microseconds(index)) {
                promise.success(index)
            }
            queue.asyncAfter(deadline: .now() + .microseconds(array.count - index)) {
                queue.startCoroutine {
                    array[index] = try promise.await()
                    exp.fulfill()
                }
            }
        }
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(array.enumerated().allSatisfy { $0.element == $0.offset })
        array.deallocate()
    }
    
    func testAwaitMeasure() {
        measure {
            ImmediateScheduler().startCoroutine {
                for index in 0..<100_000 {
                    let _ = try Coroutine.await { $0(index) }
                }
            }
        }
    }

    func testNestetAwaits() {
        let queue = DispatchQueue.global(qos: .userInteractive)
        let queue2 = DispatchQueue.global(qos: .utility)
        let group = DispatchGroup()
        measure {
            group.enter()
            queue.coroutineFuture {
                try (0..<100).map { i -> CoFuture<Void> in
                    let queue = i % 2 == 0 ? queue : queue2
                    return queue.coroutineFuture {
                        try (0..<1000)
                            .map { _ in CoFuture(result: .success(())) }
                            .forEach { try $0.await() }
                    }
                }.forEach { try $0.await() }
                group.leave()
            }.whenFailure { _ in
                XCTFail()
                group.leave()
            }
            group.wait()
        }
    }
    
    func testOnBlockedSerial() {
        let exp = expectation(description: "testOnBlockedSerial")
        exp.expectedFulfillmentCount = 1000
        let serial = DispatchQueue(label: "com.testOnBlockedSerial")
        serial.async { sleep(5) }
        for _ in 0..<1000 { serial.startCoroutine { } }
        for _ in 0..<1000 {
            DispatchQueue.global().startCoroutine { exp.fulfill() }
        }
        wait(for: [exp], timeout: 3)
    }
    
    func testSerial() {
        let exp = expectation(description: "testSerial")
        exp.expectedFulfillmentCount = 100_000
        let queue = DispatchQueue(label: "com.testSerial")
        var counter = 0
        for i in 0..<100_000 {
            queue.startCoroutine {
                XCTAssertEqual(i, counter)
                counter += 1
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(counter, 100_000)
    }
    
    func testTestMultiAwait() {
        let exp = expectation(description: "testTestMultiAwait")
        var count = 0
        DispatchQueue.global().startCoroutine {
            for _ in 0..<1000 {
                try Coroutine.await {
                    DispatchQueue.global().async(execute: $0)
                }
                try DispatchQueue.global().await {}
                count += 1
            }
            XCTAssertEqual(count, 1000)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
    
    func testSchedulerAwait() {
        let group = DispatchGroup()
        measure {
            group.enter()
            var sum = 0
            DispatchQueue.global().startCoroutine {
                for i in 0..<10_000 {
                    sum += try DispatchQueue.global().await { i }
                    sum += try DispatchQueue.global().await { i }
                    sum += try DispatchQueue.global().await { i }
                    sum += try DispatchQueue.global().await { i }
                    sum += try DispatchQueue.global().await { i }
                }
                XCTAssertEqual(sum, (0..<10_000).reduce(0, +) * 5)
                group.leave()
            }
            group.wait()
        }
    }
    
    func testRethrowError() {
        let exp = expectation(description: "testRethrowError")
        DispatchQueue.global().startCoroutine {
            do {
                try DispatchQueue.global().await {
                    throw CoFutureError.canceled
                }
            } catch let error as CoFutureError {
                XCTAssertEqual(error, .canceled)
            } catch {
                XCTFail()
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
    
    func testTimout() {
        let exp = expectation(description: "testTimout")
        let promise = CoPromise<Int>()
        let date = Date()
        Coroutine.start {
            do {
                _ = try promise.await(timeout: .seconds(1))
                XCTFail()
            } catch let error as CoFutureError {
                XCTAssertEqual(error, .timeout)
                XCTAssertDuration(from: date, in: 1..<2)
                exp.fulfill()
            } catch {
                XCTFail()
            }
        }
        wait(for: [exp], timeout: 3)
    }
    
    func testTimoutNegative() {
        let exp = expectation(description: "testTimoutNegative")
        let promise = CoPromise<Int>()
        Coroutine.start {
            do {
                _ = try promise.await(timeout: .microseconds(-100))
                XCTFail()
            } catch let error as CoFutureError {
                XCTAssertEqual(error, .timeout)
                exp.fulfill()
            } catch {
                XCTFail()
            }
        }
        wait(for: [exp], timeout: 1)
    }
    
    func testTimeoutFulfilled() {
        let future = CoFuture(result: .success(0))
        XCTAssertEqual(try? future.await(timeout: .microseconds(0)), 0)
    }

}
