import std/os

# A committed nimble.lock disables nim's pkgs2 package scan, so raw
# `nim c` invocations (CI build steps) need explicit dependency paths.
# CI writes nimble.paths right after `nimble install --depsOnly`;
# locally the file never exists and nimble-driven builds are unaffected.
when withDir(thisDir(), fileExists("nimble.paths")):
  include "nimble.paths"
# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
