//! Window geometry: how it is stored, and what makes a stored value safe to
//! restore.
//!
//! The storing is trivial; the *validating* is not, and it is why this lives
//! in Rust rather than in the Dart that calls `setBounds`. A geometry read
//! back from the store describes the machine as it was, not as it is: the
//! monitor it was on may be unplugged, the resolution may have changed, and a
//! window restored to those coordinates is invisible with no way to reach it.

/// A window's position, size, and whether it was maximized.
///
/// Coordinates are logical pixels in the primary display's space, matching
/// what `window_manager` reports and accepts.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WindowGeometry {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub maximized: bool,
}

/// Serialise for the `settings` table.
///
/// A flat comma-separated string rather than JSON: the table is
/// `TEXT`-to-`TEXT`, there is exactly one reader, and a malformed value has to
/// be survivable anyway (see [`parse_window_geometry`]), so a format that
/// cannot half-parse is worth more here than one that is self-describing.
#[flutter_rust_bridge::frb(sync)]
pub fn encode_window_geometry(geometry: WindowGeometry) -> String {
    format!(
        "{},{},{},{},{}",
        geometry.x.round(),
        geometry.y.round(),
        geometry.width.round(),
        geometry.height.round(),
        if geometry.maximized { 1 } else { 0 }
    )
}

/// Parse a stored geometry, or `None` if it is not one.
///
/// Returning `None` rather than a default matters: the caller must be able to
/// tell "no stored geometry" from "a stored geometry that happens to match the
/// default", because only the first should centre the window.
#[flutter_rust_bridge::frb(sync)]
pub fn parse_window_geometry(value: String) -> Option<WindowGeometry> {
    let parts: Vec<&str> = value.split(',').collect();
    if parts.len() != 5 {
        return None;
    }
    let nums: Vec<f64> = parts[..4].iter().filter_map(|p| p.trim().parse().ok()).collect();
    if nums.len() != 4 || !nums.iter().all(|n| n.is_finite()) {
        return None;
    }
    Some(WindowGeometry {
        x: nums[0],
        y: nums[1],
        width: nums[2],
        height: nums[3],
        maximized: parts[4].trim() == "1",
    })
}

/// Make a stored geometry safe to apply on the display available *now*.
///
/// Three separate hazards, each with its own rule:
///
/// * **The window is too small to use.** Clamped up to `min_width`/
///   `min_height`, which are the same floors the runner enforces. A stored
///   size below them can only come from another build or a hand-edited store.
/// * **The window is larger than the screen.** Clamped down, so a geometry
///   saved on a 4K monitor does not open off the edge of a laptop panel.
/// * **The window is off-screen entirely.** The rule is *visibility*, not
///   containment: a window may hang off an edge — users park them that way
///   deliberately — but at least [`MIN_VISIBLE`] pixels of it must be
///   reachable on each axis, or it cannot be dragged back. When that fails
///   the position is dropped, which the caller reads as "centre it".
///
/// Returns the geometry to apply; `None` for the position means centre.
#[flutter_rust_bridge::frb(sync)]
pub fn fit_window_geometry(
    geometry: WindowGeometry,
    screen_width: f64,
    screen_height: f64,
    min_width: f64,
    min_height: f64,
) -> FittedGeometry {
    let width = geometry.width.clamp(min_width, screen_width.max(min_width));
    let height = geometry.height.clamp(min_height, screen_height.max(min_height));

    let visible_x = (geometry.x + width).min(screen_width) - geometry.x.max(0.0);
    let visible_y = (geometry.y + height).min(screen_height) - geometry.y.max(0.0);
    let reachable = visible_x >= MIN_VISIBLE.min(width)
        && visible_y >= MIN_VISIBLE.min(height)
        // A title bar dragged above the top edge cannot be grabbed back, so
        // a negative y is never restored however wide the window is.
        && geometry.y >= 0.0;

    FittedGeometry {
        width,
        height,
        maximized: geometry.maximized,
        x: if reachable { Some(geometry.x) } else { None },
        y: if reachable { Some(geometry.y) } else { None },
    }
}

/// How much of the window must remain on screen for its position to be
/// restored. Roughly a title bar's worth: enough to grab and drag.
pub const MIN_VISIBLE: f64 = 64.0;

/// A geometry that is safe to apply. `x`/`y` are `None` when the stored
/// position was unusable and the window should be centred instead.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FittedGeometry {
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub width: f64,
    pub height: f64,
    pub maximized: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn geom(x: f64, y: f64, w: f64, h: f64) -> WindowGeometry {
        WindowGeometry {
            x,
            y,
            width: w,
            height: h,
            maximized: false,
        }
    }

    fn fit(g: WindowGeometry) -> FittedGeometry {
        fit_window_geometry(g, 1920.0, 1080.0, 980.0, 400.0)
    }

    #[test]
    fn a_geometry_round_trips_through_the_store() {
        let g = WindowGeometry {
            x: 100.0,
            y: 50.0,
            width: 1200.0,
            height: 800.0,
            maximized: true,
        };
        assert_eq!(parse_window_geometry(encode_window_geometry(g)), Some(g));
    }

    #[test]
    fn nonsense_parses_as_none_rather_than_as_a_default() {
        // The caller centres the window when this is None, so conflating
        // "unset" with "0,0,0,0" would silently move everyone's window.
        for value in ["", "junk", "1,2,3", "1,2,3,4", "1,2,3,4,5,6", "a,b,c,d,1"] {
            assert_eq!(
                parse_window_geometry(value.to_string()),
                None,
                "{value:?} should not parse"
            );
        }
    }

    #[test]
    fn an_ordinary_geometry_is_returned_unchanged() {
        let f = fit(geom(200.0, 150.0, 1200.0, 800.0));
        assert_eq!(f.x, Some(200.0));
        assert_eq!(f.y, Some(150.0));
        assert_eq!(f.width, 1200.0);
        assert_eq!(f.height, 800.0);
    }

    #[test]
    fn a_window_smaller_than_the_minimum_is_grown() {
        let f = fit(geom(0.0, 0.0, 300.0, 100.0));
        assert_eq!(f.width, 980.0);
        assert_eq!(f.height, 400.0);
    }

    #[test]
    fn a_window_from_a_bigger_monitor_is_shrunk_to_this_one() {
        let f = fit(geom(0.0, 0.0, 3800.0, 2000.0));
        assert_eq!(f.width, 1920.0);
        assert_eq!(f.height, 1080.0);
    }

    #[test]
    fn a_position_on_an_unplugged_monitor_is_dropped() {
        // The case this whole module exists for: a second screen to the right
        // that is no longer there.
        let f = fit(geom(2600.0, 300.0, 1200.0, 800.0));
        assert_eq!(f.x, None, "an unreachable window must be re-centred");
        assert_eq!(f.y, None);
        assert_eq!(f.width, 1200.0, "but its size is still worth keeping");
    }

    #[test]
    fn a_window_hanging_off_an_edge_keeps_its_position() {
        // Users park windows half off-screen on purpose; only unreachable is
        // a problem, not untidy.
        let f = fit(geom(1700.0, 100.0, 1200.0, 800.0));
        assert_eq!(f.x, Some(1700.0));
    }

    #[test]
    fn a_title_bar_dragged_above_the_top_edge_is_not_restored() {
        // Off the left is recoverable by dragging; off the top is not, because
        // the bar you would drag is what went missing.
        let f = fit(geom(200.0, -80.0, 1200.0, 800.0));
        assert_eq!(f.y, None);
        assert_eq!(f.x, None, "position is restored or dropped as a pair");
    }

    #[test]
    fn a_screen_smaller_than_the_minimum_window_still_yields_something_usable() {
        // A 800x600 display cannot satisfy a 980px minimum. Better to hand
        // back the minimum and let the window overflow than to return a
        // 800px-wide window the layout was never built for.
        let f = fit_window_geometry(geom(0.0, 0.0, 1000.0, 700.0), 800.0, 600.0, 980.0, 400.0);
        assert_eq!(f.width, 980.0);
        assert_eq!(f.height, 600.0);
    }

    #[test]
    fn maximized_survives_the_fit() {
        let g = WindowGeometry {
            maximized: true,
            ..geom(100.0, 100.0, 1200.0, 800.0)
        };
        assert!(fit(g).maximized);
    }
}
