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
- **Windows daemon has one TCP listener, not two**: there is no unix
  socket to mirror, so the listener is the endpoint. It binds
  127.0.0.1:4534 by default (first free port upward) and cfg.listen
  moves it off loopback, same as -l on posix; the port lands in the
  .port file either way, and every client is mkAttach-vetted.
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

Steps 1-5 done. `src/mpx/win.nim` is the one import layer: it re-exports
std/winlean and declares what winlean genuinely lacks (ConPTY trio +
HPCON, STARTUPINFOEXW + attribute-list procs,
GetConsoleScreenBufferInfo and its types, CreateThread,
EXTENDED_STARTUPINFO_PRESENT,
CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP,
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, ERROR_BROKEN_PIPE/ERROR_NO_DATA,
initWinsock). Step 3 found winlean has neither SOCK_STREAM nor htons at
all, so win.nim supplies those too now (SOCK_STREAM = 1, a ws2_32
htons). Callers of mpx/win use winlean's camelCase spellings
(createEvent, setEvent, openProcess, createFileW with GENERIC_WRITE/
FILE_SHARE_*/CREATE_NEW/FILE_ATTRIBUTE_NORMAL, wsaEventSelect,
getConsoleMode, and so on) via the re-export; winlean's
ERROR_FILE_EXISTS (80) covers the lock-claim retry.

`src/mpx/pty.nim` has both branches behind one API: defaultShell()
($SHELL on posix, pwsh/powershell/cmd probe on Windows, empty cmd means
default shell), openPty/setSize/read/write/close, the Windows Pty
carrying hpc/inWrite/outRead/hProcess with blocking ReadFile/WriteFile.

protocol.nim compiles on both platforms as of step 3: imports split the
pty.nim way (`when defined(windows): import mpx/win else: import
std/posix`), sendMsg/readFull use send/recv (posix EINTR retry kept
behind a wasInterrupted helper since winsock has no signal
interruption), a private sockClose wraps closeSocket/posix.close,
setNonBlocking uses ioctlsocket(FIONBIO) on Windows, connectUnix is
posix-only, connectTcp/listenTcp compile everywhere (sin_family branches
AF_INET vs TSa_Family), socketPath names the `.port` endpoint file on
Windows. runtime.nim: %TEMP% then %LOCALAPPDATA%/Temp on Windows.
session.nim: an EndpointExt const (.port vs .sock) drives
resolveSession's existence check and oldestSession's walk; the lock
claim uses createFileW(CREATE_NEW) with ERROR_FILE_EXISTS meaning "next
candidate"; windows-only daemonPort parses the .port file; isActive on
Windows = port in range + connectTcp to 127.0.0.1 succeeds. mpx.nim
calls initWinsock() as the first statement of main() on Windows.

daemon.nim compiles on both platforms as of step 5: the selector lives
inside Session (posix-only field), the shared client machinery
(flush/queue/broadcast/snapshot/handleClientMsg/feedClient, the loop's
frame parsing and mkAttach vetting factored into feedClient) is written
once against that, and each platform fills in the I/O edges. Windows
side: reader thread blocks in ReadFile into a shared buffer guarded by
a spinlock (Atomic[bool] exchange) and sets an auto-reset data event;
writer thread waits [stopEv, inEv] and drains the input queue with
blocking WriteFile; the loop is WaitForMultipleObjects over stopEv,
dataEv, the listener event, and one WSAEventSelect event per client
(FD_READ or FD_WRITE or FD_CLOSE, WSAEnumNetworkEvents as the reset),
with outq would-block handled by edge-triggered FD_WRITE instead of
posix's setInterest rearming. Transport is a single TCP listener:
127.0.0.1:4534 base by default (cfg.listen overrides, same scan), port
recorded in the .port file alongside the .pid; every client is vetted
through mkAttach like the posix -l path; 56-client cap at accept
(MaxClients, under the 64-handle ceiling); ptyEof (child exit) ends
the session, cleanup sets stopEv and gives the writer 1s before
closing handles. win.nim gained WSANETWORKEVENTS/WSAEnumNetworkEvents
and GetCurrentProcessId (winlean has neither). client.nim stays
posix-only until step 6. mpx.nim
doubles as of step 4: the std/posix import moved into the else branch
of the `when defined(windows): import mpx/win` split; the no-command
cmd comes from pty.defaultShell(); cleanSessionFiles/cleanStale/ls use
session's now-exported EndpointExt (.port on Windows) instead of a
hardcoded ".sock"; pathPresent is plain fileExists on Windows (a
.port file is regular, lstat stays for sockets); `new` daemonizes on
Windows via createProcessW with DETACHED_PROCESS or
CREATE_BREAKAWAY_FROM_JOB or CREATE_NEW_PROCESS_GROUP over the same
args list the fork path execvs, quoted through pty's now-exported
quoteArg, readiness = isActive or waitForSingleObject(pi.hProcess, 0)
== WAIT_OBJECT_0; `kill` = openProcess(PROCESS_TERMINATE) on the pid
file's pid + terminateProcess + the same stale sweep. Posix build/test
(29 OK)/example green plus a manual new/ls/kill smoke; windows check
clean on win, pty, protocol, runtime, session, daemon, and mpx.nim's
own code; `nim check --os:windows` on src/mpx.nim now fails only in
client.nim (posix-only termios/Winsize code, step 6's job). Note:
Windows daemon threading is check-verified but not yet run on a real
Windows box; step 7's tests are the first to exercise it.

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
- [x] 2. **pty.nim Windows branch.** Done. Posix code gated behind
  `when not defined(windows)`, ConPTY branch behind the same `Pty` API.
  Shared `defaultShell()`: $SHELL on posix, findExe probe of pwsh.exe,
  powershell.exe, cmd.exe on Windows; an empty `cmd` means the default
  shell in both branches (mpx.nim still resolves non-empty cmds itself
  until step 4 rewires that). Windows Pty fields: hpc, inWrite, outRead,
  hProcess, the last so the daemon can WaitForSingleObject on child exit
  without relying on the read side. openPty: two non-inheritable
  createPipe pairs, CreatePseudoConsole(size, inRead, outWrite), our
  copies of the consumed ends closed, STARTUPINFOEXW sized attribute
  list carrying PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, createProcessW with
  EXTENDED_STARTUPINFO_PRESENT passing `si.StartupInfo` to winlean's
  `var STARTUPINFO` param, minimal quoteArg for args, pi.hThread closed
  at once. setSize = ResizePseudoConsole. read/write = blocking
  ReadFile/WriteFile (winlean takes int32 counts); read maps
  ERROR_BROKEN_PIPE/ERROR_NO_DATA to 0 (EOF, like a posix master) and
  anything else to -1. close: inWrite first so the console sees input
  EOF, then ClosePseudoConsole, then outRead and hProcess. Error paths
  in openPty close what was opened before raising. Also fixed win.nim:
  pruned every declaration winlean already has (COORD, OpenProcess,
  GetConsoleMode, SetConsoleMode, SetEvent, WSACreateEvent,
  WSAEventSelect, CreateFileW, CreateEventW, and the ENABLE_/FD_/
  GENERIC_/FILE_SHARE_/CREATE_NEW/PROCESS_TERMINATE consts); they were
  ambiguous with winlean's camelCase versions at any use site.
  Verified: posix build + nimble test + nimble example green; windows
  check clean on pty.nim and win.nim.
- [x] 3. **Transport, discovery, protocol unification.** Done.
  protocol.nim: imports split the pty.nim way (`when defined(windows):
  import mpx/win else: import std/posix`); sendMsg/readFull call
  send/recv with cint counts, one-send-per-frame kept; the EINTR retry
  is posix-only behind a wasInterrupted helper (winsock has no signal
  interruption); a private sockClose wraps closeSocket/posix.close for
  error paths; setNonBlocking branches to ioctlsocket(FIONBIO,
  culong 1); connectUnix is gated `when not defined(windows)`;
  connectTcp/listenTcp compile on both platforms (sin_family from plain
  AF_INET on Windows, AF_INET.TSa_Family on posix); socketPath returns
  the `<name>.port` file on Windows. The step found winlean has neither
  SOCK_STREAM nor htons at all, so win.nim gained SOCK_STREAM (1) and a
  ws2_32 htons. runtime.nim: runtimeDir takes a Windows branch, %TEMP%
  then %LOCALAPPDATA%/Temp, "." as last resort; module doc updated.
  session.nim: posix import and unix-socket probe sit in the else
  branch; an EndpointExt const (.port vs .sock) drives resolveSession's
  existence check and oldestSession's dir walk; the lock claim uses
  createFileW(GENERIC_WRITE, share read+write, CREATE_NEW,
  FILE_ATTRIBUTE_NORMAL) with ERROR_FILE_EXISTS meaning "someone
  claimed it, next candidate"; windows-only daemonPort* parses the
  .port file; isActive on Windows = port in 1..65535 plus connectTcp
  to 127.0.0.1 succeeding. mpx.nim: `when defined(windows): import
  mpx/win` and initWinsock() as the first statement of main().
  Verified: posix build + nimble test (29 OK) + nimble example green;
  `nim check --hints:off --os:windows --cpu:amd64 --path:src` clean on
  protocol, runtime, session, and win/pty still clean. mpx.nim's own
  Windows branch stays check-unverifiable until steps 4-6 gate
  daemon/client, as the plan already expected.
- [x] 4. **mpx.nim Windows spawn/kill.** Done. `new` daemonizes on
  Windows with createProcessW (DETACHED_PROCESS or
  CREATE_BREAKAWAY_FROM_JOB or CREATE_NEW_PROCESS_GROUP) over the same
  args list the fork path execvs, quoted via pty.quoteArg (now
  exported); hThread closed at once, readiness polls isActive plus
  waitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0 for early exit,
  hProcess closed after. `kill` opens the pid-file pid with
  openProcess(PROCESS_TERMINATE), terminateProcess, closeHandle, then
  the same sleep(100) + cleanSessionFiles sweep; the posix
  kill/waitpid branch is unchanged. `ls` and
  cleanSessionFiles/cleanStale use the now-exported session.EndpointExt
  instead of ".sock"; pathPresent is plain fileExists on Windows (a
  .port file is regular, lstat stays for sockets); the no-command cmd
  routes through pty.defaultShell(); mpx.nim's std/posix import moved
  into the else branch of the win split. Verified: posix build +
  nimble test (29 OK) + nimble example green plus a manual
  new/ls/kill smoke (daemonize, list, kill, sweep, no leftovers);
  check --os:windows clean on mpx.nim's own code, its only diagnostics
  being the pre-existing runDaemon cascade from daemon.nim's
  posix-only compile (step 5's job), and still clean on win, pty,
  protocol, runtime, session.
- [x] 5. **daemon.nim Windows event loop.** Done. The selector moved
  inside Session as a posix-only field so the shared client machinery
  (flushClient/queueClient/broadcast/queueSnapshot/flushPty/handleClientMsg)
  is written once; the loop's inline frame parsing and mkAttach vetting
  were factored into feedClient so both loops share them; addClient/
  dropClient/setInterest carry the platform edges. Reader thread blocks
  in ReadFile, appends to ptyOut under a spinlock (Atomic[bool]
  exchange/clear), sets an auto-reset data event; on EOF (broken pipe
  after child exit) it sets ptyEof and pokes the event again. Writer
  thread waits [stopEv, inEv], moves the whole input queue out under
  the spinlock, writes it fully with blocking WriteFile (backpressure
  parks there, not in the loop). Main loop: WaitForMultipleObjects over
  stopEv, dataEv, one FD_ACCEPT listener event and one per-client
  WSAEventSelect event, reset via WSAEnumNetworkEvents; outq would-block
  rides edge-triggered FD_WRITE (no setInterest equivalent needed);
  the data handler drains the chunk before the eof check so the child's
  last output is not lost when chunk and eof coalesce into one wake.
  Transport: single TCP listener, 127.0.0.1:4534 base by default,
  cfg.listen overrides (same startTcpListener scan), port written to
  the .port file, pid via GetCurrentProcessId next to it; every client
  is TCP-vetted through mkAttach; 56-client cap (MaxClients) at accept;
  cleanup sets stopEv, waits up to 1s for the writer, then closes
  clients/listener/events and sweeps .port/.pid/.lock. startTcpListener
  now takes (ip, basePort) instead of (sessionName, cfg). win.nim
  gained WSANETWORKEVENTS + WSAEnumNetworkEvents and GetCurrentProcessId.
  Verified: posix build + nimble test (29 OK) + nimble example green
  plus a manual daemon/ls/kill smoke; check --os:windows clean on
  daemon.nim, and src/mpx.nim now checks clean except client.nim
  (step 6). Windows runtime behavior is still unexercised: no real
  Windows box until step 7's tests.
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
