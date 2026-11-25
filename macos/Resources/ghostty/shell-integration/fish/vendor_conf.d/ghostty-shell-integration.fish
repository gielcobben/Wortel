# This shell script aims to be written in a way where it can't really fail
# or all failure scenarios are handled, so that we never leave the shell in
# a weird state. If you find a way to break this, please report a bug!

function ghostty_restore_xdg_data_dir -d "restore the original XDG_DATA_DIR value"
    # If we don't have our own data dir then we don't need to do anything.
    if not set -q GHOSTTY_SHELL_INTEGRATION_XDG_DIR
        return
    end

    # If the data dir isn't set at all then we don't need to do anything.
    if not set -q XDG_DATA_DIRS
        return
    end

    # We need to do this so that XDG_DATA_DIRS turns into an array.
    set --function --path xdg_data_dirs "$XDG_DATA_DIRS"

    # If our data dir is in the list then remove it.
    if set --function index (contains --index "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" $xdg_data_dirs)
        set --erase --function xdg_data_dirs[$index]
    end

    # Re-export our data dir
    if set -q xdg_data_dirs[1]
        set --global --export --unpath XDG_DATA_DIRS "$xdg_data_dirs"
    else
        set --erase --global XDG_DATA_DIRS
    end

    set --erase GHOSTTY_SHELL_INTEGRATION_XDG_DIR
end

function ghostty_exit -d "exit the shell integration setup"
    functions -e ghostty_restore_xdg_data_dir
    functions -e ghostty_exit
    exit 0
end

# We always try to restore the XDG data dir
ghostty_restore_xdg_data_dir

# If we aren't interactive or we've already run, don't run.
status --is-interactive || ghostty_exit

# We do the full setup on the first prompt render. We do this so that other
# shell integrations that setup the prompt and modify things are able to run
# first. We want to run _last_.
function __ghostty_setup --on-event fish_prompt -d "Setup ghostty integration"
    functions -e __ghostty_setup

    set --local features (string split , $GHOSTTY_SHELL_FEATURES)

    # Parse the fish version for feature detection.
    # Default to 0.0 if version is unavailable or malformed.
    set -l fish_major 0
    set -l fish_minor 0
    if set -q version[1]
        set -l fish_ver (string match -r '(\d+)\.(\d+)' -- $version[1])
        if set -q fish_ver[2]; and test -n "$fish_ver[2]"
            set fish_major "$fish_ver[2]"
        end
        if set -q fish_ver[3]; and test -n "$fish_ver[3]"
            set fish_minor "$fish_ver[3]"
        end
    end

    # Our OSC133A (prompt start) sequence. If we're using Fish >= 4.1
    # then it supports click_events so we enable that.
    set -g __ghostty_prompt_start_mark "\e]133;A\a"
    if test "$fish_major" -gt 4; or test "$fish_major" -eq 4 -a "$fish_minor" -ge 1
        set -g __ghostty_prompt_start_mark "\e]133;A;click_events=1\a"
    end

    if string match -q 'cursor*' -- $features
        set -l cursor 5                                   # blinking bar
        contains cursor:steady $features && set cursor 6  # steady bar

        # Change the cursor to a beam on prompt.
        function __ghostty_set_cursor_beam --on-event fish_prompt -V cursor -d "Set cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[$cursor q"
            end
        end
        function __ghostty_reset_cursor --on-event fish_preexec -d "Reset cursor shape"
            if not functions -q fish_vi_cursor_handle
                echo -en "\e[0 q"
            end
        end
    end

    # WORTEL: put the bundled `wortel` command on PATH. See the zsh copy for why
    # upstream's $GHOSTTY_BIN_DIR block is deleted rather than disabled —
    # Contents/MacOS holds only the app's own executable, and `wortel` matched it
    # on a case-insensitive disk. Prepended so this app's command beats an older
    # symlink; fish_add_path won't add a duplicate.
    if test -n "$WORTEL_BIN_DIR"
        fish_add_path --global --path --prepend "$WORTEL_BIN_DIR"
    end

    # WORTEL: ~/.local/bin, last, where Claude Code's installer (and uv, pipx)
    # put their commands and a new Mac does not look. See the zsh copy. Not
    # fish_add_path: that skips a folder that does not exist yet, and the
    # shell that runs the installer is the one that has to find the result.
    if test -n "$HOME"; and not contains -- "$HOME/.local/bin" $PATH
        set --global --export --append PATH "$HOME/.local/bin"
    end

    # When using sudo shell integration feature, ensure $TERMINFO is set
    # and `sudo` is not already a function or alias
    if contains sudo $features; and test -n "$TERMINFO"; and test file = (type -t sudo 2> /dev/null; or echo "x")
        # Wrap `sudo` command to ensure Ghostty terminfo is preserved
        function sudo -d "Wrap sudo to preserve terminfo"
            set --function sudo_has_sudoedit_flags no
            for arg in $argv
                # Check if argument is '-e' or '--edit' (sudoedit flags)
                if string match -q -- -e "$arg"; or string match -q -- --edit "$arg"
                    set --function sudo_has_sudoedit_flags yes
                    break
                end
                # Check if argument is neither an option nor a key-value pair
                if not string match -r -q -- "^-" "$arg"; and not string match -r -q -- "=" "$arg"
                    break
                end
            end
            if test "$sudo_has_sudoedit_flags" = yes
                command sudo $argv
            else
                command sudo --preserve-env=TERMINFO $argv
            end
        end
    end

    # SSH Integration
    set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
    if contains ssh-env $features; or contains ssh-terminfo $features
        function ssh --wraps=ssh --description "SSH wrapper with Ghostty integration"
            set -l features (string split ',' -- "$GHOSTTY_SHELL_FEATURES")
            set -l ssh_term xterm-256color
            set -l ssh_opts

            # Configure environment variables for remote session
            if contains ssh-env $features
                # SendEnv, not SetEnv: see the zsh copy. (Ghostty 69554f414.)
                set -a ssh_opts -o "SendEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION"
            end

            # Install terminfo on remote host if needed
            if contains ssh-terminfo $features
                set -l ssh_user
                set -l ssh_hostname

                for line in (command ssh -G $argv 2>/dev/null)
                    set -l parts (string split ' ' -- $line)
                    if test (count $parts) -ge 2
                        switch $parts[1]
                            case user
                                set ssh_user $parts[2]
                            case hostname
                                set ssh_hostname $parts[2]
                        end
                        if test -n "$ssh_user"; and test -n "$ssh_hostname"
                            break
                        end
                    end
                end

                if test -n "$ssh_hostname"
                    set -l ssh_target "$ssh_user@$ssh_hostname"

                    # Check if terminfo is already cached
                    if test -x "$GHOSTTY_BIN_DIR/ghostty"; and "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --host="$ssh_target" >/dev/null 2>&1
                        set ssh_term xterm-ghostty
                    else if command -q infocmp
                        set -l ssh_terminfo
                        set -l ssh_cpath_dir
                        set -l ssh_cpath

                        set ssh_terminfo "$(infocmp -0 -x xterm-ghostty 2>/dev/null)"

                        if test -n "$ssh_terminfo"
                            echo "Setting up xterm-ghostty terminfo on $ssh_hostname..." >&2

                            set ssh_cpath_dir (mktemp -d "/tmp/ghostty-ssh-$ssh_user.XXXXXX" 2>/dev/null; or echo "/tmp/ghostty-ssh-$ssh_user."(random))
                            set ssh_cpath "$ssh_cpath_dir/socket"

                            # Wortel: install first, and accept an entry
                            # already there only when the host has no tic.
                            # See the zsh copy.
                            if echo "$ssh_terminfo" | command ssh $ssh_opts -o ControlMaster=yes -o ControlPath="$ssh_cpath" -o ControlPersist=60s $argv '
                                command -v tic >/dev/null 2>&1 && mkdir -p ~/.terminfo 2>/dev/null && tic -x -o ~/.terminfo - 2>/dev/null && exit 0
                                infocmp xterm-ghostty >/dev/null 2>&1 && exit 0
                                exit 1
                            ' 2>/dev/null
                                set ssh_term xterm-ghostty
                                set -a ssh_opts -o "ControlPath=$ssh_cpath"

                                # Cache successful installation
                                if test -x "$GHOSTTY_BIN_DIR/ghostty"
                                    "$GHOSTTY_BIN_DIR/ghostty" +ssh-cache --add="$ssh_target" >/dev/null 2>&1; or true
                                end
                            else
                                echo "Warning: Failed to install terminfo." >&2
                            end
                        else
                            echo "Warning: Could not generate terminfo data." >&2
                        end
                    else
                        echo "Warning: ghostty command not available for cache management." >&2
                    end
                end
            end

            # Execute SSH with TERM environment variable
            TERM="$ssh_term" COLORTERM=truecolor command ssh $ssh_opts $argv
        end
    end

    # Setup prompt marking
    function __ghostty_mark_prompt_start --on-event fish_prompt --on-event fish_posterror
        # If we never got the output end event, then we need to send it now.
        if test "$__ghostty_prompt_state" != prompt-start
            echo -en "\e]133;D\a"
        end

        set --global __ghostty_prompt_state prompt-start
        echo -en $__ghostty_prompt_start_mark
    end

    # Wortel: the command line's words, one per line. `;` and `&&` are padded
    # first so `cd x;claude` splits where the shell would, and a newline is a `;`.
    function __ghostty_wortel_words
        set --local line (string join ' ; ' -- (string split \n -- $argv[1]))
        set line (string replace --all ';' ' ; ' -- $line)
        set line (string replace --all '&&' ' && ' -- $line)
        string split --no-empty ' ' -- $line
    end

    # Wortel: the index of the program a simple command launches, given the
    # index of its first word, of its last, and then the words. Walks past env
    # assignments (FOO=bar), launchers (sudo, nohup, exec...), fish's `and`/`or`
    # and package runners (npx, `pnpm dlx`). Nothing (and false) when the
    # segment has no program.
    function __ghostty_wortel_program
        set --local i $argv[1]
        set --local e $argv[2]
        set --local words $argv[3..-1]
        while test $i -le $e
            switch $words[$i]
                case '*=*' sudo doas command builtin exec nohup nice stdbuf setsid env and or not npx bunx pnpx uvx pipx '-*'
                    set i (math $i + 1)
                case npm pnpm yarn bun deno
                    # Package runners: in `pnpm dlx codex` or `bun x pi` the
                    # program is the word after the subcommand. Only skip when
                    # the subcommand is actually there — a bare `bun` is a REPL,
                    # and it must keep reaching the dual-use check.
                    set --local next (math $i + 1)
                    if test $next -le $e; and contains -- $words[$next] x dlx exec run
                        set i (math $i + 2)
                    else
                        echo $i
                        return 0
                    end
                case '*'
                    echo $i
                    return 0
            end
        end
        return 1
    end

    # Wortel: the agent a word names, echoed; nothing (and false) when it names
    # none. The program itself or the package a runner fetches it as (`npx
    # @anthropic-ai/claude-code` is claude, `bunx @mariozechner/pi-coding-agent`
    # is pi); quotes, a leading backslash and a version pin are not part of the
    # name. See the zsh integration.
    function __ghostty_wortel_agent_name
        set --local name (string replace --all --regex '["\'\\\\]' '' -- $argv[1])
        set name (string replace --regex '^.*/' '' -- $name)
        if string match --quiet --regex '^.+@' -- $name
            set name (string replace --regex '@.*$' '' -- $name)
        end
        switch $name
            case claude pi aider codex cursor-agent gemini opencode goose cline ollama llm crush amp
            case claude-code
                set name claude
            case pi-coding-agent
                set name pi
            case gemini-cli
                set name gemini
            case opencode-ai
                set name opencode
            case aider-chat
                set name aider
            case '*'
                return 1
        end
        echo $name
    end

    # Wortel: given the leading command and the words after it, echo the agent
    # it wraps — else nothing, and false. Shared by the interactive check and
    # the marker so a wrapper-launched agent (`devx pi`, `./run claude`) is both
    # spinner-exempt and resumable. Tools whose arguments are patterns or paths
    # are excluded outright (`rg claude src` is a search), and so are remote
    # shells, multiplexers and containers: `ssh box claude` and `tmux new
    # claude` run the agent somewhere a local resume can't reach. Only the
    # first two bare words are read. See the zsh integration.
    function __ghostty_wortel_wrapped_agent
        switch (string replace --regex '^.*/' '' -- $argv[1])
            case git hg svn jj grep rg ag ack fd find ls cat sed awk jq yq xargs echo printf \
                cp mv rm ln mkdir touch tar zip unzip open chmod chown stat file du df \
                curl wget scp rsync diff patch wc sort uniq head tail tr cut comm tee \
                make cargo go rustc swift swiftc xcodebuild gradle mvn pip pip3 brew \
                which type whereis whatis history kill pkill pgrep ps test \
                ssh mosh et autossh telnet tmux screen byobu zellij dtach abduco \
                docker podman nerdctl kubectl oc limactl lima multipass vagrant distrobox toolbox devcontainer orb orbctl
                return 1
        end
        set --local looked 0
        for w in $argv[2..-1]
            switch $w
                case '-*' '*=*'
                    continue
            end
            set looked (math $looked + 1)
            __ghostty_wortel_agent_name $w; and return 0
            test $looked -ge 2; and break
        end
        return 1
    end

    # Wortel: true if a REPL that is also a script runner (python, node...) was
    # started bare; the arguments are the words after the program. `python
    # script.py`, `python -m mod` and `-c ...` are batch jobs that keep the
    # spinner.
    function __ghostty_wortel_bare_repl
        for a in $argv
            switch $a
                case -i -q -u -B -E -O -OO -s -S -I --
                    continue
                case -c -m
                    return 1
                case '*<*' '*>*' '*|*' '*&*' '*;*'
                    return 0
                case '-*'
                    continue
                case '*'
                    return 1
            end
        end
        return 0
    end

    # Wortel: true if the command line launches a long-lived interactive program
    # (agent CLI, editor, pager, REPL, system monitor, TUI) that sits at its own
    # prompt instead of returning to the shell. For those the synthetic busy
    # spinner (OSC 9;4;3 below) would never clear until you quit — no OSC 133;D
    # fires — so we skip it. Builds and tests still spin. Every command on the
    # line counts, not just the first: `cd x && claude` and `git diff | less`
    # end in a program that holds the terminal.
    function __ghostty_wortel_interactive
        set --local words (__ghostty_wortel_words $argv[1])
        set --local n (count $words)
        set --local s 1
        while test $s -le $n
            # The segment runs to the next word that starts another command on
            # the same line (`&&`, `;`, `|`, `&`...).
            set --local e $s
            while test $e -le $n; and not contains -- $words[$e] ';' '&&' '||' '|' '&' '&|'
                set e (math $e + 1)
            end
            set --local last (math $e - 1)
            set --local i (__ghostty_wortel_program $s $last $words)
            set s (math $e + 1)
            test -n "$i"; or continue
            set --local rest
            test $i -lt $last; and set rest $words[(math $i + 1)..$last]
            set --local cmd (string replace --regex '^.*/' '' -- $words[$i])
            switch $cmd
                case claude pi aider codex cursor-agent gemini opencode goose cline ollama llm crush amp
                    return 0
                case vi vim nvim vis nano emacs emacsclient helix hx kak micro ne joe
                    return 0
                case less more most moar man bat w3m lynx
                    return 0
                case top htop btop btm glances gtop nvtop s-tui
                    return 0
                case ssh mosh et autossh telnet tmux screen byobu zellij dtach abduco
                    return 0
                case watch journalctl dmesg
                    return 0
                case fzf sk gitui lazygit lazydocker k9s tig ranger nnn yazi lf vifm mc broot xplr
                    return 0
                case gdb lldb pdb
                    return 0
                case psql mysql mariadb sqlite3 litecli pgcli mycli redis-cli mongosh mongo usql duckdb clickhouse-client cqlsh
                    return 0
                case fg '%*'
                    # A job brought back to the foreground is, nearly always,
                    # the editor or agent that Ctrl-Z put there.
                    return 0
                case python python2 python3 ipython bpython ptpython node nodejs bun deno irb pry php lua luajit julia R ghci iex erl scala clj clojure
                    # Dual-use: a bare REPL is interactive, a script is not.
                    __ghostty_wortel_bare_repl $rest; and return 0
                    continue
            end
            # A wrapper no list can enumerate (`devx pi`), or a package named
            # for the agent (`npx @anthropic-ai/claude-code`). The asymmetry
            # is deliberate: a false positive costs a missing spinner on one
            # command, a false negative a spinner for the whole session.
            __ghostty_wortel_agent_name $words[$i] >/dev/null; and return 0
            __ghostty_wortel_wrapped_agent $cmd $rest >/dev/null; and return 0
        end
        return 1
    end

    # Wortel: directory shared with the app (AgentResumeStore) for agent markers.
    # Global, not local: the event-driven functions below read it at run time,
    # long after this one-shot setup function's locals are gone.
    # WORTEL_DATA_DIR when the app runs on a data folder of its own.
    if set -q WORTEL_DATA_DIR
        set --global _ghostty_wortel_agent_dir "$WORTEL_DATA_DIR/agents"
    else
        set --global _ghostty_wortel_agent_dir "$HOME/Library/Application Support/Wortel/agents"
    end

    # Wortel: $argv[1] with `.` and `..` resolved textually, the way `cd`
    # moves $PWD.
    function __ghostty_wortel_normalize
        set --local out
        for part in (string split / -- $argv[1])
            switch $part
                case '' .
                case ..
                    set -q out[1]; and set --erase out[-1]
                case '*'
                    set --append out $part
            end
        end
        if set -q out[1]
            echo /(string join / -- $out)
        else
            echo /
        end
    end

    # Wortel: if the command line launches an agent CLI, print four lines for the
    # marker (agent, model, cwd, argv); else nothing. Recorded per session so a
    # relaunch can resume it. Leading `cd`s are followed when they can be
    # resolved without running anything (`cd ~/proj && claude` runs the agent
    # there, which is where it is resumed); anything else before the agent, or a
    # cd whose end can't be seen, records nothing rather than the wrong
    # directory. See the zsh integration.
    function __ghostty_wortel_agent
        set --local words (__ghostty_wortel_words $argv[1])
        set --local n (count $words)
        set --local s 1
        set --local cwd $PWD
        set --local i
        set --local last
        while test $s -le $n
            set --local e $s
            while test $e -le $n; and not contains -- $words[$e] ';' '&&' '||' '|' '&' '&|'
                set e (math $e + 1)
            end
            set last (math $e - 1)
            set i (__ghostty_wortel_program $s $last $words)
            test -n "$i"; or return 1
            switch $words[$i]
                case cd pushd
                case '*'
                    break
            end
            # Only `cd x && …` and `cd x; …`: after `||` or `|` the next
            # command may run in a directory the cd never reached.
            test $e -le $n; and contains -- $words[$e] ';' '&&'; or return 1
            set --local args
            test $i -lt $last; and set args $words[(math $i + 1)..$last]
            set -q args[2]; and return 1
            set --local dir (string replace --all --regex '["\']' '' -- "$args[1]")
            switch $dir
                case ''
                    set dir $HOME
                case -
                    set -q dirprev[1]; or return 1
                    set dir $dirprev[-1]
                case '~'
                    set dir $HOME
                case '~/*'
                    set dir $HOME/(string sub --start 3 -- $dir)
                case '-*' '+*' '~*'
                    return 1
                case '/*'
                case '*'
                    if set -q CDPATH[1]; and test "$CDPATH" != .
                        switch $dir
                            case . .. './*' '../*'
                            case '*'
                                return 1
                        end
                    end
                    set dir $cwd/$dir
            end
            set dir (__ghostty_wortel_normalize $dir)
            test -d "$dir"; or return 1
            set cwd $dir
            set s (math $e + 1)
            set i
        end
        test -n "$i"; or return 1
        set --local rest
        test $i -lt $last; and set rest $words[(math $i + 1)..$last]
        set --local agent (__ghostty_wortel_agent_name $words[$i])
        or set agent (__ghostty_wortel_wrapped_agent $words[$i] $rest)
        or return 1
        # The model the command selects (--model/-m/--models value), if any.
        set --local model
        set --local k 1
        while test $k -le (count $rest)
            switch $rest[$k]
                case '--model=*' '--models=*' '-m=*'
                    set model (string replace --regex '^[^=]*=' '' -- $rest[$k])
                    break
                case --model --models -m
                    set --local j (math $k + 1)
                    test $j -le (count $rest); and set model $rest[$j]
                    break
            end
            set k (math $k + 1)
        end
        set model (string replace --all --regex "[\"']" '' -- "$model")
        # The command from the agent on, one line: the resume fallback for
        # agents with no "continue last" of their own. The line as given,
        # unless a cd chain was walked past.
        set --local cmdline (string join ' ' -- (string split \n -- $argv[1]))
        if test $s -gt 1
            set cmdline (string join ' ' -- $words[$s..-1])
        end
        printf '%s\n' $agent "$model" $cwd "$cmdline"
    end

    # Wortel: the command line with a leading alias expanded, the way fish will
    # run it. Abbreviations are expanded before preexec ever sees the line, but
    # an `alias` is a function: with `alias cc='claude --dangerously-skip-permissions'`
    # the line is `cc`, which names no agent. fish records the alias's text
    # as the function's description ("alias cc=claude ..."), which is read back
    # here; a function that isn't an alias is left alone. Repeatedly, for an
    # alias of an alias, but not into one already expanded.
    function __ghostty_wortel_expand_alias
        set --local line $argv[1]
        set --local seen
        for k in 1 2 3 4 5 6 7 8
            set --local w (string match --regex '^\S+' -- $line)
            test -n "$w"; or break
            contains -- $w $seen; and break
            functions --query -- $w; or break
            set --local details (functions --details --verbose -- $w)
            set -q details[5]; or break
            string match --quiet 'alias *=*' -- $details[5]; or break
            set --append seen $w
            set line (string replace --regex '^alias [^=]*=' '' -- $details[5])(string sub --start (math (string length -- $w) + 1) -- $line)
        end
        printf '%s\n' $line
    end

    # Wortel: clear this session's agent marker at every prompt, so a marker only
    # survives while an agent is actually running — which is precisely when no
    # prompt fires. See __ghostty_wortel_agent.
    # And log the exit first: a marker here means the command that just ended
    # was an agent, and $status is the only trace of *why* once the scrollback
    # is gone (129 and up is a signal). One line, on this path only; see the
    # zsh copy.
    # Only a marker this shell wrote: our own is logged and cleared, a dead
    # shell's is cleared quietly, a live other shell's is left alone. A session
    # can briefly have two shells across a relaunch; see the zsh copy.
    # Not an agent that was only stopped: Ctrl-Z comes back to a prompt with
    # the agent alive as a stopped job, and `fg` launches no agent, so clearing
    # the marker then left the agent untracked for the rest of its life. A job
    # that wasn't there when the agent's command started is the agent, stopped
    # (fish has no stop status to read, so the job list is the evidence); its
    # pid is remembered and the marker kept for as long as that job lives,
    # through `fg`, `bg` and stopping again. See the zsh copy.
    function __ghostty_wortel_clear_agent --on-event fish_prompt
        set --local last $status
        test -n "$WORTEL_SESSION_ID"; or return
        set --local marker $_ghostty_wortel_agent_dir/$WORTEL_SESSION_ID
        if not test -f $marker
            set --global __ghostty_wortel_stopped
            return
        end
        set --local owner (string replace --regex '^shellpid=' '' -- (string match --regex '^shellpid=.*' < $marker))
        if test -n "$owner"; and test "$owner" != "$fish_pid"
            kill -0 $owner 2>/dev/null; and return
            command rm -f $marker 2>/dev/null
            return
        end
        set --local agent (string replace --regex '^agent=' '' -- (string match --regex '^agent=.*' < $marker))
        set --local started (string replace --regex '^startedat=' '' -- (string match --regex '^startedat=.*' < $marker))
        set --local jobpids (jobs --pid)
        if set -q __ghostty_wortel_stopped[3]
            and test "$__ghostty_wortel_stopped[2]" = "$agent"
            and test "$__ghostty_wortel_stopped[3]" = "$started"
            and contains -- $__ghostty_wortel_stopped[1] $jobpids
            return
        end
        for pid in $jobpids
            if not contains -- $pid $__ghostty_wortel_jobs_before
                set --global __ghostty_wortel_stopped $pid "$agent" "$started"
                # Nothing is in progress while it is stopped, and the app
                # ignores the prompt's 133;D while a marker is live; see the
                # zsh copy.
                echo -en "\e]9;4;0\a"
                return
            end
        end
        set --global __ghostty_wortel_stopped
        echo (command date +%s) session=$WORTEL_SESSION_ID agent=$agent status=$last shellpid=$fish_pid >> $_ghostty_wortel_agent_dir/exits.log 2>/dev/null
        command rm -f $marker 2>/dev/null
    end

    function __ghostty_mark_output_start --on-event fish_preexec
        set --global __ghostty_prompt_state pre-exec
        echo -en "\e]133;C\a"
        # (`string collect`: a command substitution splits its output at
        # newlines, and a multi-line command is one line here.)
        set --local run (__ghostty_wortel_expand_alias $argv[1] | string collect)
        # Wortel: mark the session busy for the sidebar spinner (ConEmu OSC
        # 9;4;3, "indeterminate progress"). Clears at the next prompt (133;D) —
        # but long-lived interactive programs never return to the prompt, so
        # skip it for those (see __ghostty_wortel_interactive).
        if not __ghostty_wortel_interactive "$run"
            echo -en "\e]9;4;3;\a"
        end
        # Wortel: record a launched agent CLI so a relaunch can resume it. key=value
        # marker keyed by the surface's session id; cleared at the next prompt. A
        # marker that outlives the app means the agent was still running at quit.
        if test -n "$WORTEL_SESSION_ID"
            # The jobs that predate this command, so the next prompt can tell
            # a job it left stopped from the rest. Every command, not just an
            # agent: a `vim` stopped while the agent waits is not the agent.
            # (A builtin, in-process.) See __ghostty_wortel_clear_agent.
            set --global __ghostty_wortel_jobs_before (jobs --pid)
            set --local found (__ghostty_wortel_agent "$run")
            if test -n "$found[1]"
                set --local dir $_ghostty_wortel_agent_dir
                set --local tmp $dir/.$WORTEL_SESSION_ID.$fish_pid
                test -d $dir; or command mkdir -p $dir 2>/dev/null
                begin
                    echo "agent=$found[1]"
                    echo "model=$found[2]"
                    echo "cwd="(string replace -ra '[[:cntrl:]]' '' -- $found[3])
                    echo "argv=$found[4]"
                    # The shell's own pid — see the zsh integration: it lets the
                    # app verify from the process table that the agent is really
                    # still running.
                    echo "shellpid=$fish_pid"
                    # When the agent started — see the zsh integration.
                    echo "startedat="(command date +%s)
                end >$tmp 2>/dev/null
                # Renamed into place whole: the app reads it once, when the
                # name appears. A write or rename that fails takes its dot-file
                # with it. See the zsh integration.
                and command mv -f $tmp $dir/$WORTEL_SESSION_ID 2>/dev/null
                or command rm -f $tmp 2>/dev/null
            end
        end
    end

    function __ghostty_mark_output_end --on-event fish_postexec
        set --global __ghostty_prompt_state post-exec
        echo -en "\e]133;D;$status\a"
    end

    # Report pwd. This is actually built-in to fish but only for terminals
    # that match an allowlist and that isn't us.
    function __update_cwd_osc --on-variable PWD -d 'Notify capable terminals when $PWD changes'
        if status --is-command-substitution || set -q INSIDE_EMACS
            return
        end
        # Wortel: "localhost", not $hostname — see the zsh integration's
        # _ghostty_report_pwd. Same exposure: a cleared $hostname emits a
        # hostless URI that libghostty drops, and a captured one goes stale
        # when the machine is renamed mid-session.
        printf \e\]7\;file://localhost%s\a (string escape --style=url $PWD)
    end

    # Enable fish to handle reflow because Ghostty clears the prompt on resize.
    set --global fish_handle_reflow 1

    # Initial calls for first prompt
    if string match -q 'cursor*' -- $features
        __ghostty_set_cursor_beam
    end
    __ghostty_mark_prompt_start
    __update_cwd_osc
end

ghostty_exit
