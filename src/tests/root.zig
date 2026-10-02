//! ztex.tests — end-to-end rendering invariants.
//!
//! Wire this module into the build as a test root (importing `ztex`,
//! `ztex.parse`, `ztex.atom`) to run the full pipeline against a fixed
//! corpus. `zig test` runs the test blocks of every transitively imported
//! file, so the integration and position suites execute from this root.
//!
//! - integration.zig: full-pipeline structural and geometry invariants.
//! - sanity.zig: position-sanity invariants (finite, in-bounds coords).

const std = @import("std");

pub const integration = @import("integration.zig");
pub const sanity = @import("sanity.zig");
pub const sanity_bb = @import("sanity_bb.zig");
pub const sanity_cfrac = @import("sanity_cfrac.zig");

test {
    std.testing.refAllDecls(@This());
}
pub const sanity_dagger = @import("sanity_dagger.zig");
