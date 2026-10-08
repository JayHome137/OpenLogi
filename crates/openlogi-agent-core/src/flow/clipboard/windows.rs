//! Windows CF_UNICODETEXT clipboard backend.
#![expect(
    unsafe_code,
    reason = "the clipboard backend calls the documented Win32 clipboard and global-memory APIs"
)]

use std::os::windows::ffi::OsStrExt;
use std::ptr;

use windows_sys::Win32::Foundation::{GlobalFree, HANDLE};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows_sys::Win32::System::Memory::{
    GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
};
use windows_sys::Win32::System::Ole::{CF_HDROP, CF_UNICODETEXT};
use windows_sys::Win32::UI::Shell::{DROPFILES, DragQueryFileW};

use super::ClipboardBackend;

#[derive(Debug)]
pub(super) struct WindowsClipboard;

impl ClipboardBackend for WindowsClipboard {
    fn read_text(&self) -> Option<Vec<u8>> {
        // SAFETY: The Win32 clipboard handle is held open until the guard is
        // dropped, and the global block is locked only for the read.
        unsafe {
            if OpenClipboard(ptr::null_mut()) == 0 {
                return None;
            }
            let result = read_open_clipboard();
            CloseClipboard();
            result
        }
    }

    fn write_text(&self, bytes: &[u8]) -> Result<(), String> {
        let text = std::str::from_utf8(bytes)
            .map_err(|error| format!("clipboard text is not UTF-8: {error}"))?;
        let wide = text
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect::<Vec<_>>();
        // SAFETY: The allocated movable global block is filled before being
        // transferred to the clipboard. Windows owns it after success.
        unsafe {
            if OpenClipboard(ptr::null_mut()) == 0 {
                return Err(last_error("OpenClipboard"));
            }
            let result = (|| {
                if EmptyClipboard() == 0 {
                    return Err(last_error("EmptyClipboard"));
                }
                let bytes_len = wide.len() * std::mem::size_of::<u16>();
                let global = GlobalAlloc(GMEM_MOVEABLE, bytes_len);
                if global.is_null() {
                    return Err(last_error("GlobalAlloc"));
                }
                let target = GlobalLock(global);
                if target.is_null() {
                    GlobalFree(global);
                    return Err(last_error("GlobalLock"));
                }
                std::ptr::copy_nonoverlapping(
                    wide.as_ptr().cast::<u8>(),
                    target.cast::<u8>(),
                    bytes_len,
                );
                GlobalUnlock(global);
                if SetClipboardData(CF_UNICODETEXT.into(), global as HANDLE).is_null() {
                    GlobalFree(global);
                    return Err(last_error("SetClipboardData"));
                }
                Ok(())
            })();
            CloseClipboard();
            result
        }
    }

    fn read_files(&self) -> Option<Vec<std::path::PathBuf>> {
        // SAFETY: The clipboard stays open until all HDROP paths are copied.
        unsafe {
            if OpenClipboard(ptr::null_mut()) == 0 {
                return None;
            }
            let result = (|| {
                let handle = GetClipboardData(CF_HDROP.into());
                if handle.is_null() {
                    return None;
                }
                let drop = handle.cast();
                let count = DragQueryFileW(drop, u32::MAX, ptr::null_mut(), 0);
                let mut paths = Vec::with_capacity(count as usize);
                for index in 0..count {
                    let len = DragQueryFileW(drop, index, ptr::null_mut(), 0);
                    if len == 0 {
                        return None;
                    }
                    let mut wide = vec![0u16; len as usize + 1];
                    let Ok(capacity) = u32::try_from(wide.len()) else {
                        return None;
                    };
                    let copied = DragQueryFileW(drop, index, wide.as_mut_ptr(), capacity);
                    if copied != len {
                        return None;
                    }
                    wide.truncate(copied as usize);
                    paths.push(std::path::PathBuf::from(String::from_utf16_lossy(&wide)));
                }
                Some(paths)
            })();
            CloseClipboard();
            result
        }
    }

    fn write_files(&self, files: &[(String, Vec<u8>)]) -> Result<(), String> {
        let paths = super::persist_received_files(files)?;
        let mut wide = Vec::new();
        for path in paths {
            wide.extend(path.as_os_str().encode_wide());
            wide.push(0);
        }
        wide.push(0);
        // SAFETY: The movable global block contains a valid DROPFILES header
        // followed by a double-NUL-terminated UTF-16 path list.
        unsafe {
            if OpenClipboard(ptr::null_mut()) == 0 {
                return Err(last_error("OpenClipboard"));
            }
            let result = (|| {
                if EmptyClipboard() == 0 {
                    return Err(last_error("EmptyClipboard"));
                }
                let header_size = std::mem::size_of::<DROPFILES>();
                let data_size = header_size + wide.len() * std::mem::size_of::<u16>();
                let global = GlobalAlloc(GMEM_MOVEABLE, data_size);
                if global.is_null() {
                    return Err(last_error("GlobalAlloc"));
                }
                let target = GlobalLock(global);
                if target.is_null() {
                    GlobalFree(global);
                    return Err(last_error("GlobalLock"));
                }
                let Ok(header_size_u32) = u32::try_from(header_size) else {
                    GlobalUnlock(global);
                    GlobalFree(global);
                    return Err("DROPFILES header is too large".to_owned());
                };
                let header = DROPFILES {
                    pFiles: header_size_u32,
                    fWide: 1,
                    ..Default::default()
                };
                ptr::copy_nonoverlapping(
                    (&raw const header).cast::<u8>(),
                    target.cast::<u8>(),
                    header_size,
                );
                ptr::copy_nonoverlapping(
                    wide.as_ptr().cast::<u8>(),
                    target.cast::<u8>().add(header_size),
                    wide.len() * std::mem::size_of::<u16>(),
                );
                GlobalUnlock(global);
                if SetClipboardData(CF_HDROP.into(), global as HANDLE).is_null() {
                    GlobalFree(global);
                    return Err(last_error("SetClipboardData"));
                }
                Ok(())
            })();
            CloseClipboard();
            result
        }
    }
}

fn read_open_clipboard() -> Option<Vec<u8>> {
    // SAFETY: the caller holds the clipboard open; the global block is only
    // inspected while locked and is unlocked before returning.
    unsafe {
        let handle = GetClipboardData(CF_UNICODETEXT.into());
        if handle.is_null() {
            return None;
        }
        let size = GlobalSize(handle);
        if size < std::mem::size_of::<u16>() {
            return Some(Vec::new());
        }
        let ptr = GlobalLock(handle);
        if ptr.is_null() {
            return None;
        }
        let words =
            std::slice::from_raw_parts(ptr.cast::<u16>(), size / std::mem::size_of::<u16>());
        let end = words
            .iter()
            .position(|word| *word == 0)
            .unwrap_or(words.len());
        let result = String::from_utf16_lossy(&words[..end]).into_bytes();
        GlobalUnlock(handle);
        Some(result)
    }
}

fn last_error(operation: &str) -> String {
    format!("{operation} failed: {}", std::io::Error::last_os_error())
}
