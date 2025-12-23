//
//  LRUCache.swift
//  AI Archeology
//
//  Generic LRU (Least Recently Used) cache implementation.
//  Used by Sentry event and breadcrumb guards for bounded signature tracking.
//

import Foundation

/// Generic LRU cache with O(1) access, insert, and eviction.
struct LRUCache<Key: Hashable, Value> {
	final class Node {
		let key: Key
		var value: Value
		var prev: Node?
		var next: Node?
		
		init(key: Key, value: Value) {
			self.key = key
			self.value = value
		}
	}
	
	var capacity: Int
	private(set) var map: [Key: Node] = [:]
	private(set) var head: Node?
	private(set) var tail: Node?
	
	init(capacity: Int) {
		self.capacity = max(1, capacity)
	}
	
	mutating func setCapacity(_ newCapacity: Int) {
		capacity = max(1, newCapacity)
		evictIfNeeded()
	}
	
	/// Access or create a value, updating LRU order.
	///
	/// If the key exists, moves it to the front and provides mutable access to its value.
	/// If the key doesn't exist, creates a new entry (evicting LRU if at capacity).
	mutating func withValue(forKey key: Key, createIfMissing: () -> Value, _ body: (inout Value) -> Void) {
		if let node = map[key] {
			touch(node)
			body(&node.value)
			return
		}
		
		let node = Node(key: key, value: createIfMissing())
		insertAtHead(node)
		map[key] = node
		evictIfNeeded()
		body(&node.value)
	}
	
	private mutating func touch(_ node: Node) {
		guard head !== node else { return }
		
		// Detach from current position
		let prev = node.prev
		let next = node.next
		prev?.next = next
		next?.prev = prev
		if tail === node { tail = prev }
		
		// Insert at head
		node.prev = nil
		node.next = head
		head?.prev = node
		head = node
		
		if tail == nil { tail = node }
	}
	
	private mutating func insertAtHead(_ node: Node) {
		node.prev = nil
		node.next = head
		head?.prev = node
		head = node
		if tail == nil { tail = node }
	}
	
	private mutating func evictIfNeeded() {
		while map.count > capacity, let tail {
			// Remove tail (LRU item)
			map[tail.key] = nil
			let prev = tail.prev
			prev?.next = nil
			self.tail = prev
			if self.tail == nil { head = nil }
		}
	}
}
