//! macOS global display geometry for Flow edge detection.
#![expect(
    unsafe_code,
    reason = "CoreGraphics display enumeration has no safe binding in core-graphics"
)]

use core_graphics::display::{CGDisplayBounds, CGGetActiveDisplayList};

use crate::edge::DisplayRect;

/// Read active CoreGraphics display bounds in the same points used by CGEvents.
pub(super) fn display_rects() -> Option<Vec<DisplayRect>> {
    const MAX_DISPLAYS: u32 = 32;
    let mut ids = [0u32; MAX_DISPLAYS as usize];
    let mut count = 0u32;
    // SAFETY: `ids` has the capacity passed to CoreGraphics and `count` is a
    // valid output pointer for the number of IDs written.
    if unsafe { CGGetActiveDisplayList(MAX_DISPLAYS, ids.as_mut_ptr(), &raw mut count) } != 0 {
        return None;
    }
    let count = usize::try_from(count).ok()?;
    Some(
        ids.iter()
            .take(count)
            .filter_map(|id| {
                // SAFETY: each id was returned by the active-display query.
                let bounds = unsafe { CGDisplayBounds(*id) };
                DisplayRect::new(
                    bounds.origin.x,
                    bounds.origin.y,
                    bounds.size.width,
                    bounds.size.height,
                )
            })
            .collect(),
    )
}
