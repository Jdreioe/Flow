# Defer the flow-core Swift bridge

The Linux app consumes `flow-core` (Rust) directly; the macOS app currently
reimplements language planning — text reflow, sentence splitting, and
language detection thresholds — in Swift. We decided to defer the versioned
Swift bridge to `flow-core` until a trigger condition is met: **when core
gains logic the macOS app needs beyond language planning**, or when the two
implementations visibly diverge in behavior.

Building the bridge now buys correctness insurance against drift that has not
yet happened, at the cost of ABI-stable types, a FFI layer, and cross-platform
contract tests for logic that is small and stable. When the trigger fires,
the bridge must ship with matching contract tests rather than coupling Swift
to Rust's internal ABI (see README).

## Considered options

- **Bridge now**: rejected — duplication is small and stable; bridge cost is real.
- **Never bridge**: rejected — cross-platform behavior drift in Language Flow would be a product bug.
