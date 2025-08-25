import Testing
@testable import kcp_swift
import Foundation


@Suite(.serialized)
final class kcp_core_tests {
	var kcp:ikcp_cb<Void>!
    var capturedPackets: [[UInt8]] = []   // what the output handler sees
	init() {
		let outHandler: ikcp_cb<Void>.OutputHandler = { [weak self] buffer, _ in
			guard let self = self else { return }
			let bytes = Array(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
			self.capturedPackets.append(bytes)
		}
		
		kcp = ikcp_cb<Void>(conv:0x11223344)
		
		kcp.mtu = 1500
		kcp.mss = 1000
		kcp.nodelay = 0
		kcp.interval = 100             // 100 ms flush interval
		kcp.ssthresh = UInt32.max
	}
    private func insertDummySentSegment(sn: UInt32) {
		let seg = ikcp_cb<Void>.ikcp_segment(payloadLength: 0)
        seg.sn = sn
        kcp.snd_buf.add(seg)
    }
    @Test func inputAckUpdatesRTTAndCwnd() throws {
        kcp.snd_nxt = 2               // next SN we would use
        kcp.snd_una = 0               // earliest un‑acked

        insertDummySentSegment(sn: 0)
        insertDummySentSegment(sn: 1)

        let now: UInt32 = 123_456               // current time (ms)
        kcp.current = now + 10
        let ack  = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
		ack.conv = kcp.conv
		ack.cmd = IKCP_CMD_ACK
		ack.frg = 0
		ack.wnd = 0
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

        #expect(kcp.snd_una == 2)

        // The RTT estimator must have been updated – we only know that it is
        // non‑zero after the first measurement.
        #expect(kcp.rx_srtt != 0)
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
		push.wnd = 0
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
			push.wnd = 0
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
    
	// -----------------------------------------------------------------
    // MARK: - 4️⃣  Window‑size response (WINS) handling
    // -----------------------------------------------------------------
    
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
        }
        kcp.snd_nxt = 3
        kcp.current = 2_000
        kcp.interval = 100
		let ack0 = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
		ack0.conv = kcp.conv
		ack0.cmd = IKCP_CMD_ACK
		ack0.frg = 0
		ack0.wnd = 0
		ack0.ts = 1000
		ack0.sn = 0
		ack0.una = 1
		#expect(ikcp_cb<Void>.ikcp_segment.encode(ack0, to:encodeBuffer) == Int(IKCP_OVERHEAD))
		let ack2 = ikcp_cb<Void>.ikcp_segment(payloadLength:0)
		ack2.conv = kcp.conv
		ack2.cmd = IKCP_CMD_ACK
		ack2.frg = 0
		ack2.wnd = 0
		ack2.ts = 1000
		ack2.sn = 2
		ack2.una = 3
		#expect(ikcp_cb<Void>.ikcp_segment.encode(ack2, to:encodeBuffer + Int(IKCP_OVERHEAD)) == Int(IKCP_OVERHEAD))
		try kcp.input(encodeBuffer, count:Int(IKCP_OVERHEAD) * 2)
		#expect(kcp.snd_una == 3)
		#expect(kcp.rx_srtt != 0)
	}
	
	@Test func updateTriggersFlushAtInterval() throws {
		kcp.interval = 50
		kcp.current  = 1_000
		kcp.ts_flush = 0

		kcp.ackPush(sn: 0, ts: kcp.current)
		kcp.update(current: kcp.current) { buffer, _ in
			let bytes = Array(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
			self.capturedPackets.append(bytes)
		}
	
		#expect(self.capturedPackets.isEmpty == false, "first update must call flush() and produce a packet")
		let firstFlush = kcp.ts_flush
		kcp.current &+= 20
		kcp.update(current: kcp.current) { buffer, _ in
			let bytes = Array(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
			self.capturedPackets.append(bytes)
		}
	
		#expect(kcp.ts_flush == firstFlush, "ts_flush must stay unchanged when the interval has not elapsed")
		#expect(self.capturedPackets.count == 1, "still only the first packet should have been emitted")
	
		kcp.current &+= 40
		kcp.ackPush(sn:1, ts: kcp.current)
		kcp.update(current: kcp.current) { buffer, _ in
			let bytes = Array(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
			self.capturedPackets.append(bytes)
		}
	
		#expect(kcp.ts_flush > firstFlush, "second flush must have advanced ts_flush")
		#expect(self.capturedPackets.count == 2, "two flushes should be recorded")
	}
}

@Suite(.serialized)
struct kcp_send_tests {
    var kcp: ikcp_cb<Void>
    init() {
        kcp = ikcp_cb<Void>(conv: 0x11223344)
        kcp.mtu = 1500
        kcp.mss = 1000
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
	
	@Test func testSendAndReceiveMultipleLargeSegments() throws {
		let conv: UInt32 = 0x1234
		
		var receiver: ikcp_cb<Void>! = nil
		var sender: ikcp_cb<Void>! = nil
	
		receiver = ikcp_cb<Void>(conv: conv)
	
		sender = ikcp_cb<Void>(conv: conv)
	
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
		sender.updateSend()
		
		var now = UInt32(0)          // “current” time (ms)
	
		var received: [[UInt8]] = []
		repeat {
			sender.update(current:now) { buffer, _ in
				do {
					if let baseAddress = buffer.baseAddress {
						let _ = try receiver.input(baseAddress, count: buffer.count)
					}
				} catch let error {
					print(error)
				}
			}
			receiver.update(current:now) { buffer, _  in
				do {
					if let baseAddress = buffer.baseAddress {
						let _ = try sender.input(baseAddress, count: buffer.count)
					}
				} catch let error {
					print(error)
				}
			}
	
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
}

@Test func testLinkedListIteratorNext() {
	let myList = LinkedList<Int>()
	myList.addTail(1)
	myList.addTail(2)
	myList.addTail(3)
	myList.addTail(4)
	myList.addTail(5)
	
	// Make sure the iterator is on the head
	var it = myList.makeLoopingIterator()
	#expect(it.current() == nil)
	
	// Move iterator and check if it moves to the next node
	it = it.nextIterator()!
	#expect(it.current()!.0.value == 1)
	
	// Removing a value
	let remove = it
	it = it.nextIterator()!
	myList.remove(remove.current()!.0)
	#expect(myList.count == 4)
	#expect(it.current()!.0.value == 2)
	
	// Moving iterator and checking value
	it = it.nextIterator()!
	#expect(it.current()!.0.value == 3)
}

@Test func testLinkedListIteratorPrev() {
	let myList = LinkedList<Int>()
	myList.add(1)
	myList.add(2)
	myList.add(3)
	myList.add(4)
	myList.add(5)
	
	// Make sure the iterator is on the head
	var it = myList.makeLoopingIterator()
	#expect(it.current() == nil)
	
	// Move iterator and check if it moves to the next node
	it = it.prevIterator()!
	#expect(it.current()!.0.value == 1)
	
	// Removing a value
	let remove = it
	it = it.prevIterator()!
	myList.remove(remove.current()!.0)
	#expect(myList.count == 4)
	#expect(it.current()!.0.value == 2)
	
	// Moving iterator and checking value
	it = it.prevIterator()!
	#expect(it.current()!.0.value == 3)
}

@Test func testEmptyLinkedListIterator() {
	let myList = LinkedList<Int>()
	var it = myList.makeLoopingIterator()
	
	#expect(it.current() == nil)
	it = it.nextIterator()!
	#expect(it.current() == nil)
	it = it.prevIterator()!
	#expect(it.current() == nil)
}
