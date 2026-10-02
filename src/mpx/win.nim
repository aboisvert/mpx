# The one raw Win32 import layer for mpx. No other module declares Win32
# procs: they import this one and get std/winlean's basics re-exported
# alongside the ConPTY, console, event, thread, file and winsock pieces
# winlean lacks. Dynlib procs bind lazily, so a binary still starts on
# Windows 10 pre-1809 and fails only where ConPTY is actually used.

import std/winlean
export winlean

const
  kernel32 = "kernel32"
  ws2_32 = "ws2_32"

type
  COORD* = object
    x*: SHORT
    y*: SHORT

  HPCON* = Handle

  LPPROC_THREAD_ATTRIBUTE_LIST* = pointer

  STARTUPINFOEXW* = object
    StartupInfo*: STARTUPINFO
    lpAttributeList*: LPPROC_THREAD_ATTRIBUTE_LIST

  SMALL_RECT* = object
    Left*: SHORT
    Top*: SHORT
    Right*: SHORT
    Bottom*: SHORT

  CONSOLE_SCREEN_BUFFER_INFO* = object
    dwSize*: COORD
    dwCursorPosition*: COORD
    wAttributes*: uint16
    srWindow*: SMALL_RECT
    dwMaximumWindowSize*: COORD

  ThreadProc* = proc(lpParameter: pointer): DWORD {.stdcall, gcsafe.}

# ConPTY (kernel32, Windows 10 1809+)

proc CreatePseudoConsole*(size: COORD, hInput, hOutput: Handle,
                          dwFlags: DWORD, phPC: ptr HPCON): int32 {.
                          stdcall, dynlib: kernel32,
                          importc: "CreatePseudoConsole".}

proc ResizePseudoConsole*(hPC: HPCON, size: COORD): int32 {.
                          stdcall, dynlib: kernel32,
                          importc: "ResizePseudoConsole".}

proc ClosePseudoConsole*(hPC: HPCON) {.
                          stdcall, dynlib: kernel32,
                          importc: "ClosePseudoConsole".}

# Process spawn (kernel32)

proc InitializeProcThreadAttributeList*(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST, dwAttributeCount: DWORD,
    dwFlags: DWORD, lpSize: ptr DWORD): WINBOOL {.
    stdcall, dynlib: kernel32, importc: "InitializeProcThreadAttributeList".}

proc UpdateProcThreadAttribute*(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
                                dwFlags: DWORD, attribute: uint,
                                lpValue: pointer, cbSize: uint,
                                lpPreviousValue: pointer,
                                lpReturnSize: ptr uint): WINBOOL {.
    stdcall, dynlib: kernel32, importc: "UpdateProcThreadAttribute".}

proc DeleteProcThreadAttributeList*(lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST) {.
    stdcall, dynlib: kernel32, importc: "DeleteProcThreadAttributeList".}

proc OpenProcess*(dwDesiredAccess: DWORD, bInheritHandle: WINBOOL,
                  dwProcessId: DWORD): Handle {.
                  stdcall, dynlib: kernel32, importc: "OpenProcess".}

# Console (kernel32)

proc GetConsoleMode*(hConsoleHandle: Handle, lpMode: ptr DWORD): WINBOOL {.
                       stdcall, dynlib: kernel32, importc: "GetConsoleMode".}

proc SetConsoleMode*(hConsoleHandle: Handle, dwMode: DWORD): WINBOOL {.
                       stdcall, dynlib: kernel32, importc: "SetConsoleMode".}

proc GetConsoleScreenBufferInfo*(
    hConsoleOutput: Handle,
    lpConsoleScreenBufferInfo: ptr CONSOLE_SCREEN_BUFFER_INFO): WINBOOL {.
    stdcall, dynlib: kernel32, importc: "GetConsoleScreenBufferInfo".}

# Events and threads (kernel32)

proc CreateEventW*(lpEventAttributes: ptr SECURITY_ATTRIBUTES,
                   bManualReset, bInitialState: WINBOOL,
                   lpName: WideCString): Handle {.
                   stdcall, dynlib: kernel32, importc: "CreateEventW".}

proc SetEvent*(hEvent: Handle): WINBOOL {.
                stdcall, dynlib: kernel32, importc: "SetEvent".}

proc CreateThread*(lpThreadAttributes: ptr SECURITY_ATTRIBUTES,
                   dwStackSize: uint, lpStartAddress: ThreadProc,
                   lpParameter: pointer, dwCreationFlags: DWORD,
                   lpThreadId: ptr DWORD): Handle {.
                   stdcall, dynlib: kernel32, importc: "CreateThread".}

# Files (kernel32). CREATE_NEW is the O_EXCL equivalent used for the
# session-lock claim.

proc CreateFileW*(lpFileName: WideCString, dwDesiredAccess, dwShareMode: DWORD,
                  lpSecurityAttributes: ptr SECURITY_ATTRIBUTES,
                  dwCreationDisposition, dwFlagsAndAttributes: DWORD,
                  hTemplateFile: Handle): Handle {.
                  stdcall, dynlib: kernel32, importc: "CreateFileW".}

# Winsock (ws2_32)

proc WSACreateEvent*(): Handle {.
                          stdcall, dynlib: ws2_32, importc: "WSACreateEvent".}

proc WSAEventSelect*(s: SocketHandle, hEventObject: Handle,
                     lNetworkEvents: clong): cint {.
                     stdcall, dynlib: ws2_32, importc: "WSAEventSelect".}

proc ioctlsocket*(s: SocketHandle, cmd: clong, argp: ptr culong): cint {.
                   stdcall, dynlib: ws2_32, importc: "ioctlsocket".}

const
  # Process creation. EXTENDED_STARTUPINFO_PRESENT must accompany any
  # STARTUPINFOEXW or the attribute list is ignored.
  EXTENDED_STARTUPINFO_PRESENT* = 0x00080000'i32
  CREATE_BREAKAWAY_FROM_JOB* = 0x01000000'i32
  CREATE_NEW_PROCESS_GROUP* = 0x00000200'i32
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE* = 0x00020016'u

  # Console mode flags
  ENABLE_PROCESSED_INPUT* = 0x0001'i32
  ENABLE_LINE_INPUT* = 0x0002'i32
  ENABLE_ECHO_INPUT* = 0x0004'i32
  ENABLE_VIRTUAL_TERMINAL_INPUT* = 0x0200'i32
  ENABLE_PROCESSED_OUTPUT* = 0x0001'i32
  ENABLE_VIRTUAL_TERMINAL_PROCESSING* = 0x0004'i32

  # File access for the lock claim
  GENERIC_WRITE* = 0x40000000'i32
  FILE_SHARE_READ* = 0x00000001'i32
  FILE_SHARE_WRITE* = 0x00000002'i32
  CREATE_NEW* = 1'i32

  # Process access rights
  PROCESS_TERMINATE* = 0x0001'i32

  # Winsock event selection / nonblocking ioctl
  FIONBIO* = clong(0x8004667)
  FD_READ* = clong(0x00000001)
  FD_WRITE* = clong(0x00000002)
  FD_CLOSE* = clong(0x00000020)

proc initWinsock*() =
  ## WSAStartup is refcounted per process; one call at startup covers every
  ## socket mpx makes. 2.2 is the only version that has ever mattered.
  var data: WSAData
  if wsaStartup(0x0202'i16, addr data) != 0:
    raise newException(OSError, "WSAStartup failed: " & $getLastError())
