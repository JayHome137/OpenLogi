use super::*;

fn rect(x: f64, y: f64, width: f64, height: f64) -> DisplayRect {
    DisplayRect::new(x, y, width, height).expect("test rectangles are valid")
}

fn side_segments(edges: &ExposedEdges, side: EdgeSide) -> Vec<(f64, f64, f64)> {
    edges
        .for_side(side)
        .map(|segment| (segment.coordinate, segment.start, segment.end))
        .collect()
}

#[test]
fn display_rect_rejects_invalid_geometry() {
    assert!(DisplayRect::new(0.0, 0.0, 100.0, 100.0).is_some());
    assert!(DisplayRect::new(0.0, 0.0, 0.0, 100.0).is_none());
    assert!(DisplayRect::new(0.0, 0.0, -1.0, 100.0).is_none());
    assert!(DisplayRect::new(f64::NAN, 0.0, 100.0, 100.0).is_none());
}

#[test]
fn single_display_exposes_all_four_sides() {
    let edges = ExposedEdges::from_displays(&[rect(-100.0, -50.0, 200.0, 100.0)]);

    assert_eq!(
        side_segments(&edges, EdgeSide::Left),
        vec![(-100.0, -50.0, 50.0)]
    );
    assert_eq!(
        side_segments(&edges, EdgeSide::Right),
        vec![(100.0, -50.0, 50.0)]
    );
    assert_eq!(
        side_segments(&edges, EdgeSide::Top),
        vec![(-50.0, -100.0, 100.0)]
    );
    assert_eq!(
        side_segments(&edges, EdgeSide::Bottom),
        vec![(50.0, -100.0, 100.0)]
    );
}

#[test]
fn side_by_side_displays_hide_shared_vertical_edges() {
    let edges = ExposedEdges::from_displays(&[
        rect(-100.0, 0.0, 100.0, 100.0),
        rect(0.0, 0.0, 150.0, 100.0),
    ]);

    assert_eq!(
        side_segments(&edges, EdgeSide::Left),
        vec![(-100.0, 0.0, 100.0)]
    );
    assert_eq!(
        side_segments(&edges, EdgeSide::Right),
        vec![(150.0, 0.0, 100.0)]
    );
}

#[test]
fn vertically_stacked_displays_hide_shared_horizontal_edges() {
    let edges =
        ExposedEdges::from_displays(&[rect(0.0, -80.0, 100.0, 80.0), rect(0.0, 0.0, 100.0, 120.0)]);

    assert_eq!(
        side_segments(&edges, EdgeSide::Top),
        vec![(-80.0, 0.0, 100.0)]
    );
    assert_eq!(
        side_segments(&edges, EdgeSide::Bottom),
        vec![(120.0, 0.0, 100.0)]
    );
}

#[test]
fn l_shape_keeps_only_uncovered_part_of_a_touching_edge() {
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 100.0, 100.0),
        rect(100.0, 50.0, 100.0, 50.0),
    ]);

    assert_eq!(
        side_segments(&edges, EdgeSide::Right),
        vec![(100.0, 0.0, 50.0), (200.0, 50.0, 100.0)]
    );
    assert_eq!(
        side_segments(&edges, EdgeSide::Left),
        vec![(0.0, 0.0, 100.0)]
    );
}

#[test]
fn gap_keeps_both_facing_edges_exposed() {
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 100.0, 100.0),
        rect(110.0, 0.0, 100.0, 100.0),
    ]);

    assert_eq!(
        side_segments(&edges, EdgeSide::Right),
        vec![(100.0, 0.0, 100.0), (210.0, 0.0, 100.0)]
    );
    assert_eq!(
        side_segments(&edges, EdgeSide::Left),
        vec![(0.0, 0.0, 100.0), (110.0, 0.0, 100.0)]
    );
}

#[test]
fn overlapping_neighbors_merge_their_covered_spans() {
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 100.0, 200.0),
        rect(100.0, 25.0, 50.0, 75.0),
        rect(100.0, 80.0, 50.0, 70.0),
    ]);

    let primary_segments: Vec<_> = edges
        .for_side(EdgeSide::Right)
        .filter(|segment| segment.coordinate.total_cmp(&100.0).is_eq())
        .map(|segment| (segment.start, segment.end))
        .collect();
    assert_eq!(primary_segments, vec![(0.0, 25.0), (150.0, 200.0)]);
}

#[test]
fn irregular_multi_display_exposes_only_outer_edges() {
    // MVP① acceptance 1: irregular multi-display layout, only exposed edges trigger.
    // Scenario: 3 displays in L-shape: primary at (0,0), secondary at (1920,0),
    // third below primary at (0,1080). The internal shared edges must not be exposed.
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 1920.0, 1080.0),    // primary
        rect(1920.0, 0.0, 1920.0, 1080.0), // right neighbor
        rect(0.0, 1080.0, 1920.0, 1080.0), // bottom neighbor
    ]);

    // Primary right edge: should be fully covered by the right neighbor at x=1920
    let primary_right = edges
        .for_side(EdgeSide::Right)
        .filter(|s| s.coordinate.total_cmp(&1920.0).is_eq() && s.start >= 0.0 && s.end <= 1080.0)
        .count();
    assert_eq!(
        primary_right, 0,
        "primary's right edge at x=1920 should be covered by neighbor"
    );

    // Primary bottom edge: should be fully covered by bottom neighbor at y=1080
    let primary_bottom = edges
        .for_side(EdgeSide::Bottom)
        .filter(|s| s.coordinate.total_cmp(&1080.0).is_eq() && s.start >= 0.0 && s.end <= 1920.0)
        .count();
    assert_eq!(
        primary_bottom, 0,
        "primary's bottom edge at y=1080 should be covered by bottom neighbor"
    );

    // Left edge of primary: fully exposed
    assert_eq!(
        side_segments(&edges, EdgeSide::Left)
            .iter()
            .filter(|(coord, start, end)| {
                coord.total_cmp(&0.0).is_eq()
                    && start.total_cmp(&0.0).is_eq()
                    && end.total_cmp(&1080.0).is_eq()
            })
            .count(),
        1,
        "primary's left edge should be fully exposed"
    );

    // Right neighbor's right edge: fully exposed
    assert_eq!(
        side_segments(&edges, EdgeSide::Right)
            .iter()
            .filter(|(coord, _, _)| coord.total_cmp(&3840.0).is_eq()) // 1920 + 1920
            .count(),
        1,
        "right neighbor's right edge should be exposed"
    );

    // Bottom neighbor's bottom edge: fully exposed
    assert_eq!(
        side_segments(&edges, EdgeSide::Bottom)
            .iter()
            .filter(|(coord, _, _)| coord.total_cmp(&2160.0).is_eq()) // 1080 + 1080
            .count(),
        1,
        "bottom neighbor's bottom edge should be exposed"
    );
}

#[test]
fn overlapping_stacked_displays_hide_covered_portions() {
    // MVP① acceptance 1: overlapping/stacked displays where one partially covers another.
    // Display A: (0, 0, 1920, 1080), Display B: (1500, 500, 1920, 1080) overlapping.
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 1920.0, 1080.0),
        rect(1500.0, 500.0, 1920.0, 1080.0),
    ]);

    // Display A's right edge (x=1920) should be partially covered from y=500 to y=1080
    let a_right_exposed: Vec<_> = edges
        .for_side(EdgeSide::Right)
        .filter(|s| s.coordinate.total_cmp(&1920.0).is_eq())
        .map(|s| (s.start, s.end))
        .collect();

    // Precise assertion: ONLY the uncovered portion [0, 500] should be exposed
    assert_eq!(
        a_right_exposed.len(),
        1,
        "display A's right edge should have exactly one exposed segment"
    );
    assert!(
        (a_right_exposed[0].0 - 0.0).abs() < 1e-6 && (a_right_exposed[0].1 - 500.0).abs() < 1e-6,
        "display A's right edge should be exposed ONLY from y=0 to y=500, got {:?}",
        a_right_exposed[0]
    );

    // Explicitly verify that the covered portion [500, 1080] is NOT exposed
    let a_right_covered = edges
        .for_side(EdgeSide::Right)
        .filter(|s| {
            s.coordinate.total_cmp(&1920.0).is_eq()
                && s.start >= 500.0 - 1e-6
                && s.end <= 1080.0 + 1e-6
                && (s.start - 500.0).abs() > 1e-6 // not the boundary of exposed segment
        })
        .count();
    assert_eq!(
        a_right_covered, 0,
        "display A's covered portion [500, 1080] must not be exposed"
    );

    // Display B's right edge should be fully exposed at x=3420
    let b_right_count = edges
        .for_side(EdgeSide::Right)
        .filter(|s| s.coordinate.total_cmp(&3420.0).is_eq()) // 1500 + 1920
        .count();
    assert_eq!(
        b_right_count, 1,
        "display B's right edge should be fully exposed"
    );
}

#[test]
fn t_shape_stem_covers_inner_portions_of_top_bar() {
    // MVP① acceptance 1: genuine T-shape where stem partially covers the boundary
    // between two displays on top. Top-left: (0,0,1920,1080), Top-right: (1920,0,1920,1080)
    // Stem below: (960, 1080, 1920, 1080) — overlaps both top displays' bottom edges.
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 1920.0, 1080.0),      // top-left
        rect(1920.0, 0.0, 1920.0, 1080.0),   // top-right
        rect(960.0, 1080.0, 1920.0, 1080.0), // stem below, covers portions of both
    ]);

    // Top-left's bottom edge at y=1080: should be partially exposed, covered from x=960 onwards
    let top_left_bottom: Vec<_> = edges
        .for_side(EdgeSide::Bottom)
        .filter(|s| s.coordinate.total_cmp(&1080.0).is_eq() && s.start < 960.0)
        .map(|s| (s.start, s.end))
        .collect();
    assert_eq!(
        top_left_bottom.len(),
        1,
        "top-left bottom should have exactly one exposed segment"
    );
    assert!(
        (top_left_bottom[0].0 - 0.0).abs() < 1e-6 && (top_left_bottom[0].1 - 960.0).abs() < 1e-6,
        "top-left bottom edge should be exposed ONLY from x=0 to x=960"
    );

    // Top-right's bottom edge at y=1080: should be partially exposed from x=2880 onwards
    let top_right_bottom: Vec<_> = edges
        .for_side(EdgeSide::Bottom)
        .filter(|s| s.coordinate.total_cmp(&1080.0).is_eq() && s.start >= 2880.0 - 1e-6)
        .map(|s| (s.start, s.end))
        .collect();
    assert_eq!(
        top_right_bottom.len(),
        1,
        "top-right bottom should have exactly one exposed segment"
    );
    assert!(
        (top_right_bottom[0].0 - 2880.0).abs() < 1e-6
            && (top_right_bottom[0].1 - 3840.0).abs() < 1e-6,
        "top-right bottom edge should be exposed ONLY from x=2880 to x=3840"
    );

    // Verify the covered portions [960, 1920] and [1920, 2880] are NOT exposed
    let covered_count = edges
        .for_side(EdgeSide::Bottom)
        .filter(|s| {
            s.coordinate.total_cmp(&1080.0).is_eq()
                && s.start >= 960.0 - 1e-6
                && s.end <= 2880.0 + 1e-6
        })
        .count();
    assert_eq!(
        covered_count, 0,
        "covered portions of top displays' boundary must not be exposed"
    );

    // Internal shared edge between top-left and top-right at x=1920 should be fully covered
    let internal_vertical = edges
        .for_side(EdgeSide::Right)
        .filter(|s| s.coordinate.total_cmp(&1920.0).is_eq() && s.start >= 0.0 && s.end <= 1080.0)
        .count();
    assert_eq!(
        internal_vertical, 0,
        "internal vertical edge between top displays must not be exposed"
    );

    // Stem's bottom edge should be fully exposed
    let stem_bottom = edges
        .for_side(EdgeSide::Bottom)
        .filter(|s| s.coordinate.total_cmp(&2160.0).is_eq())
        .count();
    assert_eq!(stem_bottom, 1, "stem's bottom edge should be fully exposed");
}
