/*
 * wl-probe.c -- read diagnostics straight out of the Broadcom blob, bypassing
 *               cfg80211 entirely.
 *
 * WHY THIS EXISTS
 *   The wl driver publishes almost nothing through the normal interfaces:
 *   `iw station dump` is empty (the shim implements get_station but NOT
 *   dump_station), /proc/net/wireless has no row, and wpa_supplicant cannot
 *   enable signal-strength monitoring at all. What the blob *does* have is a
 *   private ioctl with 74 WLC_GET_* commands behind it, including packet
 *   counters and a PHY noise floor that no standard tool on this machine can
 *   reach.
 *
 *   wl_linux.c registers .ndo_do_ioctl = wl_ioctl and handles SIOCDEVPRIVATE
 *   (line 1667 of the shipped source). Whether that path still works on
 *   kernel 7.x is the open question -- ndo_do_ioctl was removed from mainline
 *   in 5.15 -- and this program is how we find out rather than reading more
 *   source.
 *
 * SAFETY
 *   Every command issued here is a GET with set=0. Nothing is written to the
 *   device. It is still an ioctl into a binary blob frozen in 2015, so it is
 *   not zero-risk; run it with the USB tether connected, as everything else
 *   touching this driver has been.
 *
 * BUILD & RUN
 *   gcc -O2 -Wall -o wl-probe wl-probe.c
 *   sudo ./wl-probe wlp3s0          # needs CAP_NET_ADMIN
 *
 * INTERPRETING FAILURE
 *   EOPNOTSUPP / ENOTTY  the private ioctl path is gone on this kernel. That is
 *                        a real answer: the blob is unreachable from userspace
 *                        and only a driver patch would open it.
 *   EPERM                not root.
 *   ENODEV               wrong interface name.
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>

/* From src/include/wlioctl.h -- the struct userspace passes in ifr_data. */
typedef struct wl_ioctl {
	unsigned int cmd;
	void        *buf;
	unsigned int len;
	unsigned char set;
	unsigned int used;
	unsigned int needed;
} wl_ioctl_t;

#define WLC_GET_RATE        12
#define WLC_GET_CHANNEL     29
#define WLC_GET_REVINFO     98
#define WLC_GET_RSSI       127
#define WLC_GET_PHY_NOISE  135
#define WLC_GET_PKTCNTS    137

/* WLC_GET_PKTCNTS returns six counters. */
typedef struct {
	uint32_t rx_good_pkt;
	uint32_t rx_bad_pkt;
	uint32_t tx_good_pkt;
	uint32_t tx_bad_pkt;
	uint32_t rx_ocast_good_pkt;
	uint32_t rx_missed_pkt;
} pktcnt_t;

static int sock = -1;
static const char *ifname;

/* Returns 0 on success, -errno on failure. */
static int wl_get(int cmd, void *buf, int len)
{
	struct ifreq ifr;
	wl_ioctl_t   wl;

	memset(buf, 0, len);
	memset(&ifr, 0, sizeof(ifr));
	memset(&wl,  0, sizeof(wl));

	wl.cmd = cmd;
	wl.buf = buf;
	wl.len = len;
	wl.set = 0;                       /* READ ONLY. Never set this. */

	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	ifr.ifr_data = (void *)&wl;

	if (ioctl(sock, SIOCDEVPRIVATE, &ifr) < 0)
		return -errno;
	return 0;
}

static void report(const char *label, int cmd, int rc)
{
	if (rc == 0)
		return;
	printf("  %-14s cmd %-3d FAILED: %s\n", label, cmd, strerror(-rc));
}

int main(int argc, char **argv)
{
	int32_t  val;
	pktcnt_t pkt;
	int      rc, any = 0;

	ifname = (argc > 1) ? argv[1] : "wlp3s0";

	sock = socket(AF_INET, SOCK_DGRAM, 0);
	if (sock < 0) {
		perror("socket");
		return 1;
	}

	printf("wl-probe: private ioctl on %s (all commands read-only)\n\n", ifname);

	/* RSSI first: it is the one we know works via get_station, so it doubles
	 * as a positive control. If this fails, the transport is the problem
	 * rather than the individual command. */
	rc = wl_get(WLC_GET_RSSI, &val, sizeof(val));
	if (rc == 0) { printf("  rssi           %d dBm\n", val); any = 1; }
	else {
		report("rssi", WLC_GET_RSSI, rc);
		printf("\n  RSSI is the control: iw station get returns it, so the blob\n"
		       "  has it. Failing here means the PRIVATE IOCTL PATH is closed on\n"
		       "  this kernel, not that the data is missing.\n");
		close(sock);
		return 2;
	}

	rc = wl_get(WLC_GET_PHY_NOISE, &val, sizeof(val));
	if (rc == 0) printf("  phy_noise      %d dBm   <- no standard tool on this box reports this\n", val);
	else report("phy_noise", WLC_GET_PHY_NOISE, rc);

	rc = wl_get(WLC_GET_RATE, &val, sizeof(val));
	if (rc == 0) printf("  rate           %d (500kbps units) = %.1f Mbit/s\n", val, val / 2.0);
	else report("rate", WLC_GET_RATE, rc);

	rc = wl_get(WLC_GET_CHANNEL, &val, sizeof(val));
	if (rc == 0) printf("  channel        %d\n", val);
	else report("channel", WLC_GET_CHANNEL, rc);

	rc = wl_get(WLC_GET_PKTCNTS, &pkt, sizeof(pkt));
	if (rc == 0) {
		printf("\n  PACKET COUNTERS -- the wedge signature would live here:\n");
		printf("    rx_good %-12u rx_bad %-12u rx_missed %u\n",
		       pkt.rx_good_pkt, pkt.rx_bad_pkt, pkt.rx_missed_pkt);
		printf("    tx_good %-12u tx_bad %-12u rx_ocast_good %u\n",
		       pkt.tx_good_pkt, pkt.tx_bad_pkt, pkt.rx_ocast_good_pkt);
		printf("\n  A wedge should show tx_good climbing while rx_good stalls.\n"
		       "  Sample twice and diff; a single reading proves nothing.\n");
	} else report("pktcnts", WLC_GET_PKTCNTS, rc);

	close(sock);
	return any ? 0 : 3;
}
