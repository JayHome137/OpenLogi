use super::*;
use crate::edge::DisplayRect;

fn rect(x: f64, y: f64, width: f64, height: f64) -> DisplayRect {
    DisplayRect::new(x, y, width, height).expect("test rectangles are valid")
}

fn point(x: f64, y: f64) -> CursorPosition {
    CursorPosition { x, y }
}

fn assert_near(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() < 1e-9,
        "expected {expected}, got {actual}"
    );
}

fn dwell_params() -> EdgeDetectorParams {
    EdgeDetectorParams {
        dwell_time: Duration::from_millis(100),
        arrival_velocity_threshold: 10_000.0,
        cooldown: Duration::from_millis(500),
        ..EdgeDetectorParams::default()
    }
}

#[test]
fn defaults_define_dwell_velocity_hysteresis_and_cooldown() {
    let params = EdgeDetectorParams::default();

    assert_near(params.edge_tolerance, 1.0);
    assert_eq!(params.dwell_time, Duration::from_millis(250));
    assert_near(params.arrival_velocity_threshold, 900.0);
    assert_near(params.rearm_distance, 12.0);
    assert_eq!(params.cooldown, Duration::from_millis(500));
}

#[test]
fn normalization_uses_cumulative_exposed_length_and_skips_gaps() {
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 100.0, 100.0),
        rect(0.0, 200.0, 100.0, 100.0),
    ]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::from_sides([EdgeSide::Left]),
        EdgeDetectorParams {
            arrival_velocity_threshold: 1.0,
            ..EdgeDetectorParams::default()
        },
    );

    assert!(
        detector
            .update(point(10.0, 250.0), Duration::ZERO)
            .is_none()
    );
    let crossing = detector
        .update(point(0.0, 250.0), Duration::from_millis(10))
        .expect("fast arrival should cross");

    assert_near(crossing.t, 0.75);
}

#[test]
fn unarmed_side_never_starts_a_crossing() {
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 100.0, 100.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::from_sides([EdgeSide::Right]),
        EdgeDetectorParams {
            dwell_time: Duration::ZERO,
            ..EdgeDetectorParams::default()
        },
    );

    assert!(detector.update(point(0.0, 50.0), Duration::ZERO).is_none());
}

#[test]
fn fast_arrival_reports_side_position_and_velocity() {
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 100.0, 100.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::from_sides([EdgeSide::Left]),
        EdgeDetectorParams {
            arrival_velocity_threshold: 900.0,
            ..EdgeDetectorParams::default()
        },
    );

    assert!(detector.update(point(10.0, 25.0), Duration::ZERO).is_none());
    let crossing = detector
        .update(point(0.0, 50.0), Duration::from_millis(10))
        .expect("1,000 px/s outward arrival should cross");

    assert_eq!(crossing.side, EdgeSide::Left);
    assert_near(crossing.t, 0.5);
    assert_near(crossing.velocity.x, -1_000.0);
    assert_near(crossing.velocity.y, 2_500.0);
}

#[test]
fn dwell_triggers_once_and_edge_jitter_does_not_retrigger() {
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 100.0, 100.0)]);
    let mut detector = EdgeDetector::new(edges, ArmedSides::ALL, dwell_params());

    assert!(detector.update(point(0.0, 40.0), Duration::ZERO).is_none());
    assert!(
        detector
            .update(point(0.5, 40.0), Duration::from_millis(99))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 40.0), Duration::from_millis(100))
            .is_some()
    );
    assert!(
        detector
            .update(point(0.5, 40.0), Duration::from_millis(700))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 40.0), Duration::from_millis(1_500))
            .is_none()
    );
}

#[test]
fn hysteresis_and_cooldown_both_gate_a_second_approach() {
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 100.0, 100.0)]);
    let mut detector = EdgeDetector::new(edges, ArmedSides::ALL, dwell_params());

    assert!(detector.update(point(0.0, 50.0), Duration::ZERO).is_none());
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(100))
            .is_some()
    );

    // Five pixels is inside the 12 px hysteresis band, so this does not re-arm.
    assert!(
        detector
            .update(point(5.0, 50.0), Duration::from_millis(150))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(300))
            .is_none()
    );

    // Leaving the band re-arms, but the 500 ms cooldown still applies.
    assert!(
        detector
            .update(point(20.0, 50.0), Duration::from_millis(350))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(400))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(500))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(600))
            .is_some()
    );
}

#[test]
fn leaving_hysteresis_band_rearms_fast_arrival() {
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 100.0, 100.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::from_sides([EdgeSide::Right]),
        EdgeDetectorParams {
            arrival_velocity_threshold: 500.0,
            cooldown: Duration::from_millis(200),
            ..EdgeDetectorParams::default()
        },
    );

    assert!(detector.update(point(90.0, 50.0), Duration::ZERO).is_none());
    assert!(
        detector
            .update(point(100.0, 50.0), Duration::from_millis(10))
            .is_some()
    );
    assert!(
        detector
            .update(point(80.0, 50.0), Duration::from_millis(20))
            .is_none()
    );
    assert!(
        detector
            .update(point(90.0, 50.0), Duration::from_millis(210))
            .is_none()
    );
    assert!(
        detector
            .update(point(100.0, 50.0), Duration::from_millis(220))
            .is_some()
    );
}

#[test]
fn corner_prefers_greater_outward_velocity() {
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 100.0, 100.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::ALL,
        EdgeDetectorParams {
            arrival_velocity_threshold: 500.0,
            ..EdgeDetectorParams::default()
        },
    );

    assert!(detector.update(point(10.0, 20.0), Duration::ZERO).is_none());
    let crossing = detector
        .update(point(0.0, 0.0), Duration::from_millis(10))
        .expect("corner arrival should cross");

    assert_eq!(crossing.side, EdgeSide::Top);
    assert_near(crossing.t, 0.0);
}

#[test]
fn corner_exact_velocity_tie_uses_left_first_priority() {
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 100.0, 100.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::ALL,
        EdgeDetectorParams {
            arrival_velocity_threshold: 500.0,
            ..EdgeDetectorParams::default()
        },
    );

    assert!(detector.update(point(10.0, 10.0), Duration::ZERO).is_none());
    let crossing = detector
        .update(point(0.0, 0.0), Duration::from_millis(10))
        .expect("corner arrival should cross");

    assert_eq!(crossing.side, EdgeSide::Left);
    assert_near(crossing.t, 0.0);
}

#[test]
fn geometry_replacement_discards_in_progress_dwell() {
    let display = rect(0.0, 0.0, 100.0, 100.0);
    let mut detector = EdgeDetector::new(
        ExposedEdges::from_displays(&[display]),
        ArmedSides::ALL,
        dwell_params(),
    );

    assert!(detector.update(point(0.0, 50.0), Duration::ZERO).is_none());
    detector.set_edges(ExposedEdges::from_displays(&[display]));
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(100))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(200))
            .is_some()
    );
}

#[test]
fn geometry_replacement_preserves_crossing_latch_until_rearm() {
    let display = rect(0.0, 0.0, 100.0, 100.0);
    let mut detector = EdgeDetector::new(
        ExposedEdges::from_displays(&[display]),
        ArmedSides::ALL,
        dwell_params(),
    );

    assert!(detector.update(point(0.0, 50.0), Duration::ZERO).is_none());
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(100))
            .is_some()
    );
    detector.set_edges(ExposedEdges::from_displays(&[display]));
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(700))
            .is_none()
    );

    assert!(
        detector
            .update(point(20.0, 50.0), Duration::from_millis(750))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(800))
            .is_none()
    );
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(900))
            .is_some()
    );
}

#[test]
fn suspend_and_side_changes_preserve_crossing_latch() {
    let display = rect(0.0, 0.0, 100.0, 100.0);
    let mut detector = EdgeDetector::new(
        ExposedEdges::from_displays(&[display]),
        ArmedSides::ALL,
        dwell_params(),
    );

    assert!(detector.update(point(0.0, 50.0), Duration::ZERO).is_none());
    assert!(
        detector
            .update(point(0.0, 50.0), Duration::from_millis(100))
            .is_some()
    );
    detector.suspend();
    detector.set_armed_sides(ArmedSides::from_sides([EdgeSide::Left, EdgeSide::Top]));
    assert!(detector.is_latched());
    // Still pinned to the crossed edge long after the cooldown: no retrigger.
    for millis in [800, 1_000, 1_200] {
        assert!(
            detector
                .update(point(0.0, 50.0), Duration::from_millis(millis))
                .is_none()
        );
    }
    assert!(
        detector
            .update(point(30.0, 50.0), Duration::from_millis(1_300))
            .is_none()
    );
    assert!(!detector.is_latched());
}

#[test]
fn arrival_inset_is_outside_contact_band_even_for_exclusive_bounds() {
    let params = EdgeDetectorParams::default();
    // On exclusive right/bottom bounds the last reachable pixel is one unit
    // inside the edge coordinate, so the arrival must clear tolerance + 1.
    assert!(ARRIVAL_INSET > params.edge_tolerance + 1.0);
    assert!(ARRIVAL_INSET < params.rearm_distance);

    let display = rect(0.0, 0.0, 100.0, 100.0);
    let mut detector = EdgeDetector::new(
        ExposedEdges::from_displays(&[display]),
        ArmedSides::ALL,
        dwell_params(),
    );
    for (millis, position) in [
        (0, point(ARRIVAL_INSET, 50.0)),
        (300, point(ARRIVAL_INSET, 50.0)),
        (600, point(100.0 - ARRIVAL_INSET, 50.0)),
        (900, point(100.0 - ARRIVAL_INSET, 50.0)),
    ] {
        assert!(
            detector
                .update(position, Duration::from_millis(millis))
                .is_none()
        );
    }
}

#[test]
fn dwell_vs_fast_approach_on_irregular_layout() {
    // MVP① acceptance 2: dwell vs fast approach behavior on multi-display.
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 1920.0, 1080.0),
        rect(1920.0, 0.0, 1920.0, 1080.0),
    ]);

    // Test slow dwell: must wait full dwell_time from first contact
    let mut detector = EdgeDetector::new(
        edges.clone(),
        ArmedSides::ALL,
        EdgeDetectorParams {
            dwell_time: Duration::from_millis(250),
            arrival_velocity_threshold: 900.0,
            cooldown: Duration::from_millis(100),
            ..EdgeDetectorParams::default()
        },
    );

    // Approach left edge slowly: x=0.5 is within tolerance=1.0, so contact starts at t=50
    assert!(detector.update(point(10.0, 500.0), Duration::ZERO).is_none());
    assert!(detector.update(point(0.5, 500.0), Duration::from_millis(50)).is_none(), "first contact at t=50");
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(100)).is_none());
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(200)).is_none());
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(299)).is_none());
    // Dwell starts at t=50, should trigger at t=300 (50+250)
    assert!(
        detector.update(point(0.0, 500.0), Duration::from_millis(300)).is_some(),
        "slow approach should trigger after dwell_time from first contact"
    );

    // Test fast approach: triggers immediately if velocity threshold met
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::ALL,
        EdgeDetectorParams {
            dwell_time: Duration::from_millis(250),
            arrival_velocity_threshold: 900.0,
            cooldown: Duration::from_millis(100),
            ..EdgeDetectorParams::default()
        },
    );

    // Fast rightward approach to right edge: 1920 px in 10ms = 192000 px/s >> 900
    assert!(detector.update(point(1900.0, 500.0), Duration::ZERO).is_none());
    let crossing = detector
        .update(point(3840.0, 500.0), Duration::from_millis(10))
        .expect("fast approach should trigger immediately");
    assert_eq!(crossing.side, EdgeSide::Right);
    assert!(crossing.velocity.x > 900.0);
}

#[test]
fn cooldown_prevents_repeated_trigger_during_latch() {
    // MVP① acceptance 3: cooldown/rearm - latch period prevents re-trigger.
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 1920.0, 1080.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::ALL,
        EdgeDetectorParams {
            dwell_time: Duration::from_millis(50),
            arrival_velocity_threshold: 10_000.0, // high threshold to test dwell path
            cooldown: Duration::from_millis(500),
            rearm_distance: 20.0,
            ..EdgeDetectorParams::default()
        },
    );

    // First crossing via dwell
    assert!(detector.update(point(0.0, 500.0), Duration::ZERO).is_none());
    assert!(
        detector.update(point(0.0, 500.0), Duration::from_millis(50)).is_some(),
        "first crossing should succeed"
    );
    assert!(detector.is_latched());

    // While latched, no matter how long we wait, staying near edge won't retrigger
    for millis in [100, 200, 300, 600, 1000, 2000] {
        assert!(
            detector.update(point(0.0, 500.0), Duration::from_millis(millis)).is_none(),
            "latched state should prevent re-trigger at t={millis}ms"
        );
        assert!(detector.is_latched());
    }

    // Only after moving away beyond rearm_distance should latch clear
    assert!(detector.update(point(25.0, 500.0), Duration::from_millis(2100)).is_none());
    assert!(!detector.is_latched(), "latch should clear after leaving hysteresis band");
}

#[test]
fn rearm_after_leaving_hysteresis_band_and_cooldown() {
    // MVP① acceptance 3: rearm requires both leaving hysteresis + respecting cooldown.
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 1920.0, 1080.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::ALL,
        EdgeDetectorParams {
            dwell_time: Duration::from_millis(50),
            arrival_velocity_threshold: 10_000.0,
            cooldown: Duration::from_millis(500),
            rearm_distance: 20.0,
            ..EdgeDetectorParams::default()
        },
    );

    // First crossing at t=0, triggers at t=50
    assert!(detector.update(point(0.0, 500.0), Duration::ZERO).is_none());
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(50)).is_some());

    // Move away beyond rearm_distance at t=100ms - clears latch but cooldown still active until t=550
    assert!(detector.update(point(30.0, 500.0), Duration::from_millis(100)).is_none());
    assert!(!detector.is_latched());

    // Return to edge at t=200ms - new contact starts, but cooldown blocks trigger
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(200)).is_none());
    // Even after full dwell elapsed (200+50=250ms), cooldown still blocks until t=550
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(250)).is_none());
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(500)).is_none());
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(549)).is_none());

    // At t=550, cooldown expires; contact started at t=200, so dwell requirement already met
    assert!(
        detector.update(point(0.0, 500.0), Duration::from_millis(550)).is_some(),
        "after cooldown expires and dwell already satisfied, should trigger"
    );
}

#[test]
fn modifier_gate_blocks_unarmed_side_crossing() {
    // MVP① acceptance 4: modifier gate - unarmed sides must not trigger.
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 1920.0, 1080.0)]);

    // Only left and top armed (simulating modifier constraint)
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::from_sides([EdgeSide::Left, EdgeSide::Top]),
        EdgeDetectorParams {
            dwell_time: Duration::ZERO, // immediate trigger when armed
            arrival_velocity_threshold: 1.0,
            ..EdgeDetectorParams::default()
        },
    );

    // Left edge (armed) should trigger
    assert!(detector.update(point(10.0, 500.0), Duration::ZERO).is_none());
    let crossing = detector.update(point(0.0, 500.0), Duration::from_millis(10));
    assert!(crossing.is_some());
    assert_eq!(crossing.unwrap().side, EdgeSide::Left);

    // Wait for cooldown + move away
    assert!(detector.update(point(100.0, 500.0), Duration::from_millis(1000)).is_none());

    // Right edge (unarmed) should NOT trigger
    assert!(detector.update(point(1900.0, 500.0), Duration::from_millis(2000)).is_none());
    assert!(
        detector.update(point(1920.0, 500.0), Duration::from_millis(2010)).is_none(),
        "unarmed right edge should not trigger"
    );
}

#[test]
fn modifier_change_during_approach_drops_contact() {
    // MVP① acceptance 4: changing armed sides mid-approach should drop in-progress contact.
    let edges = ExposedEdges::from_displays(&[rect(0.0, 0.0, 1920.0, 1080.0)]);
    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::ALL,
        EdgeDetectorParams {
            dwell_time: Duration::from_millis(200),
            arrival_velocity_threshold: 10_000.0,
            ..EdgeDetectorParams::default()
        },
    );

    // Start approaching left edge
    assert!(detector.update(point(0.0, 500.0), Duration::ZERO).is_none());
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(100)).is_none());

    // Modifier released: left side now unarmed
    detector.set_armed_sides(ArmedSides::from_sides([EdgeSide::Right, EdgeSide::Top, EdgeSide::Bottom]));

    // Even after full dwell time, should not trigger on left (now unarmed)
    assert!(
        detector.update(point(0.0, 500.0), Duration::from_millis(200)).is_none(),
        "modifier change should drop left edge contact"
    );
    assert!(detector.update(point(0.0, 500.0), Duration::from_millis(400)).is_none());
}

#[test]
fn no_trigger_on_internal_shared_edge_in_multi_display() {
    // MVP① acceptance 1: should NOT trigger on internal (covered) edges.
    let edges = ExposedEdges::from_displays(&[
        rect(0.0, 0.0, 1920.0, 1080.0),
        rect(1920.0, 0.0, 1920.0, 1080.0),
    ]);

    let mut detector = EdgeDetector::new(
        edges,
        ArmedSides::ALL,
        EdgeDetectorParams {
            dwell_time: Duration::ZERO,
            arrival_velocity_threshold: 1.0,
            cooldown: Duration::from_millis(100),
            ..EdgeDetectorParams::default()
        },
    );

    // Approach the shared boundary from primary side: x=1920 is covered
    // Since it's not exposed, cursor at exactly x=1920.0, y=500 should NOT trigger
    assert!(detector.update(point(1910.0, 500.0), Duration::ZERO).is_none());
    assert!(detector.update(point(1920.0, 500.0), Duration::from_millis(10)).is_none());
    // Even with prolonged dwell
    assert!(detector.update(point(1920.0, 500.0), Duration::from_millis(300)).is_none());

    // But approaching the exposed outer edge at x=3840 should trigger
    assert!(detector.update(point(3830.0, 500.0), Duration::from_millis(500)).is_none());
    assert!(
        detector.update(point(3840.0, 500.0), Duration::from_millis(510)).is_some(),
        "exposed outer edge should trigger"
    );
}
