/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This software may be used and distributed according to the terms of the
 * GNU General Public License version 2.
 */

#![feature(backtrace)]

use std::fs::File;
use std::io::Write;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use anyhow::Context;
use anyhow::Result;
use clap::Parser;
use cloned::cloned;
use cmdlib_logging::ScribeLoggingArgs;
use fb303_core::server::make_BaseService_server;
use fbinit::FacebookInit;
use futures::StreamExt;
use land_service_if::server::*;
use mononoke_api::Mononoke;
use mononoke_app::MononokeAppBuilder;
use signal_hook::consts::signal::SIGINT;
use signal_hook::consts::signal::SIGTERM;
use signal_hook_tokio::Signals;
use slog::info;
use srserver::service_framework::BuildModule;
use srserver::service_framework::Fb303Module;
use srserver::service_framework::ServiceFramework;
use srserver::service_framework::ThriftStatsModule;
use srserver::ThriftServer;
use srserver::ThriftServerBuilder;
use LandService_metadata_sys::create_metadata;

const SERVICE_NAME: &str = "mononoke_land_service_server";

mod errors;
mod facebook;
mod land_service_impl;

#[derive(Debug, Parser)]
struct LandServiceServerArgs {
    #[clap(flatten)]
    scribe_logging_args: ScribeLoggingArgs,
    /// Thrift host
    #[clap(long, short = 'H', default_value = "::")]
    host: String,
    /// Thrift port
    #[clap(long, short = 'p', default_value_t = 8485)]
    port: u16,
    /// Path for file in which to write the bound tcp address in rust std::net::SocketAddr format
    #[clap(long)]
    bound_address_file: Option<String>,
}

#[fbinit::main]
fn main(fb: FacebookInit) -> Result<()> {
    let app = Arc::new(MononokeAppBuilder::new(fb).build::<LandServiceServerArgs>()?);

    // Process commandline flags
    let args: LandServiceServerArgs = app.args()?;

    let logger = app.logger();
    let runtime = app.runtime();
    let exec = runtime.clone();
    let env = app.environment();

    let scuba_builder = env.scuba_sample_builder.clone();
    let mononoke = Arc::new(runtime.block_on(Mononoke::new(Arc::clone(&app)))?);

    let will_exit = Arc::new(AtomicBool::new(false));

    let fb303_base = {
        cloned!(will_exit);
        move |proto| {
            make_BaseService_server(proto, facebook::BaseServiceImpl::new(will_exit.clone()))
        }
    };

    let land_service_server = land_service_impl::LandServiceImpl::new(
        fb,
        logger.clone(),
        mononoke,
        scuba_builder,
        args.scribe_logging_args.get_scribe(fb)?,
        &app.repo_configs().common,
    );

    let service = {
        move |proto| {
            make_LandService_server(
                proto,
                land_service_server.thrift_server(),
                fb303_base.clone(),
            )
        }
    };

    let thrift: ThriftServer = ThriftServerBuilder::new(fb)
        .with_name(SERVICE_NAME)
        .expect("failed to set name")
        .with_address(&args.host, args.port, false)?
        .with_tls()
        .expect("failed to enable TLS")
        .with_cancel_if_client_disconnected()
        .with_metadata(create_metadata())
        .with_factory(exec, move || service)
        .build();

    let mut service_framework = ServiceFramework::from_server(SERVICE_NAME, thrift)
        .context("Failed to create service framework server")?;

    service_framework.add_module(BuildModule)?;
    service_framework.add_module(ThriftStatsModule)?;
    service_framework.add_module(Fb303Module)?;

    service_framework
        .serve_background()
        .expect("failed to start thrift service");

    let bound_addr = format!(
        "{}:{}",
        &args.host,
        service_framework.get_address()?.get_port()?
    );

    info!(logger, "Listening on {}", bound_addr);

    // Write out the bound address if requested, this is helpful in tests when using automatic binding with :0
    if let Some(bound_addr_path) = args.bound_address_file {
        let mut writer = File::create(bound_addr_path)?;
        writer.write_all(bound_addr.as_bytes())?;
        writer.write_all(b"\n")?;
    }

    // Start a task to spin up a thrift service
    let thrift_service_handle = runtime.spawn(run_thrift_service(service_framework));
    // Have the runtime wait for thrift service to finish
    runtime.block_on(thrift_service_handle)?
}

async fn run_thrift_service(service: ServiceFramework) -> Result<()> {
    let mut signals = Signals::new(&[SIGTERM, SIGINT])?;

    signals.next().await;
    println!("Shutting down...");
    service.stop();
    signals.handle().close();
    Ok(())
}
