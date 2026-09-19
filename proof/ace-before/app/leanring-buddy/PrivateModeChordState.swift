import Foundation

enum PrivateModeChordAction: Equatable, Sendable {
    case pass
    case consume
    case privateRead
}

struct PrivateModeChordInput: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case flagsChanged
        case keyDown
        case keyUp
    }

    enum KeyCode: Equatable, Sendable {
        case leftShift
        case rightShift
        case capsLock
        case x
        case z
        case other(UInt16)

        init(rawValue: UInt16) {
            switch rawValue {
            case 56: self = .leftShift
            case 60: self = .rightShift
            case 57: self = .capsLock
            case 7: self = .x
            case 6: self = .z
            default: self = .other(rawValue)
            }
        }
    }

    let kind: Kind
    let keyCode: KeyCode
    let physicalLeftShiftIsDown: Bool
    let physicalRightShiftIsDown: Bool
    let capsLockIsOn: Bool
    let reportedShiftFlagIsDown: Bool
    let commandIsDown: Bool
    let controlIsDown: Bool
    let optionIsDown: Bool
    let isAutorepeat: Bool
    let privateModeIsActive: Bool

    init(
        kind: Kind,
        keyCode: KeyCode,
        physicalLeftShiftIsDown: Bool = false,
        physicalRightShiftIsDown: Bool = false,
        capsLockIsOn: Bool = false,
        reportedShiftFlagIsDown: Bool = false,
        commandIsDown: Bool = false,
        controlIsDown: Bool = false,
        optionIsDown: Bool = false,
        isAutorepeat: Bool = false,
        privateModeIsActive: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.physicalLeftShiftIsDown = physicalLeftShiftIsDown
        self.physicalRightShiftIsDown = physicalRightShiftIsDown
        self.capsLockIsOn = capsLockIsOn
        self.reportedShiftFlagIsDown = reportedShiftFlagIsDown
        self.commandIsDown = commandIsDown
        self.controlIsDown = controlIsDown
        self.optionIsDown = optionIsDown
        self.isAutorepeat = isAutorepeat
        self.privateModeIsActive = privateModeIsActive
    }
}

/// Event-tap-owned state for the one Private Mode gesture:
/// turn Caps Lock on, then tap Shift+Z.
struct PrivateModeChordState: Sendable {
    private var consumedReadKeyPress = false

    mutating func reset() {
        consumedReadKeyPress = false
    }

    mutating func handle(
        _ input: PrivateModeChordInput
    ) -> PrivateModeChordAction {
        let physicalShiftIsDown =
            input.physicalLeftShiftIsDown
                || input.physicalRightShiftIsDown
        let hasDisallowedModifier =
            input.commandIsDown
                || input.controlIsDown
                || input.optionIsDown

        if input.keyCode == .x {
            return .pass
        }

        if input.kind == .flagsChanged,
           (input.keyCode == .leftShift || input.keyCode == .rightShift),
           !physicalShiftIsDown {
            consumedReadKeyPress = false
        }

        if input.keyCode == .z {
            if input.kind == .keyUp {
                let shouldConsumeRelease = consumedReadKeyPress
                consumedReadKeyPress = false
                return shouldConsumeRelease ? .consume : .pass
            }
            if input.kind == .keyDown, consumedReadKeyPress {
                return .consume
            }
            guard input.kind == .keyDown,
                  !input.isAutorepeat,
                  input.capsLockIsOn,
                  physicalShiftIsDown,
                  !hasDisallowedModifier else {
                return .pass
            }
            consumedReadKeyPress = true
            return .privateRead
        }

        return .pass
    }
}
