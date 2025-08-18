import Testing
@testable import kcp_swift

@Suite(.serialized)
final class kcp_core_tests {
	var kcp:ikcp_cb!
    var capturedPackets: [[UInt8]] = []   // what the output handler sees
	init() {
		// The output handler simply stores the raw bytes that would have been
		// sent on the UDP socket – this lets us inspect `flush()` later.
		let outHandler: ikcp_cb.OutputHandler = { [weak self] buffer in
			guard let self = self else { return }
			// `buffer` is a mutable view over the packet that `flush`
			// generated.  Copy it so the test can keep it after the closure
			// returns.
			let bytes = Array(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
			self.capturedPackets.append(bytes)
		}
		
		kcp = ikcp_cb(conv:0x11223344, output: outHandler)
		
		// Reasonable defaults – the same values used in the send‑tests.
		kcp.mtu = 1500
		kcp.mss = 1000
		kcp.stream = false
		kcp.nodelay = 0                // normal mode
		kcp.interval = 100             // 100 ms flush interval
		kcp.probe = 0
		kcp.rmt_wnd = IKCP_WND_RCV
		kcp.snd_wnd = IKCP_WND_RCV
		kcp.rcv_wnd = IKCP_WND_RCV
		kcp.cwnd = 1
		kcp.ssthresh = UInt32.max
	}
	
	// -----------------------------------------------------------------
    // MARK: - Helper: create a dummy segment in snd_buf
    // -----------------------------------------------------------------
    private func insertDummySentSegment(sn: UInt32) {
        let seg = ikcp_segment(payloadLength: 0)
        seg.sn = sn
        kcp.snd_buf.add(seg)
        kcp.nsnd_buf &+= 1
    }

   
 // -----------------------------------------------------------------
    // MARK: - 1️⃣  ACK handling
    // -----------------------------------------------------------------
    @Test
    func inputAckUpdatesRTTAndCwnd() throws {
        // -------------------------------------------------------------
        // 1️⃣  Prepare the internal state – two packets have already
        //     been transmitted (sn = 0 and sn = 1).
        // -------------------------------------------------------------
        kcp.snd_nxt = 2               // next SN we would use
        kcp.snd_una = 0               // earliest un‑acked

        insertDummySentSegment(sn: 0)
        insertDummySentSegment(sn: 1)

        // -------------------------------------------------------------
        // 2️⃣  Build an ACK packet that acknowledges **both** segments.
        //     The C implementation treats the `una` field as “next SN the
        //     sender expects”, therefore we set it to 2.
        // -------------------------------------------------------------
        let now: UInt32 = 123_456               // current time (ms)
        kcp.current = now + 10
        let ack  = ikcp_segment(payloadLength:0)
		ack.conv = kcp.conv
		ack.cmd = IKCP_CMD_ACK
		ack.frg = 0
		ack.wnd = UInt16(kcp.rcv_wnd)
		ack.ts = now
		ack.sn = 1
		ack.una = 2
		
		// 8x multiplier for safetyin testing
		let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity:Int(IKCP_OVERHEAD) * 8)
		defer {
			buffer.deallocate()
		}
		
		#expect(ikcp_segment.encode(ack, to:buffer) == Int(IKCP_OVERHEAD))
		
        // Feed the packet to the KCP instance.
        try kcp.input(buffer, count:Int(IKCP_OVERHEAD))

        // -----------------------------------------------------------
        // Verify side‑effects
        // -----------------------------------------------------------
        // snd_una must have advanced to the next un‑acked SN (2)
        #expect(kcp.snd_una == 2)

        // The RTT estimator must have been updated – we only know that it is
        // non‑zero after the first measurement.
        #expect(kcp.rx_srtt != 0)

        // cwnd should have grown (slow‑start) because cwnd < ssthresh.
        #expect(kcp.cwnd > 1)
    }
    
	// -----------------------------------------------------------------
	// MARK: - 2️⃣  PUSH handling – basic, out‑of‑order, re‑assembly
	// -----------------------------------------------------------------
    @Test
    func inputPushCreatesSegmentInRcvQueue() throws {
        // Build a PUSH segment that carries the payload “hello”.
        let payload = Array("hello".utf8)
        let push  = ikcp_segment(payloadLength:payload.count)
		push.conv = kcp.conv
		push.cmd = IKCP_CMD_PUSH
		push.frg = 0
		push.wnd = UInt16(kcp.rcv_wnd)
		push.ts = 111_111
		push.sn = 5
		push.una = 0
		push.data.update(from:payload, count:payload.count)
		kcp.rcv_nxt = 5
		
		let encodeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity:Int(IKCP_OVERHEAD) + payload.count)
		defer {
			encodeBuffer.deallocate()
		}
		#expect(ikcp_segment.encode(push, to:encodeBuffer) == (Int(IKCP_OVERHEAD) + payload.count))
		try kcp.input(encodeBuffer, count:Int(IKCP_OVERHEAD) + payload.count)
		
		 // The segment must now be in rcv_queue and rcv_nxt advanced.
        #expect(kcp.rcv_queue.count == 1)

        let seg = kcp.rcv_queue.front!.value!
        #expect(seg.sn == 5)
        #expect(seg.len == UInt32(payload.count))

        // Verify payload.
        for i in 0..<payload.count {
            #expect(seg.data[i] == payload[i])
        }

        // rcv_nxt should have moved forward because we received the
        // expected sequence number.
        #expect(kcp.rcv_nxt == 6)

	}
	
    @Test
    func outOfOrderPushSegmentsAreBufferedAndDeliveredInOrder() throws {
		kcp.rcv_nxt = 10
		let buffLen = Int(IKCP_OVERHEAD + 1)
		let encodeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity:buffLen)
		defer {
			encodeBuffer.deallocate()
		}
		
		func mkPush(sn:UInt32, byte:UInt8) {
			let push  = ikcp_segment(payloadLength:1)
			push.conv = kcp.conv
			push.cmd = IKCP_CMD_PUSH
			push.frg = 0
			push.wnd = UInt16(kcp.rcv_wnd)
			push.ts = 200_000
			push.sn = sn
			push.una = 0
			push.data.pointee = byte
			#expect(ikcp_segment.encode(push, to:encodeBuffer) == (Int(IKCP_OVERHEAD) + 1))
		}
		
		kcp.rcv_nxt = 10
		
		mkPush(sn: 10, byte: 0xAA)
		try kcp.input(encodeBuffer, count:buffLen)
		
		mkPush(sn: 12, byte:0xCC)
		try kcp.input(encodeBuffer, count:buffLen)
		
		mkPush(sn: 11, byte:0xBB)
		try kcp.input(encodeBuffer, count:buffLen)
		
		// After all three packets the rcv_queue must contain them in order.
		#expect(kcp.rcv_queue.count == 3)
		
		var expectedSN: UInt32 = 10
		for (_, seg) in kcp.rcv_queue.makeIterator() {
			#expect(seg.sn == expectedSN)
			expectedSN &+= 1
		}
		#expect(kcp.rcv_nxt == 13)
    }
    
    @Test
    func inputWindowProbeSetsProbeFlag() throws {
		let buffLen = Int(IKCP_OVERHEAD)
		let encodeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity:buffLen)
		defer {
			encodeBuffer.deallocate()
		}

		let wask = ikcp_segment(payloadLength:0)
		wask.conv = kcp.conv
		wask.cmd = IKCP_CMD_WASK
		wask.frg = 0
		wask.wnd = UInt16(kcp.rcv_wnd)
		wask.ts = 0
		wask.sn = 0
		wask.una = 0
		
        #expect(ikcp_segment.encode(wask, to:encodeBuffer) == Int(IKCP_OVERHEAD))

        #expect(kcp.probe == 0)
        try kcp.input(encodeBuffer, count:buffLen)
        #expect(kcp.probe == IKCP_ASK_TELL)
    }
    
     // -----------------------------------------------------------------
    // MARK: - 4️⃣  Window‑size response (WINS) handling
    // -----------------------------------------------------------------
    @Test
    func inputWindowSizeResponseDoesNotChangeState() throws {
		let buffLen = Int(IKCP_OVERHEAD)
		let encodeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity:buffLen)
		defer {
			encodeBuffer.deallocate()
		}
		let advertisedWnd: UInt16 = 1_234
        let wins = ikcp_segment(payloadLength:0)
        wins.conv = kcp.conv
        wins.cmd = IKCP_CMD_WINS
        wins.frg = 0
        wins.wnd = advertisedWnd
        wins.ts = 0
        wins.sn = 0
        wins.una = 0

        let beforeProbe  = kcp.probe
        
        #expect(kcp.rmt_wnd != UInt32(advertisedWnd))
		#expect(ikcp_segment.encode(wins, to:encodeBuffer) == Int(IKCP_OVERHEAD))

       	try kcp.input(encodeBuffer, count:buffLen)

        #expect(kcp.rmt_wnd == UInt32(advertisedWnd))
        #expect(kcp.probe == beforeProbe)
    }
	@Test
    func fastAckAggregatesHighestSn() throws {
		let buffLen = Int(IKCP_OVERHEAD) * 2
		let encodeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity:buffLen)
		defer {
			encodeBuffer.deallocate()
		}

        // Insert three dummy segments (sn = 0,1,2) into snd_buf.
        for sn in 0..<3 {
            let seg = ikcp_segment(payloadLength: 0)
            seg.sn = UInt32(sn)
            kcp.snd_buf.add(seg)
            kcp.nsnd_buf &+= 1
        }
        kcp.snd_nxt = 3
        kcp.current = 2_000
        kcp.interval = 100
		let ack0 = ikcp_segment(payloadLength:0)
		ack0.conv = kcp.conv
		ack0.cmd = IKCP_CMD_ACK
		ack0.frg = 0
		ack0.wnd = UInt16(kcp.rcv_wnd)
		ack0.ts = 1000
		ack0.sn = 0
		ack0.una = 1
		#expect(ikcp_segment.encode(ack0, to:encodeBuffer) == Int(IKCP_OVERHEAD))
		let ack2 = ikcp_segment(payloadLength:0)
		ack2.conv = kcp.conv
		ack2.cmd = IKCP_CMD_ACK
		ack2.frg = 0
		ack2.wnd = UInt16(kcp.rcv_wnd)
		ack2.ts = 1000
		ack2.sn = 2
		ack2.una = 3
		#expect(ikcp_segment.encode(ack2, to:encodeBuffer + Int(IKCP_OVERHEAD)) == Int(IKCP_OVERHEAD))
		try kcp.input(encodeBuffer, count:Int(IKCP_OVERHEAD) * 2)
//		try kcp.input(encodeBuffer + Int(IKCP_OVERHEAD), count:Int(IKCP_OVERHEAD) )
		#expect(kcp.snd_una == 3)
		#expect(kcp.cwnd > 1)
		#expect(kcp.rx_srtt != 0)
	}
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