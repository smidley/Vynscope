/// What the frames received so far add up to.
public enum Reassembly: Equatable, Sendable {
    /// The whole message, with the address and ISO-TP framing removed.
    case complete([UInt8])
    /// Only the first frame of a multi-frame message has arrived; send a flow-control frame to get the rest.
    case needFlowControl(expectedLength: Int)
    /// Part of a message has arrived: `received` of `expected` payload bytes.
    case incomplete(received: Int, expected: Int)
    /// No frame carried a message.
    case empty
}

/// ISO-TP as BMW uses it on the diagnostic CAN. Byte 0 of every frame is an address (the target when
/// sending, `0xF1` when receiving), then the ISO-TP PCI and payload, padded with `0x00` to 8 bytes.
/// That leaves room for 6 payload bytes in a single frame, 5 in a first frame and 6 in a consecutive frame.
public enum ISOTP {
    /// A request that fits one frame. A longer payload goes out as a `firstFrame` then `consecutiveFrames`.
    public static func singleFrame(to target: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 6, "a single frame carries at most 6 payload bytes")
        return padded([target, UInt8(payload.count)] + payload)
    }

    /// Opens a request longer than one frame: the 12-bit total length, then the first 5 payload bytes.
    /// The receiver answers with a flow-control frame before the rest is sent.
    public static func firstFrame(to target: UInt8, payload: [UInt8]) -> [UInt8] {
        precondition((7...4095).contains(payload.count), "a first frame carries a payload of 7 to 4095 bytes")
        return [target, 0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload.prefix(5)
    }

    /// The rest of a long request, 6 bytes per frame. Each frame's sequence number starts at 1 and wraps
    /// from `F` back to `0`, so the receiver can tell a lost frame from a repeat.
    public static func consecutiveFrames(to target: UInt8, payload: [UInt8]) -> [[UInt8]] {
        let rest = Array(payload.dropFirst(5))
        return stride(from: 0, to: rest.count, by: 6).enumerated().map { index, start in
            let sequence = UInt8((index + 1) & 0x0F)
            return padded([target, 0x20 | sequence] + rest[start..<min(start + 6, rest.count)])
        }
    }

    /// Lets the sender of a multi-frame response continue: clear to send, no block limit, no delay between frames.
    public static func flowControlFrame(to target: UInt8) -> [UInt8] {
        padded([target, 0x30])
    }

    /// The receiver's answer to a first frame: whether to continue, and how fast.
    public struct FlowControl: Equatable, Sendable {
        /// 0 for clear to send, 1 to wait for another flow-control frame, 2 when the receiver cannot take the message.
        public let status: UInt8
        /// Consecutive frames the sender may send before it must wait for another flow-control frame; 0 means no limit.
        public let blockSize: UInt8
        /// The least time the sender must leave between consecutive frames, in the ISO-TP encoding.
        public let separationTime: UInt8
    }

    /// Reads a flow-control frame as the adapter returns it, address byte first. Nil for any other frame, so
    /// a late consecutive frame is not taken for an answer.
    public static func flowControl(_ frame: [UInt8]) -> FlowControl? {
        guard frame.count >= 4, frame[1] >> 4 == 0x3 else { return nil }
        return FlowControl(status: frame[1] & 0x0F, blockSize: frame[2], separationTime: frame[3])
    }

    /// Joins the frames of one response into its payload, dropping each frame's address and PCI and the
    /// padding after the last byte. The first frame long enough to carry a PCI decides what the response is.
    public static func reassemble(_ frames: [[UInt8]]) -> Reassembly {
        // A frame under 2 bytes (a bare id line from the adapter) has no PCI and is skipped.
        let frames = frames.filter { $0.count >= 2 }
        guard let first = frames.first else { return .empty }
        switch first[1] >> 4 {
        case 0x0:  // single frame: the low nibble is the payload length
            let length = Int(first[1] & 0x0F)
            let payload = Array(first.dropFirst(2).prefix(length))
            if payload.count == length { return .complete(payload) }
            return .incomplete(received: payload.count, expected: length)
        case 0x1:  // first frame: a 12-bit total length, then the first 5 payload bytes
            guard first.count >= 3 else { return .empty }
            let expected = (Int(first[1] & 0x0F) << 8) | Int(first[2])
            var payload = Array(first.dropFirst(3).prefix(expected))
            // ponytail: consecutive frames are taken in the order received and their sequence nibble is
            // not checked; add the check if a car ever interleaves.
            let consecutive = frames.dropFirst().filter { $0[1] >> 4 == 0x2 }
            for frame in consecutive { payload += frame.dropFirst(2).prefix(expected - payload.count) }
            if payload.count == expected { return .complete(payload) }
            return consecutive.isEmpty
                ? .needFlowControl(expectedLength: expected)
                : .incomplete(received: payload.count, expected: expected)
        default:  // a consecutive or flow-control frame cannot start a message
            return .empty
        }
    }

    /// The bytes as the adapter takes them: two upper-case hex digits each, separated by spaces.
    public static func hexLine(_ bytes: [UInt8]) -> String {
        bytes.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16, uppercase: true) }.joined(separator: " ")
    }

    /// Pads a frame with `0x00` to the 8 bytes a CAN frame carries.
    private static func padded(_ frame: [UInt8]) -> [UInt8] {
        frame + [UInt8](repeating: 0, count: 8 - frame.count)
    }
}
