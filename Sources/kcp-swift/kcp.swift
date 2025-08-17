
#if canImport(RAW)
import RAW
#endif

fileprivate func decodeUInt32(_ ptr:inout UnsafeRawPointer) -> UInt32 {
	defer {
		ptr += MemoryLayout<UInt32>.size
	}
	return UInt32(bigEndian:ptr.assumingMemoryBound(to:UInt32.self).pointee)
}
fileprivate func decodeUInt16(_ ptr:inout UnsafeRawPointer) -> UInt16 {
	defer {
		ptr += MemoryLayout<UInt16>.size
	}
	return UInt16(bigEndian:ptr.assumingMemoryBound(to:UInt16.self).pointee)
}
fileprivate func decodeUInt8(_ ptr:inout UnsafeRawPointer) -> UInt8 {
	defer {
		ptr += MemoryLayout<UInt8>.size
	}
	return ptr.assumingMemoryBound(to:UInt8.self).pointee
}

fileprivate func encodeUInt32(_ val:UInt32, _ ptr:UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> {
	withUnsafePointer(to:val.bigEndian) { beValPtr in
		ptr.update(from:UnsafeRawPointer(beValPtr).assumingMemoryBound(to:UInt8.self), count:MemoryLayout<UInt32>.size)
	}
	return ptr + MemoryLayout<UInt32>.size
}
fileprivate func encodeUInt16(_ val:UInt16, _ ptr:UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> {
	withUnsafePointer(to:val.bigEndian) { beValPtr in
		ptr.update(from:UnsafeRawPointer(beValPtr).assumingMemoryBound(to:UInt8.self), count:MemoryLayout<UInt16>.size)
	}
	return ptr + MemoryLayout<UInt16>.size
}
fileprivate func encodeUInt8(_ val:UInt8, _ ptr:UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> {
	withUnsafePointer(to:val) { beValPtr in
		ptr.update(from:UnsafeRawPointer(beValPtr).assumingMemoryBound(to:UInt8.self), count:MemoryLayout<UInt8>.size)
	}
	return ptr + MemoryLayout<UInt8>.size
}


@inline(__always) private func imax(_ a: UInt32, _ b: UInt32) -> UInt32 {
	return a > b ? a : b
}
@inline(__always) private func ibound(_ lower: Int32, _ value: Int32, _ upper: Int32) -> Int32 {
	return min(max(value, lower), upper)
}
@inline(__always) private func itimeDiff(later a:UInt32, earlier b:UInt32) -> Int32 {
    return Int32(bitPattern: a &- b)
}

let IKCP_RTO_NDL:UInt32 = 30
let IKCP_RTO_MIN:UInt32 = 100
let IKCP_RTO_DEF:UInt32 = 200
let IKCP_RTO_MAX:UInt32 = 60000
let IKCP_CMD_PUSH:UInt8 = 81
let IKCP_CMD_ACK:UInt8 = 82
let IKCP_CMD_WASK:UInt8 = 83
let IKCP_CMD_WINS:UInt8 = 84
let IKCP_ASK_SEND:UInt32 = 1
let IKCP_ASK_TELL:UInt32 = 2
let IKCP_WND_SND:UInt32 = 32
let IKCP_WND_RCV:UInt32 = 1024
let IKCP_MTU_DEF:UInt32 = 1400
let IKCP_ACK_FAST:UInt32 = 3
let IKCP_INTERVAL:UInt32 = 100
let IKCP_OVERHEAD:UInt32 = 24
let IKCP_DEADLINK:UInt32 = 20
let IKCP_THRESH_INIT:UInt32 = 2
let IKCP_THRESH_MIN:UInt32 = 2
let IKCP_PROBE_INIT:UInt32 = 7000
let IKCP_PROBE_LIMIT:UInt32 = 120000
let IKCP_FASTACK_LIMIT:UInt32 = 5

internal final class ikcp_segment {
	internal var conv:UInt32 = 0 		// Conversation ID
	internal var cmd:UInt8 = 0			// Command type (type of segment). 81: PUSH(data), 82: ACK, 83: WASK(window probe request), 84: WINS(window size response)
	internal var frg:UInt8 = 0			// Fragment index, First Fragment: n-1, Last Fragment: 0
	internal var wnd:UInt16 = 0			// Receive window size, tells how many more segments to receive
	internal var ts:UInt32 = 0			// Timestamp. Used for RTT
	internal var sn:UInt32 = 0			// Sequence number. Identifies the order of the packet in the stream
	internal var una:UInt32 = 0			// The next sequence number the sender is expecing an ACK for
	internal var len:UInt32 = 0			// Number of bytes in `data`
	internal var resendts:UInt32 = 0	// Resend Timestamp: Time when to retransmit if no ACK is received
	internal var rto:UInt32 = 0			// Retransmission Timeout: calculated based on RTT; delay before a resend is triggered
	internal var fastack:UInt32 = 0		// Fast ACK Counter: incremented when duplicate ACK's are received. If high, then does a fast retransmit
	internal var xmit:UInt32 = 0		// Transmission Count: how many times the segment has been sent. Used for dropping
	internal var data:UnsafeMutableBufferPointer<UInt8>!		// Slice of data being transmitted
	internal init(size:Int) {
		if size == 0 {
			data = nil
		} else {
			data = UnsafeMutableBufferPointer<UInt8>.allocate(capacity:size)
		}
	}
	deinit {
		if len > 0 {
			data.deallocate()
		}
	}
}

/// KCP control block. Main structrue that represents a KCP session.
public struct ikcp_cb {
	internal var conv:UInt32		// Conversation ID
	internal var mtu:UInt32			// Maximum Transmission Unit: Largest UDP packet accepted
	internal var mss:UInt32			// Maximum Segment Size: Largest amount of data per segment
	internal var state:UInt32		// Connection State: 0 = normal, -1 = dead
	
	internal var snd_una:UInt32		// Earliest Unacknowledged Segment
	internal var snd_nxt:UInt32		// Next segment number to send
	internal var rcv_nxt:UInt32		// Next expected segment number from peer

	internal var ts_recent:UInt32	// Timestamp of the most recent packet received (used for RTT)
	internal var ts_lastack:UInt32	// Timestamp of the last ACK sent
	internal var ssthresh:UInt32	// Slow start theshold

	internal var rx_rttval:Int32	// Smoothed RTT Variance
	internal var rx_srtt:Int32		// Smoothed RTT
	internal var rx_rto:Int32		// Retransmission timeout (dynamically calculated)
	internal var rx_minrto:Int32	// Minimum RTO allowed

	internal var snd_wnd:UInt32		// Sender's Window: How many unacked segments willing to send
	internal var rcv_wnd:UInt32		// Receivers Window: How many segments we can accept
	internal var rmt_wnd:UInt32		// Remote's advertised receive window
	internal var cwnd:UInt32		// Congestion Window
	internal var probe:UInt32		// Flags for window probing

	internal var current:UInt32
	internal var interval:UInt32
	internal var ts_flush:UInt32
	internal var xmit:UInt32		// Total number of transmissions

	internal var nrcv_buf:UInt32	// Number of segments in rcv_buff
	internal var nsnd_buf:UInt32	// Number of segments in snd_buff

	internal var nrcv_que:UInt32	// Number of segments in rcv_queue
	internal var nsnd_que:UInt32	// Number of segments in snd_queue

	internal var nodelay:UInt32		// 1 for nodelay mode
	internal var updated:UInt32		// indicates if ikcp_update() has been called

	internal var ts_probe:UInt32	// Next scheduled probe time
	internal var probe_wait:UInt32	// Time to wait before probing again

	internal var dead_link:UInt32	// Max number of retransmits before considering the link dead
	internal var incr:UInt32

	internal var snd_queue:LinkedList<ikcp_segment>		// user data waiting to be segmented and sent out
	internal var rcv_queue:LinkedList<ikcp_segment>		// Fully reassembled segments ready to return to application
	internal var snd_buf:LinkedList<ikcp_segment>		// Segments sent and waiting to be ACKed
	internal var rcv_buf:LinkedList<ikcp_segment>		// Segments received out of oder and waiting to be reassembled

	internal var acklist:UnsafeMutableBufferPointer<UInt32>!
	internal var ackcount:UInt32
	internal var ackblock:UInt32

	internal var fastresend:Int64
	
	internal var fastlimit:Int64

	internal var nocwnd:Int64
	
	internal var stream:Bool
	
	internal var buffer:UnsafeMutablePointer<UInt8>! = nil
	
	public typealias OutputHandler = ((UnsafeMutableBufferPointer<UInt8>) -> Void)
	internal var output:OutputHandler? = nil

	public init(conv:UInt32, output:OutputHandler?) {
		self.conv = conv
		self.mtu = IKCP_MTU_DEF
		self.mss = mtu - IKCP_OVERHEAD
		self.state = 0

		self.snd_una = 0
		self.snd_nxt = 0
		self.rcv_nxt = 0

		self.ts_recent = 0
		self.ts_lastack = 0
		self.ssthresh = IKCP_THRESH_INIT

		self.rx_rttval = 0
		self.rx_srtt = 0
		self.rx_rto = Int32(IKCP_RTO_DEF)
		self.rx_minrto = Int32(IKCP_RTO_MIN)

		self.snd_wnd = IKCP_WND_SND
		self.rcv_wnd = IKCP_WND_RCV
		self.rmt_wnd = IKCP_WND_RCV
		self.cwnd = 0
		self.probe = 0

		self.current = 0
		self.interval = IKCP_INTERVAL
		self.ts_flush = IKCP_INTERVAL
		self.xmit = 0

		self.nrcv_buf = 0
		self.nsnd_buf = 0

		self.nrcv_que = 0
		self.nsnd_que = 0

		self.nodelay = 0
		self.updated = 0

		self.ts_probe = 0
		self.probe_wait = 0

		self.dead_link = IKCP_DEADLINK
		self.incr = 0

		self.snd_queue = .init()
		self.rcv_queue = .init()
		self.snd_buf = .init()
		self.rcv_buf = .init()

		self.acklist = nil
		self.ackcount = 0
		self.ackblock = 0

		self.fastresend = 0
		self.fastlimit = Int64(IKCP_FASTACK_LIMIT)
		self.nocwnd = 0
		
		self.stream = false
		self.output = output
	}
	
	
	public enum Error:Swift.Error {
		/// thrown when the rcv_queue is empty
		case rcvQueueEmpty
		/// thrown when the rcv_queue has less segments than the frg value of the first segment
		case rcvQueueLessThanFrg
		/// thrown when the peeked size is greater than the input count
		case peekedSizeGreaterThanInputCount
	}
	
	//---------------------------------------------------------------------
	// user/upper level recv: returns size, returns below zero for EAGAIN
	//---------------------------------------------------------------------
	// _len is the size of the expected returned message
	// _len is negative for peek mode
	/// Returns the reformed message from the KCP fragments
	public mutating func receive(_ ptr:UnsafeMutableRawPointer?, len:Int) throws -> Int {
		guard rcv_queue.isEmpty == false else {
			return -1
		}
		let isPeek:Bool = (len < 0)
		let absLen = isPeek ? -len : len
		
		let peekSize = peekSize()
		guard peekSize >= 0 else {
			return -2
		}
		guard peekSize <= absLen else {
			return -3
		}
		var recover:Bool = false
		if nrcv_que >= rcv_wnd {
			recover = true
		}
		var copied = 0
		nodeLoop: for (node, seg) in rcv_queue.makeIterator() {
			if let buf = ptr, seg.len > 0 {
				buf.advanced(by:copied).assumingMemoryBound(to:UInt8.self).update(from:seg.data.baseAddress!, count:Int(seg.len))
			}
			copied += Int(seg.len)
			if isPeek == false {
				rcv_queue.remove(node)
			}
			guard seg.frg != 0 else {
				break nodeLoop
			}
		}
		
		#if DEBUG
		guard copied == peekSize else {
			fatalError("copied is not the same as peeksize. this is unexpected")
		}
		#endif
		
		for (node, seg) in rcv_buf.makeIterator() {
			if seg.sn == rcv_nxt && nrcv_buf < rcv_wnd {
				rcv_buf.remove(node)
				nrcv_buf -= 1
				
				rcv_queue.addTail(node)
				nrcv_que += 1
				
				rcv_nxt += 1
			} else {
				break
			}
		}
		
		if nrcv_que < rcv_wnd && recover == true {
			probe |= IKCP_ASK_TELL
		}
		return copied
	}

	//---------------------------------------------------------------------
	// peek data size
	//---------------------------------------------------------------------
	/// Returns the size of the next segment in `rcv_queue`
	internal mutating func peekSize() -> Int {
		guard rcv_queue.isEmpty == false else {
			return -1
		}

        guard let firstNode = rcv_queue.front, let firstSeg = firstNode.value else {
        	return -1
        }
        if firstSeg.frg == 0 {
        	return Int(firstSeg.len)
        }
        if nrcv_que < UInt32(firstSeg.frg + 1) {
        	return -1
        }
        var total:Int = 0
		segLoop: for (_, seg) in rcv_queue.makeIterator() {
			total += Int(seg.len)
			guard seg.frg != 0 else {
				break segLoop
			}
		}
		return total
	}
	
	
	public mutating func send(_ inputPtr:UnsafePointer<UInt8>?, count len:Int) -> Int {
		guard mss > 0 else {
			return -1
		}
		guard len >= 0 else {
			return -1
		}
		var sent = 0
		var remaining = len
		var srcPtr:UnsafePointer<UInt8>? = inputPtr
		if stream == true {
			if let tailNode = snd_queue.back {
				var oldSeg = tailNode.value!
				if oldSeg.len < mss {
					let capacity = mss - oldSeg.len
					let extend = min(UInt32(remaining), capacity)
					let newSize = oldSeg.len + extend
					var seg = ikcp_segment(size:Int(oldSeg.len + extend))
					seg.data.baseAddress!.update(from:oldSeg.data.baseAddress!, count:Int(oldSeg.len))
					let encodedUpTo = (seg.data.baseAddress! + Int(oldSeg.len))
					if let src = srcPtr, extend > 0 {
						encodedUpTo.update(from:src, count:Int(extend))
						srcPtr = src + Int(extend)
					}
					seg.len = oldSeg.len + extend
					seg.frg = 0
					snd_queue.addTail(seg)
					remaining -= Int(extend)
					sent += Int(extend)
				}
			}
			
			guard remaining > 0 else {
				return sent
			}
		}
		
		var count:Int
		if remaining <= Int(mss) {
			count = 1
		} else {
			count = (remaining + Int(mss) - 1) / Int(mss)
		}
		
		guard UInt32(count) >= IKCP_WND_RCV else {
			guard stream == true && sent > 0 else {
				return -2
			}
			return sent	
		}
		if count == 0 {
			count = 1
		}
		
		for i in 0..<count {
			let fragSize = min(remaining, Int(mss))
			var seg = ikcp_segment(size:fragSize)
			if let src = srcPtr, remaining > 0 {
			
			}
			seg.len = UInt32(fragSize)
			if stream == true {
				seg.frg = 0
			} else {
				seg.frg = UInt8(count - i - 1)
			}
			snd_queue.addTail(seg)
			nsnd_que &+= 1
			
			remaining -= fragSize
			sent += fragSize
		}
		return sent
	}

	//---------------------------------------------------------------------
	// parse ack
	//---------------------------------------------------------------------
	/// Updates the RTT estimators and recalculates the Retransmission Timeout (RTO)
	internal mutating func updateAck(rtt: Int32) {
		if rx_srtt == 0 {
			rx_srtt = rtt
			rx_rttval = rtt / 2
		} else {
			var delta = rtt - rx_srtt
			if delta < 0 {
				delta = -delta
			}
			rx_rttval = ((3 * rx_rttval + delta) / 4)
			rx_srtt = (7 * rx_srtt + rtt)
			if rx_srtt < 1 {
				rx_srtt = 1
			}
		}
		
		// calculate the retransmission time
		let rtoUnbound:Int32 = Int32(rx_srtt) + Int32(imax(UInt32(interval), UInt32(4 * rx_rttval)))
		rx_rto = ibound(rx_minrto, rtoUnbound, Int32(IKCP_RTO_MAX))
	}
	
	/// Syncs `send_una` up to sync with the current contents of the `snd_buf`
	internal mutating func shrinkBuff() {
		if let node = snd_buf.front {
			snd_una = node.value!.sn
		} else {
			snd_una = snd_nxt
		}
	}

	/// Acknowledges a specific segment sn and removes if from the `snd_buff`
	internal mutating func parseAck(sn:UInt32) {
		guard itimeDiff(later:sn, earlier:snd_una) >= 0 && itimeDiff(later:sn, earlier:snd_nxt) < 0 else {
			return
		}
		segLoop: for (curNode, seg) in snd_buf.makeIterator() {
			guard seg.sn != sn else {
				snd_buf.remove(curNode)
				nsnd_buf &-= 1
				break segLoop
			}
			guard itimeDiff(later:sn, earlier:seg.sn) >= 0 else {
				break segLoop
			}
		}
	}
	
	/// Acknowledges all fragments with a `sn < una`
	internal mutating func parseUna(una: UInt32) {
		segLoop: for (curNode, seg) in snd_buf.makeIterator() {
			if itimeDiff(later:una, earlier:seg.sn) > 0 {
				snd_buf.remove(curNode)
				nsnd_buf &-= 1
			} else {
				break segLoop
			}
		}
	}
	
	/// Counts how many times a later packet was acknowledged while this segment wasn't
	internal mutating func parseFastAck(sn: UInt32, ts: UInt32) {
		guard itimeDiff(later:sn, earlier:snd_una) >= 0 && itimeDiff(later:sn, earlier:snd_nxt) < 0 else {
			return
		}
		segLoop: for (node, seg) in snd_buf.makeIterator() {
			guard itimeDiff(later:sn, earlier:seg.sn) < 0 else {
				break segLoop
			}
			if sn != seg.sn {
				#if FASTACK_CONSERVE
				if itimeDiff(ts, seg.ts) >= 0 {
					seg.fastack &+= 1
				}
				#else
				seg.fastack &+= 1
				#endif
			}
		}
	}
	
	//---------------------------------------------------------------------
	// ack append
	//---------------------------------------------------------------------
	/// Pushes an ACK onto the KCP's ACK list
	internal mutating func ackPush(sn: UInt32, ts: UInt32) {
		let newSize = ackcount + 1
		if newSize > ackblock {
			var newBlock:UInt32 = 8
			while newBlock < newSize {
				newBlock <<= 1
			}
			let newAcklistSize = Int(newBlock * 2)
			let newList = UnsafeMutableBufferPointer<UInt32>.allocate(capacity:newAcklistSize)
			for i in 0..<ackcount {
				newList[Int(i * 2)] = acklist[Int(i * 2)]
				newList[Int(i * 2) + 1] = acklist[Int(i * 2) + 1]
			}
			for i in Int(ackcount * 2)..<newAcklistSize {
				newList[i] = 0
			}
			ackblock = newBlock
			acklist = newList
		}
		let idx = Int(ackcount * 2)
		acklist[idx] = sn
		acklist[idx + 1] = ts
		ackcount &+= 1
	}
	
	internal func ackGet(p:Int, sn: inout UInt32, ts: inout UInt32) {
		guard p >= 0 && UInt32(p) < ackcount else {
			fatalError("invalid p index passed to ackGet")
		}
		let base = p * 2
		sn = acklist[base]
		ts = acklist[base + 1]
	}
	
	//---------------------------------------------------------------------
	// parse data
	//---------------------------------------------------------------------
	/// Called every time data is received. Removes out-of-window or duplicate segments, insert new segments into `rec_buf`, and moves in order segments to `rec_queue`
	internal mutating func parseData(_ newseg: ikcp_segment) {
		let sn = newseg.sn
		var isDuplicate = false
		guard itimeDiff(later:sn, earlier:rcv_nxt &+ rcv_wnd) < 0, itimeDiff(later:sn, earlier:rcv_nxt) >= 0 else {
			return
		}
		
		var insertAfterNode:LinkedList<ikcp_segment>.Node? = nil
		segLoop: for (curNode, seg) in rcv_buf.makeReverseIterator() {
			guard seg.sn != sn else {
				isDuplicate = true
				break segLoop
			}
			guard itimeDiff(later:sn, earlier:seg.sn) <= 0 else {
				insertAfterNode = curNode
				break segLoop
			}
		}
		if isDuplicate == false {
			if let anchor = insertAfterNode {
				rcv_buf.insert(newseg, after:anchor)
			} else {
				rcv_buf.add(newseg)
			}
			nrcv_buf &+= 1
		}
		while let firstNode = rcv_buf.front, firstNode.value!.sn == rcv_nxt && nrcv_que < rcv_wnd {
			rcv_buf.remove(firstNode)
			nrcv_buf &-= 1
			rcv_queue.addTail(firstNode)
			nrcv_que &+= 1
			rcv_nxt &+= 1
		}
	}
	
	public mutating func input(_ inputPtr:UnsafePointer<UInt8>, count:Int) -> Int {
		let prevUna = snd_una
		var maxAck:UInt32 = 0
		var latestTS:UInt32 = 0
		var gotAck = false
		guard count >= IKCP_OVERHEAD else {
			return -1
		}
		
		var ptr:UnsafeRawPointer = UnsafeRawPointer(inputPtr)
		var left = count
		while left >= IKCP_OVERHEAD {
			let conv = decodeUInt32(&ptr)
			guard conv == self.conv else {
				return -1
			}
			let cmd = decodeUInt8(&ptr)
			let frg = decodeUInt8(&ptr)
			let wnd = decodeUInt16(&ptr)
			let ts = decodeUInt32(&ptr)
			let sn = decodeUInt32(&ptr)
			let una = decodeUInt32(&ptr)
			let len = decodeUInt32(&ptr)
			left -= Int(IKCP_OVERHEAD)
			guard left >= Int(len) && len >= 0 else {
				return -2
			}
			rmt_wnd = UInt32(wnd)
			parseUna(una:una)
			shrinkBuff()
			switch cmd {
				case IKCP_CMD_ACK:
					if itimeDiff(later:current, earlier:ts) >= 0 {
						updateAck(rtt:itimeDiff(later:current, earlier:ts))
					}
					parseAck(sn:sn)
					shrinkBuff()
					if gotAck == false {
						gotAck = true
						maxAck = sn
						latestTS = ts
					} else if itimeDiff(later:sn, earlier:maxAck) > 0 {
						#if FASTACK_CONSERVE
						if itimeDiff(ts, latestTS) > 0 {
							maxAck = sn
							latestTS = ts
						}
						#else
						maxAck = sn
						latestTS = ts
						#endif
					}
				case IKCP_CMD_PUSH:
					if itimeDiff(later:sn, earlier:rcv_nxt + rcv_wnd) < 0 {
						ackPush(sn:sn, ts:ts)
						if itimeDiff(later:sn, earlier:rcv_nxt) >= 0 {
							let seg = ikcp_segment(size:Int(len))
							seg.conv = conv
							seg.cmd = cmd
							seg.frg = frg
							seg.wnd = wnd
							seg.ts = ts
							seg.sn = sn
							seg.una = una
							seg.len = len
							if len > 0 {
								seg.data.baseAddress!.update(from:ptr.assumingMemoryBound(to:UInt8.self), count:Int(len))
							}
							parseData(seg)
						}
					}
				case IKCP_CMD_WASK:
					probe |= IKCP_ASK_TELL
				case IKCP_CMD_WINS:
					// nothing to do here
					break;
				default:
					return -3
			}
			ptr = ptr.advanced(by:Int(len))
			left -= Int(len)
		}
		if gotAck {
			parseFastAck(sn:maxAck, ts:latestTS)
		}
		if itimeDiff(later:snd_una, earlier:prevUna) > 0 {
			if cwnd < rmt_wnd {
				let mss = self.mss
				if cwnd < ssthresh {
					cwnd &+= 1
					incr &+= mss
				} else {
					if incr < mss {
						incr = mss
					}
					incr &+= (mss * mss) / incr + (mss / 16)
					if ((cwnd &+ 1) &* mss <= incr) {
						cwnd = (incr &+ mss &- 1) / (mss > 0 ? mss : 1)
					}
				}
				
				if cwnd > rmt_wnd {
					cwnd = rmt_wnd
					incr = rmt_wnd &* mss
				}
			}
		}
		return 0
	}
	
	//---------------------------------------------------------------------
	// ikcp_encode_seg
	//---------------------------------------------------------------------
	/// Encodes a KCP segment into an array of bytes
	internal static func encodeSegment(seg: ikcp_segment, _ outputPtr:UnsafeMutablePointer<UInt8>) -> Int {
		var off = encodeUInt32(seg.conv, outputPtr)
		off = encodeUInt8(seg.cmd, off)
		off = encodeUInt8(seg.frg, off)
		off = encodeUInt16(seg.wnd, off)
		off = encodeUInt32(seg.ts, off)
		off = encodeUInt32(seg.sn, off)
		off = encodeUInt32(seg.una, off)
		off = encodeUInt32(seg.len, off)
		off.update(from:seg.data.baseAddress!, count:Int(seg.len))
		off += Int(seg.len)
		return outputPtr.distance(to:off)
	}
	
	internal func wndUnused() -> UInt16 {
		if (nrcv_que < rcv_wnd) {
			return UInt16(rcv_wnd - nrcv_que)
		}
		return 0
	}
	
	internal mutating func flush() { 
		guard updated != 0 else {
			return
		}
		var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity:Int(mtu))
		buffer.initialize(repeating:0, count:Int(mtu))
		defer {
			buffer.deallocate()
		}
		var ptrOffset = 0
		var seg = ikcp_segment(size:0)
		seg.conv = conv
		seg.cmd = IKCP_CMD_ACK
		seg.frg = 0
		seg.wnd = wndUnused()
		seg.una = rcv_nxt
		seg.len = 0
		seg.sn = 0
		seg.ts = 0
		for i in 0..<ackcount {
			let needed = ptrOffset + Int(IKCP_OVERHEAD)
			if needed > Int(mtu) {
				if output != nil {
					output!(UnsafeMutableBufferPointer<UInt8>(start:buffer, count:ptrOffset))
				} else {
					// log a warning or something?
				}
				ptrOffset = 0
			}
			var sn:UInt32 = 0
			var ts:UInt32 = 0
			ackGet(p:Int(i), sn:&sn, ts:&ts)
			ptrOffset += Self.encodeSegment(seg:seg, buffer + ptrOffset)
		}
		ackcount = 0
		
		if rmt_wnd == 0 {
			if probe_wait == 0 {
				probe_wait = IKCP_PROBE_INIT
			} else if itimeDiff(later:current, earlier:ts_probe) >= 0 {
				if probe_wait < IKCP_PROBE_INIT {
					probe_wait = IKCP_PROBE_INIT
				}
				probe_wait += probe_wait / 2
				if probe_wait > IKCP_PROBE_LIMIT {
					probe_wait = IKCP_PROBE_LIMIT
				}
				ts_probe = current + probe_wait
				probe |= IKCP_ASK_SEND
			}
		} else {
			ts_probe = 0
			probe_wait = 0
		}
		
		if (probe & IKCP_ASK_SEND) != 0 {
			seg.cmd = IKCP_CMD_WASK
			if ptrOffset + Int(IKCP_OVERHEAD) > Int(mtu) {
				if output != nil {
					output!(UnsafeMutableBufferPointer(start:buffer, count:ptrOffset))
				} else {
					// log a warning or something?
				}
				ptrOffset = 0
			}
			ptrOffset = Self.encodeSegment(seg:seg, buffer + ptrOffset)
		}
		if (probe & IKCP_ASK_TELL) != 0 {
			seg.cmd = IKCP_CMD_WINS
			if ptrOffset + Int(IKCP_OVERHEAD) > Int(mtu) {
				if output != nil {
					output!(UnsafeMutableBufferPointer(start:buffer, count:ptrOffset))
				} else {
					// log a warning or something?
				}
			}
		}
		probe = 0
		
		var cwnd = min(snd_wnd, rmt_wnd)
		if nocwnd == 0 {
			cwnd = min(cwnd, self.cwnd)
		}
		
		seekLoop: while itimeDiff(later:snd_nxt, earlier:snd_una &+ cwnd) < 0 {
			guard let node = snd_queue.front else { break seekLoop }
			snd_queue.remove(node)
			snd_buf.addTail(node)
			nsnd_que -= 1
			nsnd_buf += 1
			
			let newSeg = node.value!
			newSeg.conv = conv
			newSeg.cmd = IKCP_CMD_PUSH
			newSeg.wnd = seg.wnd
			newSeg.ts = current
			newSeg.sn = snd_nxt
			snd_nxt &+= 1
			newSeg.una = rcv_nxt
			newSeg.resendts = current
			newSeg.rto = UInt32(rx_rto)
			newSeg.fastack = 0
			newSeg.xmit = 0
		}
		
		let resent:UInt32 = fastresend > 0 ? UInt32(fastresend) : UInt32.max
		let rtomin:UInt32 = nodelay == 0 ? UInt32(rx_rto) >> 3 : 0
		
		var change = false
		var lost = false
		
		for (node, seg) in snd_buf.makeIterator() {
			var needsend = false
			if seg.xmit == 0 {
				needsend = true
				seg.xmit = 1
				seg.rto = UInt32(rx_rto)
				seg.resendts = current &+ seg.rto &+ rtomin
			} else if itimeDiff(later:current, earlier:seg.resendts) >= 0 {
				needsend = true
				seg.xmit &+= 1
				xmit &+= 1
				if nodelay == 0 {
					seg.rto = seg.rto &+ max(UInt32(seg.rto), UInt32(rx_rto))
				} else {
					let step:UInt32 = (nodelay < 2) ? seg.rto : UInt32(rx_rto)
					seg.rto = seg.rto &+ step / 2
				}
				seg.resendts = current &+ seg.rto
                lost = true
			} else if seg.fastack >= resent {
				// fast‑retransmit (duplicate ACKs)
				if Int32(seg.xmit) <= fastlimit || fastlimit <= 0 {
					needsend = true
					seg.xmit &+= 1
					seg.fastack = 0
					seg.resendts = current &+ seg.rto
					change = true
				}
			}
			
			if needsend {
				seg.ts = current
				seg.una = rcv_nxt
				let need = Int(IKCP_OVERHEAD) + Int(seg.len)
				if ptrOffset + need > Int(mtu) {
					if output != nil {
						output!(UnsafeMutableBufferPointer(start:buffer, count:ptrOffset))
					} else {
						 // log a warning or something?
					}
					ptrOffset = 0
				}
				
				ptrOffset += Self.encodeSegment(seg:seg, buffer + ptrOffset)
				
				if seg.len > 0 {
					(buffer + ptrOffset).update(from:seg.data.baseAddress!, count:Int(seg.len))
					ptrOffset += Int(seg.len)
				}
				
				if seg.xmit >= dead_link {
					state = UInt32(bitPattern:Int32(-1))
				}
			}
		}
		
		if ptrOffset > 0 {
			if output != nil {
				output!(UnsafeMutableBufferPointer(start:buffer, count:ptrOffset))
			} else {
				// log a warning or something?
			}
		}
		
		if change == true {
			let inflight = snd_nxt &- snd_una
			ssthresh = inflight / 2
			if ssthresh < IKCP_THRESH_MIN { ssthresh = IKCP_THRESH_MIN }
            cwnd = ssthresh &+ resent
            incr = cwnd &* mss
		}
		
		if lost == true {
			ssthresh = cwnd / 2
			if ssthresh < IKCP_THRESH_MIN { ssthresh = IKCP_THRESH_MIN }
			cwnd = 1
			incr = mss
		}
		if cwnd < 1 {
			cwnd = 1
			incr = mss
		}
	}
	
	public mutating func update(current:UInt32) {
		self.current = current
		if updated == 0 {
			updated = 1
			ts_flush = current
		}
		var slap = itimeDiff(later:current, earlier:ts_flush)
		if slap >= 10_000 || slap < -10_000 {
			ts_flush = current
			slap = 0
		}
		guard slap >= 0 else { return }
		ts_flush &+= interval
		if itimeDiff(later:current, earlier:ts_flush) >= 0 {
			ts_flush = current &+ interval
		}
		flush()
	}
	
	public mutating func check(current:UInt32) -> UInt32 {
		guard updated != 0 else {
			return current
		}
		var tsFlush = ts_flush
		if itimeDiff(later:current, earlier:tsFlush) >= 10_000 || itimeDiff(later:current, earlier:tsFlush) < -10_000 {
			tsFlush = current
		}
		guard itimeDiff(later:current, earlier:tsFlush) < 0 else {
			return current
		}
		var tmFlush:Int32 = itimeDiff(later:tsFlush, earlier:current)
		var tmPacket:Int32 = Int32.max
		for (_, seg) in snd_buf.makeIterator() {
			let diff = itimeDiff(later:seg.resendts, earlier:current)
			guard diff > 0 else {
				return current
			}
			if diff < tmPacket {
				tmPacket = diff
			}
		}
		var minimal = UInt32(min(tmPacket, tmFlush))
		if minimal >= interval {
			minimal = interval
		}
		return current &+ minimal
	}
	
	public struct InvalidMTUError:Swift.Error {}
	public mutating func setMTU(_ mtu:Int) throws(InvalidMTUError) {
		if mtu > 0 {
			buffer.deallocate()
		}
		guard mtu >= 50, mtu >= Int(IKCP_OVERHEAD) else {
			throw InvalidMTUError()
		}
		let needed = (mtu + Int(IKCP_OVERHEAD))
		let newBuf = UnsafeMutablePointer<UInt8>.allocate(capacity:needed)
		self.mtu = UInt32(mtu)
		self.mss = UInt32(mtu) - IKCP_OVERHEAD
		self.buffer = newBuf
	}
	
	@discardableResult
	mutating func setInterval(_ interval: Int) {
		var iv = interval
		if iv > 5_000 {
			iv = 5_000
		} else if iv < 10 {
			iv = 10
		}
		self.interval = UInt32(iv)
	}
	
	/* @discardableResult
    mutating func setNoDelay(_ nodelay: Int,
                             interval: Int,
                             resend: Int,
                             nc: Int) -> Int {

        // nodelay flag
        if nodelay >= 0 {
            self.nodelay = UInt32(nodelay)
            self.rx_minrto = (nodelay != 0) ? IKCP_RTO_NDL : IKCP_RTO_MIN
        }

        // interval (same clamping as ikcp_interval)
        if interval >= 0 {
            var iv = interval
            if iv > 5_000 { iv = 5_000 }
            else if iv < 10 { iv = 10 }
            self.interval = UInt32(iv)
        }

        // fast resend
        if resend >= 0 {
            self.fastresend = Int64(resend)
        }

        // no congestion‑window
        if nc >= 0 {
            self.nocwnd = Int64(nc)
        }

        return 0
    }*/
}
