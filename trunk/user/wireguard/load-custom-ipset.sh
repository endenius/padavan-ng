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
    local name="custom.remote"
    local list="$1"

    [ -f "$list" ] || error "file $list not found"

    ipset -N $name nethash 2>/dev/null
    ipset flush $name

    filter_ipv4 < "$list" \
        | sed -E 's#^(.*)$#add '"$name"' \1#' \
        | ipset restore

    if [ $? -eq 0 ]; then
        echo "ipset $name updated successfully"
    else
        error "ipset $name failed to update "
    fi
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
