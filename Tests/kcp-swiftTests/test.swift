//
//  KCPSendTests.swift
//  KCPTests
//
//  Run with: `swift test` (Swift 5.9+)
//

import Testing
@testable import kcp_swift

@Suite(.serialized)
struct kcp_core_tests {
	var kcp:ikcp_cb
    var capturedPackets: [[UInt8]] = []   // what the output handler sees
}

@Suite(.serialized)
struct kcp_send_tests {

    // -----------------------------------------------------------------
    // MARK: – Helper – a fresh, minimally‑configured KCP instance
    // -----------------------------------------------------------------
    var kcp: ikcp_cb

    init() {
        // The constructor you already have – the output handler is not needed
        // for the `ikcp_send` tests, so we pass `nil`.
        kcp = ikcp_cb(conv: 0x11223344, output: nil)

        // Reasonable defaults for the tests
        kcp.mtu = 1500
        kcp.mss = 1000          // “Maximum Segment Size”
        kcp.stream = false      // most tests use non‑stream mode
    }

    // -----------------------------------------------------------------
    // MARK: – 1️⃣  Simple, non‑fragmented send
    // -----------------------------------------------------------------
    @Test
    mutating func sendSinglePacket() throws {
        // 500 bytes < mss → only one segment should be created
        var payload = [UInt8](repeating: 0xAB, count: 500)

        let sent = try kcp.send(&payload, count:payload.count)

        #expect(sent == payload.count)                 // all bytes were queued
        #expect(kcp.snd_queue.count == 1)              // exactly one segment

        // Grab the segment that was inserted into the list
        let seg = kcp.snd_queue.front!.value!

        #expect(seg.len == UInt32(payload.count))      // length recorded correctly
        #expect(seg.frg == 0)                          // no fragmentation

        // Verify the data inside the segment is identical to the source
        for i in 0..<payload.count {
            #expect(seg.data[i] == payload[i])
        }
    }
    
	@Test
	mutating func sendFragmentedPacket() throws {
		// 2500 bytes → 3 fragments when mss = 1000
		let total = 2500
		var payload = (0..<total).map { UInt8($0 & 0xFF) }

		let sent = try kcp.send(&payload, count:total)

		#expect(sent == total)                         // everything queued
		#expect(kcp.snd_queue.count == 3)              // 3 fragments

		// Walk the list forward and check size / frg fields
		var expectedSize = total
		var expectedFrg: UInt8 = 2                      // count‑1 for the first fragment

		for (cur, seg) in kcp.snd_queue.makeIterator() {
			let thisSize = min(expectedSize, Int(kcp.mss))
			#expect(seg.len == UInt32(thisSize))
			#expect(seg.frg == expectedFrg)

			expectedSize -= thisSize
			if expectedFrg > 0 { expectedFrg -= 1 }
		}
		#expect(expectedSize == 0)
	}
	
	@Test
	mutating func streamModeExtension() throws {
		kcp.stream = true                     // enable stream mode

		// 1️⃣ First chunk – 600 bytes (still < mss)
		var first = [UInt8](repeating: 0x01, count: 600)
		let sent1 = try kcp.send(&first, count:first.count)
		#expect(kcp.snd_queue.count == 1)     // one segment only

		// 2️⃣ Second chunk – 300 bytes, should extend the existing segment
		var second = [UInt8](repeating: 0x02, count: 300)
		let sent2 = try kcp.send(&second, count: second.count)

		#expect(sent2 == 300)                 // all 300 bytes were accepted
		#expect(kcp.snd_queue.count == 1)     // still only one segment

		// Verify the merged segment
		let seg = kcp.snd_queue.front!.value!
		#expect(seg.len == 900)               // 600 + 300

		// First 600 bytes = 0x01, next 300 bytes = 0x02
		for i in 0..<600 {
			#expect(seg.data[i] == 0x01)
		}
		for i in 600..<900 {
			#expect(seg.data[i] == 0x02)
		}
	}
	
    // -----------------------------------------------------------------
    // MARK: – 5️⃣  Window‑overflow guard (returns –2)
    // -----------------------------------------------------------------
    @Test
    mutating func windowOverflowReturnsMinusTwo() throws {
        // Force the fragment count to be >= IKCP_WND_RCV (256)
        // Setting mss = 1 makes every byte a fragment.
        kcp.mss = 1

        var payload = [UInt8](repeating: 0xFF, count:Int(IKCP_WND_RCV))   // 256 fragments

		do {
			_ = try kcp.send(&payload, count: payload.count)
		} catch ikcp_cb.SendError.invalidDataCountForReceiveWindow {
			#expect(kcp.snd_queue.isEmpty)        // nothing was queued
		}
    }
}