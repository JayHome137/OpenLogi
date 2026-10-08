//! macOS NSPasteboard text and file backend.

#![expect(
    unsafe_code,
    reason = "NSPasteboard file-list bridging uses documented AppKit ABI"
)]
#![expect(
    deprecated,
    reason = "NSFilenamesPboardType is the stable legacy file-list pasteboard type"
)]

use objc2::rc::Retained;
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

#[derive(Debug)]
pub(super) struct MacClipboard;

impl ClipboardBackend for MacClipboard {
    fn read_text(&self) -> Option<Vec<u8>> {
        // NSPasteboard is thread-safe for these synchronous operations. The
        // agent polls from a worker task and never hands Objective-C objects
        // across the task boundary.
        let pasteboard = NSPasteboard::generalPasteboard();
        pasteboard
            .stringForType(pasteboard_type_string())
            .map(|text| text.to_string().into_bytes())
    }

    fn write_text(&self, bytes: &[u8]) -> Result<(), String> {
        let text = std::str::from_utf8(bytes)
            .map_err(|error| format!("clipboard text is not UTF-8: {error}"))?;
        let pasteboard = NSPasteboard::generalPasteboard();
        pasteboard.clearContents();
        if pasteboard.setString_forType(&NSString::from_str(text), pasteboard_type_string()) {
            Ok(())
        } else {
            Err("NSPasteboard rejected text".to_owned())
        }
    }

    fn read_files(&self) -> Option<Vec<std::path::PathBuf>> {
        let pasteboard = NSPasteboard::generalPasteboard();
        let value = pasteboard.propertyListForType(pasteboard_type_filenames())?;
        // SAFETY: `NSFilenamesPboardType` is documented to return an NSArray
        // of NSString paths. The retained ownership returned by AppKit is
        // transferred to the typed wrapper without changing the retain count.
        let array: Retained<NSArray<NSString>> =
            unsafe { Retained::from_raw(Retained::into_raw(value).cast()) }?;
        Some(
            (0..array.count())
                .map(|index| std::path::PathBuf::from(array.objectAtIndex(index).to_string()))
                .collect(),
        )
    }

    fn write_files(&self, files: &[(String, Vec<u8>)]) -> Result<(), String> {
        let paths = super::persist_received_files(files)?;
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
}
