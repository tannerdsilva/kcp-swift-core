

extension Array where Element == UInt8 {

	/// Return a UInt32 read at `offset` (little‑endian).
	func readUInt32(at offset: Int) -> UInt32 {
		let b0 = UInt32(self[offset + 0])
		let b1 = UInt32(self[offset + 1])
		let b2 = UInt32(self[offset + 2])
		let b3 = UInt32(self[offset + 3])
		return (b0 << 0) | (b1 << 8) | (b2 << 16) | (b3 << 24)
	}

	/// Return a UInt16 read at `offset` (little‑endian).
	func readUInt16(at offset: Int) -> UInt16 {
		let b0 = UInt16(self[offset + 0])
		let b1 = UInt16(self[offset + 1])
		return (b0 << 0) | (b1 << 8)
	}

	/// Return a single byte at `offset`.
	func readUInt8(at offset: Int) -> UInt8 {
		return self[offset]
	}

	/// Return a slice of `count` bytes starting at `offset`.
	func slice(at offset: Int, count: Int) -> [UInt8] {
		return Array(self[offset ..< offset + count])
	}
}

func encode32(_ val: UInt32, into buffer: inout [UInt8]) {
	buffer.append(UInt8(val & 0xFF))
	buffer.append(UInt8((val >> 8)  & 0xFF))
	buffer.append(UInt8((val >> 16) & 0xFF))
	buffer.append(UInt8((val >> 24) & 0xFF))
}

func encode16(_ val: UInt16, into buffer: inout [UInt8]) {
	buffer.append(UInt8(val & 0xFF))
	buffer.append(UInt8((val >> 8) & 0xFF))
}

func encode8(_ val: UInt8,  into buffer: inout [UInt8]) {
	buffer.append(val)
}

fileprivate func ibound(lower: Int32, middle: Int32, upper: Int32) -> Int32 {
	return min(max(lower, middle), upper)
}

fileprivate func timeDiff(later: UInt32, earlier: UInt32) -> Int32 {
	return Int32(Int32(later) - Int32(earlier))
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

internal struct ikcp_segment {
	// internal var node:iqueue_head
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
	internal var data:[UInt8]			// Slice of data being transmitted
	
	init(size:Int) {
		self.data = [UInt8](repeating: 0, count: size)
	}
	
	init() {
		self.data = []
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

	internal var snd_queue:[ikcp_segment]	// user data waiting to be segmented and sent out
	internal var rcv_queue:[ikcp_segment]	// Fully reassembled segments ready to return to application
	internal var snd_buf:[ikcp_segment]		// Segments sent and waiting to be ACKed
	internal var rcv_buf:[ikcp_segment]		// Segments received out of oder and waiting to be reassembled

	internal var acklist:[UInt32]
	internal var ackcount:UInt32
	internal var ackblock:UInt32

	internal var user:UnsafeMutableRawPointer?			// stores context (like socket or channel)

	internal var fastresend:Int64
	
	internal var fastlimit:Int64

	internal var nocwnd:Int64
	
	public var stream:Bool
	public var synchronous:Bool

	public init(conv:UInt32, user:UnsafeMutableRawPointer?, synchronous:Bool = false) {
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

		self.snd_queue = []
		self.rcv_queue = []
		self.snd_buf = []
		self.rcv_buf = []

		self.acklist = []
		self.ackcount = 0
		self.ackblock = 0

		self.user = user

		self.fastresend = 0
		self.fastlimit = Int64(IKCP_FASTACK_LIMIT)
		self.nocwnd = 0
		
		self.stream = false
		self.synchronous = synchronous
	}
	enum Error:Swift.Error {
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
	public mutating func receive(isPeek:Bool = false) throws -> [UInt8]? {
		var buffer:[UInt8] = []
		var recover = false
		var seg:ikcp_segment
		
		// Early exit if the queue is empty
		guard rcv_queue.isEmpty == false else {
			return nil
		}
		
		// Determine message size
		let peekedSize = try peekSize()
		
		// If queue is longer than the receive window, enter recovery mode
		if (self.rcv_queue.count >= self.rcv_wnd && synchronous == false) {
			recover = true
		}
		
		// Iterates through the receive queue and assembles the fragments of the message
		var len = 0
		let fragmentCount:Int = Int(rcv_queue[0].frg)+1
		for i in 0..<rcv_queue.count {
			seg = rcv_queue[i]
			
			for j in 0..<Int(seg.len) {
				buffer.append(seg.data[j])
			}
			
			len += Int(seg.len)
			
			if(seg.frg == 0) {
				break
			}
		}
		
		guard len == peekedSize else {
			throw Error.peekedSizeGreaterThanInputCount
		}
		
		if(isPeek == false) {
			rcv_queue = Array(rcv_queue.dropFirst(fragmentCount))
			nrcv_que -= UInt32(fragmentCount)
		}
		
		// Move available data from the rcv_buf -> rcv_queue
		while(rcv_buf.isEmpty == false) {
			seg = rcv_buf[0]
			if(seg.sn == rcv_nxt && (nrcv_que < rcv_wnd || synchronous)) {
				rcv_buf.remove(at: 0)
				nrcv_buf -= 1
				rcv_queue.append(seg)
				nrcv_que += 1
				rcv_nxt += 1
			} else {
				break
			}
		}
		
		// Fast recovery
		if(nrcv_que < rcv_wnd && recover) {
			probe |= IKCP_ASK_TELL
		}
		
		return buffer
	}

	//---------------------------------------------------------------------
	// peek data size
	//---------------------------------------------------------------------
	/// Returns the size of the next segment in `rcv_queue`
	internal mutating func peekSize() throws -> Int {
		guard rcv_queue.isEmpty == false else {
			throw Error.rcvQueueEmpty
		}
		let seg = rcv_queue.first!
		guard seg.frg != 0 else {
			return Int(seg.len)
		}
		guard rcv_queue.count >= seg.frg + 1 else {
			throw Error.rcvQueueLessThanFrg
		}
		var length:Int = 0
		segLoop: for seg in rcv_queue {
			length += seg.data.count
			guard seg.frg != 0 else {
				break segLoop
			}
		}
		return length
	}
	
	//---------------------------------------------------------------------
	// user/upper level send
	//---------------------------------------------------------------------
	/// Takes an array of bytes and splits it into KCP segments which get put into the `snd_queue`
	public mutating func send(buffer: inout [UInt8], _len:Int) -> Int {
		var len = _len
		var sent = 0
		var count = 0
		
		if(len < 0) { return -1 }
		
		// For streaming. We try to extend last segment
		if(stream) {
			if(!snd_queue.isEmpty) {
				let old = self.snd_queue.last!
				if(old.len < mss) {
					snd_queue.removeLast()
	
					let capacity = mss - old.len
					let extend = (len < capacity) ? len : Int(capacity)
					var seg = ikcp_segment(size: Int(old.data.count + extend))
					
					for i in 0..<Int(old.len) {
						seg.data[i] = old.data[i]
					}
					
					if(buffer.count != 0) {
						for i in 0..<extend {
							seg.data[i+Int(old.len)] = buffer[i]
						}
						buffer = Array(buffer.dropFirst(extend))
					}
					
					seg.len = old.len + UInt32(extend)
					seg.frg = 0
					snd_queue.append(seg)

					len -= extend
					sent = extend
				}
			}
		}
		
		if(len<=0) {
			return sent
		}
		
		if(len <= mss) { count = 1 }
		else { count = (len + Int(mss) - 1) / Int(mss) }
		
		if(count >= IKCP_WND_RCV && synchronous == false) {
			if(stream != false && sent > 0) {
				return sent
			}
			return -2
		}
		
		if(count == 0) { count = 1 }
		
		// Fragment
		for i in 0..<count {
			// Determine the size of the segment
			let size = len > mss ? Int(mss) : len
			// Create the segment
			var seg = ikcp_segment(size: size)
			
			// Copy piece of buffer into kcp segment
			if(len > 0) {
				for j in 0..<size {
					seg.data[j] = buffer[j+sent]
				}
			}
			seg.len = UInt32(size)
			seg.frg = (stream == false) ? UInt8(count - i - 1) : 0
			
			snd_queue.append(seg)
			
			nsnd_que += 1
			
			len -= size
			sent += size
		}
		
		buffer.removeFirst(sent)
		
		return sent
	}
	
	//---------------------------------------------------------------------
	// parse ack
	//---------------------------------------------------------------------
	/// Updates the RTT estimators and recalculates the Retransmission Timeout (RTO)
	internal mutating func updateAck(rtt: Int32) {
		var rto = 0
		if(rx_srtt == 0) {
			rx_srtt = rtt
			rx_rttval = rtt / 2
		} else {
			var delta = rtt - rx_srtt
			if(delta < 0) { delta = -delta }
			rx_rttval = (3 * rx_rttval + delta) / 4
			rx_srtt = (7 * rx_srtt + rtt) / 8
			if(rx_srtt < 1) { rx_srtt = 1 }
		}
		rto = Int(rx_srtt + max(Int32(interval), 4 * rx_rttval))
		rx_rto = ibound(lower: rx_minrto, middle: Int32(rto), upper: Int32(IKCP_RTO_MAX))
	}
	
	/// Syncs `send_una` up to sync with the current contents of the `snd_buf`
	internal mutating func shrinkBuff() {
		if(!snd_buf.isEmpty) {
			let seg = snd_buf.first!
			snd_una = seg.sn
		} else {
			snd_una = snd_nxt
		}
	}
	
	/// Acknowledges a specific segment sn and removes if from the `snd_buff`
	internal mutating func parseAck(sn:UInt32) {
		if(timeDiff(later: sn, earlier: snd_una) < 0 || timeDiff(later: sn, earlier: snd_nxt) >= 0) { return }
		
		for i in 0..<snd_buf.count {
			let seg = snd_buf[i]
			if(sn == seg.sn) {
				snd_buf.remove(at: i)
				nsnd_buf -= 1
				break
			}
			if(timeDiff(later: sn, earlier: seg.sn) < 0) { break }
		}
	}
	
	/// Acknowledges all fragments with a `sn < una`
	internal mutating func parseUna(una: UInt32) {
		for i in (0..<snd_buf.count).reversed() {
			let seg = snd_buf[i]
			if(timeDiff(later: una, earlier: seg.sn) > 0) {
				snd_buf.remove(at: i)
				nsnd_buf -= 1
			} else {
				break
			}
		}
	}
	
	/// Counts how many times a later packet was acknowledged while this segment wasn't
	internal mutating func parseFastAck(sn: UInt32, ts: UInt32) {
		if(timeDiff(later: sn, earlier: snd_una) < 0) || timeDiff(later: sn, earlier: snd_nxt) >= 0 { return }
		
		for i in 0..<snd_buf.count {
			var seg = snd_buf[i]
			if(timeDiff(later: sn, earlier: seg.sn) < 0) { break }
			else if (sn != seg.sn) {
				seg.fastack += 1
			}
		}
	}
	
	//---------------------------------------------------------------------
	// ack append
	//---------------------------------------------------------------------
	/// Pushes an ACK onto the KCP's ACK list
	internal mutating func ackPush(sn: UInt32, ts: UInt32) {
		let newsize = ackcount + 1
		
		if(newsize > ackblock) {
			var newblock = UInt32(8)
			while(newblock < newsize) {
				newblock <<= 1
			}
			var acklist = Array<UInt32>(repeating: 0, count: Int(newblock*2))
			
			if self.acklist.count != 0 {
				for i in 0..<Int(ackcount) {
					acklist[i*2]   = self.acklist[i*2]
					acklist[i*2+1] = self.acklist[i*2+1]
				}
			}
			
			self.acklist = acklist
			self.ackblock = newblock
		}
		self.acklist[Int(ackcount) * 2] = sn
		self.acklist[Int(ackcount) * 2 + 1] = ts
		ackcount += 1
	}
	
	internal func ackGet(p:Int, sn: inout UInt32, ts: inout UInt32) {
		sn = acklist[p * 2]
		ts = acklist[p * 2 + 1]
	}
	
	//---------------------------------------------------------------------
	// parse data
	//---------------------------------------------------------------------
	/// Called every time data is received. Removes out-of-window or duplicate segments, insert new segments into `rec_buf`, and moves in order segments to `rec_queue`
	internal mutating func parseData(newSeg: ikcp_segment) {
		let sn = newSeg.sn
		var isDuplicate = false
		
		if(timeDiff(later: sn, earlier: rcv_nxt &+ rcv_wnd) >= 0 ||
		   timeDiff(later: sn, earlier: rcv_nxt) < 0) {
			return
		}
		
		// Default insert is the end
		var insertIdx:Int = rcv_buf.count
		
		// Find the index it should be inserted into
		for (revIdx, seg) in rcv_buf.reversed().enumerated() {
			// The segment already exists
			if(seg.sn == sn) {
				isDuplicate = true
				break
			}
			// When a segment with smaller sn is found, the new segment goes after it
			if(timeDiff(later: sn, earlier: seg.sn) > 0) {
				insertIdx = rcv_buf.count - revIdx
				break
			}
		}
		
		if(!isDuplicate) {
			rcv_buf.insert(newSeg, at: insertIdx)
			nrcv_buf += 1
		} else {
			return
		}
		
		// Promote any in-order segments to the ready queue
		// Move available data from the rcv_buf -> rcv_queue
		while(rcv_buf.isEmpty == false) {
			let seg = rcv_buf[0]
			if(seg.sn == rcv_nxt && (nrcv_que < rcv_wnd || synchronous)) {
				rcv_buf.remove(at: 0)
				nrcv_buf -= 1
				rcv_queue.append(seg)
				nrcv_que += 1
				rcv_nxt += 1
			} else {
				break
			}
		}
	}
	
	//---------------------------------------------------------------------
	// input data
	//---------------------------------------------------------------------
	/// Recieves raw bytes and encodes them into KCP segments
	public mutating func input(data: [UInt8]) -> Int {
		let prevUna = snd_una
		var maxack = 0; var latest_ts = 0
		var flag = false
		
		guard data.count >= IKCP_OVERHEAD else {
			return -1
		}
		
		if(data.isEmpty) { return -2 }
		var pos = 0
		while(pos + Int(IKCP_OVERHEAD) <= data.count) {
			
			// Read in all header fields and make sure the conversation matches
			let conv = data.readUInt32(at: pos)
			pos += 4
			guard conv == self.conv else { return -1 }
			let cmd = data.readUInt8(at: pos)
			pos += 1
			let frg = data.readUInt8(at: pos)
			pos += 1
			let wnd = data.readUInt16(at: pos)
			pos += 2
			let ts = data.readUInt32(at: pos)
			pos += 4
			let sn = data.readUInt32(at: pos)
			pos += 4
			let una = data.readUInt32(at: pos)
			pos += 4
			let len = data.readUInt32(at: pos)
			pos += 4
			
			// Make sure the remaining payload fits
			guard data.count - pos >= Int(len) else { return -2 }

			rmt_wnd = UInt32(wnd)
			parseUna(una: una)
			shrinkBuff()
			
			switch(cmd) {
				// Ack command segment
				case IKCP_CMD_ACK:
					if(timeDiff(later: current, earlier: ts) >= 0) {
						updateAck(rtt: timeDiff(later: current, earlier: ts))
					}
					
					parseAck(sn: sn)
					shrinkBuff()
					if(!flag) {
						flag = true
						maxack = Int(sn)
						latest_ts = Int(ts)
					} else {
						if(timeDiff(later: sn, earlier: UInt32(maxack)) > 0) {
							maxack = Int(sn)
							latest_ts = Int(ts)
						}
					}
				// Push command segment
				case IKCP_CMD_PUSH:
					if(timeDiff(later: sn, earlier: rcv_nxt + rcv_wnd) < 0) {
						ackPush(sn: sn, ts: ts)
						if(timeDiff(later: sn, earlier: rcv_nxt) >= 0) {
							// Create the new segment
							var seg = ikcp_segment(size: Int(len))
							seg.conv = conv
							seg.cmd = cmd
							seg.frg = frg
							seg.wnd = wnd
							seg.ts = ts
							seg.sn = sn
							seg.una = una
							seg.len = len
							seg.data = data.slice(at: pos, count: Int(len))
							
							// Push it
							parseData(newSeg: seg)
						}
					}
				// Remote wants our window size, so we will send it
				case IKCP_CMD_WASK:
					if(synchronous == false) {
						probe |= IKCP_ASK_TELL
					}
				// Remote sent its window size, do nothing else
				case IKCP_CMD_WINS:
					break
				default:
					return -3
			}
			
			// Move past payload
			pos += Int(len)
		}
		
		if(flag) {
			parseFastAck(sn: UInt32(maxack), ts: UInt32(latest_ts))
		}
		
		if(timeDiff(later: snd_una, earlier: prevUna) > 0) {
			if(cwnd < rmt_wnd) {
				if(cwnd < ssthresh) {
					cwnd += 1
					incr += mss
				} else {
					if(incr < mss) { incr = mss }
					incr += (mss * mss) / incr + (mss / 16)
					if((cwnd + 1) * mss <= incr) {
						cwnd = (incr + mss - 1) / ((mss > 0) ? mss : 1)
					}
				}
				if(cwnd > rmt_wnd) {
					cwnd = rmt_wnd
					incr = rmt_wnd * mss
				}
			}
		}
		return 0
	}
	
	//---------------------------------------------------------------------
	// ikcp_encode_seg
	//---------------------------------------------------------------------
	/// Encodes a KCP segment into an array of bytes
	internal func encodeSegment(seg: ikcp_segment) -> [UInt8] {
		var buffer: [UInt8] = []
		
		encode32(seg.conv, into: &buffer)
		encode8(UInt8(seg.cmd), into: &buffer)
		encode8(UInt8(seg.frg), into: &buffer)
		encode16(UInt16(seg.wnd), into: &buffer)
		encode32(seg.ts, into: &buffer)
		encode32(seg.sn, into: &buffer)
		encode32(seg.una, into: &buffer)
		encode32(seg.len, into: &buffer)
		buffer.append(contentsOf: seg.data)
		
		return buffer
	}
	
	internal func wndUnused() -> UInt16 {
		if(nrcv_que < rcv_wnd) {
			return UInt16(rcv_wnd - nrcv_que)
		}
		return 0
	}
	
	//---------------------------------------------------------------------
	// ikcp_flush
	//---------------------------------------------------------------------
	/// Flushes segments to an array of segments ready to send through the network
	internal mutating func flush(output:(([UInt8]) -> Void)?) {
		let current = current; var lost = false
		var change = 0
		var buffer = [UInt8](repeating: 0, count: Int(mtu))
		guard output != nil else { return }
		
		if (updated == 0 && synchronous == false) { return }
		
		var seg = ikcp_segment()
		seg.conv = conv
		seg.cmd = IKCP_CMD_ACK
		seg.frg = 0
		seg.wnd = wndUnused()
		seg.una = rcv_nxt
		seg.len = 0
		seg.sn = 0
		seg.ts = 0
		
		// Flush acknowledges
		for i in 0..<Int(ackcount) {
			// pull stored sn/ts for this ack
			ackGet(p: i, sn: &seg.sn, ts: &seg.ts)
			
			// write the ACK header
			buffer = encodeSegment(seg: seg)
			output!(buffer)
		}
		
		ackcount = 0
		
		if(synchronous == false) {
			// Probe the window size if remote window size is 0
			if(rmt_wnd == 0) {
				if(probe_wait == 0) {
					probe_wait = IKCP_PROBE_INIT
					ts_probe = current + probe_wait
				} else {
					if(timeDiff(later: current, earlier: ts_probe) >= 0) {
						if(probe_wait < IKCP_PROBE_INIT) { probe_wait = IKCP_PROBE_INIT }
						probe_wait += probe_wait / 2
						if(probe_wait > IKCP_PROBE_LIMIT) { probe_wait = IKCP_PROBE_LIMIT }
						ts_probe = current + probe_wait
						probe |= IKCP_ASK_SEND
					}
				}
			} else {
				ts_probe = 0
				probe_wait = 0
			}
			
			// Flush window probing commands
			if(probe & IKCP_ASK_SEND) != 0 {
				seg.cmd = IKCP_CMD_WASK
				output!(encodeSegment(seg: seg))
			}
			
			if(probe & IKCP_ASK_TELL) != 0 {
				seg.cmd = IKCP_CMD_WINS
				output!(encodeSegment(seg: seg))
			}
			
			probe = 0
			
			// Calculate window size
			cwnd = min(snd_wnd, rmt_wnd)
			if(nocwnd == 0) { cwnd = min(self.cwnd, cwnd) }
		}
		
		// Move data from send queue to send buf
		while(timeDiff(later: snd_nxt, earlier: snd_una + cwnd) < 0 || synchronous) {
			if snd_queue.isEmpty { break }
			var newSeg = snd_queue.removeFirst()
			
			newSeg.conv = conv
			newSeg.cmd = IKCP_CMD_PUSH
			newSeg.wnd = seg.wnd
			newSeg.ts = current
			newSeg.sn = snd_nxt
			snd_nxt += 1
			newSeg.una = rcv_nxt
			newSeg.resendts = current
			newSeg.rto = UInt32(rx_rto)
			newSeg.fastack = 0
			newSeg.xmit = 0
			
			snd_buf.append(newSeg)
			nsnd_que -= 1
			nsnd_buf += 1
		}
		
		let resent = (fastresend > 0) ? fastresend : 0xffffffff
		let rtomin = (nodelay == 0) ? (rx_rto >> 3) : 0
		
		for i in 0..<Int(nsnd_buf) {
			var segment = snd_buf[i]
			var needSend = false
			// Basic transmit
			if(segment.xmit == 0) {
				needSend = true
				segment.xmit += 1
				segment.rto = UInt32(rx_rto)
				segment.resendts = current + segment.rto + UInt32(rtomin)
			}
			// Timeout transmit
			else if (timeDiff(later: current, earlier: segment.resendts) >= 0) {
				needSend = true
				segment.xmit += 1
				self.xmit += 1
				if(nodelay == 0) {
					segment.rto += max(segment.rto, UInt32(self.rx_rto))
				} else {
					let step = (nodelay < 2) ? Int32(segment.rto) : rx_rto
					segment.rto += UInt32(step / 2)
				}
				segment.resendts = current + segment.rto
				lost = true
			}
			// Fast retransmission
			else if (segment.fastack >= resent) {
				if(segment.xmit <= fastlimit || fastlimit <= 0) {
					needSend = true
					segment.xmit += 1
					segment.fastack = 0
					segment.resendts = current + segment.rto
					change += 1
				}
			}
			
			if(needSend) {
				segment.ts = current
				segment.wnd = seg.wnd
				segment.una = rcv_nxt
				snd_buf[i] = segment
				
				output!(encodeSegment(seg: segment))
			}
		}
		
		if 0 != change {
			let inflight = snd_nxt - snd_una
			ssthresh = inflight / 2
			if(ssthresh < IKCP_THRESH_MIN) { ssthresh = IKCP_THRESH_MIN }
			self.cwnd = self.ssthresh + UInt32(resent)
			incr = self.cwnd * self.mss
		}
		
		if(lost) {
			ssthresh = cwnd / 2
			if(ssthresh < IKCP_THRESH_MIN) { ssthresh = IKCP_THRESH_MIN }
			self.cwnd = 1
			incr = mss
		}
		
		if(cwnd < 1) {
			cwnd = 1
			incr = mss
		}
	}
	
	//---------------------------------------------------------------------
	// update state (call it repeatedly, every 10ms-100ms), or you can ask
	// ikcp_check when to call it again (without ikcp_input/_send calling).
	// 'current' - current timestamp in millisec.
	//---------------------------------------------------------------------
	public mutating func update(current: UInt32, output:(([UInt8]) -> Void)?) {
		self.current = current
		
		if(synchronous) {
			flush(output: output)
			return
		}
		
		if(updated == 0) {
			updated = 1
			ts_flush = current
		}
		
		var slap = timeDiff(later: current, earlier: ts_flush)
		
		if(slap >= 10000 || slap < -10000) {
			ts_flush = current
			slap = 0
		}
		
		if(slap >= 0 ) {
			ts_flush += interval
			if(timeDiff(later: current, earlier: ts_flush) >= 0) {
				ts_flush = current + interval
			}
			flush(output: output)
		}
	}
	
	/// (Synchronous function) Returns true if all send data has been acknowledged. 
	public func ackUpToDate() -> Bool {
		return snd_una == snd_nxt
	}
}
