# Wortel's version numbers, for scripts/release.sh. Sourced, not run.
#
# A regular release is CalVer: <ISO-week-year>.<ISO-week>.<Nth that week>,
# e.g. 2026.48.4. A beta is named for the release it leads up to, with its
# own count: 2026.48.4b1, 2026.48.4b2, then the release 2026.48.4. So the
# public numbers have no gaps, and a tester can see what a beta becomes.
#
# Two spellings of one version:
#   2026.48.4b1       the machine's: CFBundleVersion, sparkle:version, the
#                     zip, the DMG, releases/BUILD and the note's filename.
#   2026.48.4 beta 1  a person's: CFBundleShortVersionString, which is what
#                     Sparkle's dialog, About and `wortel --version` show.
#
# Why "b" and not "-beta.1" or " beta 1" in the machine's spelling: Sparkle
# compares CFBundleVersion with SUStandardVersionComparator, which stops at
# the first "-" (2026.48.4-beta.1 would equal 2026.48.4, so the release would
# never be offered over it) and treats a space as a separator (2026.48.4 beta 1
# would rank *above* 2026.48.4). A letter run after the numbers ranks below the
# bare version, and the number after it counts: 2026.48.3 < 2026.48.4b1 <
# 2026.48.4b2 < 2026.48.4. scripts/test-version.sh checks this order against
# Sparkle's own comparator, not just against version_key below.
#
# Not `sort -V`: it has no rule for "b" and puts 2026.48.4b1 after 2026.48.4.

# A string that sorts (as text) the way Sparkle orders these versions: up to
# four numeric parts, zero-filled, then 0 for a beta and 1 for a release, then
# the beta's number. Prints nothing for a version it can't read.
#
# In awk, and the dot written [.], so it reads the same sourced into bash
# (release.sh) or zsh (a person's shell, or an agent's): zsh drops the
# backslash in an unquoted `\.`, which then matches any character.
#
# A beta's number is 1 to 99 with no leading zero, the range CalVer in
# Telemetry/TelemetryEvent.swift reads back: a b0, b100 or b01 would ship,
# and its crash reports would be dropped or name a dSYM folder that isn't.
version_key() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+){0,3}(b[1-9][0-9]?)?$ ]] || return 0
  awk -v v="$1" 'BEGIN {
    base = v; beta = ""
    if ((i = index(v, "b")) > 0) { base = substr(v, 1, i - 1); beta = substr(v, i + 1) }
    n = split(base, p, ".")
    for (k = n + 1; k <= 4; k++) p[k] = 0
    printf "%010d.%010d.%010d.%010d.%d.%010d\n", p[1], p[2], p[3], p[4], (beta == "" ? 1 : 0), beta + 0
  }'
}

# The newest of the versions on stdin, one per line. Lines it can't read are
# skipped, so an odd entry in the feed can't become "the last version".
#
# A last line without a newline still counts, and an unreadable last line
# doesn't fail the loop (which, under pipefail, would fail the caller after
# it had printed the right answer).
version_newest() {
  local v key
  while IFS= read -r v || [ -n "$v" ]; do
    key=$(version_key "$v")
    if [ -n "$key" ]; then printf '%s %s\n' "$key" "$v"; fi
  done | LC_ALL=C sort | tail -1 | cut -d' ' -f2
}

# Whether $1 is newer than $2 (or $2 is empty).
version_is_newer() {
  [ -z "$2" ] && return 0
  local a b
  a=$(version_key "$1"); b=$(version_key "$2")
  [ -n "$a" ] && [[ "$a" > "$b" ]]
}

version_is_beta() { [ -n "$(version_key "$1")" ] && [[ "$1" == *b* ]]; }

# The version to publish next, after `last` (the newest published, machine
# spelling, or empty), in ISO week `week` of ISO year `year`.
#   version_next <last> <0|1 beta> <year> <week>
#
# The next regular number is the one after the newest regular this week, or
# .1 in a new week. A beta of it is that number with b1, or the b after the
# last beta of the same number. A regular release after a beta of its own
# number is that number: the beta's promotion. A week that ends during a beta
# moves on: a beta of 2026.48.4 promoted in week 49 ships as 2026.49.1, which
# Sparkle ranks above it all the same.
version_next() {
  local last=$1 beta=$2 year=$3 week=$((10#$4)) base n next lastbeta=""   # `date +%V` says 09
  base=$last
  if version_is_beta "$last"; then base=${last%%b*}; lastbeta=${last##*b}; fi
  if [[ "$base" == "$year.$week."* ]]; then
    n=${base##*.}
    if [ -n "$lastbeta" ]; then next=$base; else next="$year.$week.$((10#$n + 1))"; fi
  else
    next="$year.$week.1"
  fi
  if [ "$beta" = 1 ]; then
    if [ -n "$lastbeta" ] && [ "$base" = "$next" ]; then
      echo "${next}b$((10#$lastbeta + 1))"
    else
      echo "${next}b1"
    fi
  else
    echo "$next"
  fi
}

# The person's spelling: 2026.48.4b1 -> "2026.48.4 beta 1"; a release as is.
version_display() {
  if version_is_beta "$1"; then echo "${1%%b*} beta ${1##*b}"; else echo "$1"; fi
}
