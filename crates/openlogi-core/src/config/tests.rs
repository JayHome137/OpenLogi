//! Config tests: the shared fixtures, and one module per area.

use std::{assert_matches, fs};

use super::*;
use crate::binding::{default_binding, default_gesture_binding};
use crate::hid::{Dpi, SmartShiftAutoDisengage, SmartShiftThreshold, TunableTorque};

mod app_settings;
mod device_settings;
mod files;
mod gestures;
mod identity;
mod keyboard;
mod lighting;
mod links;
mod migrations;
mod per_app;
mod schema;

fn write_and_read(config: &Config) -> Config {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("config.toml");
    config.save_to_path(&path).expect("save");
    Config::load_from_path(&path).expect("load")
}

#[test]
fn full_flow_section_roundtrips() {
    let source = r#"
schema_version = 7

[flow]
enabled = true
require_modifier = false

[[flow.peers]]
name = "work-laptop"
public_key = "ed25519:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
addresses = ["work-laptop.tailnet.example", "10.0.0.7"]

[[flow.layout]]
edge = "right"
peer = "work-laptop"

[[flow.devices]]
key = "unit:0f1e2d3c"
peer_channels = { self = 0, "work-laptop" = 1 }
"#;

    let config: Config = toml::from_str(source).expect("full Flow config must parse");
    assert_eq!(config.flow.peers.len(), 1);
    assert_eq!(config.flow.layout[0].edge, FlowEdge::Right);
    assert_eq!(config.flow.devices[0].peer_channels["work-laptop"], 1);

    let written = toml::to_string_pretty(&config).expect("serialize Flow config");
    let reparsed: Config = toml::from_str(&written).expect("reparse Flow config");
    assert_eq!(reparsed.flow, config.flow);
}

#[test]
fn empty_flow_section_uses_defaults() {
    for source in ["schema_version = 7\n", "schema_version = 7\n\n[flow]\n"] {
        let config: Config = toml::from_str(source).expect("empty Flow config must parse");
        assert_eq!(config.flow, FlowConfig::default());
        assert!(
            !toml::to_string_pretty(&config)
                .expect("serialize default Flow config")
                .contains("[flow]")
        );
    }
}

#[test]
fn malformed_flow_entries_are_rejected() {
    for source in [
        "schema_version = 7\n[flow]\nunknown = true\n",
        "schema_version = 7\n[[flow.peers]]\nname = \"peer\"\n",
        "schema_version = 7\n[[flow.layout]]\nedge = \"diagonal\"\npeer = \"peer\"\n",
        "schema_version = 7\n[[flow.devices]]\nkey = \"unit:0f1e2d3c\"\npeer_channels = { self = \"zero\" }\n",
    ] {
        assert!(toml::from_str::<Config>(source).is_err());
    }
}
