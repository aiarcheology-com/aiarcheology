//
//  SequenceExtensionsTests.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 05.12.25.
//

import XCTest
@testable import ML_Browser

// MARK: - Sequence+Extensions Tests

final class SequenceExtensionsTests: XCTestCase {
    
    // MARK: - concurrentForEach Basic Tests
    
    func test_concurrentForEach_executesAllElements() async {
        let numbers = [1, 2, 3, 4, 5]
        let counter = Counter()
        
        await numbers.concurrentForEach { _ in
            await counter.increment()
        }
        
        let count = await counter.value
        XCTAssertEqual(count, 5)
    }
    
    func test_concurrentForEach_emptySequence_doesNothing() async {
        let empty: [Int] = []
        let counter = Counter()
        
        await empty.concurrentForEach { _ in
            await counter.increment()
        }
        
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }
    
    func test_concurrentForEach_singleElement_executesOnce() async {
        let single = [42]
        let counter = Counter()
        
        await single.concurrentForEach { _ in
            await counter.increment()
        }
        
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }
    
    // MARK: - concurrentForEach Value Processing Tests
    
    func test_concurrentForEach_processesAllValues() async {
        let values = ["a", "b", "c"]
        let results = ResultsStore<String>()
        
        await values.concurrentForEach { value in
            await results.append(value)
        }
        
        let collected = await results.values
        XCTAssertEqual(collected.sorted(), ["a", "b", "c"])
    }
    
    func test_concurrentForEach_preservesAllValues() async {
        let numbers = Array(1...100)
        let results = ResultsStore<Int>()
        
        await numbers.concurrentForEach { number in
            await results.append(number)
        }
        
        let collected = await results.values
        XCTAssertEqual(Set(collected), Set(1...100))
    }
    
    // MARK: - concurrentForEach Concurrency Tests
    
    func test_concurrentForEach_runsConcurrently() async {
        let items = [1, 2, 3]
        let concurrencyTracker = ConcurrencyTracker()
        
        await items.concurrentForEach { _ in
            await concurrencyTracker.taskStarted()
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            await concurrencyTracker.taskEnded()
        }
        
        let maxConcurrent = await concurrencyTracker.maxConcurrentTasks
        // If truly concurrent, multiple tasks should overlap
        XCTAssertGreaterThan(maxConcurrent, 1, "Tasks should run concurrently (max concurrent: \(maxConcurrent))")
    }
    
    func test_concurrentForEach_largeCollection_processesAll() async {
        let items = Array(1...1000)
        let counter = Counter()
        
        await items.concurrentForEach { _ in
            await counter.increment()
        }
        
        let count = await counter.value
        XCTAssertEqual(count, 1000, "All 1000 items should be processed")
    }
    
    // MARK: - concurrentForEach Type Tests
    
    func test_concurrentForEach_worksWithStructs() async {
        struct Item: Sendable {
            let id: Int
            let name: String
        }
        
        let items = [
            Item(id: 1, name: "One"),
            Item(id: 2, name: "Two"),
            Item(id: 3, name: "Three")
        ]
        let results = ResultsStore<String>()
        
        await items.concurrentForEach { item in
            await results.append(item.name)
        }
        
        let collected = await results.values
        XCTAssertEqual(collected.count, 3)
    }
    
    func test_concurrentForEach_worksWithOptionals() async {
        let optionals: [Int?] = [1, nil, 3, nil, 5]
        let results = ResultsStore<Int?>()
        
        await optionals.concurrentForEach { value in
            await results.append(value)
        }
        
        let collected = await results.values
        XCTAssertEqual(collected.count, 5)
    }
    
    func test_concurrentForEach_worksWithSet() async {
        let set: Set<Int> = [1, 2, 3, 4, 5]
        let counter = Counter()
        
        await set.concurrentForEach { _ in
            await counter.increment()
        }
        
        let count = await counter.value
        XCTAssertEqual(count, 5)
    }
    
    func test_concurrentForEach_worksWithDictionaryKeys() async {
        let dict = ["a": 1, "b": 2, "c": 3]
        let results = ResultsStore<String>()
        
        await dict.keys.concurrentForEach { key in
            await results.append(key)
        }
        
        let collected = await results.values
        XCTAssertEqual(Set(collected), Set(["a", "b", "c"]))
    }
    
    // MARK: - concurrentForEach Edge Cases
    
    func test_concurrentForEach_handlesLargeValues() async {
        let largeStrings = (1...10).map { String(repeating: "X", count: $0 * 1000) }
        let results = ResultsStore<Int>()
        
        await largeStrings.concurrentForEach { string in
            await results.append(string.count)
        }
        
        let collected = await results.values
        XCTAssertEqual(collected.count, 10)
    }
}

// MARK: - Helper Actors

/// Thread-safe counter for testing concurrent operations
actor Counter {
    private(set) var value = 0
    
    func increment() {
        value += 1
    }
    
    func decrement() {
        value -= 1
    }
    
    func reset() {
        value = 0
    }
}

/// Thread-safe collection for testing concurrent operations
actor ResultsStore<T> {
    private(set) var values: [T] = []
    
    func append(_ value: T) {
        values.append(value)
    }
    
    func clear() {
        values.removeAll()
    }
}

/// Tracks concurrent task execution to verify parallelism
actor ConcurrencyTracker {
    private var currentTasks = 0
    private(set) var maxConcurrentTasks = 0
    
    func taskStarted() {
        currentTasks += 1
        maxConcurrentTasks = max(maxConcurrentTasks, currentTasks)
    }
    
    func taskEnded() {
        currentTasks -= 1
    }
}
