#!/bin/bash
LC_ALL=C

min_free=37000
max_free=38000
remote="ct@wolke.pipapo.org:test"
mountpoint=wolke

#TODO: pin drop get disconnect detach connect merge status start stop clean gc_interval

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
        if [[ ! -f ".$mountpoint/cache/${1##$mountpoint/}" ]]; then
                dbg "COPY_UP $1"
                touch -ac "$1" &
                gc
        fi
}

function commit ()
{
    dbg "COMMIT $1"
    local file="${1##$mountpoint/}"
    mkdir -p ".$mountpoint/orig/${file%/*}"
    #TODO: if connected
    cp --backup=t ".$mountpoint/cache/${file}" ".$mountpoint/orig/${file}" &
}

if [[ "$1" == EVENT ]]; then
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
            dbg "unhandled $@"
        esac
        exit 0
fi


mkdir -p "$mountpoint" ".$mountpoint/cache" ".$mountpoint/orig" ".$mountpoint/precious" ".$mountpoint/detached"
sshfs -o  reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user "$remote" ".$mountpoint/orig"
unionfs-fuse -o cow ".$mountpoint/cache"=RW:".$mountpoint/orig"=RO "$mountpoint"

trap : INT

gc

inotifywait -m -r --format '%e %w%f' -e open,close_write "$mountpoint" | xargs -d '\n' -l -n1 $0 EVENT

echo done
fusermount -u -z "$mountpoint"
fusermount -u -z ".$mountpoint/orig"
