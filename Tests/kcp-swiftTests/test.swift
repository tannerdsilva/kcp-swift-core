
import Testing
import Foundation

@testable import kcp_swift

@Test func testSendAndReceiveSingleSegment() throws {
	let conv: UInt32 = 0x1234
	
	var receiver: ikcp_cb! = nil
	var sender: ikcp_cb! = nil

	receiver = ikcp_cb(conv: conv, user: nil)

	sender = ikcp_cb(conv: conv, user: nil)

	let payload1 = [UInt8](repeating: 1, count: 1000)
	var tempPayload1 = payload1
	let _ = sender.send(buffer: &tempPayload1, _len: 1000)
	
	var now = UInt32(0)          // “current” time (ms)

	var received: [[UInt8]] = []
	repeat {
		sender.update(current: now, output: { buffer in
			let _ = receiver.input(data: buffer)
	 })
		receiver.update(current: now, output: { buffer in
			let _ = sender.input(data: buffer)
	 })
		
		do {
			guard let tempReceived = try receiver.receive() else {
				continue
			}
			received.append(tempReceived)
		} catch {
			
		}

		now += 10_000        // advance 10 ms per iteration – tweak as needed
		
		Thread.sleep(forTimeInterval: 0.01)

		// Break if nothing left to send and nothing left to receive.
		if received.count == 1 { break }
	} while true
	
	#expect(received.count == 1)
	#expect(received[0] == payload1)
}

@Test func testSendAndReceiveMultipleSegments() throws {
	let conv: UInt32 = 0x1234
	
	var receiver: ikcp_cb! = nil
	var sender: ikcp_cb! = nil

	receiver = ikcp_cb(conv: conv, user: nil)

	sender = ikcp_cb(conv: conv, user: nil)

	let payload1 = [UInt8](repeating: 1, count: 20)
	let payload2 = [UInt8](repeating: 2, count: 30)
	let payload3 = [UInt8](repeating: 3, count: 40)
	let payload4 = [UInt8](repeating: 4, count: 50)
	
	var tempPayload = payload1
	let _ = sender.send(buffer: &tempPayload, _len: 20)
	tempPayload = payload2
	let _ = sender.send(buffer: &tempPayload, _len: 30)
	tempPayload = payload3
	let _ = sender.send(buffer: &tempPayload, _len: 40)
	tempPayload = payload4
	let _ = sender.send(buffer: &tempPayload, _len: 50)
	
	var now = UInt32(0)          // “current” time (ms)

	var received: [[UInt8]] = []
	repeat {
		sender.update(current: now, output: { buffer in
			let _ = receiver.input(data: buffer)
	 })
		receiver.update(current: now, output: { buffer in
			let _ = sender.input(data: buffer)
	 })
		
		do {
			guard let tempReceived = try receiver.receive() else {
				continue
			}
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

@Test func testSendAndReceiveMultipleLargeSegments() throws {
	let conv: UInt32 = 0x1234
	
	var receiver: ikcp_cb! = nil
	var sender: ikcp_cb! = nil

	receiver = ikcp_cb(conv: conv, user: nil)

	sender = ikcp_cb(conv: conv, user: nil)

	let payload1 = [UInt8](repeating: 1, count: 100000)
	let payload2 = [UInt8](repeating: 2, count: 100000)
	let payload3 = [UInt8](repeating: 3, count: 100000)
	let payload4 = [UInt8](repeating: 4, count: 100000)
	
	var tempPayload = payload1
	let _ = sender.send(buffer: &tempPayload, _len: 100000)
	tempPayload = payload2
	let _ = sender.send(buffer: &tempPayload, _len: 100000)
	tempPayload = payload3
	let _ = sender.send(buffer: &tempPayload, _len: 100000)
	tempPayload = payload4
	let _ = sender.send(buffer: &tempPayload, _len: 100000)
	
	var now = UInt32(0)          // “current” time (ms)

	var received: [[UInt8]] = []
	repeat {
		sender.update(current: now, output: { buffer in
			let _ = receiver.input(data: buffer)
	 })
		receiver.update(current: now, output: { buffer in
			let _ = sender.input(data: buffer)
	 })
		
		do {
			guard let tempReceived = try receiver.receive() else {
				continue
			}
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

@Test func testSendAndReceiveSynchronously() throws {
	let conv: UInt32 = 0x1234
	
	var receiver: ikcp_cb! = nil
	var sender: ikcp_cb! = nil
	
	sender = ikcp_cb(conv: conv, user: nil, synchronous: true)
	receiver = ikcp_cb(conv: conv, user: nil, synchronous: true)
	
	let payloadSize: Int = 1_000_000
	
	var payload = [UInt8](repeating: 0, count: payloadSize)
	for i in 0..<payloadSize {
		payload[i] = UInt8(i%256)
	}
	var tempPayload = payload
	
	while(tempPayload != []) {
		if(tempPayload.count >= 300_000) {
			_ = sender.send(buffer: &tempPayload, _len: 300_000)
		} else {
			_ = sender.send(buffer: &tempPayload, _len: tempPayload.count)
		}
	}
	
	var now = UInt32(0)
	
	// Send all segments in the queue
	sender.update(current: now, output: { buffer in
		let _ = receiver.input(data: buffer)
	})
	
	// Receive all segments and put them back together
	var received: [UInt8] = []
	while let data = try! receiver.receive() {
		received.append(contentsOf: data)
	}
	
	now+=100_000_000
	
	while(!sender.ackUpToDate()) {
		sender.update(current: now, output: { buffer in
			let _ = receiver.input(data: buffer)
	 })
		
		// Sending ACKs
		receiver.update(current: now, output: { buffer in
			let _ = sender.input(data: buffer)
	 })
	}
	
	let data = try! receiver.receive()
	#expect(data == nil)
	
	#expect(received == payload)
}
