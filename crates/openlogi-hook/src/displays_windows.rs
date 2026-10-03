//! Win32 virtual desktop geometry for Flow edge detection.
#![expect(
    unsafe_code,
    reason = "EnumDisplayMonitors exposes its callback and context through Win32 FFI"
)]

use windows_sys::Win32::Foundation::{LPARAM, RECT};
use windows_sys::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO,
};

use crate::edge::DisplayRect;

/// Read every monitor in the virtual desktop's physical screen coordinates.
pub(super) fn display_rects() -> Option<Vec<DisplayRect>> {
    let mut displays = Vec::new();
    let context = (&raw mut displays) as LPARAM;
    // SAFETY: `context` points to the live vector for the synchronous callback
    // duration; no HDC or clip rectangle is required for monitor enumeration.
    if unsafe {
        EnumDisplayMonitors(
            std::ptr::null_mut(),
            std::ptr::null(),
            Some(collect),
            context,
        )
    } == 0
    {
        return None;
    }
    (!displays.is_empty()).then_some(displays)
}

unsafe extern "system" fn collect(
    monitor: HMONITOR,
    _dc: HDC,
    _rect: *mut RECT,
    context: LPARAM,
) -> i32 {
    // SAFETY: EnumDisplayMonitors passes the original live Vec pointer supplied
    // by `display_rects`; callbacks are synchronous and serialized by Win32.
    let displays = unsafe { &mut *(context as *mut Vec<DisplayRect>) };
    let mut info = MONITORINFO {
        cbSize: u32::try_from(std::mem::size_of::<MONITORINFO>()).unwrap_or_default(),
        ..MONITORINFO::default()
    };
    // SAFETY: monitor is supplied by EnumDisplayMonitors and info has the
    // structure size required by GetMonitorInfoW.
    if unsafe { GetMonitorInfoW(monitor, &raw mut info) } == 0 {
        return 1;
    }
    let rect = info.rcMonitor;
    if let Some(display) = DisplayRect::new(
        f64::from(rect.left),
        f64::from(rect.top),
        f64::from(rect.right - rect.left),
        f64::from(rect.bottom - rect.top),
    ) {
        displays.push(display);
    }
    1
}
