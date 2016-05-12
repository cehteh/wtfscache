#!/bin/bash
LC_ALL=C

export WTFSCACHE
export WTFSCACHEROOT
export WTFSCACHEMOUNT
export WTFSCACHEMETA
export WTFSCACHETMP

export min_free
export max_free
export remote
export backups
export startup

#DONE: start:: start the daemon
#DONE: pin:: files to a 'precious' dir which doesnt get garbage collected
#DONE: get:: force caching the given files
#DONE: drop:: files from the cache --pin drops pinned files
#DONE: config loader

#TODO: disconnect:: manual disconnected operation
#TODO: connect:: reconnect after a (manual) disconnection
#TODO: detach/local:: detach files from the remote, keep edits local

#TODO: unpin:: precious -> cache
#TODO: status:: print some infos
#TODO: prune:: remove all traces of a file, including backups, also from master
#TODO: logfile for files which need to be merged (automatically detached)
#TODO: merge:: merge detached files back to the remote
#TODO: stop:: stop the daemon
#TODO: init:: setup a template
#TODO: ???:: propagate deleted files to the remote mode=writeback, local, deletes
#TODO: undelete/undo/history:: work with backup files and whiteouts
#TODO: clean/gc:: manual gc run

function dbg ()
{
    echo "$*" 1>&2
}

function die ()
{
    echo "$*" 1>&2
    exit 1
}

function disk_free ()
{
    echo -n $(df -B 1M --no-sync --output=avail -l "$1" | tail -1)
}

function gc ()
{
    dbg "GC $(disk_free "$WTFSCACHEMETA/cache/.")"
    if [[ ! -f "$WTFSCACHEMETA/$$.lst" ]] && (($(disk_free "$WTFSCACHEMETA/cache/.") <= $min_free)); then
            find "$WTFSCACHEMETA/cache" -type f -not -name '*_HIDDEN~' -printf '%A@ %p\n' | sort -n  >"$WTFSCACHEMETA/$$.lst"

            while (($(disk_free "$WTFSCACHEMETA/cache/.") < $max_free)); do
                read _ file || break
                dbg "RM $file"
                #FIXME: only when proven that file exist on remote
                [[ -f $file ]] && rm "$file"
            done <"$WTFSCACHEMETA/$$.lst"

            #TODO: prune empty dirs
            rm "$WTFSCACHEMETA/$$.lst"
    fi
}

function copy_up ()
{
    if [[ ! ( -f "$WTFSCACHEMETA/cache/${1##$WTFSCACHE/}"
           || -f "$WTFSCACHEMETA/precious/${1##$WTFSCACHE/}"
           || -f "$WTFSCACHEMETA/local/${1##$WTFSCACHE/}" ) ]]; then
            dbg "COPY_UP $1"
            touch -ac "$1"
            gc
    fi
}

function commit ()
{
    dbg "COMMIT $1"
    local file="${1##$WTFSCACHE/}"
    mkdir -p "$WTFSCACHEMETA/master/${file%/*}"
    #TODO: if connected $verify
    cp --backup="$backups" "$WTFSCACHEMETA/cache/${file}" "$WTFSCACHEMETA/master/${file}"
}





function wtfscache_start ()
{
    WTFSCACHE="$1"
    WTFSCACHEROOT="${PWD}"
    WTFSCACHEMOUNT="$WTFSCACHEROOT/$WTFSCACHE"
    WTFSCACHEMETA="$WTFSCACHEROOT/.$WTFSCACHE"
    WTFSCACHETMP="$WTFSCACHEROOT/.$WTFSCACHE"

    [[ -f "$WTFSCACHEMETA/config" ]] || die "not a wtfscache"
    source "$WTFSCACHEMETA/config"

    # max_files
    sshfs -o compression=yes,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user "$remote" "$WTFSCACHEMETA/master"
    unionfs-fuse -o cow,use_ino "$WTFSCACHEMETA/cache"=RW:"$WTFSCACHEMETA/precious"=RW:"$WTFSCACHEMETA/local"=RW:"$WTFSCACHEMETA/master"=RO "$WTFSCACHE"

    trap : INT

    gc

    # loop? restart? what about new dirs?
    inotifywait -m -r --format '%e %w%f' -e open,close_write "$WTFSCACHE" | xargs -d '\n' -l -P 32 -n1 $0 EVENT

    dbg "DONE"
    fusermount -u -z "$WTFSCACHE"
    fusermount -u -z "$WTFSCACHEMETA/master"
}



function query ()
{
    read -p "$1
$2 = [$3] "
    echo "# $1
$2='${REPLY:-$3}'
"
}




function wtfscache_init ()
{
    WTFSCACHE="$1"
    WTFSCACHEROOT="${PWD}"
    WTFSCACHEMOUNT="$WTFSCACHEROOT/$WTFSCACHE"
    WTFSCACHEMETA="$WTFSCACHEROOT/.$WTFSCACHE"
    WTFSCACHETMP="$WTFSCACHEROOT/.$WTFSCACHE"

    mkdir -p "$WTFSCACHE" "$WTFSCACHEMETA/cache" "$WTFSCACHEMETA/master" "$WTFSCACHEMETA/precious" "$WTFSCACHEMETA/local/.wtfscache"
    [[ -f "$WTFSCACHEMETA/local/.wtfscache/name" ]] || echo "$WTFSCACHE" >"$WTFSCACHEMETA/local/.wtfscache/name"

    [[ -f "$WTFSCACHEMETA/config" ]] || cat >"$WTFSCACHEMETA/config" <<EOF
$(query 'Starting garbage collector when less then this MB space is free' min_free 1024)
$(query 'Stopping the gc when this much MB space is free' max_free 2048)
$(query "Master server as 'user@host:directory'" remote '')
$(query 'Backup mode' backups numbered)
$(query 'Startup state (connected/disconnected)' startup connected)
EOF
}

function setup ()
{
    local startdir="$PWD"
    cd "${1%/*}"

    while [[ "$PWD" != '/' && ! -f ".wtfscache/name" ]]; do
        cd ..
    done

    if [[ -f ".wtfscache/name" ]]; then
            WTFSCACHE="$(<.wtfscache/name)"
            WTFSCACHEROOT="${PWD%/*}"
            WTFSCACHEMOUNT="$WTFSCACHEROOT/$WTFSCACHE"
            WTFSCACHEMETA="$WTFSCACHEROOT/.$WTFSCACHE"
            WTFSCACHETMP="$WTFSCACHEROOT/.$WTFSCACHE"
            cat ".wtfscache/name"
    else
        die "no wtfscache"
    fi

    cd "$startdir"
    source "$WTFSCACHEMETA/config"
}

function get ()
{
    local pin="$1"
    if [[ "$pin" == '--pin' ]]; then
            shift
    fi
    setup "$1"

    for i in "$@"; do
        if [[ -f "$i" ]]; then
                local file="${i##$WTFSCACHE/}"
                copy_up "$i"
                if [[ "$pin" == '--pin' ]]; then
                        dbg "PIN ${file}"
                        mkdir -p "$WTFSCACHEMETA/precious/${file%/*}"
                        [[ -f "$WTFSCACHEMETA/cache/${file}" ]] && mv "$WTFSCACHEMETA/cache/${file}" "$WTFSCACHEMETA/precious/${file}"
                fi
        #PLANNED: else pattern?
        fi
    done
}


function drop ()
{
    local pin="$1"
    if [[ "$pin" == '--pin' ]]; then
            shift
    fi
    setup "$1"

    for i in "$@"; do
        if [[ -f "$i" ]]; then
                local file="${i##$WTFSCACHE/}"
                dbg "DROP ${file}"

                [[ -f "$WTFSCACHEMETA/cache/${file}" ]] && rm "$WTFSCACHEMETA/cache/${file}"

                if [[ -f "$WTFSCACHEMETA/precious/${file}" ]]; then
                        if [[ "$pin" == '--pin' ]]; then
                                rm -f "$WTFSCACHEMETA/precious/${file}"
                        else
                            dbg "PINNED ${file}"
                        fi
                fi
        #PLANNED: else pattern?
        fi
    done
}


case "$1" in
init)
    shift
    wtfscache_init "$@"
    ;;
start)
    shift
    wtfscache_start "$@"
    ;;
get)
    shift
    get "$@"
    ;;
pin)
    shift
    get --pin "$@"
    ;;
drop)
    shift
    drop "$@"
    ;;
EVENT)
    shift
    case "$1" in
    "OPEN,ISDIR "*)
        :
        ;;
    "OPEN "*)
        copy_up "${*##OPEN }"
        ;;
    "CLOSE_WRITE,CLOSE "*)
        commit "${*##CLOSE_WRITE,CLOSE }"
        ;;
    *)
        die "unhandled event $@"
    esac
    ;;
*)
    die "unknown command $1"
    ;;
esac


