//! ztex.tests — end-to-end integration and golden regression suites.
//!
//! Wire this module into the build as a test root (importing `ztex`,
//! `ztex.parse`, `ztex.atom`) to run the full pipeline against a fixed
//! corpus. `zig test` runs the test blocks of every transitively imported
//! file, so both suites execute from this root.
//!
//! - integration.zig: deterministic structural invariants (no goldens).
//! - regression.zig: MicroTeX-style golden snapshots of the draw list and
//!   the atom tree; goldens start as `__CAPTURE__` placeholders.
//! - sanity.zig: position-sanity invariants (finite, in-bounds coords).

const std = @import("std");

pub const integration = @import("integration.zig");
pub const regression = @import("regression.zig");
pub const sanity = @import("sanity.zig");
pub const sanity_delim_form = @import("sanity_delim_form.zig");
pub const sanity_bb = @import("sanity_bb.zig");
pub const sanity_cfrac = @import("sanity_cfrac.zig");

test {
    std.testing.refAllDecls(@This());
}
pub const sanity_dagger = @import("sanity_dagger.zig");
pub const goldens = @import("goldens.zig");
