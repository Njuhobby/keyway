/// US-ANSI virtual key codes (`kVK_ANSI_*`). These are *physical* positions, so on
/// non-QWERTY layouts the letter labels won't match. For Day 1-2 spike that's fine;
/// when we ship we'll switch typed-character matching to `keyboardGetUnicodeString`.
enum KeyCode {
    static let a = 0
    static let s = 1
    static let d = 2
    static let f = 3
    static let h = 4
    static let g = 5
    static let z = 6
    static let x = 7
    static let c = 8
    static let v = 9
    static let b = 11
    static let q = 12
    static let w = 13
    static let e = 14
    static let r = 15
    static let y = 16
    static let t = 17
    static let o = 31
    static let u = 32
    static let i = 34
    static let p = 35
    static let l = 37
    static let j = 38
    static let k = 40
    static let n = 45
    static let m = 46

    static let semicolon = 41
    static let quote = 39
    static let comma = 43
    static let period = 47
    static let slash = 44

    static let escape = 53
    static let `return` = 36
    static let tab = 48
    static let space = 49
    static let delete = 51

    static let arrowLeft = 123
    static let arrowRight = 124
    static let arrowDown = 125
    static let arrowUp = 126
}
