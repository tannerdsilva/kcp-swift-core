import Testing
@testable import kcp_swift

@Suite(.serialized)
final class kcp_core_tests {
	var kcp:ikcp_cb<Void>!
    var capturedPackets: [[UInt8]] = []   // what the output handler sees
	init() {
		// The output handler simply stores the raw bytes that would have been
		// sent on the UDP socket – this lets us inspect `flush()` later.
		let outHandler: ikcp_cb<Void>.OutputHandler = { [weak self] buffer, _ in
			guard let self = self else { return }
			// `buffer` is a mutable view over the packet that `flush`
			// generated.  Copy it so the test can keep it after the closure
			// returns.
			let bytes = Array(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
			self.capturedPackets.append(bytes)
		}
		
		kcp = ikcp_cb<Void>(conv:0x11223344, output: outHandler)
		
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
		let seg = ikcp_cb<Void>.ikcp_segment(payloadLength: 0)
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
        let ack  = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
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
		
		#expect(ikcp_cb<Void>.ikcp_segment.encode(ack, to:buffer) == Int(IKCP_OVERHEAD))
		
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
        let push  = ikcp_cb<Void>.ikcp_segment(payloadLength:payload.count)
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
		#expect(ikcp_cb<Void>.ikcp_segment.encode(push, to:encodeBuffer) == (Int(IKCP_OVERHEAD) + payload.count))
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
			let push  = ikcp_cb<Void>.ikcp_segment(payloadLength:1)
			push.conv = kcp.conv
			push.cmd = IKCP_CMD_PUSH
			push.frg = 0
			push.wnd = UInt16(kcp.rcv_wnd)
			push.ts = 200_000
			push.sn = sn
			push.una = 0
			push.data.pointee = byte
			#expect(ikcp_cb<Void>.ikcp_segment.encode(push, to:encodeBuffer) == (Int(IKCP_OVERHEAD) + 1))
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

		let wask = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
		wask.conv = kcp.conv
		wask.cmd = IKCP_CMD_WASK
		wask.frg = 0
		wask.wnd = UInt16(kcp.rcv_wnd)
		wask.ts = 0
		wask.sn = 0
		wask.una = 0
		
        #expect(ikcp_cb<Void>.ikcp_segment.encode(wask, to:encodeBuffer) == Int(IKCP_OVERHEAD))

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
        let wins = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
        wins.conv = kcp.conv
        wins.cmd = IKCP_CMD_WINS
        wins.frg = 0
        wins.wnd = advertisedWnd
        wins.ts = 0
        wins.sn = 0
        wins.una = 0

        let beforeProbe  = kcp.probe
        
        #expect(kcp.rmt_wnd != UInt32(advertisedWnd))
		#expect(ikcp_cb<Void>.ikcp_segment.encode(wins, to:encodeBuffer) == Int(IKCP_OVERHEAD))

       	try kcp.input(encodeBuffer, count:buffLen)

        #expect(kcp.rmt_wnd == UInt32(advertisedWnd))
        #expect(kcp.probe == beforeProbe)
    }
    
	@Test func fastAckAggregatesHighestSn() throws {
		let buffLen = Int(IKCP_OVERHEAD) * 2
		let encodeBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity:buffLen)
		defer {
			encodeBuffer.deallocate()
		}
        for sn in 0..<3 {
            let seg = ikcp_cb<Void>.ikcp_segment(payloadLength: 0)
            seg.sn = UInt32(sn)
            kcp.snd_buf.add(seg)
            kcp.nsnd_buf &+= 1
        }
        kcp.snd_nxt = 3
        kcp.current = 2_000
        kcp.interval = 100
		let ack0 = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
		ack0.conv = kcp.conv
		ack0.cmd = IKCP_CMD_ACK
		ack0.frg = 0
		ack0.wnd = UInt16(kcp.rcv_wnd)
		ack0.ts = 1000
		ack0.sn = 0
		ack0.una = 1
		#expect(ikcp_cb<Void>.ikcp_segment.encode(ack0, to:encodeBuffer) == Int(IKCP_OVERHEAD))
		let ack2 = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
		ack2.conv = kcp.conv
		ack2.cmd = IKCP_CMD_ACK
		ack2.frg = 0
		ack2.wnd = UInt16(kcp.rcv_wnd)
		ack2.ts = 1000
		ack2.sn = 2
		ack2.una = 3
		#expect(ikcp_cb<Void>.ikcp_segment.encode(ack2, to:encodeBuffer + Int(IKCP_OVERHEAD)) == Int(IKCP_OVERHEAD))
		try kcp.input(encodeBuffer, count:Int(IKCP_OVERHEAD) * 2)
		#expect(kcp.snd_una == 3)
		#expect(kcp.cwnd > 1)
		#expect(kcp.rx_srtt != 0)
	}
	
	@Test func updateTriggersFlushAtInterval() throws {
		kcp.interval = 50
		kcp.current  = 1_000
		kcp.ts_flush = 0

		kcp.probe = IKCP_ASK_TELL
		kcp.ackPush(sn: 0, ts: kcp.current)
		kcp.update(current: kcp.current)
	
		#expect(self.capturedPackets.isEmpty == false, "first update must call flush() and produce a packet")
		let firstFlush = kcp.ts_flush
		kcp.current &+= 20
		kcp.update(current: kcp.current)
	
		#expect(kcp.ts_flush == firstFlush, "ts_flush must stay unchanged when the interval has not elapsed")
		#expect(self.capturedPackets.count == 1, "still only the first packet should have been emitted")
	
		kcp.current &+= 40
		kcp.probe = IKCP_ASK_TELL
		kcp.ackPush(sn:1, ts: kcp.current)
		kcp.update(current: kcp.current)
	
		#expect(kcp.ts_flush > firstFlush, "second flush must have advanced ts_flush")
		#expect(self.capturedPackets.count == 2, "two flushes should be recorded")
	}
}

@Suite(.serialized)
struct kcp_send_tests {
    var kcp: ikcp_cb<Void>
    init() {
        kcp = ikcp_cb<Void>(conv: 0x11223344, output: nil)
        kcp.mtu = 1500
        kcp.mss = 1000
        kcp.stream = false
    }
    @Test mutating func sendSinglePacket() throws {
        var payload = [UInt8](repeating: 0xAB, count: 500)
        let sent = try kcp.send(&payload, count:payload.count)
        #expect(sent == payload.count)
        #expect(kcp.snd_queue.count == 1)
        let seg = kcp.snd_queue.front!.value!
        #expect(seg.len == UInt32(payload.count))
        #expect(seg.frg == 0)
        for i in 0..<payload.count {
            #expect(seg.data[i] == payload[i])
        }
    }
    
	@Test mutating func sendFragmentedPacket() throws {
		let total = 2500
		var payload = (0..<total).map { UInt8($0 & 0xFF) }
		let sent = try kcp.send(&payload, count:total)
		#expect(sent == total)
		#expect(kcp.snd_queue.count == 3)
		var expectedSize = total
		var expectedFrg: UInt8 = 2
		for (cur, seg) in kcp.snd_queue.makeIterator() {
			let thisSize = min(expectedSize, Int(kcp.mss))
			#expect(seg.len == UInt32(thisSize))
			#expect(seg.frg == expectedFrg)
			expectedSize -= thisSize
			if expectedFrg > 0 { expectedFrg -= 1 }
		}
		#expect(expectedSize == 0)
	}
	
	@Test mutating func streamModeExtension() throws {
		kcp.stream = true
		var first = [UInt8](repeating: 0x01, count: 600)
		let sent1 = try kcp.send(&first, count:first.count)
		#expect(kcp.snd_queue.count == 1)
		var second = [UInt8](repeating: 0x02, count: 300)
		let sent2 = try kcp.send(&second, count: second.count)
		#expect(sent2 == 300)
		#expect(kcp.snd_queue.count == 1)
		let seg = kcp.snd_queue.front!.value!
		#expect(seg.len == 900)
		for i in 0..<600 {
			#expect(seg.data[i] == 0x01)
		}
		for i in 600..<900 {
			#expect(seg.data[i] == 0x02)
		}
	}

    @Test mutating func windowOverflowReturnsMinusTwo() throws {
        kcp.mss = 1
        var payload = [UInt8](repeating: 0xFF, count:Int(IKCP_WND_RCV))
		do {
			_ = try kcp.send(&payload, count: payload.count)
		} catch SendError.invalidDataCountForReceiveWindow {
			#expect(kcp.snd_queue.isEmpty)
		}
    }
}

import Foundation
@Test func testSendAndReceiveMultipleLargeSegments() throws {
	let conv: UInt32 = 0x1234
	
	var receiver: ikcp_cb<Void>! = nil
	var sender: ikcp_cb<Void>! = nil

	receiver = ikcp_cb<Void>(conv: conv, output: { buffer, _  in
		do {
			if let baseAddress = buffer.baseAddress {
				let _ = try sender.input(baseAddress, count: buffer.count)
			}
		} catch let error {
			print(error)
		}
	})

	sender = ikcp_cb<Void>(conv: conv, output: { buffer, _ in
		do {
			if let baseAddress = buffer.baseAddress {
				let _ = try receiver.input(baseAddress, count: buffer.count)
			}
		} catch let error {
			print(error)
		}
	})
	sender.nocwnd = 1
	receiver.nocwnd = 1

	let payload1 = [UInt8](repeating: 1, count: 3000)
	let payload2 = [UInt8](repeating: 2, count: 300000)
	let payload3 = [UInt8](repeating: 3, count: 300000)
	let payload4 = [UInt8](repeating: 4, count: 300000)
	
	var tempPayload = payload1
	let _ = try sender.send(&tempPayload, count: 3000)
	tempPayload = payload2
	let _ = try sender.send(&tempPayload, count: 300000)
	tempPayload = payload3
	let _ = try sender.send(&tempPayload, count: 300000)
	tempPayload = payload4
	let _ = try sender.send(&tempPayload, count: 300000)
	
	var now = UInt32(0)          // “current” time (ms)

	var received: [[UInt8]] = []
	repeat {
		sender.update(current: now)
		receiver.update(current: now)

		do {
			let tempReceived = try receiver.receive()
			received.append(tempReceived)
		} catch {
			
		}

		now += 10_000        // advance 10 ms per iteration – tweak as needed
		
		Thread.sleep(forTimeInterval: 0.01)

		// Break if nothing left to send and nothing left to receive.
		if received.count == 4 { break }
	} while true
	
	#expect(received.count == 4)
	#expect(received[0] == payload1)
	#expect(received[1] == payload2)
	#expect(received[2] == payload3)
	#expect(received[3] == payload4)
}
