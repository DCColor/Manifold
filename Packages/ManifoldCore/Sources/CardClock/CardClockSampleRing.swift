//
//  CardClockSampleRing.swift
//  CardClock
//
//  The card's completed frames, from its callback thread to the steering. One short lock per frame; the reader copies once a second.
//

import Foundation

public final class CardClockSampleRing: @unchecked Sendable {
    /// More than `fitWindow` plus a tick at any rate the card can run.
    private let capacity = 1024
    private let lock = NSLock()
    private var samples: [CardClockSample] = []
    private var head = 0

    public init() {}

    public func append(slot: Int64, host: Double) {
        lock.lock(); defer { lock.unlock() }
        let s = CardClockSample(slot: slot, host: host)
        if samples.count < capacity { samples.append(s) } else { samples[head] = s; head = (head + 1) % capacity }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true); head = 0
    }

    /// Oldest first.
    public func snapshot() -> [CardClockSample] {
        lock.lock(); defer { lock.unlock() }
        return Array(samples[head...] + samples[..<head])
    }
}
