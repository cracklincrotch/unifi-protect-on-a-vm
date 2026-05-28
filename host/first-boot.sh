# protect-on-mac — first-boot hook.
#
# stand-up.sh carries this file in the installer initrd; the preseed
# late_command installs it as /root/.bash_profile in the freshly built
# VM. A bash login shell sources ~/.bash_profile, so on the first boot —
# where the serial console auto-logs in as root (see autologin.conf) —
# this runs, hands off to start-here.sh, and then gets out of the way.
#
# It is NOT a normal .bash_profile and is not meant to persist: it
# removes itself and the autologin override before doing any work, so a
# reboot or a failure mid-install always lands on a clean login prompt
# next time, never an autologin loop.

# Tear down the one-shot machinery FIRST — before start-here.sh runs.
# start-here.sh reboots the VM partway through its work; that reboot must
# come up as an ordinary login, not back into this hook.
rm -f /root/.bash_profile
rm -f /etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf
rmdir /etc/systemd/system/serial-getty@ttyAMA0.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

echo
echo "==============================================================="
echo "  protect-on-mac — first boot"
echo "==============================================================="
echo
echo "Mounting the scripts CD and launching start-here.sh. It is as"
echo "interactive as ever — just answer its prompts on this console."
echo

protect_iso_mnt=/mnt/protect-on-mac
mkdir -p "$protect_iso_mnt"
if mount -o ro /dev/sr0 "$protect_iso_mnt" 2>/dev/null \
        && [ -f "$protect_iso_mnt/start-here.sh" ]; then
    bash "$protect_iso_mnt/start-here.sh"
else
    echo "Could not mount the scripts CD (/dev/sr0), or start-here.sh is"
    echo "not on it. Make sure start-protect-vm.sh attached the scripts"
    echo "ISO (SCRIPTS_ISO in protect-on-mac.conf), then run it by hand:"
    echo
    echo "    mount /dev/sr0 $protect_iso_mnt"
    echo "    bash $protect_iso_mnt/start-here.sh"
    echo
fi
unset protect_iso_mnt
