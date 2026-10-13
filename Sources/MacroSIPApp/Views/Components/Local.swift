import SwiftUI

/// View-local state.
///
/// Why not `@State`: with the macOS 27 SDK, `@State` is also declared as an attached macro whose
/// implementation (`SwiftUIMacros`) ships with Xcode but not with Command Line Tools, so
/// `@State` does not compile in this repository's toolchain ("plugin for module SwiftUIMacros not
/// found"). Using the `State` struct directly (not as an attribute) does not involve the macro.
/// With full Xcode, `@Local` can be replaced by `@State` mechanically (sed 's/@Local/@State/').
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var state: State<Value>

    init(wrappedValue: Value) {
        state = State<Value>(wrappedValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
