#!/usr/bin/env python3
"""What Ghostty changed since the commit Wortel builds, kept to what reaches Wortel.

    python3 scripts/ghostty-news.py                 # a Markdown report on stdout
    python3 scripts/ghostty-news.py --target REF    # judge a commit or tag of your choosing

It reads macos/GhosttyKit/{ghostty.ref,spm.ref,zig.version}, keeps a blobless
clone of Ghostty and of libghostty-spm in the Ghostty cache, and walks
Ghostty's main branch from the pin with --first-parent, so a pull request is
one line. A commit counts when it touches a file that reaches Wortel: not the
GTK app, translations, packaging or Ghostty's own CI. Each is put under the
area that says what has to be done about it (a changed default, a shell
integration fix to port by hand, ...).

The target is the newest Ghostty tag (v* for the app, vt-* for libghostty-vt)
that contains the pin: tags are the points upstream calls stable, so that is
what the weekly draft pull request moves to. Commits on main after it are
listed apart.

The report never writes `#1234` or a link to a Ghostty pull request: this
repository is public, and every such mention would add a line to that pull
request's timeline upstream, every week. Commits are linked; pull request
numbers are plain code.

When $GITHUB_OUTPUT is set (or --github-output is given) it also writes
target, target_sha, relevant, relevant_in_target, security and zig_min there,
for .github/workflows/ghostty-watch.yml (through scripts/ghostty-watch.sh).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from dataclasses import dataclass, field
from pathlib import Path

GHOSTTY_URL = "https://github.com/ghostty-org/ghostty"
SPM_URL = "https://github.com/Lakr233/libghostty-spm"

MACOS = Path(__file__).resolve().parent.parent
PKG = MACOS / "GhosttyKit"

# Never reaches Wortel: the other platform's app, translations, packaging,
# Ghostty's CI and agent files, and the parts of the CLI and inspector that
# Wortel does not ship (libghostty-spm's patch 0007 turns the inspector off).
IGNORED_PREFIXES = (
    "src/apprt/gtk",
    "po/",
    "flatpak/",
    "snap/",
    "nix/",
    "dist/",
    ".github/",
    ".agents/",
    "images/",
    "example/",
    "test/",
    "src/benchmark/",
    "src/inspector/",
    "src/cli/",
    "src/main_bench.zig",
    "src/main_wasm.zig",
    "flake.",
    "default.nix",
    "shell.nix",
    "typos.toml",
    "CODEOWNERS",
    ".mailmap",
)


@dataclass(frozen=True)
class Area:
    name: str
    prefixes: tuple[str, ...]
    todo: str


# In order of how much they ask of the person updating: a commit is listed
# once, under the first area it touches, with the others named beside it.
AREAS = (
    Area(
        "Links",
        ("src/config/url.zig",),
        "The matcher behind ⌘-click on a link or path. Check a click on a URL, "
        "a path and a path with a line number.",
    ),
    Area(
        "Config",
        ("src/config/",),
        "A changed default changes Wortel unless `Resources/wortel.conf` sets "
        "that key. Read the diff of `Config.zig`, not only the subject.",
    ),
    Area(
        "C API",
        (
            "include/",
            "src/apprt/",
            "src/apprt.zig",
            "src/main_c.zig",
            "src/lib_vt.zig",
            "src/lib/",
            "src/terminal/c/",
        ),
        "What `GhosttyRuntime` (`ghostty.h`) and the keeper (`ghostty/vt/`) "
        "call and answer. The compiler catches a changed signature, not a "
        "changed meaning (2026-11-23: a changed OPEN_URL fallback left every "
        "link dead).",
    ),
    Area(
        "Shell integration",
        ("src/shell-integration/",),
        "Not picked up by the update. Port by hand into "
        "`Resources/ghostty/shell-integration` (`docs/debugging.md`).",
    ),
    Area(
        "Terminfo",
        ("src/terminfo/",),
        "Not picked up by the update. Regenerate `Resources/terminfo` "
        "(`docs/building.md`).",
    ),
    Area(
        "Ghostty.app",
        ("macos/",),
        "Ghostty's own Mac app, not built into Wortel. An input, clipboard or "
        "IME fix here may need porting to Wortel's Swift.",
    ),
    Area(
        "Terminal",
        (
            "src/terminal/",
            "src/termio",
            "src/unicode/",
            "src/Surface.zig",
            "src/surface_mouse.zig",
            "src/App.zig",
            "src/Command.zig",
            "src/pty",
            "src/os/",
            "src/datastruct/",
            "src/simd/",
        ),
        "Comes with the update. The keeper's libghostty-vt is built from the same tree.",
    ),
    Area("Fonts", ("src/font/",), "Comes with the update."),
    Area("Renderer", ("src/renderer",), "Comes with the update."),
    Area("Input", ("src/input",), "Comes with the update."),
    Area(
        "Build",
        ("build.zig", "src/build", "pkg/", "vendor/", "deps/"),
        "Can break the libghostty-spm build or a patch. CI on the draft pull request says.",
    ),
    Area("Other", ("",), "Not sorted. Look at it once."),
)

# A word in a subject or body that should put a commit in front of a person
# today. It over-matches on purpose: a false alarm costs a minute.
SECURITY_WORDS = re.compile(
    r"\b(security|vulnerab\w*|CVE-\d+-\d+|GHSA-[\w-]+|exploit\w*|inject\w*|"
    r"use[- ]after[- ]free|out[- ]of[- ]bounds|overflow|memory corruption|untrusted)\b",
    re.IGNORECASE,
)

# Ghostty's own pull request numbers, written as code so GitHub links nothing.
PR_NUMBER = re.compile(r"\(#(\d+)\)")


@dataclass
class Commit:
    sha: str
    date: str
    subject: str
    body: str
    files: list[str] = field(default_factory=list)
    areas: list[Area] = field(default_factory=list)
    security: bool = False


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "--git-dir", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def mirror(cache: Path, name: str, url: str) -> Path:
    """A blobless bare clone, fetched fresh: about 25 MB and a few seconds."""
    repo = cache / f"{name}.git"
    if not (repo / "HEAD").exists():
        repo.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--quiet", "--bare", "--filter=blob:none", url, str(repo)],
            check=True,
        )
    subprocess.run(
        [
            "git", "--git-dir", str(repo), "fetch", "--quiet", "--prune", "--force",
            "--tags", "origin", "+refs/heads/main:refs/heads/main",
        ],
        check=True,
    )
    return repo


def read_ref(name: str) -> str:
    return (PKG / name).read_text().strip()


def is_ancestor(repo: Path, a: str, b: str) -> bool:
    return (
        subprocess.run(
            ["git", "--git-dir", str(repo), "merge-base", "--is-ancestor", a, b],
            capture_output=True,
        ).returncode
        == 0
    )


def resolve(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", f"{ref}^{{commit}}").strip()


def iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def commit_time(repo: Path, ref: str) -> datetime:
    return iso(git(repo, "log", "-1", "--format=%cI", ref).strip())


def commit_date(repo: Path, ref: str) -> str:
    return git(repo, "log", "-1", "--format=%cs", ref).strip()


def newest_tag_after(repo: Path, pin: str) -> str | None:
    """The newest v* or vt-* tag that contains the pin and is not the pin."""
    out = git(
        repo, "for-each-ref", "--sort=-creatordate", "--format=%(refname:short)",
        "refs/tags/v*",
    )
    for tag in out.split():
        if not re.fullmatch(r"v\d+\.\d+\.\d+|vt-\d+\.\d+\.\d+", tag):
            continue
        sha = resolve(repo, tag)
        if sha != pin and is_ancestor(repo, pin, sha):
            return tag
    return None


def area_of(path: str) -> Area | None:
    if path.startswith(IGNORED_PREFIXES) or path.endswith(".md"):
        return None
    for area in AREAS:
        if path.startswith(area.prefixes):
            return area
    return None


def walk(repo: Path, rng: str, first_parent: bool = True) -> list[Commit]:
    """Commits in a range (first-parent by default, so a merged pull request
    is one), each with the files it changed."""
    sep, end = "\x1f", "\x1e"
    out = git(
        repo, "log", *(["--first-parent"] if first_parent else []), "--no-renames", "--name-only",
        f"--format={end}%H{sep}%cs{sep}%s{sep}%b{sep}", rng,
    )
    commits = []
    for chunk in out.split(end)[1:]:
        sha, date, subject, body, rest = chunk.split(sep, 4)
        files = [f for f in rest.strip().splitlines() if f]
        c = Commit(sha, date, subject.strip(), body.strip(), files)
        order = {a.name: i for i, a in enumerate(AREAS)}
        c.areas = sorted({a for f in files if (a := area_of(f))}, key=lambda a: order[a.name])
        c.security = bool(SECURITY_WORDS.search(f"{subject}\n{body}"))
        commits.append(c)
    return commits


def relevant(commits: list[Commit]) -> list[Commit]:
    return [c for c in commits if c.areas]


def zig_min(repo: Path, ref: str) -> str | None:
    try:
        zon = git(repo, "show", f"{ref}:build.zig.zon")
    except subprocess.CalledProcessError:
        return None
    m = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon)
    # It is written to zig.version and read by CI: a version and nothing else.
    if m and re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.+]+)?", m.group(1)):
        return m.group(1)
    return None


def version_key(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", v.split("-")[0]))


def advisories_since(moment: datetime) -> list[dict] | str:
    """Ghostty's published security advisories after a moment, or why they
    could not be read."""
    if not shutil.which("gh"):
        return "gh is not installed"
    try:
        out = subprocess.run(
            [
                "gh", "api",
                "repos/ghostty-org/ghostty/security-advisories?state=published&per_page=30",
            ],
            check=True, capture_output=True, text=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        why = (e.stderr or "").strip().splitlines()
        return f"the advisories call failed ({quiet(why[-1]) if why else 'no message'})"
    return [
        a for a in json.loads(out)
        if a.get("published_at") and iso(a["published_at"]) > moment
    ]


def fixed_in(repo: Path, pin: str, advisory: dict) -> bool | None:
    """Whether an advisory's fix is already in the pin: True, False, or None
    when a package it names has a fix (a version like 1.4.0, or a commit)
    that is not known here.

    Wortel ships both packages an advisory can name, so it is fixed only when
    each is. The app's tags (v1.0.0) and libghostty-vt's (vt-1.0.0) share
    numbers, so a version is read with its own package's prefix only."""
    unknown = False
    for v in advisory.get("vulnerabilities") or []:
        package = ((v.get("package") or {}).get("name") or "").lower()
        prefix = "vt-" if "vt" in package else "v"
        text = v.get("patched_versions") or ""
        refs = [prefix + ver for ver in re.findall(r"\b\d+\.\d+\.\d+\b", text)]
        refs += re.findall(r"\b[0-9a-f]{7,40}\b", text)
        shas = []
        for ref in refs:
            try:
                shas.append(resolve(repo, ref))
            except subprocess.CalledProcessError:
                pass
        if not shas:
            unknown = True
        elif not any(is_ancestor(repo, sha, pin) for sha in shas):
            return False
    return None if unknown else True


def quiet(text: str) -> str:
    """Text from upstream, made unable to mention a person or cross-reference
    an issue or pull request from this public repository."""
    text = PR_NUMBER.sub(lambda m: f"(`{m.group(1)}`)", text)
    return text.replace("@", "@\u200b").replace("#", "\uff03")


def line(c: Commit) -> str:
    subject = quiet(c.subject)
    also = [a.name for a in c.areas[1:]]
    extra = f" _(also {', '.join(also)})_" if also else ""
    flag = " **security?**" if c.security else ""
    return f"- [`{c.sha[:9]}`]({GHOSTTY_URL}/commit/{c.sha}) {subject}{extra}{flag}"


def by_area(commits: list[Commit]) -> list[str]:
    out = []
    for area in AREAS:
        mine = [c for c in commits if c.areas[0] is area]
        if not mine:
            continue
        out += ["", f"#### {area.name} ({len(mine)})", "", f"_{area.todo}_", ""]
        out += [line(c) for c in mine]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--target", help="a Ghostty tag or commit to judge (default: the newest tag past the pin)")
    ap.add_argument("--cache", type=Path, help="where the clones live")
    ap.add_argument("--github-output", type=Path, default=os.environ.get("GITHUB_OUTPUT"))
    ap.add_argument("--limit", type=int, default=60000, help="cut the report at this many characters")
    args = ap.parse_args()

    cache = args.cache or Path(
        os.environ.get("WORTEL_GHOSTTY_CACHE", Path.home() / "Library/Caches/sh.wortel.ghostty")
    ) / "news"
    gh = mirror(cache, "ghostty", GHOSTTY_URL)
    spm = mirror(cache, "libghostty-spm", SPM_URL)

    pin = resolve(gh, read_ref("ghostty.ref"))
    pin_day = commit_date(gh, pin)
    spm_pin = resolve(spm, read_ref("spm.ref"))
    zig_ours = read_ref("zig.version")

    target_name = args.target or newest_tag_after(gh, pin)
    target = resolve(gh, target_name) if target_name else None
    if target and not is_ancestor(gh, pin, target):
        print(f"[!] {target_name} does not contain the pin {pin[:9]}", file=sys.stderr)
        return 1

    on_main = walk(gh, f"{pin}..main")
    rel_main = relevant(on_main)
    # The target's own walk, so a commit off main (--target on a branch) is
    # judged by what it holds; main after it is what main has beyond that.
    rel_target = relevant(walk(gh, f"{pin}..{target}")) if target else []
    in_target = {c.sha for c in walk(gh, f"{pin}..{target}", first_parent=False)} if target else set()
    rel_after = [c for c in rel_main if c.sha not in in_target]
    flagged = list({c.sha: c for c in rel_main + rel_target if c.security}.values())
    # Ghostty publishes an advisory hours after the release that fixes it, so
    # the date alone would report fixes the pin already has.
    advisories = advisories_since(commit_time(gh, pin))
    advisories_error = advisories if isinstance(advisories, str) else None
    if advisories_error:
        advisories = []
    else:
        advisories = [a for a in advisories if fixed_in(gh, pin, a) is not True]

    zig_needed = zig_min(gh, target or "main")
    zig_raise = bool(zig_needed and version_key(zig_needed) > version_key(zig_ours))

    # libghostty-spm: its own Ghostty.ref is the commit its patch stack was
    # last made to apply to.
    spm_main = resolve(spm, "main")
    spm_tested = git(spm, "show", "main:Ghostty.ref").strip()
    spm_changes = [
        c for c in walk(spm, f"{spm_pin}..main")
        if any(f.startswith(("Patches/", "build.sh", "Script/")) for f in c.files)
    ]
    spm_tested_known = subprocess.run(
        ["git", "--git-dir", str(gh), "cat-file", "-e", f"{spm_tested}^{{commit}}"],
        capture_output=True,
    ).returncode == 0
    spm_covers_target = bool(
        target and spm_tested_known and is_ancestor(gh, target, spm_tested)
    )

    r: list[str] = []
    main_sha = resolve(gh, "main")
    r.append(
        f"Wortel builds Ghostty [`{pin[:9]}`]({GHOSTTY_URL}/commit/{pin}) ({pin_day}). "
        f"Since then main has {len(on_main)} commits, {len(rel_main)} of them reaching Wortel "
        f"(to [`{main_sha[:9]}`]({GHOSTTY_URL}/commit/{main_sha}), {commit_date(gh, main_sha)})."
    )
    r.append("")
    if target:
        r.append(
            f"**Newest tag: `{target_name}`** ([`{target[:9]}`]({GHOSTTY_URL}/commit/{target}), "
            f"{commit_date(gh, target)}): {len(rel_target)} of its changes reach Wortel."
        )
    else:
        r.append("No Ghostty tag is newer than the pin. Nothing to move to yet.")

    r += ["", "| | |", "|---|---|"]
    r.append(
        f"| Zig | `zig.version` is {zig_ours}; "
        + (
            f"{target_name or 'main'} needs at least {zig_needed}. **Raise `zig.version`.** |"
            if zig_raise
            else f"{target_name or 'main'} needs at least {zig_needed or 'unknown'}. Fine. |"
        )
    )
    r.append(
        f"| libghostty-spm | ours is `{spm_pin[:9]}`; its main is `{spm_main[:9]}` and has "
        f"{len(spm_changes)} change{'s' if len(spm_changes) != 1 else ''} to its patches or build. "
        f"Its main was last made for Ghostty `{spm_tested[:9]}`"
        + (
            f", which already includes {target_name}. |"
            if spm_covers_target
            else (f", older than {target_name}: its patches may need work. |" if target else ". |")
        )
    )
    r.append(
        "| Security | "
        + (
            f"**Advisories not checked: {advisories_error}.** "
            if advisories_error
            else f"{len(advisories)} advisor{'y' if len(advisories) == 1 else 'ies'} published since the pin and not fixed in it. "
        )
        + f"{len(flagged)} commit{'s' if len(flagged) != 1 else ''} mention a security word. |"
    )

    if advisories:
        r += ["", "### Security advisories not fixed in the pin", ""]
        for a in advisories:
            patched = ", ".join(
                sorted({quiet(v.get("patched_versions") or "?") for v in a.get("vulnerabilities") or []})
            )
            r.append(
                f"- [{a['ghsa_id']}]({a['html_url']}) {a['severity']}: {quiet(a['summary'])} "
                f"(published {a['published_at'][:10]}, patched in {patched or '?'})"
            )
    if flagged:
        r += ["", "### Mentions a security word", "", "_Read these first. A match is a word, not a verdict._", ""]
        r += [line(c) for c in flagged]

    if target:
        r += ["", f"### In {target_name}"]
        r += by_area(rel_target) if rel_target else ["", "Nothing that reaches Wortel."]
    r += ["", f"### On main{' after ' + target_name if target else ''}"]
    r += by_area(rel_after) if rel_after else ["", "Nothing that reaches Wortel."]

    if spm_changes:
        r += ["", "### libghostty-spm", ""]
        for c in spm_changes:
            subject = quiet(c.subject)
            r.append(f"- [`{c.sha[:9]}`]({SPM_URL}/commit/{c.sha}) {subject}")

    r += [
        "",
        "_Made by `macos/scripts/ghostty-news.py`. Moving Ghostty is the `update-ghostty` skill._",
    ]

    report = "\n".join(r) + "\n"
    if len(report) > args.limit:
        cut = report[: args.limit].rsplit("\n", 1)[0]
        report = cut + "\n\n_Cut short. Run `python3 macos/scripts/ghostty-news.py` for the rest._\n"
    sys.stdout.write(report)

    if args.github_output:
        with open(args.github_output, "a") as f:
            f.write(f"target={target_name or ''}\n")
            f.write(f"target_sha={target or ''}\n")
            f.write(f"relevant={len(rel_main)}\n")
            f.write(f"relevant_in_target={len(rel_target)}\n")
            f.write(f"security={len(flagged) + len(advisories)}\n")
            f.write(f"zig_min={zig_needed or ''}\n")
            f.write(f"zig_raise={'true' if zig_raise else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
