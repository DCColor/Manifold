// Window-id + bounds for the largest on-screen Manifold window. PyObjC is absent, so this
// replaces the python Quartz call in the sweep.
import Foundation
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double, [String: Any])? = nil
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == "Manifold",
          let num = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let ww = b["Width"] as? Double, let hh = b["Height"] as? Double else { continue }
    if best == nil || ww * hh > best!.1 { best = (num, ww * hh, b) }
}
if let (num, _, b) = best {
    print("\(num) \(b["X"] as? Double ?? 0) \(b["Y"] as? Double ?? 0) \(b["Width"] as? Double ?? 0) \(b["Height"] as? Double ?? 0)")
}
