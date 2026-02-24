#!/bin/bash
# Script to show information in prompt useful for people ssh'ing to multiple
# servers.  It is inteded to be a somewhat boring but useful default to drop in
# random servers you're not putting all your conffiles on, running your
# favourite shell etc.
#
# To use, add
#
#     source /path/to/sysadmin_prompt.bash
#
# to the account's .bashrc .  You can also do
#
#     source /path/to/sysadmin_prompt.bash install
#
# and it will append a line for you.
#
# Limited customization is possible by altering the envvar $sypro_colors after
# sourcing. It's an associative array, see below for keys.

# duck test for bash >=4.x
if ! declare -A sypro_colors 2>/dev/null; then
    echo "sysadmin_prompt: error: incompatible bash version, skipping prompt."
    return
fi

# this is customizable later.
sypro_colors=(
[red]="\[\e[31m\]"
[green]="\[\e[32m\]"
[yellow]="\[\e[33m\]"
[blue]="\[\e[34m\]"
[magenta]="\[\e[35m\]"
[cyan]="\[\e[36m\]"
[bold]="\[\e[1m\]"
[dim]="\[\e[2m\]"
[normal]="\[\e[22m\]" # disables bold/dim
[reset]="\[\e[0m\]" # disables everything
[reverse]="\[\e[7m\]"
)

# customization is also possible semantically.
sypro_colors[root]=${sypro_colors[bold]}${sypro_colors[red]}
sypro_colors[error]=${sypro_colors[normal]}${sypro_colors[red]}
sypro_colors[virt]=${sypro_colors[normal]}${sypro_colors[cyan]}
sypro_colors[git]=${sypro_colors[bold]}${sypro_colors[yellow]}
# marker if we're in an ssh session
sypro_colors[ssh]=${sypro_colors[dim]}
# marker if we're in an adb session
sypro_colors[adb]=${sypro_colors[dim]}${sypro_colors[green]}
# how many seconds since last command.
sypro_colors[timer]=${sypro_colors[normal]}${sypro_colors[cyan]}
# number of jobs in background
sypro_colors[bgcount]=${sypro_colors[normal]}${sypro_colors[blue]}
# user and host colors are set automatically at prompt time.

# used to cache computed colors.
declare -A __sypro_color_cache

# things we only need to run once and not every prompt.
#
# being in a function help limit namespace pollution.
function __sypro_setup {
    # picks a random but fixed color for the word.
    #
    # specifically, transforms the word into an integer; reduces this integer to
    # one between 0 and 7; and add that to 32.  this will map it to a
    # pseudo-random but stable number between 32 and 38, the ANSI indexes for
    # green-yellow-blue-magenta-cyan-white (red, 31, is avoided because it's used
    # to highlight important information).
    function sypro_pick_color() {
        # __sypro_word2int defined below, depending on what tools we have.
        local int
        local color_index
        int="$(__sypro_word2int "$1")"
        color_index=$((32 + $(( int % 6)) ))
        echo "\[\e[${color_index}m\]"
    }

    # let's define a way to convert words to arbitrary but fixed integers.
    # returned value should use bash arithmetic format, and be <32bit to avoid
    # bash int overflows on any platform.
    if type -t md5sum >/dev/null 2>&1; then
        # md5sum version gives the most variation for similarly named hosts.
        function __sypro_word2int() {
            # put first field on $1.
            set $(echo -n "$1" | md5sum )

                # we truncate $1 to 7 characters (<32bits) to avoid integer
                # overflows on most platforms and bash versions.
                #
                # we get the start of string, not end, to be robust against
                # various md5sum and bash versions (negative indexes not always
                # work).
                echo "0x${1:0:7}"
        }

    elif type -t cksum >/dev/null 2>&1; then
        # POSIX cksum version should run on most places.
        function __sypro_word2int() {
            # trick to split on space without needing cut(1) or sed(1).
            #
            # this will set $1..$n to the results of the command. we are only
            # interested in the first field, which will be the new $1 after
            # this.
            set $(echo -n "$1" | cksum )
            echo "$1"
        }

    elif type -t od >/dev/null 2>&1; then
        # POSIX od fallback, will be the same for long words that end the same.
        function __sypro_word2int() {
            echo "0x$(echo -n "$1" |od -c -tx -An|tr -d ' '|tail -c 8)"
        }

    else
        # boring fallback based on length of string.
        function __sypro_word2int() {
            RANDOM=${#1} # primes random
            echo "$RANDOM"
        }
    fi

    # you can source the standard git-prompt.sh file your way before this
    # script, and we'll use the __git_ps1 provided.  otherwise we look for
    # it in common locations.
    if ! type -t __git_ps1 >/dev/null 2>&1; then
        for f in \
            /usr/lib/git-core/git-sh-prompt \
            /usr/share/git/git-prompt.sh \
            /usr/share/git-core/contrib/completion/git-prompt.sh \
            /etc/bash_completion.d/git-prompt
        do
            if [ -r "$f" ]; then
                source "$f"
                if type -t __git_ps1 >/dev/null 2>&1; then
                    break
                fi
            fi
        done
    fi


    # basic virtual machine detection.
    local isvirt
    if [ -f /.dockerenv ]; then
        isvirt=docker
    elif [ -r /proc/1/cgroup ] && grep -q lxc /proc/1/cgroup; then
        isvirt=lxc
    elif type -t virt-what >/dev/null 2>&1; then
        isvirt="$(virt-what 2>/dev/null \
            || sudo --non-interactive virt-what 2>/dev/null)"
	isvirt="$(echo -n "$isvirt" | tr '\n' '|')"
    elif type -t systemd-detect-virt >/dev/null 2>&1; then
        isvirt="$(systemd-detect-virt 2>/dev/null)"
    # # ruby is too slow :p
    # elif type -t facter >/dev/null 2>&1; then
    #   if `facter | grep -q '^is_virtual.*\<t'`; then
    #     isvirt=`facter |sed -ne 's/^virtual[^A-Za-z0-9]*//p'`
    #   fi
    fi

    if [ "$isvirt" ] && [ "$isvirt" != 'none' ]; then
        __sypro_virt="$isvirt"
    fi


    # timer setup idea based on Ville Laurikari and Jake McCrary:
    #
    # https://jakemccrary.com/blog/2015/05/03/put-the-last-commands-run-time-in-your-bash-prompt/
    #
    # it would be possible to use date(1) to get microseconds and use
    # human-readable duration format, bash-preexec etc. but that would increase
    # runtime and incompatibility, so we stay with the simple timer based on
    # $SECONDS because it's highly portable.
    #
    # notice if the shell has been running for more than 68 years in a 32-bit
    # system the variable may overflow and confuse the timer arithmetic.  we
    # choose not to treat this case.

    # called before every command via trap DEBUG.
    function __sypro_timer_command_hook  {
        # if we are already measuring a command, ignore. (or else we'd restart the
        # timer at the prompt-setting commands...)
        [ -v __sypro_timer_started ] && return

        # otherwise we start counting at this command.
        __sypro_timer_started=$SECONDS
    }

    # called right as PROMPT_COMMAND starts, so that we avoid including the
    # prompt time in the runtime.
    function __sypro_timer_pause {
        # calculate how much time has gone.
        __sypro_timer_elapsed=$(( SECONDS - __sypro_timer_started ))
    }

    # called after the prompt is set; primes timer to restart next command.
    function __sypro_timer_restart {
        unset __sypro_timer_started
    }


    # process the install command.
    if [ "$1" ] && [ "$1" = install ]; then
        if ! [ "$PWD" ]; then
            PWD="$(pwd)"
            if ! [ "$PWD" ]; then
                echo "ERROR: 'install' called, but we can't determine" \
                     "the working directory \$PWD." >&2
                echo "Check for permission issues, symlinks, or" \
                     "deleted directories." >&2
                if [ "$ANDROID_DATA" ]; then
                    echo "This system appears to be Android, which may" \
                         "restrict script access.  Please install manually." \
                         >&2
                fi
                exit 1
            fi
        fi

        # works with 'source'
        if [ "${BASH_SOURCE[0]}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
            local sypro_src="${BASH_SOURCE[0]}"
            # works if called as script
        elif [ "$0" ] && [ "$0" != 'bash' ]; then
            local sypro_src="$0"
        fi

        if ! [ "$sypro_src" ]; then
            echo >&2 "ERROR: Could not determine own script file name!"
            if [ "$ANDROID_ROOT" ] || [ "$ANDROID_DATA" ]; then
                echo >&2 "This appears to be an Android system, which" \
                    "may restrict script capabilities."
            fi
            echo "Please install sysadmin_prompt manually :^)"
            exit 1

        else
            if ! echo "$sypro_src" | grep -q '/'; then
                sypro_src="$PWD/$sypro_src"
            fi
            if ! [ -f "$0" ]; then
              cat >&2 <<EOS
ERROR: 'install' called from '$sypro_src', but the file
'$sypro_src' appears not to exist.

This should never happen :)

Please double-check for paths, permissions, symlinks, and parent directories,
or install sysadmin_prompt manually.

Giving up on auto-install.
pwd was: env: '$PWD', command: $(pwd).
EOS
            fi
            if ! [ -r "$0" ]; then
                cat >&2 <<EOS
ERROR: 'install' called from '$sypro_src', but the file
'$sypro_src' seems to be unreadable.

This should never happen :)

Please double-check for permissions, symlinks, and parent directories,
or install sysadmin_prompt manually.

Proceeding with installation.
pwd was: env: '$PWD', command: $(pwd).
EOS
            fi
        fi

        # duck test for gnu grep or compatible options, for nicer reporting.
        local colorgrep='grep --with-filename --color --context 2'
        if ! echo -n . | $colorgrep -qn "\." 2>/dev/null; then
            # didn't work, go with posix options only
            colorgrep='grep'
        fi

        if ! [ -f "$HOME/.bashrc" ]; then
            echo "No '$HOME/.bashrc', will create it."
        fi

        if ! [ -f "$HOME/.bashrc" ] || \
           ! grep -v '^[[:space:]]*#' "$HOME/.bashrc" \
            | $colorgrep -n \
            "\<$(basename "$sypro_src")\>" \
            "$HOME/.bashrc"
                then
                    echo "[ -f '$sypro_src' ] && source '$sypro_src'" \
                        >> "$HOME/.bashrc"
                    echo "Appended a line to '$HOME/.bashrc' ."
                else
                    echo -en "\n^ above: $(basename "$sypro_src") seems to be"
                    echo "already in '$HOME/.bashrc'; not installing."
        fi
    fi

    # hook up the timer
    trap __sypro_timer_command_hook DEBUG
    # and hook up the prompt
    PROMPT_COMMAND='sypro_prompt_command $?'
}


# run at every prompt.
function sypro_prompt_command {
    # stop running the timer.
    __sypro_timer_pause

    # we put the exit status of the last command in the prompt; it's passed as
    # an argument to this function.
    local last_status="$1"

    # we look up all colours at every prompt; this is to allow instant
    # customization without reloading. it's all in-shell so the performance hit
    # is imperceptible.
    local r="${sypro_colors[reset]}"
    local dim="${sypro_colors[dim]}"

    if [ "$last_status" != 0 ]; then
        last_status="${sypro_colors[error]}$last_status${r}"
    fi

    # only highlight job count if it's not 0
    if [ -z "$(jobs -p)" ]; then
        local bgcount="0"
    else
        local bgcount="${sypro_colors[bgcount]}\\j${r}"
    fi

    # we look up username and hostname every prompt to account for changes; but
    # use a cache to avoid lenghty recomputations.
    local hostname
    hostname="$(uname -n)"
    if ! test -v "${__sypro_color_cache[$hostname]}"; then
        __sypro_color_cache[$hostname]="$(sypro_pick_color "$hostname")"
    fi
    local hostcolor="${__sypro_color_cache[$hostname]}"

    local euidcolor
    # testing for number rather than 'root' allows root aliases.
    if [ "$(id -u)" = 0 ]; then
        euidcolor="${sypro_colors[root]}"
    else
        if ! test -v "${__sypro_color_cache[$USER]}"; then
            __sypro_color_cache[$USER]="$(sypro_pick_color "$USER")"
        fi
        euidcolor="${__sypro_color_cache[$USER]}"
    fi
    # $USER and `uname -n` seem to be more dynamic than the PS1 escapes
    # (\u and  \h).
    local user="$euidcolor$USER$r"
    local host="$hostcolor$hostname$r"

    local is_ssh
    # posixly find out if we're in an ssh session, even under sudo/su and
    # friends.  call with current shell pid or PPID, it will recurse through
    # parents.
    function __sypro_detect_ssh {
        local pid="$1"
        if [ -z "$pid" ] || [ "$pid" = 1 ] || [ "$pid" = 0 ]; then
            return 1
        fi

        local cmd
        cmd="$(ps -o comm= -p "$pid" )"
        if echo -n "$cmd"|grep -q "\<sshd\?\>"; then
            return 0
        fi

        __sypro_detect_ssh "$(ps -o ppid= -p "$pid" | tr -d '[:space:]')"
    }

    if test -v SSH_CLIENT || test -v SSH_TTY; then
        is_ssh=t
    elif [ $PPID -ne 0 ] && __sypro_detect_ssh $PPID; then
        is_ssh=t
    else
        unset is_ssh
    fi
    if test -v is_ssh; then
        is_ssh="${sypro_colors[ssh]}(ssh)$r"
    fi
    unset __sypro_detect_ssh

    if env | grep -q '^ANDROID_SOCKET_'; then
        local is_adb="${sypro_colors[adb]}(adb)$r"
    fi


    if type -t __git_ps1 >/dev/null 2>&1; then
        local git
        git="${sypro_colors[git]}$(__git_ps1 '::%s')$r"
    fi

    if [ "$__sypro_virt" ]; then
        local isvirt
        isvirt="[${sypro_colors[virt]}$__sypro_virt$r]"
    fi

    local runtime
    case $__sypro_timer_elapsed in
        0) runtime=0${dim}s;;
        -|'') runtime=-;;
        *) runtime="${sypro_colors[timer]}${__sypro_timer_elapsed}${r}${dim}s${r}"
            ;;
    esac
    PS1="$r$user$dim@$r$host$is_ssh$is_adb$isvirt$dim(e:$last_status$dim,$runtime$dim)(j:${bgcount}$dim)$r \w$git\n$euidcolor>"'\$'"$r "
    __sypro_timer_restart
}

# run the one-off setup
__sypro_setup "$@"
