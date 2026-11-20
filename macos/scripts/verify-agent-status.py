#!/usr/bin/env python3
"""Check what Wortel makes of what agents say, in a running copy of the app.

`ProgramStatusTests`, `ReportedStatusTests` and `ProgramStatusWatchTests` pin
the parsing and the rules. This does the half they cannot: `SessionManager` is
not in the test target, so whether a report ends up as a dot, a banner, a sound
or nothing is only checked by running the app. Every notification bug Wortel
has shipped was of that kind.

    ./scripts/verify-agent-status.py                # everything, about 4 minutes
    ./scripts/verify-agent-status.py approval       # scenarios by substring
    ./scripts/verify-agent-status.py --real         # plus real Claude Code: put to sleep, woken
    ./scripts/verify-agent-status.py --soak         # only the soak: twenty agents, random turns
    ./scripts/verify-agent-status.py --soak=7       # the same, from seed 7 (a failure prints its seed)
    ./scripts/verify-agent-status.py --keep         # leave the copy open afterwards
    ./scripts/verify-agent-status.py path/to/Wortel.app

It runs a throwaway copy beside yours, never your Wortel: its own bundle id, data
folder, keeper and socket, telemetry off (the `test-copy` skill has why each).
In it, stand-in agents say exactly what a script tells them to, in the format the
real ones use (the Program Status Protocol, OSC 7501, and OSC 9 notifications),
under the names the shell integration knows them by: `codex`, `claude`, `pi`,
`opencode`, `gemini`, `goose`. The app's own debug log says what it decided.

The soak is the nearest thing here to a day of use. Twenty stand-ins each run
forty random state changes, some standing and some flickering past faster than
an announcement settles, and three things are held against the log: every report
sent was heard, in order; everything announced follows a state that stood long
enough to mean it; and every state that stood was announced, and taken back
when it ended.

Three parts: the scenarios below (a turn, a block, timing, old versions, plain
programs), then terminals hibernated under their agent, then the app closed
and reopened around five sessions. The copy is opened in the background and
nothing is typed or clicked, so it can run while you work.

Needs the screen unlocked: with it locked there is no display, nothing reads
the ptys and nothing runs. `--real` spends a few short Claude Code turns.

The copy is signed ad hoc, and an ad-hoc app is never shown a banner, so a
banner is judged by Wortel's own log of handing it to Notification Center, not
by anyone seeing it. For the banner itself, sign a copy with a development
identity and watch (`docs/agent-signals.md`, "Tested how").
"""
import json, os, random, re, shutil, signal, subprocess, sys, tempfile, threading, time

MACOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
KEEP, REAL = "--keep" in sys.argv, "--real" in sys.argv
SOAK = next((a for a in sys.argv[1:] if a == "--soak" or a.startswith("--soak=")), None)
APP = next((a for a in ARGS if a.endswith(".app")), None)
ONLY = [a for a in ARGS if not a.endswith(".app")]

HOME = os.path.expanduser("~")
BASE = f"{HOME}/.was-{os.getpid()}"              # short: the sockets live under it
COPY, DATA = BASE + "/WortelTest.app", BASE + "/data"
WORK = tempfile.mkdtemp(prefix="wortel-as.", dir="/tmp")
S, CWD, LOG = WORK, WORK + "/cwd", WORK + "/status.log"
W = COPY + "/Contents/Resources/bin/wortel"
ENV = dict(os.environ, WORTEL_DATA_DIR=DATA)
OPEN = ["open", "-g", "-n", "--env", "WORTEL_DATA_DIR=" + DATA, "--env", "DO_NOT_TRACK=1"]

AGENT = r'''"""A stand-in agent: says what its steps file tells it to, when it tells it to."""
import base64, os, re, select, sys, termios, time, tty

APPS = {"claude": "claude-code"}
name = sys.argv[1]
app = APPS.get(name, name)
steps = [line.rstrip("\n") for line in open(sys.argv[2]) if line.strip() and not line.startswith("#")]
out = sys.stdout

def emit(text):
    out.write(text); out.flush()

def b64(text):
    return base64.b64encode(text.encode()).decode()

sent = None
def report(body):
    emit("\x1b]7501;" + body + "\x1b\\")
    if sent:
        pairs = dict(pair.split("=", 1) for pair in body.split(":") if "=" in pair)
        sent.write(pairs.get("state", "") + "/" + pairs.get("kind", "") + "\n"); sent.flush()

tui = False
try:
    for step in steps:
        verb, _, rest = step.partition(":")
        if verb == "tui":
            tui = True; emit("\x1b[?2004h")
        elif verb == "pid":
            open(rest, "w").write(str(os.getpid()))
        elif verb == "sentlog":      # keep a record of every report sent, for comparing with what was heard
            sent = open(rest, "w")
        elif verb == "s" or verb == "hold":
            time.sleep(float(rest))
        elif verb == "until":        # until:<epoch seconds>: the same instant in several sessions
            time.sleep(max(0, float(rest) - time.time()))
        elif verb == "r":            # r:<state>[:key=value...]
            state, _, extra = rest.partition(":")
            report(f"state={state}:app={app}" + (":" + extra if extra else ""))
        elif verb == "rm":           # rm:<state>:<kind or ->:<text>
            state, kind, text = rest.split(":", 2)
            report(f"state={state}:app={app}" + ("" if kind == "-" else f":kind={kind}") + f":msg={b64(text)}")
        elif verb == "child":        # child:<id>:<state>:<kind or ->:<title>:<text>
            cid, state, kind, title, text = rest.split(":", 4)
            body = f"state={state}:app={app}:id={cid}"
            if kind != "-": body += f":kind={kind}"
            if title: body += f":title={b64(title)}"
            if text: body += f":msg={b64(text)}"
            report(body)
        elif verb == "clearid":
            report(f"state=clear:id={rest}")
        elif verb == "clear":
            report("state=clear")
        elif verb == "raw":
            emit(rest.encode().decode("unicode_escape"))
        elif verb == "osc9":
            emit("\x1b]9;" + rest + "\x07")
        elif verb == "osc777":
            title, _, body = rest.partition("|")
            emit("\x1b]777;notify;" + title + ";" + body + "\x07")
        elif verb == "bell":
            emit("\x07")
        elif verb == "say":
            emit(rest + "\r\n")
        elif verb == "query":        # query:<file to write the answer to>
            fd = sys.stdin.fileno(); old = termios.tcgetattr(fd)
            try:
                tty.setraw(fd)
                # As Claude Code asks: DA1 right behind the question, and
                # supported only if the status answer comes first.
                emit("\x1b]7501;?\x1b\\\x1b[c")
                got = b""; end = time.time() + 1.5
                while time.time() < end and not got.endswith(b"c"):
                    if select.select([fd], [], [], 0.1)[0]: got += os.read(fd, 64)
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
            first = re.match(rb"\x1b\]7501;\?[^\x1b\x07]*(\x1b\\|\x07)", got)
            open(rest, "w").write("answered" if first else "silent:" + got.hex())
        else:
            raise SystemExit(f"unknown step: {step}")
finally:
    if tui: emit("\x1b[?2004l")
'''

def wortel(*args):
    return subprocess.run([W, *args], env=ENV, capture_output=True, text=True).stdout.strip()

def app_pid():
    out = subprocess.run(["pgrep", "-f", COPY + "/Contents/MacOS/Wortel"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None

def screen_is_locked():
    """A locked Mac has no display, so no terminal can be made and every session closes at once."""
    probe = "import CoreGraphics; let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]; " \
            "var n: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n); " \
            "print((d[\"CGSSessionScreenIsLocked\"] as? Int ?? 0) == 1 || n == 0 ? 1 : 0)"
    return subprocess.run(["swift", "-e", probe], capture_output=True, text=True).stdout.strip() == "1"

def set_up():
    global APP
    if screen_is_locked(): sys.exit("the screen is locked, or no display is awake; unlock it and run again")
    if not APP:
        settings = subprocess.run(["xcodebuild", "-project", MACOS + "/Wortel.xcodeproj", "-scheme", "Wortel",
                                   "-configuration", "Debug", "-showBuildSettings"], capture_output=True, text=True).stdout
        found = re.search(r" BUILT_PRODUCTS_DIR = (.*)", settings)
        APP = found.group(1).strip() + "/Wortel.app" if found else ""
    if not os.path.isdir(APP): sys.exit(f"no app at {APP!r}: build it, or pass its path")
    for d in (DATA, CWD, WORK + "/bin", WORK + "/steps", WORK + "/out"): os.makedirs(d, exist_ok=True)
    open(WORK + "/agent.py", "w").write(AGENT)
    for name in ("codex", "claude", "pi", "opencode", "crush", "gemini", "goose"):
        path = f"{WORK}/bin/{name}"
        open(path, "w").write(f'#!/bin/sh\nexec python3 -I {WORK}/agent.py "$(basename "$0")" "$@"\n')
        os.chmod(path, 0o755)
    subprocess.run(["cp", "-Rc", APP, COPY], check=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier com.gielcobben.Wortel.verify-status",
                    COPY + "/Contents/Info.plist"], check=True)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", COPY], capture_output=True, check=True)
    # Started before the app: a stream opened by pid after a relaunch has missed the launch.
    stream = subprocess.Popen(["/usr/bin/log", "stream", "--level", "debug", "--style", "compact", "--predicate",
                               f'processImagePath CONTAINS "{os.path.basename(BASE)}/" AND category == "agent-status"'],
                              stdout=open(LOG, "w"), stderr=subprocess.DEVNULL)
    time.sleep(1)
    subprocess.run(OPEN + ["--env", "WORTEL_HIBERNATE_AFTER=5", "--env", "WORTEL_SLEEP_AFTER=15", COPY])
    for _ in range(40):
        time.sleep(0.5)
        if app_pid() and wortel("list", "--json").startswith("["): break
    else:
        sys.exit("the copy did not come up (is the screen locked?)")
    return stream

def put_away(stream):
    stream.terminate()
    if KEEP:
        print(f"\nleft open: {COPY}\n  its log: {LOG}\n  remove it with the block at the end of the test-copy skill")
        return
    pid = app_pid()
    if pid: os.kill(pid, signal.SIGTERM)
    time.sleep(1)
    table = [l.split() for l in subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines()]
    keepers = subprocess.run(["pgrep", "-f", COPY + "/Contents/Resources/bin/wortel-keeper"], capture_output=True, text=True).stdout.split()
    doomed = set(keepers)
    for _ in range(8):
        doomed |= {pid for pid, parent in table if parent in doomed}
    for pid in doomed:
        try: os.kill(int(pid), signal.SIGKILL)
        except OSError: pass
    shutil.rmtree(BASE, ignore_errors=True)
    shutil.rmtree(WORK, ignore_errors=True)

def lines_for(sid):
    """(seconds since midnight, text) for each agent-status line about a session."""
    out = []
    for line in open(LOG, errors="replace"):
        if sid not in line or "agent-status] " not in line: continue
        clock = re.match(r"\S+ (\d+):(\d+):([\d.]+)", line)
        at = int(clock.group(1)) * 3600 + int(clock.group(2)) * 60 + float(clock.group(3)) if clock else 0.0
        out.append((at, line.split("agent-status] ", 1)[1].strip()))
    return out

def parse_status(text):
    """`status blocked/permission app=codex record=ses_1 +msg replayed after working id=...` -> (state, kind, child, replayed)."""
    said, _, _ = text[len("status "):].partition(" after ")
    replayed = said.endswith(" replayed")
    if replayed: said = said[:-len(" replayed")]
    if said == "clear": return ("clear", None, False, replayed)
    if said.startswith("clear record="): return ("clearRecord", None, True, replayed)
    state, _, kind = said.split(" ")[0].partition("/")
    return (state, kind or None, " record=" in said, replayed)

def events_for(sid):
    out = []
    for _, text in lines_for(sid):
        if text.startswith("status: "):
            out.append(("H",))
        elif text.startswith("status "):
            state, _, child, replayed = parse_status(text)
            out.append(("S", ("child-" if child and state != "clearRecord" else "") + state, replayed))
        elif text.startswith("attention raised"):
            m = re.search(r"kind=(\w+) banner=(\w+) sound=(\w+)", text)
            out.append(("R", m.group(1), m.group(2) == "true", m.group(3) == "true"))
        elif text.startswith("attention not raised"):
            out.append(("N",))
        elif text.startswith("attention cleared"):
            out.append(("C",))
        elif text.startswith("banner handed"):
            out.append(("B",))
        elif text.startswith("attention "):
            m = re.search(r"attention (\S+) kind=(\w+)", text)
            out.append(("A", m.group(1), m.group(2)))
    return out

def raised(ev): return [e for e in ev if e[0] == "R"]
def kinds(ev): return [e[1] for e in raised(ev)]
def banners(ev): return [e[1] for e in raised(ev) if e[2]]
def has(ev, *tag): return any(e[:len(tag)] == tag for e in ev)
def order(ev, *tags):
    """Whether events matching `tags` appear in that order (each tag a tuple prefix)."""
    i = 0
    for e in ev:
        if i < len(tags) and e[:len(tags[i])] == tags[i]: i += 1
    return i == len(tags)
def posted(ev): return sum(1 for e in ev if e[0] == "B")

def fmt(e):
    if e[0] == "S": return "S:" + e[1] + ("*" if e[2] else "")
    if e[0] == "R": return "R:" + e[1] + ("+banner" if e[2] else "") + ("+sound" if e[3] else "")
    if e[0] == "A": return "A:" + e[1] + ":" + e[2]
    return ":".join(str(x) for x in e)

RESULTS = []
def report(name, expect, ok, ev, extra=""):
    RESULTS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}  [{expect}]", flush=True)
    if not ok: print("      events:", " ".join(fmt(e) for e in ev), extra, flush=True)

def start(name, agent, steps, cwd=None):
    """A session running a stand-in agent (or, with no agent, a plain script that reports)."""
    path = f"{WORK}/steps/{len(os.listdir(WORK + '/steps'))}.steps"
    open(path, "w").write("\n".join(steps) + "\n")
    command = [f"{WORK}/bin/{agent}", path] if agent else ["python3", "-I", WORK + "/agent.py", "myprog", path]
    return wortel("new", "--cwd", cwd or CWD, "--name", name[:40], "--", *command).splitlines()[-1]

def unselect():
    # The newest session is the selected one. None under test should be: what
    # is raised for it depends on whether anyone is looking at the copy.
    wortel("new", "--cwd", CWD, "--name", "(selected, not a test)")

def wait_for(condition, seconds):
    """Poll until `condition()` holds, and say whether it did."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition(): return True
        time.sleep(0.5)
    return bool(condition())

def states():
    return {s["id"]: s["state"] for s in json.loads(wortel("list", "--json"))}

SCENARIOS = []
def scenario(name, agent, steps, wait, check, expect, actions=()):
    SCENARIOS.append(dict(name=name, agent=agent, steps=steps, wait=wait, check=check, expect=expect, actions=actions))

PID = lambda n: f"{WORK}/out/{n}.pid"
OUT = lambda n: f"{WORK}/out/{n}.txt"

# --- a turn, start to end
scenario("codex: a whole turn", "codex", ["tui", "r:idle", "s:1", "r:working", "s:3", "r:done", "hold:4"], 10,
         lambda ev, st: kinds(ev) == ["turnDone"] and banners(ev) == ["turnDone"] and st == "finished",
         "one turn-done banner; state finished")
scenario("codex: servers starting (working then idle)", "codex", ["tui", "r:idle", "r:working", "s:4", "r:idle", "hold:3"], 9,
         lambda ev, st: kinds(ev) == [] and st == "idle", "nothing raised")
scenario("codex: interrupted turn", "codex", ["tui", "r:idle", "r:working", "s:3", "r:idle", "hold:3"], 8,
         lambda ev, st: kinds(ev) == [], "nothing raised")
scenario("codex: a turn that failed", "codex", ["tui", "r:working", "s:3", "rm:error:-:Rate limit reached", "hold:3"], 8,
         lambda ev, st: kinds(ev) == ["failed"] and raised(ev)[0][2] and raised(ev)[0][3] and st == "failed",
         "one failed banner with sound; state failed")
scenario("pi: a whole turn", "pi", ["tui", "query:" + OUT("pi-query"), "r:idle", "r:working", "s:3", "r:done", "hold:3"], 9,
         lambda ev, st: kinds(ev) == ["turnDone"] and open(OUT("pi-query")).read() == "answered",
         "its question answered; one turn-done banner")
scenario("claude: a whole turn", "claude", ["tui", "query:" + OUT("claude-query"), "r:idle", "r:working", "s:3", "r:done", "hold:3"], 9,
         lambda ev, st: kinds(ev) == ["turnDone"] and open(OUT("claude-query")).read() == "answered",
         "its question answered; one turn-done banner")

# --- blocked
scenario("codex: approval, answered, then done", "codex",
         ["tui", "r:working", "s:1", "r:blocked:kind=permission", "s:3", "r:working", "s:3", "r:done", "hold:3"], 13,
         lambda ev, st: kinds(ev) == ["needsInput", "turnDone"] and order(ev, ("R", "needsInput"), ("C",), ("R", "turnDone")),
         "needs-input banner, cleared when answered, then turn-done")
scenario("codex: approval with its own notification first", "codex",
         ["tui", "r:working", "s:1", "osc9:Approval requested: npm test", "r:blocked:kind=permission", "hold:5"], 8,
         lambda ev, st: kinds(ev) == ["needsInput"] and not has(ev, "A", "notification") and not has(ev, "A", "status-words"),
         "one needs-input; the notification raises nothing of its own")
scenario("codex: approval, its notification a second later", "codex",
         ["tui", "r:working", "s:1", "r:blocked:kind=permission", "s:1.2", "osc9:Approval requested: npm test", "hold:4"], 8,
         lambda ev, st: [(e[1], e[2]) for e in raised(ev)] == [("needsInput", True), ("needsInput", False)],
         "banner once; the better words arrive without a second banner")
scenario("codex: question, sign-in", "codex",
         ["tui", "r:working", "s:1", "r:blocked:kind=question", "s:2", "r:working", "s:1", "r:blocked:kind=auth", "hold:4"], 10,
         lambda ev, st: kinds(ev) == ["needsInput", "needsInput"] and order(ev, ("R", "needsInput"), ("C",), ("R", "needsInput")),
         "two needs-input episodes, the first cleared in between")
scenario("codex: approved by its own rule in 0.1s", "codex",
         ["tui", "r:working", "s:1", "r:blocked:kind=permission", "s:0.1", "r:working", "s:3", "r:done", "hold:3"], 10,
         lambda ev, st: kinds(ev) == ["turnDone"], "no needs-input at all; one turn-done")
scenario("codex: blocked, then the agent is killed", "codex",
         ["pid:" + PID("kill-blocked"), "tui", "r:working", "s:1", "r:blocked:kind=permission", "hold:60"], 10,
         lambda ev, st: order(ev, ("R", "needsInput"), ("C",)) and st != "needs-you",
         "needs-input, cleared when the agent is gone",
         actions=[(5, lambda s: os.kill(int(open(PID("kill-blocked")).read()), signal.SIGKILL))])
scenario("codex: killed while working", "codex",
         ["pid:" + PID("kill-working"), "tui", "r:working", "hold:60"], 9,
         lambda ev, st: st != "working" and "turnDone" not in kinds(ev) and "needsInput" not in kinds(ev),
         "not left working, and not announced as a finished turn",
         actions=[(4, lambda s: os.kill(int(open(PID("kill-working")).read()), signal.SIGKILL))])

# --- timing and repeats
scenario("codex: done, then the next queued message at once", "codex",
         ["tui", "r:working", "s:3", "r:done", "s:0.1", "r:working", "s:3", "r:done", "hold:3"], 11,
         lambda ev, st: kinds(ev) == ["turnDone"], "one turn-done, for the second turn only")
scenario("codex: the same report five times", "codex",
         ["tui", "r:working", "s:3", "r:done", "r:done", "r:done", "r:done", "r:done", "hold:3"], 8,
         lambda ev, st: kinds(ev) == ["turnDone"], "one turn-done")
scenario("codex: done and gone in the same breath", "codex", ["tui", "r:working", "s:3", "r:done", "clear"], 8,
         lambda ev, st: kinds(ev) == ["turnDone"], "still announced, though it exited at once")
scenario("codex: two turns, nobody looking between", "codex",
         ["tui", "r:working", "s:3", "r:done", "s:3", "r:working", "s:3", "r:done", "hold:3"], 14,
         lambda ev, st: [(e[1], e[2], e[3]) for e in raised(ev)] == [("turnDone", True, True), ("turnDone", True, True)]
                        and order(ev, ("R", "turnDone"), ("C",), ("R", "turnDone")),
         "two banners with sound; the first dot goes when it works again")
scenario("codex: five different questions in three seconds", "codex",
         ["tui", "r:working", "s:1"] + sum([[f"rm:blocked:permission:Question {i}", "s:0.6"] for i in range(5)], []) + ["hold:3"], 9,
         lambda ev, st: len(banners(ev)) == 1 and len(raised(ev)) >= 3 and sum(1 for e in raised(ev) if e[3]) == 1,
         "one banner and one sound; the rest change the dot quietly")
scenario("codex: blocks and is answered every 0.6s", "codex",
         ["tui", "r:working", "s:1"] + ["r:blocked:kind=permission", "s:0.6", "r:working", "s:0.6"] * 6 + ["hold:3"], 13,
         lambda ev, st: len(raised(ev)) >= 4 and posted(ev) <= 3,
         "a dot each time; at most one banner in three seconds (7.2s of it: three)")
scenario("codex: a question held back as too soon, then a rename", "codex",
         ["tui", "r:working", "s:1", "rm:blocked:permission:First", "s:1", "r:working", "s:0.3",
          "rm:blocked:permission:Second", "hold:8"], 9,
         lambda ev, st: len(raised(ev)) == 2 and posted(ev) == 1,
         "one banner; renaming the session does not post the one held back",
         actions=[(4.5, lambda s: wortel("rename", "--session", s["id"], "Renamed while waiting"))])
scenario("codex: a report cut in two", "codex",
         ["tui", "r:working", "s:3", r"raw:\x1b]7501;sta", "s:0.4", r"raw:te=done:app=codex\x1b\\", "hold:3"], 8,
         lambda ev, st: kinds(ev) == ["turnDone"], "read as one report")
scenario("codex: rubbish between reports", "codex",
         ["tui", "r:working", "s:3", r"raw:\x1b]7501;state=paused\x1b\\", r"raw:\x1b]7501;nonsense\x07",
          r"raw:\x1b]7501;state=blocked:id=a b\x1b\\", r"raw:\x1b]7501;state=clear:id=//\x1b\\",
          r"raw:\x1b]7501;state=error:msg=a\x1b\\", r"raw:\x1b]7501;state=error:title=a\x1b\\",
          r"raw:\x1b]7501;state=error:" + "k" * 17 + r"=1\x1b\\", "s:1", "r:done", "hold:3"], 9,
         lambda ev, st: kinds(ev) == ["turnDone"],
         "none of the rubbish is taken for a report; one turn-done")

# --- programs that never say done, and ones nobody has heard of
scenario("opencode: a turn ends by going idle", "opencode", ["tui", "r:idle", "r:working", "s:3", "r:idle", "hold:3"], 8,
         lambda ev, st: kinds(ev) == ["turnDone"], "one turn-done")
scenario("opencode: under two seconds of work", "opencode", ["tui", "r:idle", "r:working", "s:1", "r:idle", "hold:3"], 6,
         lambda ev, st: kinds(ev) == [], "nothing raised")
scenario("opencode: one of its sessions waits on you", "opencode",
         ["tui", "r:working", "s:1", "child:ses_1:blocked:permission:Fix login:Permission needs input", "s:3",
          "clearid:ses_1", "s:2", "r:idle", "hold:3"], 11,
         lambda ev, st: kinds(ev) == ["needsInput", "turnDone"] and order(ev, ("R", "needsInput"), ("C",), ("R", "turnDone")),
         "needs-input, cleared when answered, then turn-done")
scenario("claude: a background agent asks after the turn finished", "claude",
         ["tui", "r:working", "s:3", "r:done", "s:2", "child:agent-7:blocked:question:Migration:Which database?", "s:3",
          "clearid:agent-7", "hold:3"], 13,
         lambda ev, st: kinds(ev) == ["turnDone", "needsInput"] and order(ev, ("R", "needsInput"), ("C",)),
         "turn-done, then needs-input, cleared when answered, and no second turn-done")
scenario("claude: background commands listed", "claude",
         ["tui", "r:working", "child:bash_1:working:-:npm run build:", "child:bash_2:working:-:tests:", "s:3",
          "clearid:bash_1", "r:done", "s:1", "clearid:bash_2", "hold:5"], 11,
         lambda ev, st: kinds(ev) == ["turnDone"] and order(ev, ("S", "done"), ("S", "clearRecord"), ("R", "turnDone")),
         "one turn-done, once the last command has ended")
scenario("claude: a turn ends while a background command runs", "claude",
         ["tui", "r:working", "s:2", "child:bash_1:working:-:release.sh:", "s:1", "r:done", "s:4",
          "clearid:bash_1", "hold:5"], 15,
         lambda ev, st: kinds(ev) == ["turnDone"] and order(ev, ("S", "clearRecord"), ("R", "turnDone"))
             and st == "finished",
         "no turn-done while the command runs; one when it ends; state finished")
scenario("claude: background command ends, and it carries on", "claude",
         ["tui", "r:working", "s:2", "child:bash_1:working:-:release.sh:", "s:1", "r:done", "s:3",
          "clearid:bash_1", "s:1.5", "r:working", "s:3", "r:done", "hold:3"], 17,
         lambda ev, st: kinds(ev) == ["turnDone"], "one turn-done, at the real end; none when the command ended")
scenario("claude: work listed after the turn", "claude",
         ["tui", "r:working", "s:3", "r:done", "s:2", "child:bash_9:working:-:late:", "s:2", "clearid:bash_9", "hold:5"], 15,
         lambda ev, st: kinds(ev) == ["turnDone"], "one turn-done; the late work neither takes it back nor repeats it")
scenario("unknown program learns to say done", None,
         ["r:working", "s:3", "r:idle", "s:3", "r:working", "s:3", "r:done", "s:3", "r:working", "s:3", "r:idle", "hold:2"], 21,
         lambda ev, st: kinds(ev)[:2] == ["turnDone", "turnDone"] and "turnDone" not in kinds(ev)[2:],
         "idle ends its first turn; after it has said done once, idle is only idle")

# --- old versions and agents that do not report
scenario("old codex: interface up, says nothing", "codex", ["tui", "hold:26"], 25,
         lambda ev, st: has(ev, "H") and kinds(ev) == [], "marked as out of date after 20s")
scenario("codex without an interface (like codex exec)", "codex", ["hold:26"], 25,
         lambda ev, st: not has(ev, "H"), "not marked")
scenario("gemini: says nothing", "gemini", ["tui", "hold:26"], 25,
         lambda ev, st: not has(ev, "H") and kinds(ev) == [] and st == "idle", "not marked, nothing raised")
scenario("old codex: its own notifications still arrive", "codex",
         ["tui", "s:1", "osc9:Approval requested: npm test", "s:4", "osc9:All tests pass and the build is green.", "hold:3"], 10,
         lambda ev, st: kinds(ev)[:1] == ["needsInput"], "the approval notification is needs-input")
scenario("goose: the bell", "goose", ["tui", "s:1", "bell", "hold:3"], 6,
         lambda ev, st: kinds(ev) == ["needsInput"], "needs-input")

# --- several sessions notifying at once (libghostty's core allows one a second for the whole app)
for n in (1, 2, 3):
    scenario(f"old agent {n} of 3 asks at the same instant", "gemini",
             ["tui", "until:AT", "osc9:Approval requested: npm test", "hold:4"], 28,
             lambda ev, st: kinds(ev) == ["needsInput"] and banners(ev) == ["needsInput"],
             "its own banner, though two others said the same in the same instant")
scenario("a script sends ten notifications in a second", None,
         ["s:1"] + sum([[f"osc9:Step {i} of the build is running", "s:0.1"] for i in range(10)], []) + ["s:3"], 8,
         lambda ev, st: len(raised(ev)) >= 5 and len(banners(ev)) <= 2 and sum(1 for e in raised(ev) if e[3]) == 1,
         "one sound, at most two banners; the rest change the dot quietly")

# --- plain programs
scenario("a script that reports, then exits", None, ["r:working", "s:3", "r:done"], 8,
         lambda ev, st: "turnDone" in kinds(ev), "turn-done kept after it exits")
scenario("a script blocked, then exits without saying so", None, ["r:working", "s:1", "r:blocked:kind=question", "s:3"], 9,
         lambda ev, st: order(ev, ("R", "needsInput"), ("C",)), "needs-input, cleared at the prompt")

def wanted(name):
    return not ONLY or any(part.lower() in name.lower() for part in ONLY)

def scenarios():
    todo = [s for s in SCENARIOS if wanted(s["name"])]
    if not todo: return
    # One instant for the sessions that have to speak at the same time, far
    # enough off that all of them are up by then.
    at = time.time() + 22
    for s in todo:
        s["id"] = start(s["name"], s["agent"], [step.replace("until:AT", f"until:{at}") for step in s["steps"]])
        s["t0"] = time.time()
        for at, fn in s["actions"]: threading.Timer(at, fn, args=[s]).start()
        time.sleep(0.4)
    unselect()
    time.sleep(max(0, max(s["t0"] + s["wait"] for s in todo) - time.time()) + 1.5)
    now = states()
    for s in todo:
        ev = events_for(s["id"])
        try: ok = bool(s["check"](ev, now.get(s["id"])))
        except Exception as error: ok = False; ev.append(("ERR", repr(error)))
        report(s["name"], s["expect"], ok, ev, f"state: {now.get(s['id'])}")

def notices(pattern, since="6m"):
    """Lines the copy logged at notice level or above (kept on disk, unlike the debug stream)."""
    # By pid: `log show` finds nothing by the image path of a copy this young.
    out = subprocess.run(["/usr/bin/log", "show", "--last", since, "--style", "compact", "--predicate",
                          f'processID == {app_pid()} AND eventMessage CONTAINS "{pattern}"'],
                         capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if pattern in l]

def hibernation():
    """A session whose surface was dropped out of sight still hears its agent (WORTEL_HIBERNATE_AFTER=5)."""
    if not wanted("hibernated"): return
    h1 = start("hibernated: a turn ends", "claude", ["tui", "r:idle", "r:working", "s:13", "r:done", "hold:20"])
    h2 = start("hibernated: blocked, answered, done", "claude",
               ["tui", "r:idle", "r:working", "s:11", "r:blocked:kind=permission", "s:4", "r:working", "s:3", "r:done", "hold:20"])
    unselect()
    time.sleep(24)
    asleep = notices("dropped the terminal of ")
    ev = events_for(h1)
    report("hibernated: a turn ends", "the terminal was freed before the turn ended, and it was still announced",
           any(h1 in l for l in asleep) and kinds(ev) == ["turnDone"], ev)
    ev = events_for(h2)
    report("hibernated: blocked, answered, done", "needs-input, cleared, turn-done, all with no terminal",
           any(h2 in l for l in asleep) and order(ev, ("R", "needsInput"), ("C",), ("R", "turnDone")), ev)

def sleeping():
    """The real Claude Code, put to sleep after 15s idle and out of sight, then woken (WORTEL_SLEEP_AFTER=15)."""
    if not REAL or not wanted("sleep"): return
    real = wortel("new", "--cwd", MACOS, "--name", "sleep: real Claude", "--", "claude", "--model", "haiku").splitlines()[-1]
    unselect()
    # Not on a clock: under the load of the scenarios before it, Claude Code
    # can take a while to come up, and text sent before it has is lost.
    wait_for(lambda: has(events_for(real), "S", "idle"), 40)
    for attempt in range(3):
        wortel("send", real, "Reply with only the word ok. Use no tools.", "--enter")
        if wait_for(lambda: has(events_for(real), "S", "working"), 8): break
        print("   the prompt did not start a turn; sending it again", flush=True)
    wait_for(lambda: kinds(events_for(real)) == ["turnDone"], 30)
    ev = events_for(real)
    report("sleep: the real Claude's turn first", "turn-done", kinds(ev) == ["turnDone"], ev)
    before, slept, deadline = len(raised(ev)), [], time.time() + 70
    while time.time() < deadline and not slept:
        time.sleep(5)
        slept = [l for l in notices("asleep", "3m") + notices("to sleep", "3m") if real in l]
    ev = events_for(real)
    report("sleep: put to sleep", "the agent was ended, its going raised nothing, and its dot stayed",
           bool(slept) and len(raised(ev)) == before and ("S", "clear", False) in ev, ev)
    wortel("send", real, "Reply with only the word yes. Use no tools.", "--enter")   # starts the resume, and says so
    time.sleep(14)
    wortel("send", real, "Reply with only the word yes. Use no tools.", "--enter")
    time.sleep(14)
    after = events_for(real)[len(ev):]
    report("sleep: woken and working again", "resumed, reported again, and its next turn announced",
           kinds(after)[-1:] == ["turnDone"] and has(after, "S", "working"), after)

def relaunch():
    """The app closed and reopened around five sessions, whose shells the keeper keeps."""
    if not wanted("relaunch"): return
    t0 = time.time()
    r1 = start("relaunch: still blocked", "codex", ["tui", "r:working", "s:1", "r:blocked:kind=permission", "hold:120"])
    r2 = start("relaunch: working, done after", "codex", ["tui", "r:working", f"until:{t0 + 34}", "r:done", "hold:40"])
    r3 = start("relaunch: finished while closed", "codex", ["tui", "r:working", f"until:{t0 + 15}", "r:done", "hold:60"])
    r4 = start("relaunch: asked while closed", "gemini", ["tui", f"until:{t0 + 16}", "osc9:Approval requested: deploy to production", "hold:60"])
    r5 = start("relaunch: idle, then a turn", "codex", ["tui", "r:idle", f"until:{t0 + 38}", "r:working", "s:3", "r:done", "hold:30"])
    r6 = start("relaunch: opencode working across it", "opencode", ["tui", "r:idle", "r:working", f"until:{t0 + 34}", "r:idle", "hold:30"])
    unselect()
    time.sleep(max(0, t0 + 11 - time.time()))
    pre = {sid: len(events_for(sid)) for sid in (r1, r2, r3, r4, r5, r6)}
    os.kill(app_pid(), signal.SIGTERM)
    time.sleep(max(0, t0 + 21 - time.time()))
    subprocess.run(OPEN + [COPY])
    time.sleep(max(0, t0 + 48 - time.time()))
    post = {sid: events_for(sid)[pre[sid]:] for sid in pre}
    report("relaunch: still blocked", "the dot comes back, with no second banner",
           [(e[1], e[2]) for e in raised(post[r1])] == [("needsInput", False)], post[r1])
    report("relaunch: working, done after", "restored as working; announced when it finished",
           kinds(post[r2]) == ["turnDone"] and banners(post[r2]) == ["turnDone"], post[r2])
    report("relaunch: finished while closed", "the dot, no banner for old news",
           [(e[1], e[2]) for e in raised(post[r3])] == [("turnDone", False)], post[r3])
    report("relaunch: asked while closed", "the dot, no banner for old news",
           [(e[1], e[2]) for e in raised(post[r4])] == [("needsInput", False)], post[r4])
    report("relaunch: idle, then a turn", "nothing at launch; its next turn announced",
           kinds(post[r5]) == ["turnDone"] and banners(post[r5]) == ["turnDone"], post[r5])
    report("relaunch: opencode working across it", "restored as working, so its going idle is a finished turn",
           kinds(post[r6]) == ["turnDone"], post[r6])

KIND = {"done": "turnDone", "error": "failed", "blocked": "needsInput"}

def soak_steps(rng, sentlog):
    """Forty random changes of state: some stand, some flicker past inside the 0.4s an announcement settles for."""
    steps, state, question = ["tui", "sentlog:" + sentlog, "r:idle"], "idle", 0
    for _ in range(40):
        steps.append("s:" + str(rng.choice([0.05, 0.1, 0.15]) if rng.random() < 0.35 else rng.choice([0.9, 1.3, 2.4])))
        state = rng.choices({
            "idle": ["working"], "working": ["done", "blocked", "idle", "error", "working"],
            "blocked": ["working", "blocked", "done", "idle"], "done": ["working", "idle", "done"],
            "error": ["working", "idle"]}[state], {
            "idle": [1], "working": [40, 30, 10, 10, 10], "blocked": [60, 15, 10, 15],
            "done": [60, 30, 10], "error": [70, 30]}[state])[0]
        if state == "blocked":
            question += 1
            steps.append(f"rm:blocked:{rng.choice(['permission', 'question', 'auth'])}:Question {question}")
        else:
            steps.append("r:" + state)
    return steps + ["hold:6"]

def soak_check(sid, sentlog):
    """What is wrong with one soaked session's log, as a list of sentences. Empty is a pass."""
    wrong, lines = [], lines_for(sid)
    heard = [(at,) + parse_status(text)[:2] for at, text in lines if text.startswith("status ") and not text.startswith("status: ")]
    sent = [tuple(l.split("/")) for l in open(sentlog).read().split()]
    if [(state, kind or "") for _, state, kind in heard] != sent:
        wrong.append(f"sent {len(sent)} reports, heard {len(heard)}, or not in the same order")
    # A change is a report that says something new: the same state again is not one,
    # and a new question is (each has its own words).
    changes = [h for i, h in enumerate(heard) if i == 0 or h[1] != heard[i - 1][1] or h[1] == "blocked"]
    signals = [(at, re.search(r"kind=(\w+)", text).group(1)) for at, text in lines
               if text.startswith("attention status") and "kind=" in text]
    cleared = [at for at, text in lines if text.startswith("attention cleared")]
    for i, (at, state, _) in enumerate(changes):
        stood = changes[i + 1][0] - at if i + 1 < len(changes) else 99
        if state in KIND and stood >= 0.75 and not any(k == KIND[state] and at + 0.3 <= t <= at + 1.5 for t, k in signals):
            wrong.append(f"{state} stood {stood:.1f}s and was not announced")
        # A new question straight after is still a block: nothing to take back yet.
        if (state == "blocked" and 0.75 <= stood < 99 and changes[i + 1][1] != "blocked"
                and not any(changes[i + 1][0] - 0.05 <= t <= changes[i + 1][0] + 0.6 for t in cleared)):
            wrong.append("a block that ended was not taken back")
    for t, kind in signals:
        before = [c for c in changes if c[0] <= t]
        if not before or KIND.get(before[-1][1]) != kind or not 0.3 <= t - before[-1][0] <= 1.5:
            wrong.append(f"{kind} announced with no {[k for k, v in KIND.items() if v == kind][0]} standing behind it")
    return wrong

def soak():
    """Twenty stand-in agents, forty random changes each, held against the log (see the top of the file)."""
    seed = int(SOAK.split("=")[1]) if "=" in SOAK else int(time.time()) % 100000
    print(f"soak, seed {seed}", flush=True)
    sessions = []
    for n in range(20):
        sentlog = f"{WORK}/out/soak-{n}.sent"
        sessions.append((start(f"soak {n}", "codex", soak_steps(random.Random(seed * 100 + n), sentlog)), sentlog, n))
        time.sleep(0.3)
    unselect()
    time.sleep(62)
    for sid, sentlog, n in sessions:
        wrong = soak_check(sid, sentlog)
        report(f"soak {n} (seed {seed})", "every report heard in order; announced exactly what stood",
               not wrong, [], "; ".join(sorted(set(wrong))[:4]))

def main():
    stream = set_up()
    try:
        if SOAK:
            soak()
        else:
            scenarios()
            hibernation()
            sleeping()
            relaunch()      # last: it reopens the copy without the shortened clocks
    finally:
        put_away(stream)
    print(f"\n{sum(RESULTS)} of {len(RESULTS)} passed")
    return 0 if RESULTS and all(RESULTS) else 1

if __name__ == "__main__":
    sys.exit(main())
