//
//  Uniforms.swift
//  The bytes handed to the field shader every frame.
//
//  This used to live inside FieldRenderer.swift as a `private struct`, which was
//  fine while there was exactly one renderer. Field Lab (ios/tools/FieldLab)
//  is a second one, and a `private` struct means it would have needed its own
//  copy — a third declaration of a layout that nothing checks, where the two
//  that already existed could only be kept in step by hand.
//
//  So it lives here and both renderers compile this same file. There is still
//  one pairing that no compiler will ever check for you:
//
//      **this struct and `struct Uniforms` in Field.metal.**
//
//  Adding a field to one side compiles cleanly on the other and silently
//  reinterprets memory. Every field is a float4 for that reason — no padding,
//  so the two layouts can only disagree in ways that are obvious to read side
//  by side. Add to the END when you extend it: appending leaves the offsets of
//  everything above untouched, so a half-applied change costs you one wrong
//  value instead of shifting the whole struct.
//

import simd

struct Uniforms {
    var resTime: SIMD4<Float>
    var groundCount: SIMD4<Float>
    var holdParams: SIMD4<Float>
    var colony: SIMD4<Float>
    var palA: SIMD4<Float>
    var palB: SIMD4<Float>
    var palC: SIMD4<Float>
    var palD: SIMD4<Float>

    /// Four scratch floats with no meaning of their own. Field Lab drives them
    /// from sliders so a constant can be swept with a mouse instead of edited,
    /// rebuilt and squinted at; the app always sends zero.
    ///
    /// Nothing shipped may read `lab`. It is a probe you temporarily solder a
    /// constant to — `TUNNEL_SPEED` becomes `u.lab.x`, you find the value you
    /// want, and then you put the number in the constant and take the probe
    /// back out. A form left reading `lab` renders correctly in the lab and
    /// with that term at zero on a phone, which is the kind of bug that gets
    /// found on a real device at the worst possible moment.
    var lab: SIMD4<Float> = .zero
}
