import Testing
import Foundation
@testable import Steddi

/// Pure-unit coverage for the indexed binary min-heap that backs the A* open set
/// (§4.1). Verifies the heap property under random ops, decrease-key correctness,
/// and the `push` upsert convenience the search relaxation relies on.
@Suite("BinaryHeap")
struct BinaryHeapTests {

    @Test("empty heap pops nil and reports empty")
    func emptyHeap() {
        var heap = BinaryHeap<Double>()
        #expect(heap.isEmpty)
        #expect(heap.count == 0)
        #expect(heap.popMin() == nil)
        #expect(heap.peek() == nil)
        #expect(!heap.contains(0))
    }

    @Test("single insert then pop returns the element")
    func singleElement() {
        var heap = BinaryHeap<Double>()
        heap.insert(7, priority: 3.5)
        #expect(!heap.isEmpty)
        #expect(heap.count == 1)
        #expect(heap.contains(7))
        #expect(heap.priority(of: 7) == 3.5)
        let popped = heap.popMin()
        #expect(popped?.id == 7)
        #expect(popped?.priority == 3.5)
        #expect(heap.isEmpty)
        #expect(!heap.contains(7))
    }

    @Test("pops in ascending priority order")
    func ascendingOrder() {
        var heap = BinaryHeap<Double>()
        let inputs: [(Int, Double)] = [(0, 5), (1, 1), (2, 9), (3, 3), (4, 2), (5, 8), (6, 0), (7, 4)]
        for (id, p) in inputs { heap.insert(id, priority: p) }

        var popped: [Double] = []
        while let m = heap.popMin() { popped.append(m.priority) }
        #expect(popped == popped.sorted())
        #expect(popped == [0, 1, 2, 3, 4, 5, 8, 9])
    }

    @Test("decreaseKey reorders the heap")
    func decreaseKeyReorders() {
        var heap = BinaryHeap<Double>()
        heap.insert(0, priority: 10)
        heap.insert(1, priority: 20)
        heap.insert(2, priority: 30)
        // Pull id 2 to the front.
        heap.decreaseKey(2, to: 1)
        #expect(heap.peek()?.id == 2)
        #expect(heap.popMin()?.id == 2)
        #expect(heap.popMin()?.id == 0)
        #expect(heap.popMin()?.id == 1)
    }

    @Test("push inserts when absent and lowers when present")
    func pushUpsert() {
        var heap = BinaryHeap<Double>()
        #expect(heap.push(5, priority: 100))   // inserts
        #expect(heap.contains(5))
        #expect(heap.priority(of: 5) == 100)

        #expect(heap.push(5, priority: 40))    // lowers
        #expect(heap.priority(of: 5) == 40)

        #expect(!heap.push(5, priority: 80))   // higher: ignored
        #expect(heap.priority(of: 5) == 40)
        #expect(heap.count == 1)
    }

    @Test("differential against a sorted reference under random ops")
    func differentialAgainstSortedReference() {
        var rng = SeededGenerator(seed: 0xC0FFEE)
        var heap = BinaryHeap<Int>()
        // Track the live minimum-priority per id with a dictionary reference.
        var reference: [Int: Int] = [:]

        for _ in 0..<2_000 {
            let id = Int.random(in: 0..<200, using: &rng)
            let priority = Int.random(in: 0..<1000, using: &rng)
            if let existing = reference[id] {
                // push only lowers; mirror that in the reference.
                if priority < existing {
                    heap.push(id, priority: priority)
                    reference[id] = priority
                } else {
                    heap.push(id, priority: priority)   // ignored by heap
                }
            } else {
                heap.push(id, priority: priority)
                reference[id] = priority
            }
        }

        // Drain the heap; it must yield every live id in non-decreasing priority,
        // with the same priority the reference recorded.
        var lastPriority = Int.min
        var drainedCount = 0
        while let m = heap.popMin() {
            #expect(m.priority >= lastPriority)
            lastPriority = m.priority
            #expect(reference[m.id] == m.priority)
            drainedCount += 1
        }
        #expect(drainedCount == reference.count)
    }

    @Test("contains and priority track membership across pops")
    func membershipTracking() {
        var heap = BinaryHeap<Double>()
        for i in 0..<10 { heap.insert(i, priority: Double(10 - i)) }
        for i in 0..<10 { #expect(heap.contains(i)) }

        _ = heap.popMin()   // removes id 9 (priority 1)
        #expect(!heap.contains(9))
        #expect(heap.priority(of: 9) == nil)
        #expect(heap.contains(0))
    }
}

/// A tiny deterministic PRNG so the differential test is reproducible across runs
/// and machines (no dependence on the system RNG).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        // splitmix64
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
