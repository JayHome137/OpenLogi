//! Flow settings page: how the pointer takes the mouse and keyboard to another
//! computer, whether copied text goes with it, where each paired computer sits,
//! and the pairing ceremony that adds one.
//!
//! Settings are `[flow]` in `config.toml` and reach the agent on reload, like
//! every other page. Peer link state and the pairing ceremony are the agent's:
//! they arrive in its observed [`FlowStatus`] (see [`apply_status`]), and the
//! pairing buttons send the same agent commands as `openlogi flow`.

use gpui::Global;
use gpui_component::radio::{Radio, RadioGroup};
use openlogi_core::config::{FlowConfig, FlowEdge};
use openlogi_ipc::{
    FlowCommandError, FlowLinkState, FlowPairingFailure, FlowPairingPhase, FlowStatus,
};

use super::{
    App, AppContext, AppState, Axis, Button, ButtonVariants, Context, Disableable, Entity,
    FontWeight, IconName, InputEvent, InputState, InteractiveElement, ParentElement, SettingField,
    SettingGroup, SettingItem, SettingPage, SettingsView, SharedString, Styled, Subscription,
    Window, div, h_flex, theme, v_flex,
};
use crate::services::ipc::{
    Command, FlowPairCancel, FlowPairConfirm, FlowPairListen, FlowPairReject, FlowPairStart,
};
use crate::ui::components::control_input;
use crate::ui::theme::Typography as _;

/// What the agent last reported about Flow, plus a pairing command it refused
/// (which starts no ceremony, so the status alone never explains it).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct FlowUi {
    status: FlowStatus,
    refusal: Option<FlowCommandError>,
}

impl Global for FlowUi {}

/// Take in the agent's latest Flow status. A changed ceremony supersedes a
/// refusal shown for the previous one. When the agent's peers differ from the
/// GUI's `[flow]` (it just saved a peer it paired), adopt the section from
/// disk so later saves here do not conflict with that write.
pub(super) fn apply_status(cx: &mut App, status: &FlowStatus) {
    let previous = cx.try_global::<FlowUi>().cloned().unwrap_or_default();
    if previous.status == *status {
        return;
    }
    let refusal = previous
        .refusal
        .filter(|_| previous.status.pairing == status.pairing);
    cx.set_global(FlowUi {
        status: status.clone(),
        refusal,
    });
    let stale_peers = AppState::try_read(cx).is_some_and(|state| {
        let configured = &state.flow_config().peers;
        configured.len() != status.peers.len()
            || configured
                .iter()
                .zip(&status.peers)
                .any(|(peer, observed)| peer.public_key != observed.public_key)
    });
    if stale_peers {
        AppState::apply(cx, AppState::adopt_flow_from_disk);
    }
}

/// Show a pairing command the agent refused or never received.
pub(super) fn apply_refusal(cx: &mut App, refusal: FlowCommandError) {
    let mut ui = cx.try_global::<FlowUi>().cloned().unwrap_or_default();
    ui.refusal = Some(refusal);
    cx.set_global(ui);
}

/// The pairing address field, and a subscription that re-renders the page
/// when the agent's Flow status changes. The field re-renders it as it is
/// typed in, so Pair enables with the first character.
pub(super) fn watch(
    window: &mut Window,
    cx: &mut Context<SettingsView>,
) -> (Entity<InputState>, Subscription) {
    let address =
        cx.new(|cx| InputState::new(window, cx).placeholder(tr!("flow.address_placeholder")));
    cx.subscribe(&address, |_, _, event: &InputEvent, cx| {
        if matches!(event, InputEvent::Change) {
            cx.notify();
        }
    })
    .detach();
    (address, cx.observe_global::<FlowUi>(|_, cx| cx.notify()))
}

fn send(cx: &mut App, command: impl Into<Command>) {
    if let Some(state) = AppState::try_global(cx) {
        let _ = state.read(cx).ipc_sender().send(command.into());
    }
    // A new command gets a fresh verdict.
    if let Some(ui) = cx.try_global::<FlowUi>().filter(|ui| ui.refusal.is_some()) {
        let ui = FlowUi {
            refusal: None,
            ..ui.clone()
        };
        cx.set_global(ui);
    }
}

pub(super) fn flow_page(address: Entity<InputState>, cx: &App) -> SettingPage {
    let config = AppState::try_read(cx)
        .map(|state| state.flow_config().clone())
        .unwrap_or_default();
    SettingPage::new(tr!("flow.flow"))
        .icon(IconName::Network)
        .description(tr!("flow.flow_description"))
        .resettable(false)
        .group(
            SettingGroup::new()
                .item(use_flow_item())
                .item(switch_computers_item())
                .item(copy_and_paste_item()),
        )
        .group(computers_group(&config, cx))
        .group(
            SettingGroup::new().title(tr!("flow.pair_computer")).item(
                SettingItem::new(
                    tr!("flow.pair_computer"),
                    SettingField::render(move |_, _, cx| pairing_panel(&address, cx)),
                )
                .layout(Axis::Vertical)
                .description(tr!("flow.pair_description")),
            ),
        )
}

fn use_flow_item() -> SettingItem {
    SettingItem::new(
        tr!("flow.use_flow"),
        SettingField::switch(
            |cx| AppState::try_read(cx).is_some_and(|s| s.flow_config().enabled),
            |enabled, cx| {
                AppState::apply(cx, |state| state.commit_flow_enabled(enabled));
            },
        ),
    )
    .description(tr!("flow.use_flow_description"))
}

/// The two ways Logi Options+ offers to switch: the edge alone, or the edge
/// with Control held, so reaching for something at the edge never switches.
fn switch_computers_item() -> SettingItem {
    SettingItem::new(
        tr!("flow.switch_computers"),
        SettingField::render(|_, _, cx| {
            let required = AppState::try_read(cx).is_some_and(|s| s.flow_config().require_modifier);
            RadioGroup::vertical("flow-switch-computers")
                .child(
                    Radio::new("flow-edge")
                        .label(tr!("flow.edge_of_screen"))
                        .debug_selector(|| "flow-edge".into()),
                )
                .child(
                    Radio::new("flow-edge-holding-control")
                        .label(if cfg!(target_os = "macos") {
                            tr!("flow.edge_of_screen_holding_control")
                        } else {
                            tr!("flow.edge_of_screen_holding_ctrl")
                        })
                        .debug_selector(|| "flow-edge-holding-control".into()),
                )
                .selected_index(Some(usize::from(required)))
                .on_change(|index, _, cx| {
                    let required = match index {
                        0 => false,
                        1 => true,
                        _ => unreachable!("Flow has exactly two ways to switch computers"),
                    };
                    AppState::apply(cx, |state| state.commit_flow_require_modifier(required));
                })
        }),
    )
    .layout(gpui::Axis::Vertical)
    .description(tr!("flow.switch_computers_description"))
}

/// The shared-clipboard switch. Both computers need it on.
fn copy_and_paste_item() -> SettingItem {
    SettingItem::new(
        tr!("flow.copy_and_paste"),
        SettingField::switch(
            |cx| AppState::try_read(cx).is_some_and(|s| s.flow_config().clipboard),
            |enabled, cx| {
                AppState::apply(cx, |state| state.commit_flow_clipboard(enabled));
            },
        ),
    )
    .description(tr!("flow.copy_and_paste_description"))
}

const EDGES: [(&str, Option<FlowEdge>); 5] = [
    ("none", None),
    ("left", Some(FlowEdge::Left)),
    ("right", Some(FlowEdge::Right)),
    ("top", Some(FlowEdge::Top)),
    ("bottom", Some(FlowEdge::Bottom)),
];

fn edge_label(edge: Option<FlowEdge>) -> SharedString {
    match edge {
        None => tr!("flow.edge_none"),
        Some(FlowEdge::Left) => tr!("flow.edge_left"),
        Some(FlowEdge::Right) => tr!("flow.edge_right"),
        Some(FlowEdge::Top) => tr!("flow.edge_top"),
        Some(FlowEdge::Bottom) => tr!("flow.edge_bottom"),
    }
}

/// Each paired computer, how its link is doing, and the edge of this screen
/// that leads to it.
fn computers_group(config: &FlowConfig, cx: &App) -> SettingGroup {
    let group = SettingGroup::new().title(tr!("flow.computers"));
    if config.peers.is_empty() {
        return group.item(SettingItem::render(|_, _, cx| {
            div()
                .text_color(theme::palette(cx).text_muted)
                .child(tr!("flow.no_computers"))
        }));
    }
    let observed = cx
        .try_global::<FlowUi>()
        .map(|ui| ui.status.peers.clone())
        .unwrap_or_default();
    config.peers.iter().fold(group, |group, peer| {
        let state = observed
            .iter()
            .find(|status| status.public_key == peer.public_key)
            .map_or(FlowLinkState::Lost, |status| status.state);
        let options = EDGES
            .iter()
            .map(|(id, edge)| (SharedString::new_static(id), edge_label(*edge)))
            .collect();
        let name = peer.name.clone();
        let read_name = name.clone();
        group.item(
            SettingItem::new(
                SharedString::from(peer.name.clone()),
                SettingField::dropdown(
                    options,
                    move |cx| {
                        let edge = AppState::try_read(cx).and_then(|state| {
                            state
                                .flow_config()
                                .layout
                                .iter()
                                .find(|layout| layout.peer == read_name)
                                .map(|layout| layout.edge)
                        });
                        let id = EDGES
                            .iter()
                            .find(|(_, candidate)| *candidate == edge)
                            .map_or("none", |(id, _)| id);
                        SharedString::new_static(id)
                    },
                    move |id, cx| {
                        let Some(&(_, edge)) = EDGES.iter().find(|(candidate, _)| id == *candidate)
                        else {
                            return;
                        };
                        AppState::apply(cx, |state| state.commit_flow_peer_edge(&name, edge));
                    },
                ),
            )
            .description(link_state_label(state)),
        )
    })
}

fn link_state_label(state: FlowLinkState) -> SharedString {
    match state {
        FlowLinkState::Connected => tr!("flow.peer_connected"),
        FlowLinkState::Degraded => tr!("flow.peer_degraded"),
        FlowLinkState::Lost => tr!("flow.peer_lost"),
    }
}

/// The pairing ceremony: dial or wait, compare the code both screens show,
/// then confirm or reject it.
fn pairing_panel(address: &Entity<InputState>, cx: &App) -> gpui::Div {
    let ui = cx.try_global::<FlowUi>().cloned().unwrap_or_default();
    let muted = theme::palette(cx).text_muted;
    let panel = v_flex().w_full().gap_2();
    match &ui.status.pairing {
        Some(FlowPairingPhase::Connecting { address }) => {
            let waiting = if address == "incoming" {
                tr!("flow.waiting_for_connection")
            } else {
                tr!("flow.connecting", address => address.clone())
            };
            panel.child(
                h_flex()
                    .w_full()
                    .gap_2()
                    .justify_between()
                    .child(div().text_color(muted).child(waiting))
                    .child(cancel_button()),
            )
        }
        Some(FlowPairingPhase::Prompted {
            machine_name,
            sas,
            local_confirmed,
            ..
        }) => panel.children(prompted(machine_name, sas, *local_confirmed, muted)),
        idle => {
            let note = idle_note(&ui, idle.as_ref());
            panel
                .child(pairing_form(address, ui.status.enabled, cx))
                .children(note.map(|note| {
                    div()
                        .text_color(muted)
                        .debug_selector(|| "flow-pairing-note".into())
                        .child(note)
                }))
        }
    }
}

/// The code to compare, and Confirm / Reject until this side has confirmed.
fn prompted(
    machine_name: &str,
    sas: &str,
    local_confirmed: bool,
    muted: gpui::Hsla,
) -> [gpui::Div; 2] {
    let code = v_flex()
        .gap_1()
        .child(div().child(tr!("flow.compare_code", name => machine_name.to_owned())))
        .child(
            div()
                .text_title()
                .font_weight(FontWeight::SEMIBOLD)
                .debug_selector(|| "flow-pairing-code".into())
                .child(SharedString::from(sas.to_owned())),
        );
    let actions = if local_confirmed {
        h_flex()
            .gap_2()
            .child(
                div()
                    .text_color(muted)
                    .child(tr!("flow.waiting_for_confirmation")),
            )
            .child(cancel_button())
    } else {
        h_flex()
            .gap_2()
            .child(
                Button::new("flow-pair-confirm")
                    .primary()
                    .label(tr!("flow.codes_match"))
                    .debug_selector(|| "flow-pair-confirm".into())
                    .on_click(|_, _, cx| send(cx, FlowPairConfirm)),
            )
            .child(
                Button::new("flow-pair-reject")
                    .outline()
                    .label(tr!("flow.codes_differ"))
                    .debug_selector(|| "flow-pair-reject".into())
                    .on_click(|_, _, cx| send(cx, FlowPairReject)),
            )
    };
    [code, actions]
}

/// The address field with Pair, and Wait for a request.
fn pairing_form(address: &Entity<InputState>, enabled: bool, cx: &App) -> gpui::Div {
    let typed = !address.read(cx).value().trim().is_empty();
    let pair_address = address.clone();
    h_flex()
        .w_full()
        .gap_2()
        .child(div().flex_1().min_w_0().child(control_input(address)))
        .child(
            Button::new("flow-pair-start")
                .primary()
                .label(tr!("flow.pair"))
                .disabled(!enabled || !typed)
                .debug_selector(|| "flow-pair-start".into())
                .on_click(move |_, _, cx| {
                    let address = pair_address.read(cx).value().trim().to_owned();
                    if !address.is_empty() {
                        send(cx, FlowPairStart { address });
                    }
                }),
        )
        .child(
            Button::new("flow-pair-listen")
                .outline()
                .label(tr!("flow.wait_for_request"))
                .disabled(!enabled)
                .debug_selector(|| "flow-pair-listen".into())
                .on_click(|_, _, cx| send(cx, FlowPairListen)),
        )
}

/// What the idle form says under it: why pairing is off, a refused command,
/// or how the last ceremony ended.
fn idle_note(ui: &FlowUi, phase: Option<&FlowPairingPhase>) -> Option<SharedString> {
    if !ui.status.enabled {
        return Some(tr!("flow.flow_off"));
    }
    if let Some(refusal) = &ui.refusal {
        return Some(refusal_text(refusal));
    }
    match phase {
        Some(FlowPairingPhase::Paired { name, .. }) => {
            Some(tr!("flow.paired", name => name.clone()))
        }
        Some(FlowPairingPhase::Failed(failure)) => Some(failure_text(failure)),
        _ => None,
    }
}

fn cancel_button() -> Button {
    Button::new("flow-pair-cancel")
        .outline()
        .label(tr!("common.cancel"))
        .debug_selector(|| "flow-pair-cancel".into())
        .on_click(|_, _, cx| send(cx, FlowPairCancel))
}

fn failure_text(failure: &FlowPairingFailure) -> SharedString {
    match failure {
        FlowPairingFailure::Rejected => tr!("flow.pair_rejected"),
        FlowPairingFailure::Timeout => tr!("flow.pair_timed_out"),
        FlowPairingFailure::Cancelled | FlowPairingFailure::NoActiveSession => {
            tr!("flow.pair_cancelled")
        }
        FlowPairingFailure::AlreadyActive => tr!("flow.pair_busy"),
        FlowPairingFailure::Unavailable => tr!("flow.flow_off"),
        FlowPairingFailure::Connection { message }
        | FlowPairingFailure::Protocol { message }
        | FlowPairingFailure::Persistence { message } => {
            tr!("flow.pair_failed", message => message.clone())
        }
    }
}

fn refusal_text(refusal: &FlowCommandError) -> SharedString {
    match refusal {
        FlowCommandError::Disabled | FlowCommandError::Unavailable => tr!("flow.flow_off"),
        FlowCommandError::AlreadyActive => tr!("flow.pair_busy"),
        FlowCommandError::NoActiveSession => tr!("flow.pair_cancelled"),
        FlowCommandError::Invalid { message }
        | FlowCommandError::Connection { message }
        | FlowCommandError::Protocol { message }
        | FlowCommandError::Persistence { message } => {
            tr!("flow.pair_failed", message => message.clone())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::{assets::AssetResolver, i18n::LOCALE_LOCK};
    use crate::state::{ConfigPersistence, Sources};
    use crate::ui::theme;
    use crate::windows::{WindowRegistry, settings};
    use gpui::{AppContext as _, Modifiers, TestAppContext, VisualTestContext, px, size};
    use openlogi_core::config::Config;

    #[gpui::test]
    fn switch_computers_choices_update_state_and_respect_failed_saves(cx: &mut TestAppContext) {
        let _locale = LOCALE_LOCK.lock().unwrap();
        cx.update(|cx| {
            gpui_component::init(cx);
            theme::register_builtin_themes(cx);
        });

        for read_only in [false, true] {
            let handle = cx.update(|cx| {
                let (commands, _) = tokio::sync::mpsc::unbounded_channel();
                let resolver = AssetResolver::new();
                let mut sources = Sources::in_memory(Config::ephemeral(), &resolver, commands);
                if read_only {
                    sources.persistence = ConfigPersistence::ReadOnly("read-only test".into());
                }
                AppState::set_global(cx.new(|_| AppState::new(sources)), cx);
                settings::open_at(settings::SettingsPage::Flow, cx);
                cx.global::<WindowRegistry>().settings.unwrap()
            });
            let mut visual = VisualTestContext::from_window(handle.into(), cx);
            visual.simulate_resize(size(px(920.), px(640.)));
            visual.update(|window, cx| window.draw(cx).clear(cx));
            let edge = visual.debug_bounds("flow-edge").unwrap();
            let holding_control = visual.debug_bounds("flow-edge-holding-control").unwrap();
            assert!(holding_control.top() >= edge.bottom());

            visual.simulate_click(holding_control.center(), Modifiers::default());
            visual.update(|window, cx| {
                window.draw(cx).clear(cx);
                let state = AppState::try_read(cx).unwrap();
                assert_eq!(state.flow_config().require_modifier, !read_only);
            });
            visual.simulate_click(edge.center(), Modifiers::default());
            visual.update(|window, cx| {
                window.draw(cx).clear(cx);
                let state = AppState::try_read(cx).unwrap();
                assert!(!state.flow_config().require_modifier);
                window.remove_window();
            });
        }
    }

    fn open_flow_page(
        cx: &mut TestAppContext,
        config: Config,
        status: &FlowStatus,
    ) -> (
        VisualTestContext,
        tokio::sync::mpsc::UnboundedReceiver<crate::services::ipc::Command>,
    ) {
        cx.update(|cx| {
            gpui_component::init(cx);
            theme::register_builtin_themes(cx);
        });
        let (handle, commands) = cx.update(|cx| {
            let (sender, commands) = tokio::sync::mpsc::unbounded_channel();
            let resolver = AssetResolver::new();
            let sources = Sources::in_memory(config, &resolver, sender);
            AppState::set_global(cx.new(|_| AppState::new(sources)), cx);
            apply_status(cx, status);
            settings::open_at(settings::SettingsPage::Flow, cx);
            (cx.global::<WindowRegistry>().settings.unwrap(), commands)
        });
        let mut visual = VisualTestContext::from_window(handle.into(), cx);
        visual.simulate_resize(size(px(920.), px(900.)));
        visual.update(|window, cx| window.draw(cx).clear(cx));
        (visual, commands)
    }

    #[gpui::test]
    fn a_prompted_ceremony_shows_the_code_and_confirms_through_the_agent(cx: &mut TestAppContext) {
        let _locale = LOCALE_LOCK.lock().unwrap();
        let status = FlowStatus {
            enabled: true,
            peers: Vec::new(),
            pairing: Some(FlowPairingPhase::Prompted {
                public_key: format!("ed25519:{}", "cd".repeat(32)),
                machine_name: "desk".into(),
                sas: "123 456".into(),
                local_confirmed: false,
                peer_confirmed: false,
            }),
        };
        let (mut visual, mut commands) = open_flow_page(cx, Config::ephemeral(), &status);
        assert!(visual.debug_bounds("flow-pairing-code").is_some());
        assert!(visual.debug_bounds("flow-pair-start").is_none());
        let confirm = visual.debug_bounds("flow-pair-confirm").unwrap();
        visual.simulate_click(confirm.center(), Modifiers::default());
        assert!(matches!(
            commands.try_recv(),
            Ok(crate::services::ipc::Command::FlowPairConfirm(_))
        ));
        visual.update(|window, _| window.remove_window());
    }

    #[gpui::test]
    fn an_idle_page_waits_for_a_request_and_shows_a_refusal(cx: &mut TestAppContext) {
        let _locale = LOCALE_LOCK.lock().unwrap();
        let status = FlowStatus {
            enabled: true,
            ..FlowStatus::default()
        };
        let (mut visual, mut commands) = open_flow_page(cx, Config::ephemeral(), &status);
        assert!(visual.debug_bounds("flow-pairing-note").is_none());
        let listen = visual.debug_bounds("flow-pair-listen").unwrap();
        visual.simulate_click(listen.center(), Modifiers::default());
        assert!(matches!(
            commands.try_recv(),
            Ok(crate::services::ipc::Command::FlowPairListen(_))
        ));

        visual.update(|window, cx| {
            apply_refusal(cx, FlowCommandError::AlreadyActive);
            window.draw(cx).clear(cx);
        });
        assert!(visual.debug_bounds("flow-pairing-note").is_some());
        visual.update(|window, _| window.remove_window());
    }
}
