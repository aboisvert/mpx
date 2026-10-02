# Cybernetic Plan: mpx v3, cross-platform (Windows)

## Context

mpx is a transparent terminal multiplexer: a daemon owns the PTY master and
forwards bytes verbatim; clients are dumb terminals; ttty models the screen
only for attach snapshots. It is currently POSIX-only. Goal: native Windows
support (ConPTY, Win10 1809+) plus CI covering all four primary targets:
linux-amd64, linux-arm64, macOS-universal, windows-amd64 (termux-arm64 stays
as the fifth, untouched).

The v0-v2 plan (multiplexer core, ttty integration, multi-client, TCP relay)
is complete; history lives in git history of this file at `3f8c6dc` and below.

Code that matters: `src/mpx/pty.nim` (openpty/fork/ioctl), `protocol.nim`
(AF_UNIX + TCP, read/write on socket fds), `client.nim` (termios raw mode,
SIGWINCH self-pipe, selectors loop), `daemon.nim` (selectors event loop,
outq/inbuf queues), `mpx.nim` (fork-daemonize, kill via SIGTERM, ls),
`session.nim` (S_ISSOCK discovery, O_EXCL locks), `runtime.nim` (/tmp dirs).

Decisions already made, do not relitigate:

- **Transport on Windows**: loopback TCP + a `<name>.port` file in mpxDir.
  Reuses the existing TCP framing and mkAttach vetting. Named pipes (DACLs,
  per-SID namespace like wmux) are a future hardening step, not now.
- **Daemon loop on Windows**: WaitForMultipleObjects on WSA socket events
  plus a pty-data event; ConPTY is read by a blocking reader thread and
  written by a blocking writer thread (queues + events). Anonymous pipes
  are not selectable; threads are the honest translation of epoll here.
- **MAXIMUM_WAIT_OBJECTS is 64**: cap attached clients at 56 on Windows.
- **Client on Windows**: console mode raw VT input, resize detected by a
  250ms poller thread (there is no SIGWINCH on Windows), loop waits on
  console input handle (waitable) + socket event + resize event. Ctrl-G
  (0x07) detach logic is unchanged.
- **protocol.nim**: socket I/O becomes `send`/`recv` on both platforms
  (read/write on fds does not work on Windows sockets). Nonblocking via
  `ioctlsocket(FIONBIO)` on Windows, fcntl elsewhere.
- **Win32 imports** live in one new module `src/mpx/win.nim` (importc,
  dynlib kernel32/user32/ws2_32, stdcall). No other module declares raw
  Win32 procs.
- **Default shell on Windows**: pwsh.exe, else powershell.exe, else cmd.exe.
- **Spawning the daemon on Windows**: CreateProcessW with
  DETACHED_PROCESS (no console: CTRL_CLOSE_EVENT never reaches it) and
  CREATE_BREAKAWAY_FROM_JOB (escapes sshd's job object). If breakaway is
  refused, warn on stderr and continue (wmux precedent).
- **Local verification limits**: this sandbox has no mingw and no Windows.
  Per-module Windows verification is `nim check --os:windows --cpu:amd64`.
  Runtime verification of Windows code happens on the CI windows runner.
- Windows version floor: 10 1809 (ConPTY). Note in README.

House rules: read `~/p/3CODE.md`. No macros. No em dashes in anything
committed. Commit per step, short one-liners, stage specific files, never
push, no nimble install after commits.

## Current State

Step 1 done: `src/mpx/win.nim` exists and checks clean under
`--os:windows`. It imports and re-exports std/winlean (which already
supplies createPipe, createProcessW, waitForSingleObject,
waitForMultipleObjects, terminateProcess, OpenProcess's cousins, socket
primitives, MAXIMUM_WAIT_OBJECTS, DETACHED_PROCESS, SYNCHRONIZE) and
declares the missing pieces: ConPTY trio + HPCON/COORD,
STARTUPINFOEXW + attribute-list procs, console procs + types + flags,
CreateEventW/SetEvent/CreateThread, CreateFileW, WSACreateEvent/
WSAEventSelect/ioctlsocket, OpenProcess, FIONBIO/FD_* consts,
initWinsock(). Posix build/test/example stay green (win.nim is not
imported by anything posix yet). Existing workflows untouched:
linux-amd64.yml, linux-arm64.yml, osx.yml, termux.yml, release.yml
(release.yml still needs windows-amd64 added in step 8).

## Steps

- [x] 1. **win.nim import layer.** Done. `src/mpx/win.nim` imports and
  re-exports std/winlean, so the pieces winlean already has (createPipe,
  createProcessW with `var STARTUPINFO` that a STARTUPINFOEXW's
  StartupInfo field satisfies, waitForSingleObject,
  waitForMultipleObjects, terminateProcess, getStdHandle, readFile/
  writeFile, socket/send/recv, MAXIMUM_WAIT_OBJECTS, DETACHED_PROCESS,
  SYNCHRONIZE, WSAData/wsaStartup) come from there. Declared fresh,
  dynlib kernel32/ws2_32 + stdcall: ConPTY (CreatePseudoConsole,
  ResizePseudoConsole, ClosePseudoConsole, HPCON = Handle, COORD),
  STARTUPINFOEXW, LPPROC_THREAD_ATTRIBUTE_LIST, attribute-list procs
  plus PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE (0x00020016) and
  EXTENDED_STARTUPINFO_PRESENT, CREATE_BREAKAWAY_FROM_JOB,
  CREATE_NEW_PROCESS_GROUP, console (GetConsoleMode, SetConsoleMode,
  GetConsoleScreenBufferInfo, CONSOLE_SCREEN_BUFFER_INFO, SMALL_RECT,
  the ENABLE_ line/echo/processed/VT flags), CreateEventW, SetEvent,
  CreateThread + ThreadProc, CreateFileW with GENERIC_WRITE/
  FILE_SHARE_*/CREATE_NEW, WSACreateEvent, WSAEventSelect, ioctlsocket
  with FIONBIO and FD_READ/FD_WRITE/FD_CLOSE, OpenProcess with
  PROCESS_TERMINATE. Added `initWinsock()` (WSAStartup 2.2, raises
  OSError). Verified: windows check clean, posix build + nimble test +
  nimble example green.
- [ ] 2. **pty.nim Windows branch.** Gate the posix code with
  `when not defined(windows)`; add the ConPTY branch behind the same
  `Pty` API: openPty (CreatePipe pair, CreatePseudoConsole with initial
  size, CreateProcessW with the pseudoconsole attribute, running the
  resolved default shell when cmd is the shell case), setSize
  (ResizePseudoConsole), read/write (ReadFile/WriteFile on the pipe
  ends, blocking), close (ClosePseudoConsole + closing handles), plus a
  way for the daemon to learn the child exited (WaitForSingleObject on
  the process handle, or read returning broken-pipe). Default-shell
  resolution helper shared by both branches. Verify: posix build + test
  green; `nim check --os:windows` clean on pty.nim.
- [ ] 3. **Transport, discovery, protocol unification.** protocol.nim:
  sendMsg/readFull use send/recv; setNonBlocking branches to
  ioctlsocket; keep one-send-per-frame. runtime.nim: runtimeDir falls
  back to %TEMP% (getEnv TEMP, then LOCALAPPDATA/Temp) on Windows.
  session.nim: `when defined(windows)` discovery via `<name>.port` files
  (isActive = port file parses + TCP connect to 127.0.0.1 succeeds;
  oldestSession ranks .pid mtimes among sessions with a .port),
  exclusive lock claim via CreateFileW CREATE_NEW. mpx.nim calls
  initWinsock on Windows. Verify: build + nimble test + nimble example
  green on posix; check --os:windows clean for these modules.
- [ ] 4. **mpx.nim Windows spawn/kill.** The `new` path daemonize step:
  CreateProcessW (detached, breakaway, new process group) instead of
  fork/execv; readiness loop polls isActive plus
  WaitForSingleObject(pid, 0) for early exit; `kill`: TerminateProcess
  via OpenProcess on the pid from the pid file, then the existing stale
  sweep; `ls`: walk mpxDir for .port files instead of .sock. Verify:
  posix suite green; check --os:windows clean on mpx.nim.
- [ ] 5. **daemon.nim Windows event loop.** Reader thread: blocking
  ReadFile on the ConPTY output pipe, appends chunks to a shared buffer,
  SetEvent. Writer thread: waits on an input event, drains the input
  queue with blocking WriteFile. Main loop: WaitForMultipleObjects over
  stop event, pty-data event, listen + tcp + client socket events
  (WSAEventSelect), mirroring the posix loop's accept/vet/snapshot/
  broadcast/outq logic (nonblocking send, queue on would-block). Child
  exit ends the session as today (read side sees broken pipe). 56-client
  cap enforced at accept. Verify: posix suite green; check --os:windows
  clean on daemon.nim.
- [ ] 6. **client.nim Windows console layer.** Save console modes; raw
  VT input (clear line/echo/processed, set VT input), best-effort VT
  processing on output; resize poller thread (250ms, console screen
  buffer info, SetEvent + stash w/h); loop waits on console input handle
  + socket event + resize event; Ctrl-G lone-keypress detach unchanged;
  restore modes on exit. Verify: posix suite green; check --os:windows
  clean on client.nim; from here `nim check --os:windows` on
  src/mpx.nim must be clean too.
- [ ] 7. **Tests and example.** Read tests/test1.nim and example/
  example.nim first, then extend: windows branches exercise openPty +
  ConPTY roundtrip with the resolved shell and daemon-over-loopback at
  wire level (no console needed; precedent: wmux tests drive the
  protocol directly). Keep posix paths intact. nimble test must pass on
  both ubuntu and windows runners. Verify: nimble test + nimble example
  green locally (posix).
- [ ] 8. **CI.** New .github/workflows/windows-amd64.yml mirroring
  linux-amd64.yml: runs-on windows-latest, build to mpx.exe, nimble
  test, package as zip (mpx-windows-amd64/ with mpx.exe, VERSION,
  README.md), artifact upload, capocasa.dev upload on main. release.yml:
  add windows-amd64.yml to the workflow wait list and
  mpx-windows-amd64.zip to Collect archive files (and its ls).
  Verify: YAML valid (`nim` not needed), steps mirror existing files.
- [ ] 9. **README + final review.** Replace "Windows: not supported"
  with a Windows section: Win10 1809+ floor, loopback TCP transport
  with the same name-gating caveat as -l, detach key unchanged, and the
  honest transparency asterisk (conhost re-renders the stream; passthrough
  mode is possible future hardening on Win11 22000+). Then the skill's
  Finishing pass: whole-diff review, full local matrix (build, test,
  example, check --os:windows on src/mpx.nim), clean committed tree.

## Verification commands (posix, run every step)

    nim c --hints:off --path:src -o:build/mpx src/mpx.nim
    nimble test
    nimble example
