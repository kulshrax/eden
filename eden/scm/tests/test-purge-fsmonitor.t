#require fsmonitor

  $ configure modernclient
  $ setconfig status.use-rust=False workingcopy.ruststatus=False
  $ newclientrepo repo
  $ touch x

Watchman clock is set after "status"

  $ hg status
  ? x
  $ hg debugshell -c 'ui.write("%s\n" % str(repo.dirstate.getclock()))'
  c:* (glob)

Watchman clock is not reset after a "purge --all"

  $ hg purge --all
  $ hg debugshell -c 'ui.write("%s\n" % str(repo.dirstate.getclock()))'
  c:* (glob)
  $ hg status
