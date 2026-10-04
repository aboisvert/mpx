# mpx Windows runtime test: the beck-verified flow, scripted
#
# Run with: nimble test (on Windows)
#
# Requires mpx.exe in the working directory: CI builds it before
# `nimble test`, and the beck deploy drops it next to this binary.
#
# Covers: new cmd (daemon spawn, ConPTY child, TCP listener, .port
# file), attach roundtrip through the vetted TCP path, Ctrl-G detach,
# stdin-EOF detach, snapshot on reattach, default-shell probe, ls,
# kill with file sweep.

import std/[os, osproc, strutils, streams]
import mpx/runtime

const Session = "winsmoke"
const Shell = "winshell"
const EnvSession = "winenv"

let Bin = "mpx.exe"

proc runMpx(args: seq[string], chunks: seq[string] = @[],
            closeAfterMs = 0, secs = 30): tuple[output: string, exitCode: int] =
  ## chunks land as separate pipe writes 500ms apart so a lone BEL
  ## reaches the client in its own ReadFile and exercises the real
  ## Ctrl-G detach path. closeAfterMs > 0 holds stdin open after the
  ## chunks, letting snapshots land before EOF ends the client.
  let p = startProcess(Bin, args = args, options = {poStdErrToStdOut})
  for c in chunks:
    sleep(500)
    try:
      p.inputStream.write(c)
      p.inputStream.flush()
    except OSError, IOError:
      # child died before reading stdin; the exitCode assert below
      # carries its stderr
      break
  if closeAfterMs > 0:
    sleep(closeAfterMs)
    p.inputStream.close()
  discard p.waitForExit(secs * 1000)
  if p.running:
    p.kill()
  result.output = p.outputStream.readAll()
  result.exitCode = p.peekExitCode()
  p.close()

# Sweep leftovers from a previous run; kill of a dead session is
# expected to die (stale-file cleanup), the exit code is ignored
for s in [Session, Shell, EnvSession]:
  discard runMpx(@["kill", s], secs = 15)

# new cmd: daemon spawns detached, client attaches, `echo zkmark`
# roundtrips through the pty, then Ctrl-G (a lone BEL chunk) detaches
let first = runMpx(@["new", Session, "cmd"],
                   chunks = @["echo zkmark\r", "\a"])
doAssert first.exitCode == 0,
  "new+attach roundtrip failed (" & $first.exitCode & "): " & first.output
doAssert "zkmark" in first.output,
  "expected zkmark roundtripped through the pty: " & first.output
echo "test: new cmd, live roundtrip, Ctrl-G detach verified"

let envOut = runMpx(@["new", EnvSession, "cmd /c echo %MPX_SESSION%"],
                    closeAfterMs = 1500)
doAssert envOut.exitCode == 0,
  "MPX_SESSION roundtrip failed (" & $envOut.exitCode & "): " & envOut.output
doAssert EnvSession in envOut.output,
  "expected MPX_SESSION echoed in pty output: " & envOut.output
echo "test: MPX_SESSION in pty child verified"

# Reattach: the snapshot carries the previous output; stdin EOF with
# no input ends the client
let snap = runMpx(@["attach", Session], closeAfterMs = 1500)
doAssert snap.exitCode == 0, "reattach failed: " & snap.output
doAssert "zkmark" in snap.output,
  "snapshot missing previous output: " & snap.output
echo "test: reattach snapshot verified"

# A session with the default shell (pwsh/powershell/cmd probe)
let shell = runMpx(@["new", Shell], closeAfterMs = 1500)
doAssert shell.exitCode == 0,
  "default-shell session failed: " & shell.output
echo "test: default-shell session verified"

# ls lists both sessions
let lsOut = runMpx(@["ls"], secs = 15)
doAssert Session in lsOut.output and Shell in lsOut.output and
  EnvSession in lsOut.output,
  "ls missing sessions: " & lsOut.output
echo "test: ls lists both sessions"

# kill sweeps processes and files
for s in [Session, Shell, EnvSession]:
  let k = runMpx(@["kill", s], secs = 20)
  doAssert k.exitCode == 0, "kill " & s & " failed: " & k.output
  doAssert not fileExists(mpxDir() / (s & ".port")),
    s & " .port file survived kill"
  doAssert not fileExists(mpxDir() / (s & ".pid")),
    s & " .pid file survived kill"
echo "test: kill and file sweep verified"

echo "ALL WINDOWS TESTS PASSED"
