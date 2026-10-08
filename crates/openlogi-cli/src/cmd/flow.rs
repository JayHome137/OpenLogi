//! Flow management through the running Agent.

use std::process::ExitCode;

use anyhow::{Result, anyhow};
use clap::{Args, Subcommand};
use openlogi_ipc::FlowCommandError;
use tarpc::context;

use crate::agent;

/// Manage cross-machine Flow without opening hardware from the CLI process.
#[derive(Debug, Args)]
pub struct FlowArgs {
    #[command(subcommand)]
    command: Option<FlowCommand>,
}

#[derive(Debug, Subcommand)]
enum FlowCommand {
    /// Print the current Flow status and pairing phase as JSON.
    Status,
    /// Persistently enable Flow and arm its runtime.
    Enable,
    /// Persistently disable Flow and stop its runtime.
    Disable,
    /// Connect to a peer address and begin the SAS ceremony.
    PairStart {
        /// Hostname or IP address of the other OpenLogi agent.
        address: String,
    },
    /// Wait for one inbound Flow peer pairing connection.
    Listen,
    /// Confirm the currently displayed SAS code.
    Confirm,
    /// Reject the currently displayed SAS code.
    Reject,
    /// Cancel the active Flow pairing ceremony.
    Cancel,
}

/// Run one Flow command through the agent-owned IPC boundary.
pub async fn run(args: FlowArgs) -> Result<ExitCode> {
    let client = agent::connect()
        .await
        .map_err(|error| anyhow!("could not connect to the running Agent: {error}"))?;
    let command = args.command.unwrap_or(FlowCommand::Status);
    match command {
        FlowCommand::Status => {
            let snapshot = agent::snapshot(&client).await?;
            println!("{}", serde_json::to_string_pretty(&snapshot.flow)?);
        }
        FlowCommand::Enable => {
            call_config(&client, true).await?;
            println!("Flow enabled");
        }
        FlowCommand::Disable => {
            call_config(&client, false).await?;
            println!("Flow disabled");
        }
        FlowCommand::PairStart { address } => {
            call_flow(agent::call(
                client.flow_pair_start(context::current(), address),
            ))
            .await?;
            println!("Flow pairing started");
        }
        FlowCommand::Listen => {
            call_flow(agent::call(client.flow_pair_listen(context::current()))).await?;
            println!("Flow pairing listener started");
        }
        FlowCommand::Confirm => {
            call_flow(agent::call(client.flow_pair_confirm(context::current()))).await?;
            println!("Flow pairing confirmation sent");
        }
        FlowCommand::Reject => {
            call_flow(agent::call(client.flow_pair_reject(context::current()))).await?;
            println!("Flow pairing rejected");
        }
        FlowCommand::Cancel => {
            call_flow(agent::call(client.flow_pair_cancel(context::current()))).await?;
            println!("Flow pairing cancelled");
        }
    }
    Ok(ExitCode::SUCCESS)
}

async fn call_config(
    client: &openlogi_ipc::AgentClient,
    enabled: bool,
) -> Result<(), anyhow::Error> {
    let result = agent::call(client.flow_set_enabled(context::current(), enabled))
        .await
        .map_err(|error| anyhow!("Flow config update transport failed: {error:?}"))?;
    result.map_err(|error| anyhow!("Flow config update failed: {}", error.message))
}

async fn call_flow(
    result: Result<Result<(), FlowCommandError>, tarpc::client::RpcError>,
) -> Result<(), anyhow::Error> {
    let result = result.map_err(|error| anyhow!("Flow command transport failed: {error:?}"))?;
    result.map_err(|error| anyhow!("Flow command failed: {error:?}"))
}

#[cfg(test)]
mod tests {
    use clap::Parser as _;

    use super::*;

    #[test]
    fn pair_start_keeps_the_full_address_argument() {
        let cli =
            crate::Cli::try_parse_from(["openlogi", "flow", "pair-start", "desk.local:59869"])
                .expect("Flow pair-start parses");
        let crate::cmd::Command::Flow(args) = cli.cmd.expect("Flow command") else {
            panic!("expected Flow command");
        };
        assert!(matches!(
            args.command,
            Some(FlowCommand::PairStart { address }) if address == "desk.local:59869"
        ));
    }

    #[test]
    fn listen_command_parses() {
        let cli =
            crate::Cli::try_parse_from(["openlogi", "flow", "listen"]).expect("Flow listen parses");
        let crate::cmd::Command::Flow(args) = cli.cmd.expect("Flow command") else {
            panic!("expected Flow command");
        };
        assert!(matches!(args.command, Some(FlowCommand::Listen)));
    }
}
