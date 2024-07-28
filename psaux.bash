#!/bin/bash


# so initially i was hoping you could get everything from /proc/<pid>/status
# because it's easy to parse (in most cases) but apparently you can't get
# things like the cpu% :(
#while read -ra data; do
#    case ${data[0]} in
#        State:) stat=${data[1]};;
#        Uid:) uid=${data[1]};;
#        Gid:) gid=${data[1]};;
#        VmSize:) vsz=${data[1]};;
#        VmRSS:) rss=${data[1]};;
#    esac
#done < "$dir"/status
# it would have been so easy!!!!
#
# SO INSTEAD LET'S DO IT AAAAAALL __PROPERLY__ (with zero forking)

# you can test that it doesn't fork with
# strace -fe fork,clone,clone3 -o strout ./psaux.bash; cat strout



users=()
read_passwd() {
    local IFS=: fields
    while read -ra fields; do
        users[fields[2]]=${fields[0]}
    done < /etc/passwd
}

IFS=$' \t\n'

devices=()
resolve_devices() {
    # ok so this seems to always have 4 == tty/ttyS, 5 == console/ptmx and 136 == pts
    # but let's just do it properly
    local fields
    while read -ra fields; do
        if [[ ${fields[0]} == [0-9]* ]]; then
            devices[fields[0]]+=${fields[1]}" "
        fi
    done < /proc/devices
}

ttyname() {
    local major minor device fmt
    (( major = $1 >> 8, minor = $1 & 0xff ))
    # now let's play the fun game of guess whatever the fuck the name could be

    REPLY=?
    for device in ${devices[major]}; do
        # ps checks for these:

        #lookup("/dev/pts/%s");
        #lookup("/dev/%s");       <- i don't think this can happen in this context?
        #lookup("/dev/tty%s");
        #lookup("/dev/pty%s");    <- seems like it can't happen on my machine?
        #lookup("/dev/%snsole");  <- i hope this doesn't happen????

        # but we're cooler so we're also checking for stuff like ttyS[0-9]+
        REPLY=$device/$minor
        for fmt in %s/%s %s%s; do
            printf -v REPLY "$fmt" "$device" "$minor"
            [[ -e /dev/$REPLY ]] && return
        done
    done
}

process_uid=()
process_pid=()
process_cpu=()
process_mem=()
process_vsz=()
process_rss=()
process_tty=()
process_stat=()
process_start=()
process_time=()
process_command=()
widths=()
add_process() {
    process_uid[$2]=$1
    process_pid[$2]=$2
    process_cpu[$2]=$3
    process_mem[$2]=$4
    process_vsz[$2]=$5
    process_rss[$2]=$6
    process_tty[$2]=$7
    process_stat[$2]=$8
    process_start[$2]=$9
    process_time[$2]=${10}
    process_command[$2]=${11}

    local i width
    for (( i = 1; i <= $#; i++)) do
        width=${@:i:1} width=${#width}
        (( widths[i-1] = width+1 > widths[i-1] ? width+1 : widths[i-1] ))
    done
}

get_term_size() {
    local oldrow oldcol
    # in interactive mode bash enables checkwinsize which reports $LINES and $COLUMNS and reacts nicely to sigwinch
    # unfortunately checkwinsize is fucking unusable and broken in 30 different ways in non interactive scripts
    #
    # the normal, reliable way to check the terminal size requires an ioctl we don't have direct access to
    # (altho bash itself does, and it will immediately use it for [[ -t ]], but you can't have it because fuck you)
    #
    # one could in theory start a script with #!/bin/bash -i and use checkwinsize
    # it kinda works but it sucks because it sources all your dotfiles and whatevers
    #
    # so let's manually ask the terminal with the raw ansi codes
    # (which seems to work on my terminal.  if it doesn't work on yours maybe you need a better terminal?)
    # (tested on terminator 2.1.3, which surely is the most common terminal in the world and the only one people care about)
    if [[ -t 1 ]]; then
        # get the current position
        IFS='[;' read -sdR -p $'\e[6n' _ oldrow oldcol

        # hide cursor and move it to the end of the screen
        printf '\e[%s' '?25l' '9999;9999H' # your terminal is smaller than 9999x9999

        # finally get a reasonable estimate
        IFS='[;' read -sdR -p $'\e[6n' _ LINES COLUMNS

        # show cursor again and go back to the old position
        printf '\e[%s' '?25h' "$oldrow;1H"
        # (if we were not at col 1, we just ignore it because we use \n anyway)
    else
        COLUMNS=20000 # whatever
    fi
}

# turns out that the most difficult problem in computer science is aligning things
# this one function looks simple but it took so fucking long
printall() {
    get_term_size

    #              USER   PID   %CPU  %MEM  VSZ   RSS   TTY    STAT   START TIME  COMMAND
    printf -v fmt '%%-%ds %%%ds %%%ds %%%ds %%%ds %%%ds %%-%ds %%-%ds %%%ss %%%ss %%-.%ds' "${widths[@]}"

    local i line
    for i in "${process_pid[@]}"; do
        printf -v line "$fmt" \
        "${process_uid[i]}" \
        "${process_pid[i]}" \
        "${process_cpu[i]}" \
        "${process_mem[i]}" \
        "${process_vsz[i]}" \
        "${process_rss[i]}" \
        "${process_tty[i]}" \
        "${process_stat[i]}" \
        "${process_start[i]}" \
        "${process_time[i]}" \
        "${process_command[i]}"
        printf "%.${COLUMNS}s\n" "$line"
    done

}

almost_ps_aux() {
    read_passwd
    resolve_devices
    read _ memtotal _ < /proc/meminfo
    read boottime _ < /proc/uptime
    boottime=${boottime%%[!0-9]*}

    local REPLY
    local cmdline stat status # various fds
    local dir pid cmd_line stat_fields status_fields name user state tty cpu start vsz rss time time_of_day # variables

    local sys_clk_tck=100 # hardcoded from my unistd.h

    add_process USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND

    # bash<5 doesn't have epochseconds, so try to get it (which doesn't work on macos because strftime doesn't support %s)
    [[ $EPOCHSECONDS ]] || printf -v EPOCHSECONDS '%(%s)T'
    # however i've not yet checked any of this in any other bash so this might not be very useful after all

    printf -v time_of_day '%(10#%H*3600+10#%M*60+10#%S)T' # omg haxxx
    time_of_day=$(($time_of_day))

    for dir in /proc/[1-9]*; do
        pid=${dir#/proc/}

        [[ $cmdline ]] && exec {cmdline}>&-
        [[ $stat    ]] && exec {stat}>&-
        [[ $status  ]] && exec {status}>&-

        # if something can't be opened, skip this process entirely, it's probably either dead already or inaccessible so wtf can we do about it
        {
        exec {cmdline}< "$dir"/cmdline || continue
        exec {stat}<    "$dir"/stat    || continue
        exec {status}<  "$dir"/status  || continue
        } 2>/dev/null

        cmd_line=()
        while read -rd '' -u "$cmdline"; do
            cmd_line+=("$REPLY")
        done
        # if cmd_line is empty, this might be a kernel thread
        # this is not always the case because you can just wipe your own cmdline, and idfk how to detect if something was _actually_ a k thread
        # htop literally does the same thing as this
        # ps places square brackets around these process names for whatever reason

        # linux escapes newlines in the file name here, so it's guaranteed to all fit on a single line
        read -ru "$status" _ name
        while read -ru "$status" -a status_fields; do
            case ${status_fields[0]} in
                VmLck:) vmlocked=${status_fields[1]} ;;
                Uid:) uid=${status_fields[1]} ;; # this seems to be the only reliable way to get the uid from bash using builtins only
            esac
        done
        (( ! ${#cmd_line[@]} )) && cmd_line[0]=[$name]

        read -rd '' -u "$stat"

        # splitting on spaces here is fine because the rest are all numbers, and it removes the trailing newline we got with read -d ''
        # (putting pid and the empty fields in here makes it so the offsets match the docs for proc/pid/stat
        #
        # note: we don't care about the comm field at all because we already have cmdline
        # it could contain parentheses and spaces and stuff, but it's always terminated by the last ) in the file
        stat_fields=(. "$pid" . ${REPLY##*) })

        state=${stat_fields[3]}
        (( stat_fields[19] >  0   )) && state+=N  # for whatever reason, in ps aux N is printed first and < is printed last (i think????)
        (( stat_fields[6]  == pid )) && state+=s
        (( stat_fields[20] != 1   )) && state+=l
        (( stat_fields[8]  == pid )) && state+=+
        (( stat_fields[19] <  0   )) && state+='<'
        (( vmlocked )) && state+=L

        ttyname "${stat_fields[7]}"; tty=$REPLY
        cpu=$((stat_fields[14] / sys_clk_tck))  # fixme: apparently completely wrong????
        start=$((boottime-(stat_fields[22] / sys_clk_tck)))
        # if this was at least yesterday
        if (( start >= time_of_day )); then
            printf -v start '%(%b%d)T' "$((EPOCHSECONDS-start))"
        else
            printf -v start '%(%H:%M)T' "$((EPOCHSECONDS-start))"
        fi
        vsz=$((stat_fields[23]/1024))
        rss=$((stat_fields[24] * 4096 / 1024)) # hugepages unsupported for now
        mem=$((rss*1000/memtotal)) mem=$((${mem::-1})).${mem: -1}
        time=$(((stat_fields[14]+stat_fields[15]) / sys_clk_tck)) # seems correct, probably slightly wrong tho???
        printf -v time '%d:%02d' "$((time/60))" "$((time%60))" # ps aux seems to always use this exact format i think???

        #add_process "user=${users[uid]-?}" "pid=$pid" "cpu=$cpu" "mem=$mem" "vsz=$vsz" "rss=$rss" "tty=$tty" "state=$state" "start=$start" "time=$time" "cmdline=<${cmd_line[*]}>"
         add_process      "${users[uid]-?}"     "$pid"     "$cpu"     "$mem"     "$vsz"     "$rss"     "$tty"       "$state"       "$start"      "$time"          "${cmd_line[*]}"
    done

    [[ $cmdline ]] && exec {cmdline}>&-
    [[ $stat    ]] && exec {stat}>&-
    [[ $status  ]] && exec {status}>&-

    printall
}

almost_ps_aux
