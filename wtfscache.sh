#!/bin/bash
LC_ALL=C

#DONE: start:: start the daemon
#DONE: pin:: files to a 'precious' dir which doesnt get garbage collected
#DONE: get:: force caching the given files
#DONE: drop:: files from the cache --pin drops pinned files

#TODO: config loader

#TODO: disconnect:: manual disconnected operation
#TODO: connect:: reconnect after a (manual) disconnection
#TODO: detach/local:: detach files from the remote, keep edits local

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
    dbg "GC $(disk_free ".$mountpoint/cache/.")"
    if [[ ! -f ".$mountpoint/$$.lst" ]] && (($(disk_free ".$mountpoint/cache/.") <= $min_free)); then
            find ".$mountpoint/cache" -type f -not -name '*_HIDDEN~' -printf '%A@ %p\n' | sort -n  >".$mountpoint/$$.lst"

            while (($(disk_free ".$mountpoint/cache/.") < $max_free)); do
                read _ file || break
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
    mountpoint="$1"
    [[ -f ".$mountpoint/config" ]] || die "not a wtfscache"
    source ".$mountpoint/config"

    sshfs -o compression=yes,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user "$remote" ".$mountpoint/master"
    unionfs-fuse -o cow,use_ino ".$mountpoint/cache"=RW:".$mountpoint/precious"=RW:".$mountpoint/local"=RW:".$mountpoint/master"=RO "$mountpoint"

    trap : INT

    gc

    # loop? restart? what about new dirs?
    inotifywait -m -r --format '%e %w%f' -e open,close_write "$mountpoint" | xargs -d '\n' -l -n1 $0 EVENT

    dbg "DONE"
    fusermount -u -z "$mountpoint"
    fusermount -u -z ".$mountpoint/master"
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
    mountpoint="$1"

    mkdir -p "$mountpoint" ".$mountpoint/cache" ".$mountpoint/master" ".$mountpoint/precious" ".$mountpoint/local/.wtfscache"
    [[ -f ".$mountpoint/local/.wtfscache/name" ]] || echo "$mountpoint" >".$mountpoint/local/.wtfscache/name"

    [[ -f ".$mountpoint/config" ]] || cat >".$mountpoint/config" <<EOF
$(query 'Starting garbage collector when less then this MB space is free' min_free 1024)
$(query 'Stopping the gc when this much MB space is free' max_free 2048)
$(query "Master server as 'user@host:directory'" remote '')
$(query 'Backup mode' backups numbered)
$(query 'Startup state (connected/disconnected)' startup connected)
EOF
}

function cdroot ()
{
    cd "${1%/*}"

    while [[ "$PWD" != '/' && ! -f ".wtfscache/name" ]]; do
        cd ..
    done

    if [[ -f ".wtfscache/name" ]]; then
            WTFSCACHEROOT="$PWD"
            cat ".wtfscache/name"
    else
        die "not a wtfscache"
    fi
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
                copy_up "$i"
                if [[ "$pin" == '--pin' ]]; then
                        dbg "PIN ${file}"
                        mkdir -p ".$mountpoint/precious/${file%/*}"
                        [[ -f ".$mountpoint/cache/${file}" ]] && mv ".$mountpoint/cache/${file}" ".$mountpoint/precious/${file}"
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

    for i in "$@"; do
        if [[ -f "$i" ]]; then
                local file="${i##$mountpoint/}"
                dbg "DROP ${file}"

                [[ -f ".$mountpoint/cache/${file}" ]] && rm ".$mountpoint/cache/${file}"

                if [[ -f ".$mountpoint/precious/${file}" ]]; then
                        if [[ "$pin" == '--pin' ]]; then
                                rm -f ".$mountpoint/precious/${file}"
                        else
                            dbg "PINNED ${file}"
                        fi
                fi
        #PLANNED: else pattern?
        fi
    done
}


case "$1" in
TEST)
    shift
    cdroot $1
    echo $WTFSCACHEROOT
    ;;
init)
    shift
    wtfscache_init "$@"
    ;;
start)
    shift
    wtfscache_main "$@"
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


