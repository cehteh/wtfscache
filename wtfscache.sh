#!/bin/bash
LC_ALL=C

min_free=37500
max_free=38000
remote="ct@wolke.pipapo.org:test"
mountpoint=wolke

#DONE: pin:: files to a 'precious' dir which doesnt get garbage collected
#DONE: get:: force caching the given files

#TODO: drop/clean/gc:: files from the cache -f drops pinned files
#TODO: connect:: reconnect after a (manual) disconnection
#TODO: disconnect:: manual disconnected operation
#TODO: detach/local:: detach files from the remote, keep edits local
#TODO: logfile for files which need to be merged (automatically detached)
#TODO: merge:: merge detached files back to the remote
#TODO: status:: print some infos
#TODO: start:: start the daemon
#TODO: stop:: stop the daemon
#TODO: init:: setup a template
#TODO: ???:: propagate deleted files to the remote
#TODO: undelete/undo/history:: work with backup files and whiteouts

function dbg ()
{
    echo "$*" 1>&2
}

function disk_free ()
{
    echo -n $(df -B 1M --no-sync --output=avail -l "$1" | tail -1)
}

function gc ()
{
    dbg "GC $(disk_free ".$mountpoint/cache/.")"
    if [[ ! -f ".$mountpoint/$$.lst" ]] && (($(disk_free ".$mountpoint/cache/.") <= $min_free)); then
            find ".$mountpoint/cache" -type f -not -name '*_HIDDEN~' -printf '%A@ %p\n' | sort -n  >".$mountpoint/$$.lst"

            while (($(disk_free ".$mountpoint/cache/.") < $max_free)); do
                read _ file;
                dbg "RM $file"
                #FIXME: only when proven that file exist on remote
                [[ -f $file ]] && rm "$file"
            done <".$mountpoint/$$.lst"

            rm ".$mountpoint/$$.lst"
    fi
}

function copy_up ()
{
    if [[ ! ( -f ".$mountpoint/cache/${1##$mountpoint/}"
           || -f ".$mountpoint/precious/${1##$mountpoint/}"
           || -f ".$mountpoint/local/${1##$mountpoint/}" ) ]]; then
            dbg "COPY_UP $1"
            touch -ac "$1"
            gc
    fi
}

function commit ()
{
    dbg "COMMIT $1"
    local file="${1##$mountpoint/}"
    mkdir -p ".$mountpoint/master/${file%/*}"
    #TODO: if connected
    cp --backup=t ".$mountpoint/cache/${file}" ".$mountpoint/master/${file}" &
}





function wtfscache_main ()
{
    mkdir -p "$mountpoint" ".$mountpoint/cache" ".$mountpoint/master" ".$mountpoint/precious" ".$mountpoint/local"
    sshfs -o  reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user "$remote" ".$mountpoint/master"
    unionfs-fuse -o cow ".$mountpoint/cache"=RW:".$mountpoint/precious"=RW:".$mountpoint/master"=RO "$mountpoint"

    trap : INT

    gc

    inotifywait -m -r --format '%e %w%f' -e open,close_write "$mountpoint" | xargs -d '\n' -l -n1 $0 EVENT

    dbg "DONE"
    fusermount -u -z "$mountpoint"
    fusermount -u -z ".$mountpoint/master"
}


function get ()
{
    local pin="$1"
    if [[ "$pin" == '--pin' ]]; then
            shift
    fi

    for i in "$@"; do
        if [[ -f "$i" ]]; then
                local file="${i##$mountpoint/}"
                dbg "PIN ${file}"
                copy_up "$i"
                if [[ "$pin" == '--pin' ]]; then
                        mkdir -p ".$mountpoint/precious/${file%/*}"
                        [[ -f ".$mountpoint/cache/${file}" ]] && mv ".$mountpoint/cache/${file}" ".$mountpoint/precious/${file}"
                fi
        #PLANNED: else pattern?
        fi
    done
}


case "$1" in
start)
    wtfscache_main
    exit 0
    ;;
get)
    shift
    get "$@"
    ;;
pin)
    shift
    get --pin "$@"
    ;;
EVENT)
    shift
    case "$1" in
    "OPEN,ISDIR "*)
        :
        ;;
    "OPEN "*)
        copy_up "${*##OPEN }" &
        ;;
    "CLOSE_WRITE,CLOSE "*)
        commit "${*##CLOSE_WRITE,CLOSE }"
        ;;
    *)
        dbg "unhandled $@"
    esac
    ;;
esac


