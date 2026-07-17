#!/bin/sh
# Force the Protect postgres cluster's data_directory to the internal disk
# (/data on vda), never the array (/srv).
#
# WHY: Protect ships several independent code paths that repoint this cluster at
# /srv (unifi-protect-db-cluster-migrate, ...-setuppgconf, and the app's
# hooks/pre-start "safety net"). They all gate on /ssd1 existing, which is the
# only thing keeping our DB on vda. data_directory is read ONLY at postgres
# start, so a silent rewrite lies dormant until the next restart. On 2026-07-13
# a hard crash detonated exactly that: Protect came back on a STALE /srv cluster
# frozen at ~June 15 (month of events gone, SuperLink fingerprints stale,
# sensors "adopted to another console"). This runs immediately before the
# cluster starts, so the correct path is always in force.
WANT=/data/postgresql/14/protect/data
CUR=$(pg_conftool -s 14 protect get data_directory 2>/dev/null)
if [ "$CUR" != "$WANT" ]; then
    logger -t assert-protect-datadir "data_directory was '$CUR' - forcing '$WANT'"
    pg_conftool 14 protect set data_directory "$WANT" || true
fi
exit 0
