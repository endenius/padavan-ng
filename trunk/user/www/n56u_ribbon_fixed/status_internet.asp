<% detect_internet(); %>
<% net_update_vpnc_wg_state(); %>
var now_wan_internet = '<% nvram_get_x("", "link_internet"); %>';
var now_vpnc_state = '<% nvram_get_x("", "vpnc_state_t"); %>';
