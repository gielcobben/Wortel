#!/usr/bin/env python3
"""Check that a session's servers are actually found, against a real machine.

`RunningJobsTests` pins the shaping against fixtures. This does the half a
fixture cannot: it starts real servers in a real login shell, in every shape
agents and people actually start them in, and asks Wortel's own scan what it
sees. Every bug this feature has shipped was of that kind — a server the tests
had no fixture for, found by the person who was running it.

    ./scripts/verify-running-jobs.py            # everything, about 5 minutes
    ./scripts/verify-running-jobs.py human      # only the hand-typed shapes
    ./scripts/verify-running-jobs.py "exec 'n"  # one shape, by substring

It compiles `ProcessTable` + `RunningJobs` into a small command that prints what
the pill would say, so what runs here is the shipping code and not a copy of it.
Nothing is installed, and every process it starts is killed on the way out.
"""
import getpass
import json
import os
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

MACOS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(tempfile.gettempdir(), "wortel-verify-running-jobs")
BIN = os.path.join(WORK, "bin")
SCAN = os.path.join(WORK, "scan")
NODE = shutil.which("node")
SESSION_ID = "00000000-0000-0000-0000-000000000001"

# The scan, as the app runs it, printed as JSON.
MAIN_SWIFT = '''
import Foundation
let shell = pid_t(CommandLine.arguments[1])!
let agent = CommandLine.arguments[2].isEmpty ? nil : CommandLine.arguments[2]
let id = UUID(uuidString: "%s")!
let ownersPath = CommandLine.arguments[3]
struct Record: Codable { let pid: Int32; let start: Double }
var owners: ProcessOwners = [:]
if let data = FileManager.default.contents(atPath: ownersPath),
   let records = try? JSONDecoder().decode([Record].self, from: data) {
    for r in records {
        owners[ProcessKey(pid: r.pid, startedAt: Date(timeIntervalSince1970: r.start))] = id
    }
}
let table = ProcessTable.snapshot()
let snapshot = RunningJobs.scan(
    table: table,
    roots: [SessionProcessRoot(sessionID: id, shellPID: shell, agentName: agent)],
    excludedPGIDs: [getpgrp()], owners: owners)
let carried = RunningJobs.recordingOwners(snapshot, table: table, previous: owners)
try? JSONEncoder().encode(carried.map { Record(pid: $0.key.pid, start: $0.key.startedAt.timeIntervalSince1970) })
    .write(to: URL(fileURLWithPath: ownersPath))
let scoped = snapshot.scoped(to: id)
func row(_ job: RunningJob) -> [String: Any] {
    ["label": job.label, "ports": job.ports, "pgid": job.pgid, "pids": job.pids,
     "agent": job.isAgent, "ownsGroup": job.ownsGroup, "detached": job.detached]
}
let out: [String: Any] = [
    "pill": scoped.hasWork ? ["title": scoped.status.title, "ports": scoped.status.ports] : NSNull(),
    "work": scoped.work.map(row), "agents": scoped.agents.map(row), "orphans": scoped.orphans.map(row)]
print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
             encoding: .utf8)!)
''' % SESSION_ID

SOURCES = ["Wortel/Processes/ProcessTable.swift", "Wortel/Processes/RunningJobs.swift",
           "Wortel/Sessions/AgentResumeStore.swift", "Wortel/Sessions/AgentConversation.swift",
           "Wortel/Sessions/FolderRoot.swift",
           "Wortel/CLI/WortelCommand.swift",
           # AgentResumeStore finds its folder through it (WORTEL_DATA_DIR).
           "Wortel/DataDirectory.swift"]


def build():
    os.makedirs(BIN, exist_ok=True)
    main = os.path.join(WORK, "main.swift")
    open(main, "w").write(MAIN_SWIFT)
    # A server that outlives its shell, so every shape has something to find.
    open(os.path.join(WORK, "server.js"), "w").write(
        "require('http').createServer((q,r)=>r.end('ok')).listen(+process.argv[2],'127.0.0.1');\n"
        "setInterval(()=>{},1e9);\n")
    result = subprocess.run(["swiftc", "-O", "-o", SCAN, main]
                            + [os.path.join(MACOS, s) for s in SOURCES],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr)
        sys.exit("could not build the scan")


def fake_agent(name):
    """An agent process by name: node copied, so `p_comm` reads like the real
    binary's (`pi`, `goose`). What the scan matches on is the name and argv, so
    a copy is the same thing to it, and no agent has to be installed."""
    path = os.path.join(BIN, name)
    if not os.path.exists(path):
        shutil.copy(NODE, path)
    return path


class Session:
    """A session's shell, spawned the way the keeper spawns one: a pty, and
    `/usr/bin/login` with the bash trampoline. Nothing here is a stand-in for
    the shell, because the two process groups login creates are exactly what
    the scan has to see past."""

    def __init__(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(WORK)
            os.environ["WORTEL_SESSION_ID"] = SESSION_ID
            os.execv("/usr/bin/login",
                     ["login", "-flp", getpass.getuser(), "/bin/bash",
                      "--noprofile", "--norc", "-c", "exec -l /bin/zsh -l"])
        self.drain(2.5)

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if ready:
                try:
                    os.read(self.fd, 65536)
                except OSError:
                    return

    def type(self, line, wait=1.0):
        os.write(self.fd, (line + "\r").encode())
        self.drain(wait)

    def close(self):
        """Hang the shell up, and keep reading its pty while it goes.

        Not a blocking `waitpid`: a process's exit flushes what it last wrote
        to its terminal, and a pty nobody reads blocks that flush in the
        kernel, past SIGKILL. With a waitpid here the run stopped dead on one
        shape, login and zsh both stuck exiting, until the script itself was
        killed and the pty closed."""
        try:
            os.kill(self.pid, signal.SIGHUP)
        except ProcessLookupError:
            pass
        end = time.time() + 10
        while time.time() < end:
            try:
                done, _ = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                break
            if done:
                break
            self.drain(0.1)
        else:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # Closing our end is the last word: it hangs up anything still on it.
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pass


def listeners(port):
    found = subprocess.run(["lsof", "-tiTCP:%d" % port, "-sTCP:LISTEN"],
                           capture_output=True, text=True)
    return [int(pid) for pid in found.stdout.split()]


def kill_port(port):
    for pid in listeners(port):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def scan(shell, agent, owners):
    out = subprocess.run([SCAN, str(shell), agent, owners], capture_output=True, text=True)
    return json.loads(out.stdout)


PASSED, FAILED = [], []


def check(name, port, start, agent=""):
    kill_port(port)
    session = Session()
    owners = os.path.join(WORK, "owners-%d.json" % port)
    if os.path.exists(owners):
        os.remove(owners)
    try:
        start(session, port)
        deadline = time.time() + 10
        while time.time() < deadline and not listeners(port):
            time.sleep(0.2)
        listening = bool(listeners(port))
        time.sleep(0.5)
        # Twice, like the app's cadence: the second scan carries ownership on.
        scan(session.pid, agent, owners)
        time.sleep(1.0)
        result = scan(session.pid, agent, owners)
        pill = result["pill"]
        shown = bool(pill) and (":%d" % port) in pill["ports"]
        if not listening:
            print("%-9s %-60s the server never started" % ("SKIP", name))
        elif shown:
            PASSED.append(name)
            print("%-9s %-60s %s" % ("ok", name, pill["title"] + " " + " ".join(pill["ports"])))
        else:
            FAILED.append(name)
            print("%-9s %-60s pill=%s" % ("MISSING", name, pill))
            for pid in listeners(port):
                line = subprocess.run(["ps", "-o", "pid,ppid,pgid,comm", "-p", str(pid)],
                                      capture_output=True, text=True).stdout.splitlines()[-1]
                print(" " * 10 + "listener: " + line.strip())
            print(" " * 10 + "scan: " + json.dumps(result)[:400])
    finally:
        kill_port(port)
        session.close()
        subprocess.run(["pkill", "-f", os.path.join(WORK, "agent-")], capture_output=True)


def server(port):
    return "%s server.js %d" % (NODE, port)


def agent_start(name, script):
    """Run `script` as the agent: the shapes below are what each agent's shell
    tool does, transcribed from its source."""
    def start(session, port):
        path = os.path.join(WORK, "agent-%d.js" % port)
        open(path, "w").write(script.replace("PORT", str(port)) + "\nsetInterval(()=>{},1e9);\n")
        session.type("%s %s" % (fake_agent(name), os.path.basename(path)))
    return start


def main():
    if not NODE:
        sys.exit("node is needed to run the servers this starts")
    only = sys.argv[1:]

    def wanted(name):
        return not only or any(pattern in name for pattern in only)

    build()
    base = 18400
    spawn = "require('child_process')"

    # Typed by a person at the prompt.
    human = [
        ("human: foreground", lambda s, p: s.type(server(p))),
        ("human: cmd &", lambda s, p: s.type(server(p) + " &")),
        ("human: nohup cmd & disown",
         lambda s, p: s.type("nohup %s >/dev/null 2>&1 & disown" % server(p))),
        ("human: ( cmd & ), adopted by launchd at once",
         lambda s, p: s.type("( %s >/dev/null 2>&1 & )" % server(p))),
        ("human: zsh -c 'cmd'", lambda s, p: s.type("zsh -c '%s'" % server(p))),
        # An Apple platform binary: the kernel will not hand over its
        # environment, so this one can only be found by its terminal session.
        ("human: ( /usr/bin/python3 -m http.server & )",
         lambda s, p: s.type("( /usr/bin/python3 -m http.server %d --bind 127.0.0.1 "
                             ">/dev/null 2>&1 & )" % p, 3)),
    ]
    port = base
    for name, start in human:
        port += 1
        if wanted(name):
            check(name, port, start)

    # Started by an agent. Each shape is a real one: see docs/running-processes.md.
    shapes = [
        ("same group, sh -c (Pi extensions via pi.exec, aider without a tty)",
         "%s.spawn('/bin/sh',['-c','CMD'],{stdio:'ignore'});"),
        ("same group, bash -c with pipes (goose, Kimi, droid foreground)",
         "const c=%s.spawn('/bin/bash',['-c','CMD']);c.stdout.on('data',()=>{});"),
        ("setsid sh -c (Pi bash tool, opencode, amp, cursor-agent)",
         "%s.spawn('/bin/sh',['-c','CMD'],{stdio:'ignore',detached:true});"),
        ("setsid bash -c with a subshell wrapper (Gemini, Qwen)",
         "%s.spawn('/bin/bash',['-c','(\\n trap \\'true\\' EXIT\\nCMD\\n)'],"
         "{stdio:'ignore',detached:true});"),
        ("pty (Codex unified exec, Gemini node-pty, aider with a tty)",
         "%s.spawn('/usr/bin/script',['-q','/dev/null','/bin/zsh','-c','CMD'],{stdio:'ignore'});"),
        ("direct child, no shell (crush)",
         "%s.spawn(NODE,['server.js','PORT'],{stdio:'ignore',detached:true});"),
        ("worker setsid then bash setsid (Kimi run_in_background)",
         "%s.spawn(NODE,['-e',\"require('child_process')"
         ".spawn('/bin/bash',['-c','CMD'],{stdio:'ignore',detached:true});"
         "setInterval(()=>{},1e9)\"],{stdio:'ignore',detached:true});"),
        ("same group, 'cmd &' so the shell returns at once",
         "%s.exec('CMD >/dev/null 2>&1 &');"),
        ("same group, 'nohup cmd &'", "%s.exec('nohup CMD >/dev/null 2>&1 &');"),
        ("setsid sh -c 'nohup cmd &' (every agent's backgrounding)",
         "%s.spawn('/bin/sh',['-c','nohup CMD >/dev/null 2>&1 &'],{stdio:'ignore',detached:true});"),
        ("pty zsh -c 'nohup cmd &' (Codex backgrounding)",
         "%s.spawn('/usr/bin/script',['-q','/dev/null','/bin/zsh','-c',"
         "'nohup CMD >/dev/null 2>&1 &'],{stdio:'ignore'});"),
        ("same group, the server as a direct child (MCP stdio shape)",
         "%s.spawn(NODE,['server.js','PORT'],{stdio:'ignore'});"),
    ]
    # Three agents: one resumable, one that runs commands in its own group, and
    # one Wortel knows by name only.
    for agent in ["pi", "goose", "kimi"]:
        for shape, script in shapes:
            port += 1
            name = "%s: %s" % (agent, shape)
            if wanted(name):
                body = (script % spawn).replace("CMD", server(port)).replace("NODE", "'%s'" % NODE)
                check(name, port, agent_start(agent, body),
                      agent=agent)

    # A project named after an agent is not the agent.
    for folder in ["claude-demo", "pi-site"]:
        port += 1
        name = "human: project directory named %s" % folder
        if not wanted(name):
            continue
        directory = os.path.join(WORK, folder)
        os.makedirs(directory, exist_ok=True)
        shutil.copy(os.path.join(WORK, "server.js"), os.path.join(directory, "server.js"))
        check(name, port,
              lambda s, p, d=directory: s.type("%s %s/server.js %d" % (NODE, d, p)))

    print()
    print("%d found, %d missing" % (len(PASSED), len(FAILED)))
    for name in FAILED:
        print("  missing: " + name)
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
