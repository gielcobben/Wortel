# Parts of this script are based on Kitty's bash integration. Kitty is
# distributed under GPLv3, so this file is also distributed under GPLv3.
# The license header is reproduced below:
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# We need to be in interactive mode to proceed.
if [[ "$-" != *i* ]]; then builtin return; fi

# When automatic shell integration is active, we were started in POSIX
# mode and need to manually recreate the bash startup sequence.
if [ -n "$GHOSTTY_BASH_INJECT" ]; then
  # Store a temporary copy of our startup flags and unset these global
  # environment variables so we can safely handle reentrancy.
  builtin declare __ghostty_bash_flags="$GHOSTTY_BASH_INJECT"
  builtin unset ENV GHOSTTY_BASH_INJECT

  # Restore an existing ENV that was replaced by the shell integration code.
  if [[ -n "$GHOSTTY_BASH_ENV" ]]; then
    builtin export ENV=$GHOSTTY_BASH_ENV
    builtin unset GHOSTTY_BASH_ENV
  fi

  # Restore bash's default 'posix' behavior. Also reset 'inherit_errexit',
  # which doesn't happen as part of the 'posix' reset.
  builtin set +o posix
  builtin shopt -u inherit_errexit 2>/dev/null

  # Unexport HISTFILE if it was set by the shell integration code.
  if [[ -n "$GHOSTTY_BASH_UNEXPORT_HISTFILE" ]]; then
    builtin export -n HISTFILE
    builtin unset GHOSTTY_BASH_UNEXPORT_HISTFILE
  fi

  # Manually source the startup files. See INVOCATION in bash(1) and
  # run_startup_files() in shell.c in the Bash source code.
  if builtin shopt -q login_shell; then
    if [[ $__ghostty_bash_flags != *"--noprofile"* ]]; then
      [ -r /etc/profile ] && builtin source "/etc/profile"
      for __ghostty_rcfile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        [ -r "$__ghostty_rcfile" ] && {
          builtin source "$__ghostty_rcfile"
          break
        }
      done
    fi
  else
    if [[ $__ghostty_bash_flags != *"--norc"* ]]; then
      # The location of the system bashrc is determined at bash build
      # time via -DSYS_BASHRC and can therefore vary across distros:
      #  Arch, Debian, Ubuntu use /etc/bash.bashrc
      #  Fedora uses /etc/bashrc sourced from ~/.bashrc instead of SYS_BASHRC
      #  Void Linux uses /etc/bash/bashrc
      #  Nixos uses /etc/bashrc
      for __ghostty_rcfile in /etc/bash.bashrc /etc/bash/bashrc /etc/bashrc; do
        [ -r "$__ghostty_rcfile" ] && {
          builtin source "$__ghostty_rcfile"
          break
        }
      done
      if [[ -z "$GHOSTTY_BASH_RCFILE" ]]; then GHOSTTY_BASH_RCFILE="$HOME/.bashrc"; fi
      [ -r "$GHOSTTY_BASH_RCFILE" ] && builtin source "$GHOSTTY_BASH_RCFILE"
    fi
  fi

  builtin unset __ghostty_rcfile
  builtin unset __ghostty_bash_flags
  builtin unset GHOSTTY_BASH_RCFILE
fi

# WORTEL: put the bundled `wortel` command on PATH. See the zsh copy
# (Resources/ghostty/shell-integration/zsh/ghostty-integration) for why
# upstream's $GHOSTTY_BIN_DIR block is deleted rather than disabled — in short,
# Contents/MacOS holds only the app's own executable, `wortel` matched it on a
# case-insensitive disk, and `no-path` in the feature list still matches the
# `*"path"*` guard. Prepended so this app's command beats an older symlink.
if [[ -n "${WORTEL_BIN_DIR-}" && ":$PATH:" != *":${WORTEL_BIN_DIR-}:"* ]]; then
  export PATH="$WORTEL_BIN_DIR:$PATH"
fi

# And take Contents/MacOS back off — the core adds it whatever the `path`
# feature says, and the only file in it is the app's own executable, which a
# case-insensitive disk hands over for `wortel`. See the zsh copy.
if [[ -n "${GHOSTTY_BIN_DIR-}" ]]; then
  PATH=":$PATH:"
  PATH="${PATH//:$GHOSTTY_BIN_DIR:/:}"
  PATH="${PATH#:}"
  PATH="${PATH%:}"
  export PATH
fi

# Sudo
if [[ "$GHOSTTY_SHELL_FEATURES" == *"sudo"* && -n "$TERMINFO" ]]; then
  # Wrap `sudo` command to ensure Ghostty terminfo is preserved.
  #
  # This approach supports wrapping a `sudo` alias, but the alias definition
  # must come _after_ this function is defined. Otherwise, the alias expansion
  # will take precedence over this function, and it won't be wrapped.
  function sudo {
    builtin local sudo_has_sudoedit_flags="no"
    for arg in "$@"; do
      # Check if argument is '-e' or '--edit' (sudoedit flags)
      if [[ "$arg" == "-e" || $arg == "--edit" ]]; then
        sudo_has_sudoedit_flags="yes"
        builtin break
      fi
      # Check if argument is neither an option nor a key-value pair
      if [[ "$arg" != -* && "$arg" != *=* ]]; then
        builtin break
      fi
    done
    if [[ "$sudo_has_sudoedit_flags" == "yes" ]]; then
      builtin command sudo "$@"
    else
      builtin command sudo --preserve-env=TERMINFO "$@"
    fi
  }
fi

# SSH Integration
if [[ "$GHOSTTY_SHELL_FEATURES" == *ssh-* ]]; then
  function ssh() {
    builtin local ssh_term ssh_opts
    ssh_term="xterm-256color"
    ssh_opts=()

    # Configure environment variables for remote session
    if [[ "$GHOSTTY_SHELL_FEATURES" == *ssh-env* ]]; then
      # SendEnv, not `SetEnv COLORTERM=truecolor`: a SetEnv given with -o
      # replaces every SetEnv in the user's own ~/.ssh/config. COLORTERM is set
      # on the ssh command at the bottom instead. (Ghostty 69554f414.)
      ssh_opts+=(-o "SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION")
    fi

    # Install terminfo on remote host if needed
    if [[ "$GHOSTTY_SHELL_FEATURES" == *ssh-terminfo* ]]; then
      builtin local ssh_user ssh_hostname

      while IFS=' ' read -r ssh_key ssh_value; do
        case "$ssh_key" in
        user) ssh_user="$ssh_value" ;;
        hostname) ssh_hostname="$ssh_value" ;;
        esac
        [[ -n "$ssh_user" && -n "$ssh_hostname" ]] && break
      done < <(builtin command ssh -G "$@" 2>/dev/null)

      if [[ -n "$ssh_hostname" ]]; then
        builtin local ssh_target="${ssh_user}@${ssh_hostname}"

        # Check if terminfo is already cached
        if "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --host="$ssh_target" >/dev/null 2>&1; then
          ssh_term="xterm-ghostty"
        elif builtin command -v infocmp >/dev/null 2>&1; then
          builtin local ssh_terminfo ssh_cpath_dir ssh_cpath

          ssh_terminfo=$(infocmp -0 -x xterm-ghostty 2>/dev/null)

          if [[ -n "$ssh_terminfo" ]]; then
            builtin echo "Setting up xterm-ghostty terminfo on $ssh_hostname..." >&2

            ssh_cpath_dir=$(mktemp -d "/tmp/ghostty-ssh-$ssh_user.XXXXXX" 2>/dev/null) || ssh_cpath_dir="/tmp/ghostty-ssh-$ssh_user.$$"
            ssh_cpath="$ssh_cpath_dir/socket"

            # Wortel: install first, and accept an entry already there only
            # when the host has no tic. See the zsh copy.
            if builtin echo "$ssh_terminfo" | builtin command ssh -o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s "$@" '
              command -v tic >/dev/null 2>&1 && mkdir -p ~/.terminfo 2>/dev/null && tic -x -o ~/.terminfo - 2>/dev/null && exit 0
              infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
              exit 1
            ' 2>/dev/null; then
              ssh_term="xterm-ghostty"
              ssh_opts+=(-o "ControlPath=$ssh_cpath")

              # Cache successful installation
              "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --add="$ssh_target" >/dev/null 2>&1 || true
            else
              builtin echo "Warning: Failed to install terminfo." >&2
            fi
          else
            builtin echo "Warning: Could not generate terminfo data." >&2
          fi
        else
          builtin echo "Warning: ghostty command not available for cache management." >&2
        fi
      fi
    fi

    # Execute SSH with TERM environment variable
    TERM="$ssh_term" COLORTERM=truecolor builtin command ssh "${ssh_opts[@]}" "$@"
  }
fi

# This is set to 1 when we're executing a command so that we don't
# send prompt marks multiple times.
_ghostty_executing=""
_ghostty_last_reported_cwd=""

function __ghostty_precmd() {
  local ret="$?"
  # Wortel: bash-preexec calls this with `$?` set to the status of the command
  # that ended, and nothing else. The PROMPT_COMMAND hook (bash 4.4+) passes
  # it as `$1` instead, because its own `local` has reset `$?` to 0 by the time
  # this runs: read only `$?`, every command there ended 0, to OSC 133;D and to
  # the agent exit log alike, and a Ctrl-Z (146) looked like an exit.
  [[ $# -gt 0 ]] && ret="$1"
  if test "$_ghostty_executing" != "0"; then
    _GHOSTTY_SAVE_PS1="$PS1"
    _GHOSTTY_SAVE_PS2="$PS2"

    # Use 133;P (not 133;A) inside PS1 to avoid fresh-line behavior on
    # readline redraws (e.g., vi mode switches, Ctrl-L). The initial
    # 133;A with fresh-line is emitted once via printf below.
    PS1='\[\e]133;P;k=i\a\]'$PS1'\[\e]133;B\a\]'
    PS2='\[\e]133;P;k=s\a\]'$PS2'\[\e]133;B\a\]'

    # Bash doesn't redraw the leading lines in a multiline prompt so we mark
    # the start of each line (after each newline) as a secondary prompt. This
    # correctly handles multiline prompts by setting the first to primary and
    # the subsequent lines to secondary.
    #
    # We only replace the \n prompt escape, not literal newlines ($'\n'),
    # because literal newlines may appear inside $(...) command substitutions
    # where inserting escape sequences would break shell syntax.
    if [[ "$PS1" == *"\n"* ]]; then
      PS1="${PS1//\\n/\\n$'\\[\\e]133;P;k=s\\a\\]'}"
    fi

    # Cursor
    if [[ "${GHOSTTY_SHELL_FEATURES-}" == *"cursor"* ]]; then
      builtin local cursor=5  # blinking bar
      [[ "$GHOSTTY_SHELL_FEATURES" == *"cursor:steady"* ]] && cursor=6  # steady bar

      [[ "$PS1" != *"\[\e[${cursor} q\]"* ]] && PS1=$PS1"\[\e[${cursor} q\]"
      [[ "${PS0-}" != *'\[\e[0 q\]'* ]] && PS0=${PS0-}'\[\e[0 q\]' # reset
    fi

    # Title (working directory): printed below, not put in PS1 as `\w`.
  fi

  # Wortel: `${BASHPID-}`: bash 3.2 (the macOS /bin/bash) has no BASHPID, and
  # under a user's `set -u` the bare one ended this function right here, so
  # no prompt mark was written and no agent marker ever cleared.
  if test "$_ghostty_executing" != ""; then
    # End of current command. Report its status.
    builtin printf "\e]133;D;%s;aid=%s\a" "$ret" "${BASHPID-}"
  fi

  # Fresh line and start of prompt. When ble.sh is active, emit 133;P instead
  # of 133;A because ble.sh maintains its own cursor position tracking. 133;A's
  # cursor movement (CR+LF when not at column 0) is invisible to ble.sh and
  # desyncs its position state, causing display artifacts like duplicate
  # prompts. See: https://github.com/akinomyoga/ble.sh/issues/684 (Ghostty
  # b1ad24e24.)
  if [[ -n "${BLE_VERSION-}" ]]; then
    builtin printf "\e]133;P;k=i\a"
  else
    builtin printf "\e]133;A;redraw=last;cl=line;aid=%s\a" "${BASHPID-}"
  fi

  # unfortunately bash provides no hooks to detect cwd changes
  # in particular this means cwd reporting will not happen for a
  # command like cd /test && cat. PS0 is evaluated before cd is run.
  if [[ "$_ghostty_last_reported_cwd" != "$PWD" ]]; then
    _ghostty_last_reported_cwd="$PWD"
    # Wortel: "localhost", not "$HOSTNAME" — see the zsh integration's
    # _ghostty_report_pwd for why. Same exposure: an unset $HOSTNAME emits a
    # hostless URI that libghostty drops, and a captured one goes stale when
    # the machine is renamed mid-session.
    #
    # Control bytes are taken out of the directory first (Ghostty 6eb24a0f0): a
    # raw ESC or BEL in a directory name ended this OSC 7 early and started a
    # sequence of its own, such as an OSC 52 clipboard write. Backslashes are
    # safe, because printf only expands escapes in its format, not in %s.
    builtin printf "\e]7;kitty-shell-cwd://localhost%s\a" "${PWD//[[:cntrl:]]/}"
  fi

  # Title (working directory), as `\w` would show it. Wortel prints it here
  # rather than putting `\[\e]2;\w\a\]` in PS1, upstream's way: bash copies
  # a raw ESC or BEL in a directory name straight through `\w` (measured on
  # 3.2), so a directory could inject a sequence of its own, the hole closed
  # for OSC 7 above. Printed at every prompt, as the PS1 version was.
  if [[ "${GHOSTTY_SHELL_FEATURES-}" == *"title"* ]]; then
    builtin local title="$PWD"
    if [[ -n "${HOME-}" ]]; then
      case "$title" in
        "$HOME")   title="~" ;;
        "$HOME"/*) title="~${title:${#HOME}}" ;;
      esac
    fi
    builtin printf "\e]2;%s\a" "${title//[[:cntrl:]]/}"
  fi

  # Wortel: clear this session's agent marker at every prompt. See
  # __ghostty_wortel_clear_agent.
  if [[ -n "${WORTEL_SESSION_ID-}" ]]; then
    __ghostty_wortel_clear_agent "$ret"
  fi

  _ghostty_executing=0
}

# Wortel: clear this session's agent marker, so a marker only survives while an
# agent is actually running — which is precisely when no prompt fires. See
# __ghostty_wortel_agent.
#
# And log the exit first: a marker here means the command that just ended was
# an agent, and its status (`$1`) is the only trace of *why* once the
# scrollback is gone (129 and up is a signal: 129 SIGHUP, 130 SIGINT, 143
# SIGTERM). One line, on this path only; see the zsh copy.
#
# Only a marker this shell wrote: our own is logged and cleared, a dead shell's
# is cleared quietly, a live other shell's is left alone. A session can briefly
# have two shells across a relaunch; see the zsh copy.
#
# Not an agent that was only stopped: Ctrl-Z comes back to a prompt with the
# agent alive as a suspended job (status 146), and `fg` launches no agent, so
# clearing the marker then left the agent untracked for the rest of its life.
# A stop keeps the marker and remembers the job's pid for as long as that
# process lives, through `fg`, `bg` and stopping again; see the zsh copy.
#
# Written for `set -u` and `set -e`, since it runs in the user's own shell:
# every expansion has a default, and nothing ends on a failing test.
function __ghostty_wortel_clear_agent() {
  builtin local marker="$_ghostty_wortel_agent_dir/$WORTEL_SESSION_ID"
  if [[ ! -f "$marker" ]]; then
    _ghostty_wortel_stopped=""
    return 0
  fi
  builtin local line agent="" owner="" started="" pid
  while IFS= builtin read -r line; do
    case "$line" in
      agent=*)     agent="${line#agent=}" ;;
      shellpid=*)  owner="${line#shellpid=}" ;;
      startedat=*) started="${line#startedat=}" ;;
    esac
  done 2>/dev/null < "$marker"
  if [[ -n "$owner" && "$owner" != "$$" ]]; then
    builtin kill -0 "$owner" 2>/dev/null || command rm -f "$marker" 2>/dev/null
    return 0
  fi
  if [[ -n "${_ghostty_wortel_stopped-}" &&
        "${_ghostty_wortel_stopped#* }" == "$agent $started" ]] &&
     builtin kill -0 "${_ghostty_wortel_stopped%% *}" 2>/dev/null; then
    return 0
  fi
  case "${1-}" in
    14[5-9]|150)
      # A stop signal's status (macOS numbers SIGSTOP 17, SIGTSTP 18, SIGTTIN
      # 21, SIGTTOU 22; 19 and 20 are Linux's), and the current job stopped:
      # the status alone could be an exit code. The one fork here, on the path
      # where an agent has just stopped.
      pid="$(builtin jobs -ps %+ 2>/dev/null)"
      pid="${pid%%[!0-9]*}"
      if [[ -n "$pid" ]]; then
        _ghostty_wortel_stopped="$pid $agent $started"
        # Nothing is in progress while it is stopped, and the app ignores the
        # prompt's 133;D while a marker is live; see the zsh copy.
        builtin printf '\e]9;4;0\a'
        return 0
      fi
      ;;
  esac
  _ghostty_wortel_stopped=""
  __ghostty_wortel_now
  builtin printf '%s session=%s agent=%s status=%s shellpid=%s\n' \
    "$REPLY" "$WORTEL_SESSION_ID" "$agent" "${1-?}" "$$" \
    >> "$_ghostty_wortel_agent_dir/exits.log" 2>/dev/null
  command rm -f "$marker" 2>/dev/null
  return 0
}

# Wortel: the time in epoch seconds, in REPLY. A builtin from bash 4.2; the
# macOS /bin/bash is 3.2, which forks `date` (on the agent path only).
function __ghostty_wortel_now() {
  if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
    builtin printf -v REPLY '%(%s)T' -1
  else
    REPLY="$(command date +%s)"
  fi
}

# Wortel: split a command line into the caller's `words` (bash's scoping is
# dynamic, so the caller's local is the one assigned). `;` and `&&` are padded
# first so `cd x;claude` splits where the shell would. The split is the
# shell's own word splitting with globbing off and the default IFS, whatever
# the user's is: a custom IFS made `claude --model x` one word, and the agent
# in it invisible. (Not a here-string: before bash 5.1 that is a temp file
# written for every command typed.)
function __ghostty_wortel_split() {
  builtin local line="${1-}" IFS=$' \t\n' noglob="" semi=' ; ' and=' && '
  # Exactly this form: from bash 5.2 an unquoted `&` in a replacement stands
  # for the matched text (patsub_replacement), which turned ` && ` into
  # ` &&&& `, and 3.2 keeps the quotes of a quoted literal one (`" && "`), and
  # of the whole thing in double quotes. A quoted variable, unquoted
  # assignment, is literal in both.
  line=${line//$'\n'/"$semi"}
  line=${line//;/"$semi"}
  line=${line//&&/"$and"}
  [[ $- == *f* ]] && noglob=1
  builtin set -f
  words=($line)
  [[ -n "$noglob" ]] || builtin set +f
  return 0
}

# Wortel: walk to the program a simple command launches. Advances `i` (the
# caller's index into its `words`) past env assignments (FOO=bar), launchers
# (sudo, nohup, exec...) and package runners (npx, `pnpm dlx`), stopping at
# `e`, the segment's last word. REPLY is the program's word, or empty.
function __ghostty_wortel_program() {
  builtin local w
  REPLY=""
  while (( i <= e )); do
    w="${words[i]}"
    case "$w" in
      *=*)                                              i=$((i+1)); continue ;;
      sudo|doas|command|builtin|exec|nohup|nice|stdbuf|setsid|env)
                                                        i=$((i+1)); continue ;;
      npx|bunx|pnpx|uvx|pipx)                           i=$((i+1)); continue ;;
      npm|pnpm|yarn|bun|deno)
        # Package runners: in `pnpm dlx codex` or `bun x pi` the program is the
        # word after the subcommand. Only skip when the subcommand is actually
        # there — a bare `bun` is a REPL and must keep reaching the dual-use
        # check.
        case "${words[i+1]-}" in
          x|dlx|exec|run)                               i=$((i+2)); continue ;;
        esac
        REPLY="$w"; return 0 ;;
      -*)                                               i=$((i+1)); continue ;;
      *)                                                REPLY="$w"; return 0 ;;
    esac
  done
  return 0
}

# Wortel: the agent a word names, in REPLY; false (and REPLY empty) when it
# names none. The program itself or the package a runner fetches it as
# (`npx @anthropic-ai/claude-code` is claude, `bunx
# @mariozechner/pi-coding-agent` is pi); quotes, a leading backslash and a
# version pin are not part of the name. See the zsh copy.
function __ghostty_wortel_agent_name() {
  REPLY="${1-}"
  REPLY="${REPLY//[\"\'\\]/}"
  REPLY="${REPLY##*/}"
  case "$REPLY" in
    ?*@*) REPLY="${REPLY%%@*}" ;;
  esac
  case "$REPLY" in
    claude|pi|aider|codex|cursor-agent|gemini|opencode|goose|cline|ollama|llm|crush|amp) ;;
    claude-code)        REPLY=claude ;;
    pi-coding-agent)    REPLY=pi ;;
    gemini-cli)         REPLY=gemini ;;
    opencode-ai)        REPLY=opencode ;;
    aider-chat)         REPLY=aider ;;
    *)                  REPLY=""; return 1 ;;
  esac
  return 0
}

# Wortel: true if a REPL that is also a script runner (python, node...) was
# started bare. `python script.py`, `node app.js`, `python -m mod` and `-c
# ...` are batch jobs that should keep the spinner; the arguments are the words
# after the program.
function __ghostty_wortel_bare_repl() {
  builtin local a
  for a in "$@"; do
    case "$a" in
      -i|-q|-u|-B|-E|-O|-OO|-s|-S|-I|--) continue ;;
      -c|-m)             return 1 ;;
      *[\<\>\|\&\;]*)    return 0 ;;
      -*)                continue ;;
      *)                 return 1 ;;
    esac
  done
  return 0
}

# Wortel: true if the command line launches a long-lived interactive program
# (agent CLI, editor, pager, REPL, system monitor, TUI) that sits at its own
# prompt instead of returning to the shell. For those the synthetic busy spinner
# (OSC 9;4;3 in preexec) would never clear until you quit — no OSC 133;D fires —
# so we skip it and let the program report its own progress. Builds/tests spin.
# Every command on the line counts, not just the first: `cd x && claude` and
# `git diff | less` end in a program that holds the terminal.
function __ghostty_wortel_interactive() {
  builtin local -a words
  __ghostty_wortel_split "${1-}"
  builtin local s=0 e i n=0 cmd REPLY
  # (An empty array's length is "unbound" to bash 5 under `set -u`.)
  [[ -n "${words[*]+x}" ]] && n=${#words[@]}
  while (( s < n )); do
    # The segment runs to the next word that starts another command on the
    # same line (`&&`, `;`, `|`, `&`...).
    e=$s
    while (( e < n )); do
      case "${words[e]}" in
        ';'|'&&'|'||'|'|'|'|&'|'&') break ;;
      esac
      e=$((e+1))
    done
    i=$s; s=$((e+1)); e=$((e-1))
    __ghostty_wortel_program
    cmd="${REPLY##*/}"
    [[ -n "$cmd" ]] || continue
    case "$cmd" in
      claude|pi|aider|codex|cursor-agent|gemini|opencode|goose|cline|ollama|llm|crush|amp) return 0 ;;
      vi|vim|nvim|vis|nano|emacs|emacsclient|helix|hx|kak|micro|ne|joe) return 0 ;;
      less|more|most|moar|man|bat|w3m|lynx) return 0 ;;
      top|htop|btop|btm|glances|gtop|nvtop|s-tui) return 0 ;;
      ssh|mosh|et|autossh|telnet|tmux|screen|byobu|zellij|dtach|abduco) return 0 ;;
      watch|journalctl|dmesg) return 0 ;;
      fzf|sk|gitui|lazygit|lazydocker|k9s|tig|ranger|nnn|yazi|lf|vifm|mc|broot|xplr) return 0 ;;
      gdb|lldb|pdb) return 0 ;;
      psql|mysql|mariadb|sqlite3|litecli|pgcli|mycli|redis-cli|mongosh|mongo|usql|duckdb|clickhouse-client|cqlsh) return 0 ;;
      # A job brought back to the foreground is, nearly always, the editor or
      # agent that Ctrl-Z put there; spinning for it spun for the rest of its
      # life.
      fg|%*) return 0 ;;
      python|python2|python3|ipython|bpython|ptpython|node|nodejs|bun|deno|irb|pry|php|lua|luajit|julia|R|ghci|iex|erl|scala|clj|clojure)
        __ghostty_wortel_bare_repl "${words[@]:i+1:e-i}" && return 0
        continue ;;
    esac
    # The leading word is not a program we know. It may well be a wrapper no
    # list can ever enumerate — `devx pi`, a repo's own `./run claude`, a
    # company shim — so look just past it: if one of the next couple of bare
    # words names an agent, believe that over the wrapper. Only two words, flags
    # skipped, to keep it from reading an agent's name out of an unrelated
    # argument. The asymmetry is deliberate: a false positive costs a missing
    # spinner on one command, a false negative leaves a spinner turning for the
    # whole session. (Package names count too: `npx @anthropic-ai/claude-code`
    # arrives here with `npx` already walked past.)
    __ghostty_wortel_agent_name "$REPLY" && return 0
    __ghostty_wortel_wrapped_agent "$cmd" "${words[@]:i+1:e-i}" && return 0
  done
  return 1
}

# Wortel: given the leading command and the words after it, set REPLY to the
# agent it wraps and return true — else false. Shared by the interactive check
# and the marker so a wrapper-launched agent is both spinner-exempt and
# resumable.
function __ghostty_wortel_wrapped_agent() {
  builtin local lead="${1-}" w
  lead="${lead##*/}"
  builtin shift
  REPLY=""
  # Tools whose arguments are patterns or paths are excluded outright: `rg claude
  # src` and `git log claude` are ordinary commands that must keep their spinner,
  # and no syntax distinguishes a wrapper's subcommand from a search term.
  case "$lead" in
    git|hg|svn|jj|grep|rg|ag|ack|fd|find|ls|cat|sed|awk|jq|yq|xargs|echo|printf) return 1 ;;
    cp|mv|rm|ln|mkdir|touch|tar|zip|unzip|open|chmod|chown|stat|file|du|df) return 1 ;;
    curl|wget|scp|rsync|diff|patch|wc|sort|uniq|head|tail|tr|cut|comm|tee) return 1 ;;
    make|cargo|go|rustc|swift|swiftc|xcodebuild|gradle|mvn|pip|pip3|brew) return 1 ;;
    which|type|whereis|whatis|history|kill|pkill|pgrep|ps|test) return 1 ;;
    # Somewhere else entirely: another machine, a multiplexer's own server, a
    # container. `ssh box claude` and `tmux new claude` were recorded as a
    # claude running here, so a relaunch resumed it in the local shell (and for
    # tmux, beside the copy still running in it). See the zsh copy.
    ssh|mosh|et|autossh|telnet|tmux|screen|byobu|zellij|dtach|abduco) return 1 ;;
    docker|podman|nerdctl|kubectl|oc|limactl|lima|multipass|vagrant|distrobox|toolbox|devcontainer|orb|orbctl) return 1 ;;
  esac
  builtin local looked=0
  for w in "$@"; do
    case "$w" in
      -*|*=*) continue ;;
    esac
    looked=$((looked+1))
    __ghostty_wortel_agent_name "$w" && return 0
    (( looked < 2 )) || break
  done
  return 1
}

# Wortel: REPLY is the path $1 with `.` and `..` resolved textually, the way
# `cd` (logical, the default) moves $PWD.
function __ghostty_wortel_normalize() {
  builtin local IFS=/ part out="" noglob=""
  builtin local -a parts
  [[ $- == *f* ]] && noglob=1
  builtin set -f
  parts=(${1-})
  [[ -n "$noglob" ]] || builtin set +f
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..)   out="${out%/*}" ;;
      *)    out="$out/$part" ;;
    esac
  done
  REPLY="${out:-/}"
}

# Wortel: directory shared with the app (AgentResumeStore) for agent markers.
_ghostty_wortel_agent_dir="${WORTEL_DATA_DIR:-$HOME/Library/Application Support/Wortel}/agents"
# "<pid> <agent> <startedat>" of an agent Ctrl-Z stopped, while it lives. See
# __ghostty_wortel_clear_agent.
_ghostty_wortel_stopped=""

# Wortel: if the command line launches an agent CLI, set the caller's
# `_ghostty_wortel_found` to (agent model cwd argv) for the marker; else leave
# it empty. Recorded per session (keyed by WORTEL_SESSION_ID) so a relaunch can
# resume the agent.
#
# Leading `cd`s are followed when they can be resolved without running anything
# (`cd ~/proj && claude` runs the agent there, which is where it is resumed);
# anything else before the agent, or a cd whose end can't be seen, records
# nothing rather than the wrong directory. See the zsh copy.
function __ghostty_wortel_agent() {
  _ghostty_wortel_found=()
  builtin local -a words args
  __ghostty_wortel_split "${1-}"
  builtin local s=0 e i k sep n=0 cwd="$PWD" dir model="" program argv REPLY
  [[ -n "${words[*]+x}" ]] && n=${#words[@]}
  while (( s < n )); do
    e=$s
    while (( e < n )); do
      case "${words[e]}" in
        ';'|'&&'|'||'|'|'|'|&'|'&') break ;;
      esac
      e=$((e+1))
    done
    i=$s; sep=$e; e=$((e-1))
    __ghostty_wortel_program
    case "$REPLY" in
      cd|pushd) ;;
      *) break ;;
    esac
    # Only `cd x && …` and `cd x; …`: after `||` or `|` the next command may
    # run in a directory the cd never reached.
    case "${words[sep]-}" in
      ';'|'&&') ;;
      *) return 0 ;;
    esac
    args=()
    (( i < e )) && args=("${words[@]:i+1:e-i}")
    case "${args[0]-}" in
      -L|-P|--) args=("${args[@]:1}") ;;
    esac
    [[ -z "${args[1]-}" ]] || return 0
    dir="${args[0]-}"
    dir="${dir//[\"\']/}"
    case "$dir" in
      '')         dir="$HOME" ;;
      -)          dir="${OLDPWD-}" ;;
      '~')        dir="$HOME" ;;
      '~/'*)      dir="$HOME/${dir#'~/'}" ;;
      [-+~]*)     return 0 ;;
      /*)         ;;
      *)
        if [[ -n "${CDPATH-}" ]]; then
          case "$dir" in
            .|..|./*|../*) ;;
            *) return 0 ;;
          esac
        fi
        dir="$cwd/$dir" ;;
    esac
    __ghostty_wortel_normalize "$dir"
    dir="$REPLY"
    [[ -d "$dir" ]] || return 0
    cwd="$dir"
    s=$((sep+1))
    REPLY=""
  done
  [[ -n "$REPLY" ]] || return 0
  program="$REPLY"
  if ! __ghostty_wortel_agent_name "$program"; then
    # Wrapper form (`devx pi`): record the agent, not the wrapper, so the
    # session is resumable and the app knows which agent is running.
    __ghostty_wortel_wrapped_agent "$program" "${words[@]:i+1:e-i}" || return 0
  fi
  # The model the command selects (--model/-m/--models value), if any.
  # Best-effort, for the sidebar badge.
  k=$((i+1))
  while (( k <= e )); do
    case "${words[k]}" in
      --model=*|--models=*|-m=*)  model="${words[k]#*=}"; break ;;
      --model|--models|-m)        (( k < e )) && model="${words[k+1]}"; break ;;
    esac
    k=$((k+1))
  done
  model="${model#[\"\']}"; model="${model%[\"\']}"
  # The command from the agent on, one line: the resume fallback for agents
  # with no "continue last" of their own. The line as given, unless a cd chain
  # was walked past.
  if (( s == 0 )); then
    argv="${1//$'\n'/ }"
  else
    builtin local IFS=' '
    argv="${words[*]:s}"
  fi
  _ghostty_wortel_found=("$REPLY" "$model" "$cwd" "$argv")
  return 0
}

# Wortel: REPLY is the command line with a leading alias expanded, the way the
# shell will run it: with `alias cc='claude --dangerously-skip-permissions'`
# the line is `cc`, which names no agent, so the agent went unrecorded (and
# spun the spinner for as long as it ran), and argv lost the flags a resume is
# rebuilt from. Repeatedly, for an alias of an alias, but not into one already
# expanded (`alias ls='ls -G'`). BASH_ALIASES is bash 4; 3.2 gets the parser's
# own expansion from BASH_COMMAND instead (see __ghostty_preexec_bp).
function __ghostty_wortel_expand_alias() {
  REPLY="${1-}"
  (( BASH_VERSINFO[0] >= 4 )) || return 0
  REPLY="${REPLY#"${REPLY%%[![:space:]]*}"}"
  builtin local w seen=" " k=0
  while (( k < 8 )); do
    w="${REPLY%%[[:space:]]*}"
    case "$w" in
      ''|*[!A-Za-z0-9_.+-]*) break ;;
    esac
    [[ -n "${BASH_ALIASES[$w]+x}" ]] || break
    case "$seen" in
      *" $w "*) break ;;
    esac
    seen="$seen$w "
    REPLY="${BASH_ALIASES[$w]}${REPLY:${#w}}"
    k=$((k+1))
  done
  return 0
}

# `$1` is the command line, or empty when it isn't known (see the hooks
# below). `$2` is "expanded" when aliases have been expanded already.
function __ghostty_preexec() {
  builtin local cmd="${1-}" run="${1-}"

  PS1="$_GHOSTTY_SAVE_PS1"
  PS2="$_GHOSTTY_SAVE_PS2"

  # Title (current command), cut to 200 characters: libghostty drops an OSC
  # longer than 2048 bytes whole, which would leave the old title standing.
  if [[ -n $cmd && "${GHOSTTY_SHELL_FEATURES-}" == *"title"* ]]; then
    builtin local title="${cmd//[[:cntrl:]]/}"
    builtin printf "\e]2;%s\a" "${title:0:200}"
  fi

  # End of input, start of output.
  builtin printf "\e]133;C;\a"
  if [[ -n "$run" && "${2-}" != expanded ]]; then
    __ghostty_wortel_expand_alias "$run"
    run="$REPLY"
  fi
  # Wortel: mark the session busy for the sidebar spinner (ConEmu OSC 9;4;3,
  # "indeterminate progress"). Clears at the next prompt via OSC 133;D — but
  # long-lived interactive programs never return to the prompt, so we skip it
  # for those (see __ghostty_wortel_interactive). A command we can't see gets
  # none either: one that spins for ever is the failure people notice.
  if [[ -n "$run" ]] && ! __ghostty_wortel_interactive "$run"; then
    builtin printf "\e]9;4;3;\a"
  fi
  # Wortel: record a launched agent CLI so a relaunch can resume it. key=value
  # marker keyed by the surface's session id; cleared at the next prompt. A
  # marker that outlives the app means the agent was still running at quit.
  if [[ -n "${WORTEL_SESSION_ID-}" && -n "$run" ]]; then
    builtin local -a _ghostty_wortel_found
    __ghostty_wortel_agent "$run"
    if [[ -n "${_ghostty_wortel_found[0]-}" ]]; then
      builtin local dir="$_ghostty_wortel_agent_dir" tmp REPLY
      tmp="$dir/.$WORTEL_SESSION_ID.$$"
      [[ -d "$dir" ]] || command mkdir -p "$dir" 2>/dev/null
      __ghostty_wortel_now
      { builtin printf 'agent=%s\n' "${_ghostty_wortel_found[0]}"
        builtin printf 'model=%s\n' "${_ghostty_wortel_found[1]}"
        builtin printf 'cwd=%s\n' "${_ghostty_wortel_found[2]//[[:cntrl:]]/}"
        builtin printf 'argv=%s\n' "${_ghostty_wortel_found[3]}"
        # The shell's own pid — see the zsh integration: it lets the app verify
        # from the process table that the agent is really still running.
        builtin printf 'shellpid=%s\n' "$$"
        # When the agent started — see the zsh integration.
        builtin printf 'startedat=%s\n' "$REPLY"
      } > "$tmp" 2>/dev/null &&
        # Renamed into place whole: the app reads it once, when the name
        # appears. A write or rename that fails takes its dot-file with it.
        # See the zsh integration.
        command mv -f "$tmp" "$dir/$WORTEL_SESSION_ID" 2>/dev/null ||
        command rm -f "$tmp" 2>/dev/null
    fi
  fi
  _ghostty_executing=1
}

if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  __ghostty_preexec_hook() {
    builtin local cmd num
    cmd=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1)
    num="${cmd#"${cmd%%[![:space:]]*}"}"
    num="${num%%[!0-9]*}"
    cmd="${cmd#*[[:digit:]][* ] }"  # remove leading history number
    [[ -n "$cmd" ]] || return 0
    # Wortel: `history 1` is the last line *saved*, which is not always this
    # one. A line history leaves out (HISTCONTROL=ignorespace's leading space,
    # a HISTIGNORE pattern) hands this the line before it: ` ls` after
    # `claude` recorded a claude, and `fg` under HISTIGNORE=fg wrote a fresh
    # marker over the one it was resuming. PROMPT_COMMAND's $HISTCMD is the
    # number the next saved line will get (verified on 5.2 and 5.3), so a lower
    # one here means this line was not saved. With ignoredups (ignoreboth,
    # erasedups) an exact repeat looks the same, and its text is right —
    # `claude` twice has to be recorded twice — so then the text is kept.
    # Otherwise it is the previous command's, and no text is better than that.
    if [[ -n "$num" && -n "${_ghostty_wortel_histcmd-}" ]] && (( num < _ghostty_wortel_histcmd )); then
      case ":${HISTCONTROL-}:" in
        *:ignoredups:*|*:ignoreboth:*|*:erasedups:*) ;;
        *) cmd="" ;;
      esac
    fi
    __ghostty_preexec "$cmd"
  }

  # Bash 5.1+ restores the command status for each PROMPT_COMMAND array entry.
  # Scalar values need to save and restore it before existing commands run.
  # (Ghostty 591ccacbd.)
  __ghostty_restore_status() {
    builtin return "$1"
  }

  __ghostty_hook() {
    # The status saved ahead of a user's scalar PROMPT_COMMAND, when there is
    # one: by the time this runs, the commands before it have replaced `$?`.
    builtin local ret="${__ghostty_status:-$?}"
    builtin unset __ghostty_status
    # Wortel: the number the next saved history line will get; see
    # __ghostty_preexec_hook.
    _ghostty_wortel_histcmd="${HISTCMD-}"
    __ghostty_precmd "$ret"

    # Append preexec hook to PS0 if not already present.
    # Use function substitution in 5.3+, otherwise command substitution.
    # (Ghostty 2a952b4df: no readonly variable to carry it.)
    # Wortel: `${PS0-}`, as everywhere these hooks run: under a user's `set -u`
    # an unset PS0 stopped this line, so PS0 never got the preexec hook.
    if [[ "${PS0-}" != *"__ghostty_preexec_hook"* ]]; then
      if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
        # shellcheck disable=SC2016
        PS0=${PS0-}'${ __ghostty_preexec_hook; }'
      else
        # shellcheck disable=SC2016
        PS0=${PS0-}'$(__ghostty_preexec_hook >/dev/tty)'
      fi
    fi
  }

  # Append our hook to PROMPT_COMMAND, preserving its existing type. Array
  # entries receive their command's status directly, while scalar values
  # need a leading status capture before existing commands run.
  #
  # The 2>/dev/null suppresses "command not found" in subshells that inherit
  # PROMPT_COMMAND without the function definitions (Ghostty 4b9324f48). This
  # also silences any errors from inside our hooks, but those are all terminal
  # escape sequences and non-actionable.
  #
  # The guard matches the hook as a substring, so it also finds it in an array
  # (Ghostty a4031c8e3); "declare -a" without the space also takes an exported
  # array, "declare -ax" (ed7f046ee); and a scalar that ends in a newline gets
  # no ";" after it, which was a syntax error (1f3a3b41f).
  # shellcheck disable=SC2128,SC2178,SC2179
  if [[ "${PROMPT_COMMAND[*]:-}" != *"__ghostty_hook 2>/dev/null"* ]]; then
    if [[ -z "${PROMPT_COMMAND[*]:-}" ]]; then
      if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
        PROMPT_COMMAND=("__ghostty_hook 2>/dev/null")
      else
        PROMPT_COMMAND="__ghostty_hook 2>/dev/null"
      fi
    elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
      PROMPT_COMMAND+=("__ghostty_hook 2>/dev/null")
    else
      PROMPT_COMMAND='__ghostty_status=$?;if builtin declare -F __ghostty_restore_status >/dev/null;then __ghostty_restore_status "$__ghostty_status";else (exit "$__ghostty_status");fi;'"${PROMPT_COMMAND}"
      [[ "${PROMPT_COMMAND}" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=";"
      PROMPT_COMMAND+="__ghostty_hook 2>/dev/null"
    fi
  fi
else
  builtin source "$(dirname -- "${BASH_SOURCE[0]}")/bash-preexec.sh"
  # Wortel: bash-preexec hands preexec `history 1` as well, with the same blind
  # spot (see __ghostty_preexec_hook), and no HISTCMD to check it against: in
  # this bash it reads 1 inside the hooks. But preexec runs from the DEBUG trap,
  # where BASH_COMMAND is the simple command about to run, straight from the
  # parser and with aliases already expanded. So the history line is used only
  # when it begins with that command (then it is this line, and has the rest of
  # it: `cd x && claude`), and BASH_COMMAND otherwise: for ` ls` after `claude`,
  # and for `cc`, which BASH_COMMAND already has as the alias's `claude ...`.
  __ghostty_preexec_bp() {
    builtin local cmd="${1-}" bc="${BASH_COMMAND-}" rest='[[:space:];&|]*'
    if [[ -n "$bc" && "$cmd" != "$bc" && "$cmd" != "$bc"$rest ]]; then
      __ghostty_preexec "$bc" expanded
    else
      __ghostty_preexec "$cmd"
    fi
  }
  preexec_functions+=(__ghostty_preexec_bp)
  precmd_functions+=(__ghostty_precmd)
fi
