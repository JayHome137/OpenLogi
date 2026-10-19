//! Flow settings: the `[flow]` edits behind the Settings window's Flow page.

use openlogi_core::config::{FlowEdge, FlowLayout, FlowPeer};

use super::*;

fn state_with_config(config: Config) -> AppState {
    let resolver = AssetResolver::new();
    let (commands, _receiver) = tokio::sync::mpsc::unbounded_channel();
    AppState::new(Sources::in_memory(config, &resolver, commands))
}

fn peer(name: &str, byte: &str) -> FlowPeer {
    FlowPeer {
        name: name.into(),
        public_key: format!("ed25519:{}", byte.repeat(32)),
        addresses: Vec::new(),
    }
}

#[test]
fn placing_a_peer_on_an_edge_moves_whoever_was_there() {
    let mut config = Config::ephemeral();
    config.flow.peers = vec![peer("desk", "ab"), peer("laptop", "cd")];
    config.flow.layout = vec![FlowLayout {
        edge: FlowEdge::Left,
        peer: "desk".into(),
    }];
    let mut state = state_with_config(config);

    let _ = state.commit_flow_peer_edge("laptop", Some(FlowEdge::Left));
    assert_eq!(
        state.flow_config().layout,
        vec![FlowLayout {
            edge: FlowEdge::Left,
            peer: "laptop".into(),
        }]
    );

    let _ = state.commit_flow_peer_edge("laptop", Some(FlowEdge::Right));
    let _ = state.commit_flow_peer_edge("desk", Some(FlowEdge::Left));
    assert_eq!(state.flow_config().layout.len(), 2);

    let _ = state.commit_flow_peer_edge("desk", None);
    assert_eq!(
        state.flow_config().layout,
        vec![FlowLayout {
            edge: FlowEdge::Right,
            peer: "laptop".into(),
        }]
    );

    // An unknown peer is never placed.
    let _ = state.commit_flow_peer_edge("ghost", Some(FlowEdge::Top));
    assert_eq!(state.flow_config().layout.len(), 1);
}

#[test]
fn flow_can_be_turned_on_and_off() {
    let mut state = state_with_config(Config::ephemeral());
    let _ = state.commit_flow_enabled(true);
    assert!(state.flow_config().enabled);
    let _ = state.commit_flow_enabled(false);
    assert!(!state.flow_config().enabled);
}
