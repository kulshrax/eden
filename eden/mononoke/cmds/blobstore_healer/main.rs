/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This software may be used and distributed according to the terms of the
 * GNU General Public License version 2.
 */

#![cfg_attr(not(fbcode_build), allow(unused_crate_dependencies))]
#![feature(never_type)]

mod dummy;
mod healer;

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use std::time::Instant;

use anyhow::bail;
use anyhow::format_err;
use anyhow::Context;
use anyhow::Error;
use anyhow::Result;
use blobstore::Blobstore;
use blobstore_factory::make_blobstore;
use blobstore_factory::BlobstoreOptions;
use blobstore_factory::ReadOnlyStorage;
use blobstore_sync_queue::BlobstoreSyncQueue;
use blobstore_sync_queue::SqlBlobstoreSyncQueue;
use borrowed::borrowed;
use cached_config::ConfigStore;
use chrono::Duration as ChronoDuration;
use clap::Parser;
use context::CoreContext;
use context::SessionContainer;
use dummy::DummyBlobstore;
use dummy::DummyBlobstoreSyncQueue;
use fbinit::FacebookInit;
use futures::future;
use futures_03_ext::BufferedParams;
use healer::Healer;
use metaconfig_types::BlobConfig;
use metaconfig_types::StorageConfig;
use mononoke_app::fb303::Fb303AppExtension;
use mononoke_app::MononokeApp;
use mononoke_app::MononokeAppBuilder;
use mononoke_types::DateTime;
use slog::info;
use slog::o;
use sql_construct::SqlConstructFromDatabaseConfig;
use sql_ext::facebook::MysqlOptions;
use wait_for_replication::WaitForReplication;

#[derive(Parser)]
#[clap(about = "Monitors blobstore_sync_queue to heal blobstores with missing data")]
struct MononokeBlobstoreHealerArgs {
    /// set limit for how many queue entries to process
    #[clap(long, default_value_t = 10000)]
    sync_queue_limit: usize,
    /// performs a single healing and prints what would it do without doing it
    #[clap(long)]
    dry_run: bool,
    /// drain the queue without healing.  Use with caution.
    #[clap(long)]
    drain_only: bool,
    /// id of storage group to be healed, e.g. manifold_xdb_multiplex
    #[clap(long)]
    storage_id: String,
    /// Optional source blobstore key in SQL LIKE format, e.g. repo0138.hgmanifest%
    #[clap(long)]
    blobstore_key_like: Option<String>,
    /// Log a lot less
    #[clap(long, short = 'q')]
    quiet: bool,
    /// If specified, only perform the given number of iterations
    #[clap(long)]
    iteration_limit: Option<u64>,
    /// Seconds. If specified, override default minimum age to heal of 120 seconds
    #[clap(long, default_value_t = 120)]
    heal_min_age_secs: i64,
    /// How maby blobs to heal concurrently.
    #[clap(long, default_value_t = 100)]
    heal_concurrency: usize,
    /// max combined size of concurrently healed blobs (approximate, will still let individual larger blobs through)
    #[clap(long, default_value_t = 10_000_000_000)]
    heal_max_bytes: u64,
}

async fn maybe_schedule_healer_for_storage(
    fb: FacebookInit,
    ctx: &CoreContext,
    dry_run: bool,
    drain_only: bool,
    blobstore_sync_queue_limit: usize,
    buffered_params: BufferedParams,
    storage_config: StorageConfig,
    mysql_options: &MysqlOptions,
    source_blobstore_key: Option<String>,
    readonly_storage: ReadOnlyStorage,
    blobstore_options: &BlobstoreOptions,
    iter_limit: Option<u64>,
    heal_min_age: ChronoDuration,
    config_store: &ConfigStore,
) -> Result<(), Error> {
    let (blobstore_configs, multiplex_id, queue_db, scuba_table, scuba_sample_rate) =
        match storage_config.clone().blobstore {
            BlobConfig::Multiplexed {
                blobstores,
                multiplex_id,
                queue_db,
                scuba_table,
                scuba_sample_rate,
                ..
            } => (
                blobstores,
                multiplex_id,
                queue_db,
                scuba_table,
                scuba_sample_rate,
            ),
            s => bail!("Storage doesn't use Multiplexed blobstore, got {:?}", s),
        };

    let sync_queue = SqlBlobstoreSyncQueue::with_database_config(
        fb,
        &queue_db,
        mysql_options,
        readonly_storage.0,
    )
    .context("While opening sync queue")?;

    let sync_queue: Arc<dyn BlobstoreSyncQueue> = if dry_run {
        let logger = ctx.logger().new(o!("sync_queue" => ""));
        Arc::new(DummyBlobstoreSyncQueue::new(sync_queue, logger))
    } else {
        Arc::new(sync_queue)
    };

    let blobstores = blobstore_configs.into_iter().map({
        borrowed!(scuba_table);
        move |(id, _, blobconfig)| async move {
            let blobconfig = BlobConfig::Logging {
                blobconfig: Box::new(blobconfig),
                scuba_table: scuba_table.clone(),
                scuba_sample_rate,
            };

            let blobstore = make_blobstore(
                fb,
                blobconfig,
                mysql_options,
                readonly_storage,
                blobstore_options,
                ctx.logger(),
                config_store,
                &blobstore_factory::default_scrub_handler(),
                None,
            )
            .await?;

            let blobstore: Arc<dyn Blobstore> = if dry_run {
                let logger = ctx.logger().new(o!("blobstore" => format!("{:?}", id)));
                Arc::new(DummyBlobstore::new(blobstore, logger))
            } else {
                blobstore
            };

            Result::<_, Error>::Ok((id, blobstore))
        }
    });

    let blobstores = future::try_join_all(blobstores)
        .await?
        .into_iter()
        .collect::<HashMap<_, _>>();

    let wait_for_replication = WaitForReplication::new(fb, config_store, storage_config, "healer")?;

    let multiplex_healer = Healer::new(
        blobstore_sync_queue_limit,
        buffered_params,
        sync_queue,
        Arc::new(blobstores),
        multiplex_id,
        source_blobstore_key,
        drain_only,
    );

    schedule_healing(
        ctx,
        multiplex_healer,
        wait_for_replication,
        iter_limit,
        heal_min_age,
    )
    .await
}

// Pass None as iter_limit for never ending run
async fn schedule_healing(
    ctx: &CoreContext,
    multiplex_healer: Healer,
    wait_for_replication: WaitForReplication,
    iter_limit: Option<u64>,
    heal_min_age: ChronoDuration,
) -> Result<(), Error> {
    let mut count = 0;
    let healing_start_time = Instant::now();
    let mut total_deleted_rows = 0;

    loop {
        let iteration_start_time = Instant::now();
        count += 1;
        if let Some(iter_limit) = iter_limit {
            if count > iter_limit {
                return Ok(());
            }
        }

        wait_for_replication
            .wait_for_replication(ctx.logger())
            .await
            .context("While waiting for replication")?;

        let now = DateTime::now().into_chrono();
        let healing_deadline = DateTime::new(now - heal_min_age);
        let (last_batch_was_full_size, deleted_rows) = multiplex_healer
            .heal(ctx, healing_deadline)
            .await
            .context("While healing")?;

        total_deleted_rows += deleted_rows;
        let total_elapsed = healing_start_time.elapsed().as_secs_f32();
        let iteration_elapsed = iteration_start_time.elapsed().as_secs_f32();
        info!(
            ctx.logger(),
            "Iteration rows processed: {} rows, {}s; total: {} rows, {}s",
            deleted_rows,
            iteration_elapsed,
            total_deleted_rows,
            total_elapsed,
        );

        // if last batch read was not full,  wait at least 1 second, to avoid busy looping as don't
        // want to hammer the database with thousands of reads a second.
        if !last_batch_was_full_size {
            info!(ctx.logger(), "The last batch was not full size, waiting...",);
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
}

#[fbinit::main]
fn main(fb: FacebookInit) -> Result<()> {
    let app = MononokeAppBuilder::new(fb)
        .with_app_extension(Fb303AppExtension {})
        .build::<MononokeBlobstoreHealerArgs>()?;

    app.run_with_fb303_monitoring(
        async_main,
        "blobstore_healer",
        cmdlib::monitoring::AliveService,
    )
}

async fn async_main(app: MononokeApp) -> Result<(), Error> {
    let args: MononokeBlobstoreHealerArgs = app.args()?;
    let env = app.environment();

    let storage_id = args.storage_id;
    let logger = app.logger();
    let config_store = app.config_store();
    let mysql_options = &env.mysql_options;
    let readonly_storage = env.readonly_storage;
    let blobstore_options = &env.blobstore_options;
    let storage_configs = app.storage_configs();
    let storage_config = storage_configs
        .storage
        .get(&storage_id)
        .ok_or_else(|| format_err!("Storage id `{}` not found", storage_id))?;
    let source_blobstore_key = args.blobstore_key_like;
    let blobstore_sync_queue_limit = args.sync_queue_limit;
    let heal_concurrency = args.heal_concurrency;
    let heal_max_bytes = args.heal_max_bytes;
    let dry_run = args.dry_run;
    let drain_only = args.drain_only;
    if drain_only && source_blobstore_key.is_none() {
        bail!("Missing --blobstore-key-like restriction for --drain-only");
    }

    let iter_limit = args.iteration_limit;
    let healing_min_age = ChronoDuration::seconds(args.heal_min_age_secs);
    let quiet = args.quiet;
    if !quiet {
        info!(logger, "Using storage_config {:?}", storage_config);
    }

    let scuba = env.scuba_sample_builder.clone();

    let ctx = SessionContainer::new_with_defaults(app.fb).new_context(logger.clone(), scuba);
    let buffered_params = BufferedParams {
        weight_limit: heal_max_bytes,
        buffer_size: heal_concurrency,
    };

    maybe_schedule_healer_for_storage(
        app.fb,
        &ctx,
        dry_run,
        drain_only,
        blobstore_sync_queue_limit,
        buffered_params,
        storage_config.clone(),
        mysql_options,
        source_blobstore_key,
        readonly_storage,
        blobstore_options,
        iter_limit,
        healing_min_age,
        config_store,
    )
    .await
}
