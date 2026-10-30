import Foundation

/// The link's resilience decisions, with no CoreBluetooth in them: what to do on a drop, an answer, a tick of the
/// clock or a signal reading. `BLELink` feeds it events and carries out the actions it returns.
public struct LinkPolicy: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, connecting, ready, reconnecting(since: Date) }
    public enum Event: Equatable, Sendable {
        case connectStarted(Date)        // `connect()` began; a drop now is a failed connect, not a reconnect
        case connectFailed(Date)         // `connect()` threw; back to idle
        case becameReady(Date)           // a connect or a reconnect finished
        case dropped(Date, reason: String)  // the system reported the adapter gone, or Bluetooth went off
        case commandSent(Date)           // a caller's command went out; the idle clock restarts
        case commandAnswered(Date)       // its prompt arrived
        case commandTimedOut(Date)       // its prompt did not arrive while the link said ready
        case keepAliveAnswered(Date), keepAliveMissed(Date)
        case probeAnswered(Date), probeMissed(Date)
        case tick(Date)                  // about once a second while ready or reconnecting
        case signal(Int, Date)           // an RSSI reading in dBm
        case disconnectedByOwner(Date)
        case restorationTaken(Date)      // a caller's command took the restoration a reconnect left owed
    }
    public enum Action: Equatable, Sendable {
        case startReconnect              // ask the system to connect to the kept adapter
        case giveUp(String)              // cancel the pending connect, fail the waiters, show the message
        case sendKeepAlive               // `ATI` with the 2-second timeout, answered or missed
        case sendProbe                   // the same command after a timeout, answered or missed
        case failTimedOut                // the probe answered: the timed-out command fails with `timeout`
        case warn(String?)               // the warning line to show, or nil to clear it
        case log(String)                 // one log line
    }
    public static let window: Duration = .seconds(60)
    public static let idleBeforeKeepAlive: Duration = .seconds(30)
    public static let signalEvery: Duration = .seconds(5)
    public static let weakSignal = -85, goodSignal = -80  // ponytail: calibration knobs for the i4's cabin
    public private(set) var phase: Phase = .idle
    public private(set) var warning: String?
    public private(set) var reconnects = 0
    /// True from a reconnect until a caller's command takes it: the adapter came back in its power-on defaults, so
    /// the next command is refused once, for its caller to set the adapter up again.
    public private(set) var restorationOwed = false

    /// When the adapter was last heard from or last sent a caller's command; the keep-alive counts from here.
    private var lastActivity = Date.distantPast
    private var commandInFlight = false
    private var keepAliveOut = false
    private var keepAliveMisses = 0
    private var probeOut = false
    private var lastSignal: Int?
    private var signalIsWeak = false
    /// The reconnect warning stays due until a command is answered; the signal warning shows over it.
    private var reconnectWarningDue = false

    public init() {}

    /// Takes in `event` and returns what the link must do, in order; a change of the warning line comes last.
    public mutating func handle(_ event: Event) -> [Action] {
        var actions: [Action] = []
        switch event {
        case .connectStarted where phase == .idle:
            phase = .connecting
        case .connectFailed where phase == .connecting:
            stop()
        case .becameReady(let date):
            if case .reconnecting(let since) = phase {
                start(at: date, reconnected: true)
                reconnects += 1
                restorationOwed = true
                actions = [.log("adapter reconnected after \(Int(date.timeIntervalSince(since))) s")]
            } else if phase == .connecting {
                start(at: date, reconnected: false)
            }
        case .dropped(let date, let reason):
            switch phase {
            case .ready, .reconnecting: actions = drop(at: date, reason)
            case .connecting: stop()
            case .idle: break
            }
        case .commandSent(let date) where phase == .ready:
            commandInFlight = true
            lastActivity = date
        case .commandAnswered(let date) where phase == .ready:
            commandInFlight = false
            reconnectWarningDue = false
            heard(at: date)
        case .commandTimedOut where phase == .ready:
            probeOut = true
            actions = [.sendProbe]
        case .keepAliveAnswered(let date) where phase == .ready && keepAliveOut:
            keepAliveOut = false
            heard(at: date)
        case .keepAliveMissed(let date) where phase == .ready && keepAliveOut:
            keepAliveOut = false
            keepAliveMisses += 1
            if keepAliveMisses < 2 {
                actions = [.log("keep-alive missed once")]
            } else {
                actions = drop(at: date, "no answer to the keep-alive")
            }
        case .probeAnswered(let date) where phase == .ready && probeOut:
            probeOut = false
            commandInFlight = false
            heard(at: date)
            actions = [.failTimedOut]
        case .probeMissed(let date) where phase == .ready && probeOut:
            actions = drop(at: date, "no answer to the probe")
        case .tick(let date) where phase == .ready:
            if !commandInFlight, !keepAliveOut,
               date.timeIntervalSince(lastActivity) >= Self.idleBeforeKeepAlive / .seconds(1) {
                keepAliveOut = true
                actions = [.sendKeepAlive]
            }
        case .tick(let date):
            if case .reconnecting(let since) = phase, date.timeIntervalSince(since) >= Self.window / .seconds(1) {
                stop()
                actions = [
                    .log("adapter did not come back in \(Self.window.components.seconds) s"),
                    .giveUp("The adapter did not come back. Reconnect when it is in range."),
                ]
            }
        case .signal(let reading, _) where phase == .ready:
            // Two readings in a row past a threshold, so that a signal hovering around one does not flap.
            if let last = lastSignal, max(last, reading) < Self.weakSignal, !signalIsWeak {
                signalIsWeak = true
                actions = [.log("signal weak: \(reading) dBm")]
            } else if let last = lastSignal, min(last, reading) > Self.goodSignal {
                signalIsWeak = false
            }
            lastSignal = reading
        case .disconnectedByOwner where phase != .idle:
            if case .reconnecting = phase { actions = [.log("disconnected by the owner")] }  // only when it ends one
            stop()
        case .restorationTaken:
            restorationOwed = false
        default:
            break
        }
        let shown: String? = if signalIsWeak {
            "Weak Bluetooth signal"
        } else if reconnectWarningDue {
            "The adapter dropped and reconnected"
        } else {
            nil
        }
        if shown != warning {
            warning = shown
            actions.append(.warn(shown))
        }
        return actions
    }

    /// A drop while ready or reconnecting: one log line with the last signal reading, and a new connection request.
    /// The window runs from the first drop, so a drop while reconnecting does not extend it.
    private mutating func drop(at date: Date, _ reason: String) -> [Action] {
        if phase == .ready { phase = .reconnecting(since: date) }
        let signal = lastSignal.map { ", signal \($0) dBm" } ?? ""
        return [.log("adapter dropped: \(reason)\(signal)"), .startReconnect]
    }

    /// Ready on a new connection, which starts with nothing in flight and no signal readings.
    private mutating func start(at date: Date, reconnected: Bool) {
        stop()
        phase = .ready
        lastActivity = date
        reconnectWarningDue = reconnected
    }

    /// Back to idle, forgetting the connection. The reconnect count stays, and so does the warning shown, for
    /// `handle` to clear.
    private mutating func stop() {
        let (reconnects, warning) = (self.reconnects, self.warning)
        self = LinkPolicy()
        (self.reconnects, self.warning) = (reconnects, warning)
    }

    /// The adapter answered: the idle clock restarts and a missed keep-alive is forgiven.
    private mutating func heard(at date: Date) {
        lastActivity = date
        keepAliveMisses = 0
    }
}
