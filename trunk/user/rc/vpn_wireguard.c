/*
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston,
 * MA 02111-1307 USA
 */

#include <stdio.h>
#include <stdlib.h>
#include "rc.h"

int
start_wireguard_server(void)
{
    return eval("/usr/bin/wgs.sh", "start");
}

void
stop_wireguard_server(void)
{
    eval("/usr/bin/wgs.sh", "stop");
}

void
restart_wireguard_server(void)
{
    eval("/usr/bin/wgs.sh", "restart");
}

int
start_wireguard_client(void)
{
    return eval("/usr/bin/wgc.sh", "start");
}

void
stop_wireguard_client(void)
{
    eval("/usr/bin/wgc.sh", "stop");
}

void
restart_wireguard_client(void)
{
    eval("/usr/bin/wgc.sh", "restart");
}

void
reload_wireguard_client(void)
{
    if (nvram_get_int("vpnc_enable") == 1 && nvram_get_int("vpnc_type") == 3)
        eval("/usr/bin/wgc.sh", "reload");
}

void
ipset_update_wireguard_client(void)
{
    eval("/usr/bin/wgc.sh", "ipset-update");
}
