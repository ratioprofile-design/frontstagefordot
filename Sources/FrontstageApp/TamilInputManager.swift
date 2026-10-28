#if os(macOS)
import Foundation
import Carbon
import AppKit

@MainActor
enum TamilInputManager {
    private static var previousInputSource: TISInputSource?
    private static var isTamilActive = false

    /// Checks if a given input source represents Tamil
    static func isTamilSource(_ source: TISInputSource) -> Bool {
        let id = inputSourceID(source)
        let name = inputSourceName(source)
        if id.localizedCaseInsensitiveContains("tamil") || name.localizedCaseInsensitiveContains("tamil") {
            return true
        }
        if id.hasSuffix(".ta") || id.contains(".ta.") || id.contains("TransliterationIM.ta") {
            return true
        }
        return false
    }

    /// Automatically switches to the macOS Tamil keyboard input source
    static func activateTamilInput() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }

        if isTamilSource(current) {
            isTamilActive = true
            return
        }

        // Only store previous if it is NOT Tamil
        previousInputSource = current

        if let tamilSource = findTamilInputSource() {
            TISSelectInputSource(tamilSource)
            isTamilActive = true
        }
    }

    /// Restores the user's previous keyboard input source or system default English
    static func restoreStandardInput() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            isTamilActive = false
            return
        }

        let isCurrentlyTamil = isTamilSource(current)

        guard isCurrentlyTamil || isTamilActive else {
            isTamilActive = false
            return
        }

        var targetSource: TISInputSource? = nil
        if let prev = previousInputSource {
            if !isTamilSource(prev) {
                targetSource = prev
            }
        }

        if targetSource == nil {
            targetSource = findDefaultInputSource()
        }

        if let target = targetSource {
            TISSelectInputSource(target)
        }
        previousInputSource = nil
        isTamilActive = false
    }

    private static func findTamilInputSource() -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        for source in list {
            let isSelectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            let isSelectable = isSelectablePtr != nil && (Unmanaged<CFBoolean>.fromOpaque(isSelectablePtr!).takeUnretainedValue() == kCFBooleanTrue)
            guard isSelectable else { continue }

            if isTamilSource(source) {
                return source
            }
        }
        return nil
    }

    private static func findDefaultInputSource() -> TISInputSource? {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        // Preferred standard input sources
        let preferred = ["com.apple.keylayout.ABC-India", "com.apple.keylayout.ABC", "com.apple.keylayout.US", "com.apple.keylayout.British"]
        for pref in preferred {
            if let match = list.first(where: { inputSourceID($0) == pref }) {
                return match
            }
        }
        // Fallback to any selectable ASCII-capable source that is not Tamil
        for source in list {
            let isSelectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            let isSelectable = isSelectablePtr != nil && (Unmanaged<CFBoolean>.fromOpaque(isSelectablePtr!).takeUnretainedValue() == kCFBooleanTrue)
            guard isSelectable else { continue }

            if !isTamilSource(source) {
                let isAsciiPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
                let isAscii = isAsciiPtr != nil && (Unmanaged<CFBoolean>.fromOpaque(isAsciiPtr!).takeUnretainedValue() == kCFBooleanTrue)
                if isAscii {
                    return source
                }
            }
        }
        return nil
    }

    private static func inputSourceID(_ source: TISInputSource) -> String {
        let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        return idPtr != nil ? (Unmanaged<CFString>.fromOpaque(idPtr!).takeUnretainedValue() as String) : ""
    }

    private static func inputSourceName(_ source: TISInputSource) -> String {
        let namePtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        return namePtr != nil ? (Unmanaged<CFString>.fromOpaque(namePtr!).takeUnretainedValue() as String) : ""
    }
}
#endif
