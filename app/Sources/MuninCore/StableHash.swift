/// Valheim keys everything — prefab names, object field names — by this hash
/// (`Utils.GetStableHashCode`): two interleaved djb2 streams over UTF-16 code
/// units, in wrapping 32-bit arithmetic.
public func stableHash(_ string: String) -> Int32 {
    let units = Array(string.utf16)
    var a: Int32 = 5381
    var b: Int32 = 5381
    var i = 0
    while i < units.count && units[i] != 0 {
        a = ((a &<< 5) &+ a) ^ Int32(units[i])
        if i == units.count - 1 || units[i + 1] == 0 { break }
        b = ((b &<< 5) &+ b) ^ Int32(units[i + 1])
        i += 2
    }
    return a &+ (b &* 1_566_083_941)
}
