#!/bin/bash
LC_ALL=C


min_free=37
max_free=38
remote="ct@wolke.pipapo.org:test"
mountpoint=wolke


function dbg ()
{
    echo "$*" 1>&2
}


function disk_free ()
{
    echo -n $(df -B 1G --no-sync --output=avail -l "$1" | tail -1)
}

function gc ()
{
    dbg "gc $(disk_free ".$mountpoint.cache/.")"
    if [[ ! -f ".$mountpoint.$$.lst" ]] && (($(disk_free ".$mountpoint.cache/.") <= $min_free)); then
            dbg "gc DOIT"
            find ".$mountpoint.cache" -type f -not -name '*_HIDDEN~' -printf '%A@ %p\n' | sort -n  >".$mountpoint.$$.lst"

            while (($(disk_free ".$mountpoint.cache/.") < $max_free)); do
                read _ file;
                dbg "RM $file"
                rm "$file"
            done <".$mountpoint.$$.lst"

            rm ".$mountpoint.$$.lst"
    fi
}

function _touch ()
{
        dbg "_TOUCH $1"
        [[ -f "$1" ]] || exit 0

        # if not in cache
        [[ -f ".$mountpoint.cache/${1##$mountpoint/}" ]] && exit 0

        dbg "GET $1"
        touch -ac "$1" &

        gc
}

export -f _touch


if [[ "$1" == _touch ]]; then
        _touch "$2"
        exit 0
fi


#usage: sshfscache cmd options user@host:dir mountpoint






#options:
# -f free_space
# --stop
# 
#creates:
#  dir/.sshfscache.mountpoint
#  mountpoint
#  .mountpoint.cache
#  .mountpoint.orig
#  .mountpoint.pid

mkdir -p "$mountpoint" ".$mountpoint.cache" ".$mountpoint.orig"
sshfs -o  reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user "$remote" ".$mountpoint.orig"
unionfs-fuse -o cow ".$mountpoint.cache"=RW:".$mountpoint.orig"=RO "$mountpoint"

gc

inotifywait -m -r --format '%w%f' -e open "$mountpoint" | xargs -d '\n' -l -n1 $0 _touch

sleep 1

wait
sleep 1

fusermount -u "$mountpoint"

sleep 1

fusermount -u ".$mountpoint.orig"

#get

#drop

#add


#sync
