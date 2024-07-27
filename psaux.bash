#!/bin/bash -i

# important!!! -i ^^^^
shopt -s checkwinsize
#COLUMNS=${COLUMNS-100}

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

# SO INSTEAD LET'S DO IT AAAAAALL __PROPERLY__

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

cnt=0
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
    process_uid[cnt]=$1
    process_pid[cnt]=$2
    process_cpu[cnt]=$3
    process_mem[cnt]=$4
    process_vsz[cnt]=$5
    process_rss[cnt]=$6
    process_tty[cnt]=$7
    process_stat[cnt]=$8
    process_start[cnt]=$9
    process_time[cnt]=${10}
    process_command[cnt]=${11}
    ((cnt++))

    local i width
    for (( i = 1; i <= $#; i++)) do
        width=${@:i:1} width=${#width}
        (( widths[i-1] = width+1 > widths[i-1] ? width+1 : widths[i-1] ))
    done
}

# turns out that the most difficult problem in computer science is aligning things
# this one function looks simple but it took so fucking long
printall() {
    printf -v fmt "%%-%ds " "${widths[@]}"

    local line maxwidth=$((COLUMNS-1))
    for (( i = 0; i < cnt; i++)) do
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
        printf "%.${maxwidth}s\n" "$line"
    done

}

almost_ps_aux() {
    read_passwd
    resolve_devices
    read _ memtotal _ < /proc/meminfo

    local REPLY
    local cmdline stat status # various fds
    local dir pid cmd_line stat_fields user state tty cpu start vsz rss time # variables

    local sys_clk_tck=100 # hardcoded from my unistd.h

    add_process USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND

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

        read -rd '' -u "$stat"

        # splitting on spaces here is fine because the rest are all numbers, and it removes the trailing newline we got with read -d ''
        # (putting pid and the empty fields in here makes it so the offsets match the docs for proc/pid/stat
        #
        # note: we don't care about the comm field at all because we already have cmdline
        # it could contain parentheses and spaces and stuff, but it's always terminated by the last ) in the file
        stat_fields=(. "$pid" . ${REPLY##*) })

        state=${stat_fields[3]}
        ttyname "${stat_fields[7]}"; tty=$REPLY
        cpu=$((stat_fields[14] / sys_clk_tck))  # fixme: apparently completely wrong????
        start=$((stat_fields[22] / sys_clk_tck))
        vsz=$((stat_fields[23]/1024))
        rss=$((stat_fields[24] * 4096 / 1024)) # hugepages unsupported for now
        time=$(((stat_fields[14]+stat_fields[15]+stat_fields[16]+stat_fields[17]) / sys_clk_tck)) # idfk if this is correct

        read -rd '' -u "$status"
        # if cmd_line is empty, this might be a kernel thread
        # this is not always the case because you can just wipe your cmdline, and idfk how to detect this
        # ps also places square brackets around these for whatever reason
        (( ! ${#cmd_line[@]} )) && cmd_line[0]=${REPLY%%$'\n'*} cmd_line[0]=[${cmd_line[0]#$'Name:\t'}]

        # this seems to be the only reliable way to get the uid from bash using builtins only
        uid=(${REPLY##*Uid:})

        # mem% currently calculated as rss/memtotal.   proably wrong
        #add_process "user=${users[uid[1]]-?}" "pid=$pid" "cpu=$cpu" "mem=$((rss/memtotal))" "vsz=$vsz" "rss=$rss" "tty=$tty" "state=$state" "start=$start" "time=$time" "cmdline=<${cmd_line[*]}>"
         add_process      "${users[uid[1]]-?}"     "$pid"     "$cpu"     "$((rss/memtotal))"     "$vsz"     "$rss"     "$tty"       "$state"       "$start"      "$time"          "${cmd_line[*]}"
    done

    [[ $cmdline ]] && exec {cmdline}>&-
    [[ $stat    ]] && exec {stat}>&-
    [[ $status  ]] && exec {status}>&-

    printall
}

almost_ps_aux