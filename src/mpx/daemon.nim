import std/[posix, os, strutils, sequtils, selectors, atomics]
import mpx/[pty, protocol, log, config]
import ttty/[terminal, grid]

const
  # Cap on a client's pending output. A client that cannot drain (dead
  # peer, stalled TCP link) gets dropped instead of growing the queue
  # without bound. Snapshots are a few MB at worst and must fit.
  OutqCap = 16 * 1024 * 1024

type
  Client = object
    fd: SocketHandle
    vetted: bool      # unix clients are trusted on arrival, TCP must name the session
    snapshotPending: bool  # no frame sent yet: wait for the client's resize so
                           # the snapshot renders at the client's geometry
    outq: seq[byte]   # framed bytes the socket would not take yet
    inbuf: seq[byte]  # partial frame(s) read off a non-blocking socket

  Session = object
    name: string
    pty: Pty
    clients: seq[Client]
    ptyInq: seq[byte]  # input the pty buffer would not take yet
    running: bool
    term: Terminal  # ttty side cache for attach snapshots

# Set by the signal handler, polled by the event loop: a signal interrupts
# select (EINTR makes it return empty) and the loop condition picks it up.
var shutdownRequested: Atomic[bool]

proc onShutdown(sig: cint) {.noconv.} =
  shutdownRequested.store(true, moRelaxed)

proc newSession(name, cmd: string): Session =
  result.name = name
  result.pty = openPty(cmd)
  result.running = true
  result.term = newTerminal(80, 24, 10000)  # larger scrollback

proc clientIndex(session: Session, fd: SocketHandle): int =
  for i, c in session.clients:
    if c.fd == fd:
      return i
  -1

proc removeClient(session: var Session, fd: SocketHandle) =
  var i = 0
  while i < session.clients.len:
    if session.clients[i].fd == fd:
      session.clients.delete(i)
    else:
      inc i

proc dropClient(session: var Session, sel: var Selector[SocketHandle], fd: SocketHandle) =
  session.removeClient(fd)
  try:
    sel.unregister(fd)
  except ValueError:
    discard
  discard posix.close(fd)

proc setInterest(sel: var Selector[SocketHandle], fd: SocketHandle,
                  wantWrite: bool) =
  # Write interest only while a queue is pending: an always-writable fd
  # would make select spin.
  var evs = {Event.Read}
  if wantWrite:
    evs.incl Event.Write
  sel.updateHandle(fd, evs)

proc flushClient(session: var Session, sel: var Selector[SocketHandle], i: int): bool =
  ## Push queued frames until the socket is full. False: peer is gone.
  let c = addr session.clients[i]
  while c.outq.len > 0:
    let w = posix.write(c.fd.cint, addr c.outq[0], c.outq.len)
    if w > 0:
      c.outq.delete(0 ..< w)
    elif errno == EAGAIN or errno == EWOULDBLOCK:
      break
    else:
      return false
  setInterest(sel, c.fd, c.outq.len > 0)
  result = true

proc queueClient(session: var Session, sel: var Selector[SocketHandle],
                 i: int, kind: MsgKind, payload: openArray[byte]): bool =
  ## Frame and append to a client's queue, then send what fits now.
  ## False: over cap or hard write error; caller drops the client.
  let frame = frameBytes(kind, payload)
  let c = addr session.clients[i]
  if c.outq.len + frame.len > OutqCap:
    return false
  c.outq.add frame
  result = session.flushClient(sel, i)

proc broadcast(session: var Session, sel: var Selector[SocketHandle],
               kind: MsgKind, payload: openArray[byte]) =
  var i = 0
  while i < session.clients.len:
    if not session.clients[i].vetted or session.clients[i].snapshotPending:
      inc i  # unvetted TCP clients hear nothing; a pre-snapshot client is
             # about to receive the whole modeled screen instead
    elif session.queueClient(sel, i, kind, payload):
      inc i
    else:
      session.dropClient(sel, session.clients[i].fd)

proc queueSnapshot(session: var Session, sel: var Selector[SocketHandle], i: int) =
  ## Full-model render: scrollback as text, then the live screen with
  ## attributes. Ends by moving the terminal cursor to the cell the
  ## session's program thinks it occupies: programs keep drawing with
  ## relative cursor moves after the attach, and a cursor left at the
  ## bottom row would smear that output across the screen.
  let g = session.term.grid
  let snap = g.renderAnsiFull()
  if snap.len > 0:
    let first = max(0, g.rows.len - g.height)
    let r = max(0, g.row - first)
    var frame = snap & "\x1b[" & $(r + 1) & ";" & $(g.col + 1) & "H"
    if not session.queueClient(sel, i, mkOutput, frame.toOpenArrayByte(0, frame.len-1)):
      session.dropClient(sel, session.clients[i].fd)

proc flushPty(session: var Session, sel: var Selector[SocketHandle]) =
  ## Feed queued input to the pty. The program may stop reading (a build
  ## spewing output, a stopped editor); blocking here would stall every
  ## client, so the remainder waits for writability instead.
  let fd = session.pty.masterFd.SocketHandle
  while session.ptyInq.len > 0:
    let w = posix.write(session.pty.masterFd, addr session.ptyInq[0],
                        session.ptyInq.len)
    if w > 0:
      session.ptyInq.delete(0 ..< w)
    elif errno == EAGAIN or errno == EWOULDBLOCK:
      setInterest(sel, fd, true)
      return
    else:
      discard  # EIO: child gone; the read side ends the session
  setInterest(sel, fd, false)

proc takeClientFrame(session: var Session, i: int,
                     kind: var MsgKind, payload: var seq[byte]): bool =
  takeFrame(session.clients[i].inbuf, kind, payload)

proc handleClientMsg(session: var Session, sel: var Selector[SocketHandle],
                     i: int, kind: MsgKind, payload: seq[byte]): bool =
  ## Handle one parsed frame. False: the client must be dropped.
  if not session.clients[i].vetted:
    return true  # unvetted TCP clients only get mkAttach processed
  case kind
  of mkInput:
    # Primaryless: every attached client writes to the pty.
    if payload.len > 0:
      session.ptyInq.add payload
      session.flushPty(sel)
  of mkResize:
    # Any client may resize; last one wins.
    if payload.len >= 4:
      let w = (payload[0].uint16 shl 8) or payload[1].uint16
      let h = (payload[2].uint16 shl 8) or payload[3].uint16
      session.pty.setSize(w, h)
      session.term.grid.resize(w.int, h.int)
      # First frame to a fresh client renders at its geometry: resized
      # grid first, then the snapshot. Rendered before the resize, a
      # taller grid than the client pushes all content off the top of
      # its screen, leaving a blank screen with the cursor at the bottom.
      if session.clients[i].snapshotPending:
        session.clients[i].snapshotPending = false
        session.queueSnapshot(sel, i)
      # Broadcast resize to all clients so they can adapt
      session.broadcast(sel, mkResize, payload)
  of mkDetach:
    return false
  else:
    discard
  result = true

proc startTcpListener(sessionName: string, cfg: Config): (SocketHandle, int) =
  ## First free port at or above the configured base. Raises OSError when
  ## nothing is free in the scan window.
  let (ip, basePort) = parseListen(cfg.listen)
  const maxTries = 64
  for p in basePort ..< basePort + maxTries:
    try:
      let fd = listenTcp(ip, p)
      return (fd, p)
    except OSError:
      continue
  raise newException(OSError, "no free TCP port in " & $basePort & ".." & $(basePort + maxTries - 1))

proc runDaemon*(sessionName, cmd: string, cfg: Config) =
  let log = initLogger(cfg.log)
  # A client that vanished mid-broadcast must cost us the client, not the
  # process: writes to its dead socket would raise SIGPIPE and take the
  # daemon, and the session with it.
  discard signal(SIGPIPE, SIG_IGN)
  # SIGTERM/SIGINT/SIGHUP must run the cleanup below, not skip it: the
  # default disposition kills the daemon mid-flight and leaves socket,
  # pid, and lock files behind for attach to trip over.
  discard signal(SIGTERM, onShutdown)
  discard signal(SIGINT, onShutdown)
  discard signal(SIGHUP, onShutdown)
  log.info "daemon: session=" & sessionName & " cmd=" & cmd
  removeSocket(sessionName)
  let path = socketPath(sessionName)
  # Record the daemon pid next to the socket: kill targets the exact
  # process without /proc cmdline matching (which breaks under qemu
  # emulation and differs across platforms).
  writeFile(path.changeFileExt("pid"), $getpid())

  let listenFd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if listenFd == SocketHandle(-1):
    raise newException(OSError, "socket failed")

  var saddr: Sockaddr_un
  saddr.sun_family = AF_UNIX.TSa_Family
  let pathCstr = path.cstring
  if pathCstr.len >= saddr.sun_path.len:
    raise newException(OSError, "socket path too long")
  copyMem(addr saddr.sun_path, pathCstr, pathCstr.len)

  if bindSocket(listenFd, cast[ptr SockAddr](addr saddr), sizeof(Sockaddr_un).SockLen) != 0:
    raise newException(OSError, "bind failed: " & path)
  if listen(listenFd, 5) != 0:
    raise newException(OSError, "listen failed")

  # Optional TCP listener. Session name gates access: TCP clients send
  # mkAttach with the session name, wrong names get dropped.
  var tcpFd = SocketHandle(-1)
  var tcpPort = 0
  if cfg.listen.len > 0:
    try:
      (tcpFd, tcpPort) = startTcpListener(sessionName, cfg)
      log.info "listening on tcp " & cfg.listen.rsplit(':', 1)[0] & ":" & $tcpPort
    except ValueError, OSError:
      log.info "tcp listener disabled: " & getCurrentExceptionMsg()

  var session = newSession(sessionName, cmd)
  # Everything the event loop touches is non-blocking: a single stalled
  # write (slow client, busy program) used to wedge the loop, freezing
  # the session for every client, including fresh attaches.
  setNonBlocking(session.pty.masterFd.SocketHandle)
  var sel = newSelector[SocketHandle]()
  sel.registerHandle(listenFd, {Event.Read}, listenFd)
  if tcpFd != SocketHandle(-1):
    sel.registerHandle(tcpFd, {Event.Read}, tcpFd)
  sel.registerHandle(session.pty.masterFd.SocketHandle, {Event.Read}, session.pty.masterFd.SocketHandle)

  log.info "listening on " & path

  while session.running and not shutdownRequested.load(moRelaxed):
    let events = sel.select(-1)
    for ev in events:
      if ev.fd == listenFd.cint:
        # New client on the unix socket: trusted, attach immediately
        let clientFd = accept(listenFd, nil, nil)
        if clientFd != SocketHandle(-1):
          setNonBlocking(clientFd)
          session.clients.add(Client(fd: clientFd, vetted: true, snapshotPending: true))
          sel.registerHandle(clientFd, {Event.Read}, clientFd)
          log.info "client attached fd=" & $clientFd.cint
      elif ev.fd == tcpFd.cint:
        # New TCP client: hold it until it names the right session
        let clientFd = accept(tcpFd, nil, nil)
        if clientFd != SocketHandle(-1):
          setNonBlocking(clientFd)
          session.clients.add(Client(fd: clientFd, vetted: false))
          sel.registerHandle(clientFd, {Event.Read}, clientFd)
      elif ev.fd == session.pty.masterFd:
        if Event.Write in ev.events:
          session.flushPty(sel)
        if (Event.Read in ev.events or Event.Error in ev.events) and
            session.running:
          # PTY output. The last slave fd closing surfaces as
          # Event.Error (EPOLLHUP), not Read: the read below confirms it.
          var buf: array[4096, byte]
          let n = session.pty.read(addr buf[0], buf.len)
          if n > 0:
            # Feed ttty side cache
            session.term.write(cast[string](buf[0..<n]))
            session.broadcast(sel, mkOutput, buf[0..<n])
          elif n == 0 or errno == EIO:
            # Child exited. Linux reports PTY EOF as EIO (-1), BSD as 0.
            # EAGAIN just means the readable edge was already drained.
            session.running = false
            break
      else:
        # Client socket: readable frames, writable queue
        let fd = ev.fd.SocketHandle
        let i = session.clientIndex(fd)
        if i < 0:
          continue
        var drop = false
        try:
          if Event.Write in ev.events:
            drop = not session.flushClient(sel, i)
          if (Event.Read in ev.events or Event.Error in ev.events) and
            not drop:
            # Error on a client socket is a dead peer; the read says EOF
            var buf: array[4096, byte]
            let n = posix.read(fd.cint, addr buf[0], buf.len)
            if n > 0:
              session.clients[i].inbuf.add buf[0..<n]
              var kind: MsgKind
              var payload: seq[byte]
              while not drop:
                # Handling a frame can drop another client (dead peer in
                # broadcast); indexes shift, so re-resolve ours every time
                let ci = session.clientIndex(fd)
                if ci < 0:
                  drop = true
                  break
                if not session.takeClientFrame(ci, kind, payload):
                  break
                if kind == mkAttach and session.clients[ci].vetted.not:
                  # Unvetted TCP client: check the session name
                  if payload == session.name.toOpenArrayByte(0, session.name.len-1):
                    session.clients[ci].vetted = true
                    drop = not session.queueClient(sel, ci, mkAttached, [])
                    if not drop:
                      session.clients[ci].snapshotPending = true
                      log.info "client attached fd=" & $fd.cint & " (tcp)"
                  else:
                    let err = "no such session"
                    discard session.queueClient(sel, ci, mkError,
                      err.toOpenArrayByte(0, err.len-1))
                    drop = true
                else:
                  if not session.handleClientMsg(sel, ci, kind, payload):
                    drop = true
            else:
              drop = true  # EOF
        except IOError:
          drop = true
        if drop:
          dropClient(session, sel, fd)

  # Cleanup
  for client in session.clients:
    discard posix.close(client.fd)
  discard posix.close(listenFd)
  if tcpFd != SocketHandle(-1):
    discard posix.close(tcpFd)
  removeSocket(sessionName)
  removeLock(sessionName)
  try:
    removeFile(socketPath(sessionName).changeFileExt("pid"))
  except OSError:
    discard
  session.pty.close()
  log.info "daemon: exited"
  log.close()
