import std/[posix, termios, selectors]
import mpx/[protocol, config, pty]

# Not exported by Nim's posix: Linux, macOS, and the BSDs all use 28.
const SIGWINCH = cint(28)

const
  CtrlA = 0x01.byte        # screen-style command prefix
  CtrlBackslash = 0x1c.byte  # dtach-style single-key detach

# Self-pipe for SIGWINCH: the handler only pokes a byte (write to a pipe
# is async-signal-safe); the resize frame itself is sent from the main
# loop. Writing the socket from the handler interleaved a frame between
# another frame's length prefix and payload, desyncing the daemon's
# stream parse and freezing the session.
var winchPipe: array[2, cint] = [cint(-1), cint(-1)]

proc onWinch(sig: cint) {.noconv.} =
  var b: byte = 1
  discard posix.write(winchPipe[1], addr b, 1)

proc sendResize(fd: SocketHandle) =
  var ws: Winsize
  discard ioctl(1, TIOCGWINSZ, addr ws)
  if ws.ws_col > 0 and ws.ws_row > 0:
    discard sendMsg(fd, mkResize,
      [byte(ws.ws_col shr 8), byte(ws.ws_col and 0xff),
       byte(ws.ws_row shr 8), byte(ws.ws_row and 0xff)])

proc runClient*(sessionName: string, cfg: Config) =
  discard signal(SIGPIPE, SIG_IGN)  # a closed peer is an error, not death
  let fd =
    try:
      connectUnix(socketPath(sessionName))
    except OSError:
      # No local socket. If TCP is configured, scan for the session there
      # (wireguard, port forward, or same host over 127.0.0.1).
      if cfg.listen.len == 0:
        raise
      var found = SocketHandle(-1)
      let (ip, basePort) = parseListen(cfg.listen)
      for p in basePort ..< basePort + 64:
        try:
          let candidate = connectTcp(ip, p)
          discard sendMsg(candidate, mkAttach, sessionName.toOpenArrayByte(0, sessionName.len-1))
          let (kind, payload) = recvMsg(candidate)
          if kind == mkAttached:
            found = candidate
            break
          # Wrong session or error: keep scanning
          discard posix.close(candidate)
        except OSError, IOError, ValueError:
          continue  # nothing on this port, keep scanning
      if found == SocketHandle(-1):
        raise newException(OSError, "connect failed: session not found on socket or tcp")
      found

  # Save terminal state and set raw mode
  var oldTermios, rawTermios: Termios
  discard tcgetattr(0, addr oldTermios)
  rawTermios = oldTermios
  rawTermios.c_iflag = rawTermios.c_iflag and not (ICRNL or IXON)
  rawTermios.c_lflag = rawTermios.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  rawTermios.c_oflag = rawTermios.c_oflag and not OPOST
  rawTermios.c_cc[VMIN] = 1.char
  rawTermios.c_cc[VTIME] = 0.char
  discard tcsetattr(0, TCSADRAIN, addr rawTermios)

  # Our terminal size is the session's size: claim it, and follow the
  # local window with SIGWINCH for the life of the attach (the desk
  # window resizing re-sizes the shared pty; a smaller co-attached
  # viewer -- the phone -- deliberately does not).
  var win: Winsize
  discard ioctl(1, TIOCGWINSZ, addr win)
  var w = win.ws_col
  var h = win.ws_row
  if w == 0 or h == 0:
    w = 80
    h = 24
  discard sendMsg(fd, mkResize, [byte(w shr 8), byte(w and 0xff), byte(h shr 8), byte(h and 0xff)])

  if pipe(winchPipe) != 0:
    raise newException(OSError, "pipe failed")
  # Both ends non-blocking: the handler must never block on a full pipe,
  # and the drain loop must not block on an emptied one.
  for i in {0, 1}:
    let pfl = fcntl(winchPipe[i], F_GETFL)
    discard fcntl(winchPipe[i], F_SETFL, pfl or O_NONBLOCK)
  let oldWinch = signal(SIGWINCH, onWinch)

  var prefixPending = false

  var sel = newSelector[SocketHandle]()
  sel.registerHandle(fd, {Event.Read}, fd)
  sel.registerHandle(winchPipe[0].SocketHandle, {Event.Read}, winchPipe[0].SocketHandle)

  # Try to register stdin; may fail if stdin is not selectable (e.g. /dev/null)
  var stdinRegistered = false
  try:
    sel.registerHandle(SocketHandle(0), {Event.Read}, SocketHandle(0))
    stdinRegistered = true
  except IOSelectorsException:
    discard

  var running = true
  while running:
    let events = sel.select(if stdinRegistered: -1 else: 100)
    for ev in events:
      if ev.fd == 0:
        # stdin -> daemon, through the detach keys
        var buf: array[4096, byte]
        let n = posix.read(0, addr buf[0], buf.len)
        if n > 0:
          var i = 0
          while i < n and running:
            let b = buf[i]
            inc i
            if prefixPending:
              prefixPending = false
              if b == byte('d'):
                discard sendMsg(fd, mkDetach)
                running = false
              elif b == CtrlA:
                discard sendMsg(fd, mkInput, [CtrlA])
              else:
                # not a prefix command we know: the pair goes through
                # untouched, transparency over cleverness
                discard sendMsg(fd, mkInput, [CtrlA, b])
            elif b == CtrlA:
              prefixPending = true
            elif b == CtrlBackslash:
              discard sendMsg(fd, mkDetach)
              running = false
            else:
              # bulk of typing: forward the rest of the chunk at once
              discard sendMsg(fd, mkInput, buf[i-1 ..< n])
              break
        else:
          running = false
      elif ev.fd == winchPipe[0]:
        # SIGWINCH arrived: drain the poke and send the resize from here
        var poke: array[64, byte]
        while posix.read(winchPipe[0], addr poke[0], poke.len) > 0:
          discard
        sendResize(fd)
      elif ev.fd == fd.cint:
        # daemon -> stdout
        try:
          let (kind, payload) = recvMsg(fd)
          case kind
          of mkOutput:
            discard posix.write(1, unsafeAddr payload[0], payload.len)
          of mkResize:
            # Another client resized; we just ignore
            discard
          else:
            discard
        except IOError:
          running = false
    # If stdin not registered, poll it manually with non-blocking read
    if not stdinRegistered:
      var buf: array[4096, byte]
      let fl = fcntl(0, F_GETFL)
      discard fcntl(0, F_SETFL, fl or O_NONBLOCK)
      let n = posix.read(0, addr buf[0], buf.len)
      discard fcntl(0, F_SETFL, fl)
      if n > 0:
        discard sendMsg(fd, mkInput, buf[0..<n])

  # Restore terminal
  discard signal(SIGWINCH, oldWinch)
  if winchPipe[0] != -1:
    discard posix.close(winchPipe[0])
    discard posix.close(winchPipe[1])
    winchPipe = [cint(-1), cint(-1)]
  discard tcsetattr(0, TCSADRAIN, addr oldTermios)
  discard posix.close(fd)
