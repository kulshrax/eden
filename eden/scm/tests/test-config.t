#debugruntest-compatible
#chg-compatible

hide outer repo
  $ setconfig workingcopy.ruststatus=False
  $ hg init

Invalid syntax: no value

  $ cat > .hg/hgrc << EOF
  > novaluekey
  > EOF
  $ hg showconfig
  hg: parse errors: "*hgrc": (glob)
   --> 1:11
    |
  1 | novaluekey\xe2\x90\x8a (esc)
    |           ^---
    |
    = expected equal_sign
  
  [255]

Invalid syntax: no key

  $ cat > .hg/hgrc << EOF
  > =nokeyvalue
  > EOF
  $ hg showconfig
  hg: parse errors: "*hgrc": (glob)
   --> 1:1
    |
  1 | =nokeyvalue\xe2\x90\x8a (esc)
    | ^---
    |
    = expected EOI, new_line, config_name, left_bracket, comment_line, or directive
  
  [255]

Test hint about invalid syntax from leading white space

  $ cat > .hg/hgrc << EOF
  >  key=value
  > EOF
  $ hg showconfig
  hg: parse errors: "*hgrc": (glob)
   --> 1:2
    |
  1 |  key=value\xe2\x90\x8a (esc)
    |  ^---
    |
    = expected EOI or new_line
  
  [255]

  $ cat > .hg/hgrc << EOF
  >  [section]
  > key=value
  > EOF
  $ hg showconfig
  hg: parse errors: "*hgrc": (glob)
   --> 1:2
    |
  1 |  [section]\xe2\x90\x8a (esc)
    |  ^---
    |
    = expected EOI or new_line
  
  [255]

Reset hgrc

  $ echo > .hg/hgrc

Test case sensitive configuration

  $ cat <<EOF >> $HGRCPATH
  > [Section]
  > KeY = Case Sensitive
  > key = lower case
  > EOF

  $ hg showconfig Section
  Section.KeY=Case Sensitive
  Section.key=lower case

  $ hg showconfig Section -Tjson
  [
   {
    "name": "Section.KeY",
    "source": "*", (glob)
    "value": "Case Sensitive"
   },
   {
    "name": "Section.key",
    "source": "*", (glob)
    "value": "lower case"
   }
  ]
  $ hg showconfig Section.KeY -Tjson
  [
   {
    "name": "Section.KeY",
    "source": "*", (glob)
    "value": "Case Sensitive"
   }
  ]
  $ hg showconfig -Tjson | tail -7
   },
   {
    "name": "*", (glob)
    "source": "*", (glob)
    "value": "*" (glob)
   }
  ]

Test "%unset"

  $ cat >> $HGRCPATH <<EOF
  > [unsettest]
  > local-hgrcpath = should be unset (HGRCPATH)
  > %unset local-hgrcpath
  > 
  > global = should be unset (HGRCPATH)
  > 
  > both = should be unset (HGRCPATH)
  > 
  > set-after-unset = should be unset (HGRCPATH)
  > EOF

  $ cat >> .hg/hgrc <<EOF
  > [unsettest]
  > local-hgrc = should be unset (.hg/hgrc)
  > %unset local-hgrc
  > 
  > %unset global
  > 
  > both = should be unset (.hg/hgrc)
  > %unset both
  > 
  > set-after-unset = should be unset (.hg/hgrc)
  > %unset set-after-unset
  > set-after-unset = should be set (.hg/hgrc)
  > EOF

  $ hg showconfig unsettest
  unsettest.set-after-unset=should be set (.hg/hgrc)

Test exit code when no config matches

  $ hg config Section.idontexist
  [1]

sub-options in [paths] aren't expanded

  $ cat > .hg/hgrc << EOF
  > [paths]
  > foo = ~/foo
  > foo:suboption = ~/foo
  > EOF

  $ hg showconfig paths
  paths.foo=$TESTTMP/foo
  paths.foo:suboption=~/foo

edit failure

  $ HGEDITOR=false hg config --edit
  abort: edit failed: false exited with status 1
  [255]

config affected by environment variables

  $ EDITOR=e1 hg config --debug | grep 'ui\.editor'
  $EDITOR: ui.editor=e1

  $ EDITOR=e2 hg config --debug --config ui.editor=e3 | grep 'ui\.editor'
  --config: ui.editor=e3

verify that aliases are evaluated as well

  $ hg init aliastest
  $ cd aliastest
  $ cat > .hg/hgrc << EOF
  > [ui]
  > user = repo user
  > EOF
  $ touch index
  $ unset HGUSER
  $ hg ci -Am test
  adding index
  $ hg log --template '{author}\n'
  repo user
  $ cd ..

alias has lower priority

  $ hg init aliaspriority
  $ cd aliaspriority
  $ cat > .hg/hgrc << EOF
  > [ui]
  > user = alias user
  > username = repo user
  > EOF
  $ touch index
  $ unset HGUSER
  $ hg ci -Am test
  adding index
  $ hg log --template '{author}\n'
  repo user
  $ cd ..

reponame is set from paths.default

  $ cat >> $HGRCPATH << EOF
  > [remotefilelog]
  > %unset reponame
  > EOF
  $ newrepo reponame-path-default-test
  $ enable remotenames
  $ hg paths --add default test:repo-myrepo1
  $ hg config remotefilelog.reponame
  repo-myrepo1
  $ cat .hg/reponame
  repo-myrepo1 (no-eol)

config editing without an editor

  $ newrepo

 invalid pattern
  $ hg config --edit invalid.syntax
  abort: invalid argument: 'invalid.syntax'
  (try section.name=value)
  [255]

 append configs
  $ hg config --local "aa.bb.cc.字=配
  > 置" ee.fff=gggg
  $ tail -6 .hg/hgrc | dos2unix
  [aa]
  bb.cc.字 = 配
    置
  
  [ee]
  fff = gggg

 update config in-place without appending
  $ hg config --local aa.bb.cc.字=new_值 "aa.bb.cc.字=新值
  > 测
  > 试
  > "
  $ tail -7 .hg/hgrc | dos2unix
  [aa]
  bb.cc.字 = 新值
    测
    试
  
  [ee]
  fff = gggg

  $ hg config aa.bb.cc.字
  新值\n测\n试

 with comments
  $ newrepo
  $ cat > .hg/hgrc << 'EOF'
  > [a]
  > # b = 1
  > b = 2
  >   second line
  > # b = 3
  > EOF

  $ hg config --local a.b=4
  $ cat .hg/hgrc
  [a]
  # b = 1
  b = 4
  # b = 3

#if no-windows
 user config
 (FIXME: windows implementation currently updates the real user's hgrc outside TESTTMP)
  $ hg config --edit a.b=1
  $ tail -2 ~/.hgrc
  [a]
  b = 1

#endif
