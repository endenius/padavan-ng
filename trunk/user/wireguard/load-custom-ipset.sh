#!/bin/sh

filter_ipv4()
{
    grep -E -x '^[[:space:]]*((25[0-5]|2[0-4][0-9]|1[0-9]{2}|0?[0-9]{1,2})\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|0?[0-9]{1,2})(/(3[0-2]|[12]?[0-9]))?[[:space:]]*$' \
    | sed -E 's#/32|/0##g' | sort | uniq
}

error()
{
    echo "$@"
    exit 1
}

restore()
{
    [ "$1" ] || exit

    local name="custom.remote"
    local list="$1"

    [ -f "$list" ] || error "file $list not found"

    echo -n > /tmp/$name.ipset.$$
    for i in $(filter_ipv4 < $list); do
        echo "add $name $i" >> /tmp/$name.ipset.$$
    done

    if [ ! -s /tmp/$name.ipset.$$ ]; then
        rm -f /tmp/$name.ipset.$$
        error "nothing to load"
    fi

    ipset -N $name nethash 2>/dev/null
    ipset flush $name

    res=$(cat /tmp/$name.ipset.$$ | ipset restore 2>&1)
    if [ $? = 0 ]; then
        echo "ipset $name created"
    else
        echo "$res"
    fi

    rm -f /tmp/$name.ipset.$$
}

case "$1" in
    "")
        echo "Usage: $0 <filelist_ipv4_cidr>"
        exit 1
        ;;
    *)
        restore "$1"
        ;;
esac
