/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This software may be used and distributed according to the terms of the
 * GNU General Public License version 2.
 */

use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use anyhow::anyhow;
use anyhow::Result;
use configmodel::Config;
use configparser::config::ConfigSet;
use manifest_tree::ReadTreeManifest;
use manifest_tree::TreeManifest;
use parking_lot::Mutex;
use parking_lot::RwLock;
use pathmatcher::AlwaysMatcher;
use pathmatcher::DifferenceMatcher;
use pathmatcher::ExactMatcher;
use pathmatcher::GitignoreMatcher;
use pathmatcher::IntersectMatcher;
use pathmatcher::Matcher;
use pathmatcher::UnionMatcher;
use status::Status;
use storemodel::ReadFileContents;
use treestate::filestate::StateFlags;
use treestate::tree::VisitorResult;
use treestate::treestate::TreeState;
use types::HgId;
use types::RepoPathBuf;

#[cfg(feature = "eden")]
use crate::edenfs::EdenFileSystem;
use crate::filesystem::FileSystemType;
use crate::filesystem::PendingChangeResult;
use crate::filesystem::PendingChanges;
use crate::physicalfs::PhysicalFileSystem;
use crate::status::compute_status;
use crate::watchmanfs::WatchmanFileSystem;

type ArcReadFileContents = Arc<dyn ReadFileContents<Error = anyhow::Error> + Send + Sync>;
type ArcReadTreeManifest = Arc<dyn ReadTreeManifest + Send + Sync>;

struct FileSystem {
    root: PathBuf,
    file_store: ArcReadFileContents,
    file_system_type: FileSystemType,
    inner: Box<dyn PendingChanges + Send>,
}

impl AsRef<Box<dyn PendingChanges + Send>> for FileSystem {
    fn as_ref(&self) -> &Box<dyn PendingChanges + Send> {
        &self.inner
    }
}

pub struct WorkingCopy {
    treestate: Arc<Mutex<TreeState>>,
    tree_resolver: ArcReadTreeManifest,
    filesystem: Mutex<FileSystem>,
    ignore_matcher: Arc<GitignoreMatcher>,
}

impl WorkingCopy {
    pub fn new(
        root: PathBuf,
        // TODO: Have constructor figure out FileSystemType
        file_system_type: FileSystemType,
        treestate: Arc<Mutex<TreeState>>,
        tree_resolver: ArcReadTreeManifest,
        filestore: ArcReadFileContents,
        config: &ConfigSet,
    ) -> Result<Self> {
        tracing::debug!(target: "dirstate_size", dirstate_size=treestate.lock().len());

        let ignore_matcher = Arc::new(GitignoreMatcher::new(
            &root,
            WorkingCopy::global_ignore_paths(&root, config)
                .iter()
                .map(|i| i.as_path())
                .collect(),
        ));

        let filesystem = Mutex::new(Self::construct_file_system(
            root.clone(),
            file_system_type,
            treestate.clone(),
            tree_resolver.clone(),
            filestore,
        )?);

        Ok(WorkingCopy {
            treestate,
            tree_resolver,
            filesystem,
            ignore_matcher,
        })
    }

    pub fn treestate(&self) -> Arc<Mutex<TreeState>> {
        self.treestate.clone()
    }

    pub(crate) fn current_manifests(
        treestate: &TreeState,
        tree_resolver: &ArcReadTreeManifest,
    ) -> Result<Vec<Arc<RwLock<TreeManifest>>>> {
        let mut parents = treestate.parents().peekable();
        if parents.peek_mut().is_some() {
            parents
                .into_iter()
                .map(|p| tree_resolver.get(&p?))
                .collect()
        } else {
            let null_commit = HgId::null_id().clone();
            Ok(vec![tree_resolver.get(&null_commit)?])
        }
    }

    fn global_ignore_paths(root: &Path, config: &ConfigSet) -> Vec<PathBuf> {
        let mut ignore_paths = vec![];
        if let Some(value) = config.get("ui", "ignore") {
            let path = Path::new(value.as_ref());
            ignore_paths.push(root.join(path));
        }
        for name in config.keys_prefixed("ui", "ignore.") {
            let value = config.get("ui", &name).unwrap();
            let path = Path::new(value.as_ref());
            ignore_paths.push(root.join(path));
        }
        ignore_paths
    }

    fn construct_file_system(
        root: PathBuf,
        file_system_type: FileSystemType,
        treestate: Arc<Mutex<TreeState>>,
        tree_resolver: ArcReadTreeManifest,
        store: ArcReadFileContents,
    ) -> Result<FileSystem> {
        let inner: Box<dyn PendingChanges + Send> = match file_system_type {
            FileSystemType::Normal => Box::new(PhysicalFileSystem::new(
                root.clone(),
                tree_resolver,
                store.clone(),
                treestate.clone(),
                false,
                8,
            )?),
            FileSystemType::Watchman => Box::new(WatchmanFileSystem::new(
                root.clone(),
                treestate.clone(),
                tree_resolver,
                store.clone(),
            )?),
            FileSystemType::Eden => {
                #[cfg(not(feature = "eden"))]
                panic!("cannot use EdenFS in a non-EdenFS build");
                #[cfg(feature = "eden")]
                Box::new(EdenFileSystem::new(root.clone())?)
            }
        };
        Ok(FileSystem {
            root,
            file_store: store,
            file_system_type,
            inner,
        })
    }

    fn added_files(&self) -> Result<Vec<RepoPathBuf>> {
        let mut added_files: Vec<RepoPathBuf> = vec![];
        self.treestate.lock().visit(
            &mut |components, _| {
                let path = components.concat();
                let path = RepoPathBuf::from_utf8(path)?;
                added_files.push(path);
                Ok(VisitorResult::NotChanged)
            },
            &|_path, dir| match dir.get_aggregated_state() {
                None => true,
                Some(state) => {
                    let any_not_exists_parent = !state
                        .intersection
                        .intersects(StateFlags::EXIST_P1 | StateFlags::EXIST_P2);
                    let any_exists_next = state.union.intersects(StateFlags::EXIST_NEXT);
                    any_not_exists_parent && any_exists_next
                }
            },
            &|_path, file| {
                !file
                    .state
                    .intersects(StateFlags::EXIST_P1 | StateFlags::EXIST_P2)
                    && file.state.intersects(StateFlags::EXIST_NEXT)
            },
        )?;
        Ok(added_files)
    }

    fn sparse_matcher(
        &self,
        manifests: &Vec<Arc<RwLock<TreeManifest>>>,
    ) -> Result<Arc<dyn Matcher + Send + Sync + 'static>> {
        let fs = &self.filesystem.lock();

        let mut sparse_matchers: Vec<Arc<dyn Matcher + Send + Sync + 'static>> = Vec::new();
        if fs.file_system_type == FileSystemType::Eden {
            sparse_matchers.push(Arc::new(AlwaysMatcher::new()));
        } else {
            let ident = identity::must_sniff_dir(&fs.root)?;
            for manifest in manifests.iter() {
                match crate::sparse::repo_matcher(
                    &fs.root.join(ident.dot_dir()),
                    manifest.read().clone(),
                    fs.file_store.clone(),
                )? {
                    Some(matcher) => {
                        sparse_matchers.push(matcher);
                    }
                    None => {
                        sparse_matchers.push(Arc::new(AlwaysMatcher::new()));
                    }
                };
            }
        }

        Ok(Arc::new(UnionMatcher::new(sparse_matchers)))
    }

    pub fn status(
        &self,
        matcher: Arc<dyn Matcher + Send + Sync + 'static>,
        last_write: SystemTime,
        config: &dyn Config,
    ) -> Result<Status> {
        let added_files = self.added_files()?;

        let manifests =
            WorkingCopy::current_manifests(&self.treestate.lock(), &self.tree_resolver)?;
        let mut non_ignore_matchers: Vec<Arc<dyn Matcher + Send + Sync + 'static>> =
            Vec::with_capacity(manifests.len());

        for manifest in manifests.iter() {
            non_ignore_matchers.push(Arc::new(manifest_tree::ManifestMatcher::new(
                manifest.clone(),
            )));
        }
        non_ignore_matchers.push(Arc::new(ExactMatcher::new(added_files.iter())));

        let matcher = Arc::new(IntersectMatcher::new(vec![
            matcher,
            self.sparse_matcher(&manifests)?,
        ]));

        let matcher = Arc::new(DifferenceMatcher::new(
            matcher,
            DifferenceMatcher::new(
                self.ignore_matcher.clone(),
                UnionMatcher::new(non_ignore_matchers),
            ),
        ));
        let pending_changes = self
            .filesystem
            .lock()
            .inner
            .pending_changes(matcher.clone(), last_write, config)?
            .filter_map(|result| match result {
                Ok(PendingChangeResult::File(change_type)) => {
                    match matcher.matches_file(change_type.get_path()) {
                        Ok(true) => Some(Ok(change_type)),
                        Err(e) => Some(Err(e)),
                        _ => None,
                    }
                }
                Err(e) => Some(Err(e)),
                _ => None,
            });

        let p1_manifest = &*manifests[0].read();
        compute_status(
            p1_manifest,
            self.treestate.clone(),
            pending_changes,
            matcher.clone(),
        )
    }

    pub fn copymap(&self) -> Result<Vec<(RepoPathBuf, RepoPathBuf)>> {
        self.treestate
            .lock()
            .visit_by_state(StateFlags::COPIED)?
            .into_iter()
            .map(|(path, state)| {
                let copied_path = state
                    .copied
                    .ok_or_else(|| anyhow!("Invalid treestate entry for {}: missing copied from path on file with COPIED flag", String::from_utf8_lossy(&path)))
                    .map(|p| p.into_vec())
                    .and_then(|p| RepoPathBuf::from_utf8(p).map_err(|e| anyhow!(e)))?;
                Ok((
                    RepoPathBuf::from_utf8(path).map_err(|e| anyhow!(e))?,
                    copied_path,
                ))
            })
            .collect()
    }
}
