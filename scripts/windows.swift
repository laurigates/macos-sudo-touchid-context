// Prints on-screen windows as "id<TAB>owner<TAB>title" so a single window can be
// captured with `screencapture -l <id>` (used by scripts/screenshot.sh).
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows {
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let title = w[kCGWindowName as String] as? String ?? ""
    print("\(id)\t\(owner)\t\(title)")
}
