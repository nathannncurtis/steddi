import Foundation

/// An indexed binary min-heap (priority queue) with decrease-key support, the
/// open set for A* (§4.1). Swift has no stdlib heap; this is the ~tested-pure
/// unit the spec calls for.
///
/// "Indexed" means each element carries a stable integer `id` (here, a
/// `NodeIndex` cast to `Int`) and the heap keeps an `id -> heap position` map so
/// `decreaseKey` is O(log n) instead of an O(n) scan. A* relaxes a node's
/// tentative cost repeatedly; without decrease-key the open set bloats with
/// stale duplicates. The map lets us update an existing entry's priority in place.
///
/// Generic over a `Comparable` priority so the same heap serves any cost
/// currency. Pure value semantics — no I/O, no shared state — so it unit-tests
/// like `RouteGeometry`.
struct BinaryHeap<Priority: Comparable> {

    /// One heap slot: the caller's stable id and its current priority.
    private struct Element {
        var id: Int
        var priority: Priority
    }

    /// The binary heap, level-order. `storage[0]` is the minimum.
    private var storage: [Element] = []
    /// `id -> index into storage`, kept in sync on every sift so `decreaseKey`
    /// and `contains` are O(1)/O(log n). An id absent from the map is not in the
    /// heap (never inserted, or already popped).
    private var positions: [Int: Int] = [:]

    init() {}

    /// Reserve capacity for `n` elements — A* sizes this to the node count to
    /// avoid reallocations mid-search.
    init(minimumCapacity n: Int) {
        storage.reserveCapacity(n)
        positions.reserveCapacity(n)
    }

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    /// Whether `id` currently has an entry in the heap.
    func contains(_ id: Int) -> Bool { positions[id] != nil }

    /// The priority currently associated with `id`, or nil if it isn't queued.
    func priority(of id: Int) -> Priority? {
        guard let pos = positions[id] else { return nil }
        return storage[pos].priority
    }

    /// Insert `id` with `priority`. Precondition: `id` is not already present
    /// (use `decreaseKey` / `push` for updates). O(log n).
    mutating func insert(_ id: Int, priority: Priority) {
        precondition(positions[id] == nil, "BinaryHeap.insert: id \(id) already present")
        storage.append(Element(id: id, priority: priority))
        let inserted = storage.count - 1
        positions[id] = inserted
        siftUp(from: inserted)
    }

    /// Insert `id` if absent, or lower its priority if the new value is smaller.
    /// A higher new priority is ignored (the heap is a min-heap; A* never wants
    /// to *raise* a tentative cost). Returns true if the heap changed. This is
    /// the convenience A* relaxation uses.
    @discardableResult
    mutating func push(_ id: Int, priority: Priority) -> Bool {
        if let pos = positions[id] {
            guard priority < storage[pos].priority else { return false }
            storage[pos].priority = priority
            siftUp(from: pos)
            return true
        }
        insert(id, priority: priority)
        return true
    }

    /// Lower the priority of an already-present `id`. Precondition: present and
    /// the new priority is not greater than the current one. O(log n).
    mutating func decreaseKey(_ id: Int, to priority: Priority) {
        guard let pos = positions[id] else {
            preconditionFailure("BinaryHeap.decreaseKey: id \(id) not present")
        }
        precondition(priority <= storage[pos].priority, "BinaryHeap.decreaseKey: priority increased")
        storage[pos].priority = priority
        siftUp(from: pos)
    }

    /// Peek the minimum without removing it.
    func peek() -> (id: Int, priority: Priority)? {
        guard let first = storage.first else { return nil }
        return (first.id, first.priority)
    }

    /// Remove and return the minimum (id + priority), or nil if empty. O(log n).
    mutating func popMin() -> (id: Int, priority: Priority)? {
        guard !storage.isEmpty else { return nil }
        let minElement = storage[0]
        positions[minElement.id] = nil

        let last = storage.removeLast()
        if !storage.isEmpty {
            storage[0] = last
            positions[last.id] = 0
            siftDown(from: 0)
        }
        return (minElement.id, minElement.priority)
    }

    // MARK: - Sift

    private mutating func siftUp(from index: Int) {
        var child = index
        let element = storage[child]
        while child > 0 {
            let parent = (child - 1) / 2
            guard element.priority < storage[parent].priority else { break }
            storage[child] = storage[parent]
            positions[storage[child].id] = child
            child = parent
        }
        storage[child] = element
        positions[element.id] = child
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        let element = storage[parent]
        let n = storage.count
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            var smallestPriority = element.priority

            if left < n, storage[left].priority < smallestPriority {
                smallest = left
                smallestPriority = storage[left].priority
            }
            if right < n, storage[right].priority < smallestPriority {
                smallest = right
            }
            guard smallest != parent else { break }

            storage[parent] = storage[smallest]
            positions[storage[parent].id] = parent
            parent = smallest
        }
        storage[parent] = element
        positions[element.id] = parent
    }
}
