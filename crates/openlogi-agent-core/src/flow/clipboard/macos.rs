//! macOS NSPasteboard text and file backend.

#![expect(
    unsafe_code,
    reason = "NSPasteboard file-list bridging uses documented AppKit ABI"
)]
#![expect(
    deprecated,
    reason = "NSFilenamesPboardType is the stable legacy file-list pasteboard type"
)]

use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use dispatch2::DispatchQueue;
use objc2::MainThreadMarker;
use objc2::rc::{Retained, autoreleasepool};
use objc2_app_kit::{NSFilenamesPboardType, NSPasteboard, NSPasteboardTypeString};
use objc2_foundation::{NSArray, NSString};

use super::ClipboardBackend;

#[expect(
    unsafe_code,
    reason = "NSPasteboard's extern type constant is a trusted AppKit ABI"
)]
const fn pasteboard_type_string() -> &'static objc2_app_kit::NSPasteboardType {
    // SAFETY: AppKit exports this immutable typed constant for the process
    // lifetime.
    unsafe { NSPasteboardTypeString }
}

#[expect(
    unsafe_code,
    reason = "NSPasteboard's extern type constant is a trusted AppKit ABI"
)]
const fn pasteboard_type_filenames() -> &'static objc2_app_kit::NSPasteboardType {
    // SAFETY: AppKit exports this immutable typed constant for the process
    // lifetime.
    unsafe { NSFilenamesPboardType }
}

/// How long a clipboard call waits for the main thread. The pasteboard work
/// itself is sub-millisecond; this only bounds a main thread that is busy or
/// not running its run loop, which then costs a failed read/write instead of
/// a hang.
const MAIN_THREAD_WAIT: Duration = Duration::from_millis(500);

/// Run pasteboard work on the main thread and wait (bounded) for its result.
///
/// AppKit documents NSPasteboard as main-thread API. The Flow clipboard
/// loop, the paste worker and the hook all run elsewhere, so every backend
/// call hops to the main queue, where the agent runs `NSApplication`. Called
/// on the main thread already, the work runs inline. Objective-C objects
/// never leave the closure; only owned Rust values cross back.
fn on_main<T: Send + 'static>(
    what: &'static str,
    work: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    if MainThreadMarker::new().is_some() {
        return Some(autoreleasepool(|_| work()));
    }
    let (reply, answer) = mpsc::sync_channel(1);
    DispatchQueue::main().exec_async(move || {
        // A reply after the wait gave up has nobody left to read it.
        let _ = reply.send(autoreleasepool(|_| work()));
    });
    answer
        .recv_timeout(MAIN_THREAD_WAIT)
        .inspect_err(|_| tracing::warn!(what, "main thread did not answer the clipboard in time"))
        .ok()
}

fn read_text_on_main() -> Option<Vec<u8>> {
    let pasteboard = NSPasteboard::generalPasteboard();
    pasteboard
        .stringForType(pasteboard_type_string())
        .map(|text| text.to_string().into_bytes())
}

fn write_text_on_main(text: &str) -> Result<(), String> {
    let pasteboard = NSPasteboard::generalPasteboard();
    pasteboard.clearContents();
    if pasteboard.setString_forType(&NSString::from_str(text), pasteboard_type_string()) {
        Ok(())
    } else {
        Err("NSPasteboard rejected text".to_owned())
    }
}

fn read_files_on_main() -> Option<Vec<PathBuf>> {
    let pasteboard = NSPasteboard::generalPasteboard();
    let value = pasteboard.propertyListForType(pasteboard_type_filenames())?;
    // SAFETY: `NSFilenamesPboardType` is documented to return an NSArray
    // of NSString paths. The retained ownership returned by AppKit is
    // transferred to the typed wrapper without changing the retain count.
    let array: Retained<NSArray<NSString>> =
        unsafe { Retained::from_raw(Retained::into_raw(value).cast()) }?;
    Some(
        (0..array.count())
            .map(|index| PathBuf::from(array.objectAtIndex(index).to_string()))
            .collect(),
    )
}

fn write_files_on_main(paths: &[PathBuf]) -> Result<(), String> {
    let values: Vec<Retained<NSString>> = paths
        .iter()
        .map(|path| NSString::from_str(&path.to_string_lossy()))
        .collect();
    let values = NSArray::from_retained_slice(&values);
    let pasteboard = NSPasteboard::generalPasteboard();
    pasteboard.clearContents();
    // SAFETY: `values` is an Objective-C NSArray containing only retained
    // NSString objects, which is the property-list shape AppKit expects.
    if unsafe { pasteboard.setPropertyList_forType(&values, pasteboard_type_filenames()) } {
        Ok(())
    } else {
        Err("NSPasteboard rejected file list".to_owned())
    }
}

#[derive(Debug)]
pub(super) struct MacClipboard;

impl ClipboardBackend for MacClipboard {
    fn read_text(&self) -> Option<Vec<u8>> {
        on_main("clipboard read", read_text_on_main).flatten()
    }

    fn write_text(&self, bytes: &[u8]) -> Result<(), String> {
        let text = std::str::from_utf8(bytes)
            .map_err(|error| format!("clipboard text is not UTF-8: {error}"))?
            .to_owned();
        on_main("clipboard write", move || write_text_on_main(&text))
            .unwrap_or_else(|| Err("main thread did not apply the clipboard in time".to_owned()))
    }

    fn read_files(&self) -> Option<Vec<PathBuf>> {
        on_main("clipboard file read", read_files_on_main).flatten()
    }

    fn supports_files(&self) -> bool {
        true
    }

    fn write_files(&self, paths: &[PathBuf]) -> Result<(), String> {
        let paths = paths.to_vec();
        on_main("clipboard file write", move || write_files_on_main(&paths))
            .unwrap_or_else(|| Err("main thread did not apply the clipboard in time".to_owned()))
    }
}
