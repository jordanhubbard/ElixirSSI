/*
 * ssi_init — the only native program ElixirSSI runs before the BEAM.
 *
 * Linux hands PID 1 to this file. It does the minimum the BEAM cannot do for
 * itself before it exists — mount the kernel's pseudo filesystems and attach a
 * controlling console — and then *execs* the Erlang runtime, so the BEAM
 * replaces this program and becomes PID 1. From that instant every policy
 * decision (devices, network, storage, cluster membership, shells, the
 * desktop, shutdown) is made by Elixir code in the SSI application.
 *
 * Release layout (built by os/scripts/mkinitramfs.sh):
 *   /ssi/releases/start_erl.data   "ERTS_VSN REL_VSN"
 *   /ssi/erts-ERTS_VSN/bin/erlexec
 *   /ssi/releases/REL_VSN/{start.boot,sys.config,vm.args}
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

#define SSI_ROOT "/ssi"

static void say(const char *msg) {
    (void)!write(2, msg, strlen(msg));
}

static void must_mount(const char *src, const char *dst, const char *type,
                       unsigned long flags, const char *data) {
    mkdir(dst, 0755);
    if (mount(src, dst, type, flags, data) != 0 && errno != EBUSY) {
        char line[256];
        snprintf(line, sizeof line, "ssi_init: mount %s on %s: %s\n", type, dst,
                 strerror(errno));
        say(line);
    }
}

static void attach_console(void) {
    int fd = open("/dev/console", O_RDWR | O_NOCTTY);
    if (fd < 0) return;
    setsid();
    ioctl(fd, TIOCSCTTY, 1);
    dup2(fd, 0);
    dup2(fd, 1);
    dup2(fd, 2);
    if (fd > 2) close(fd);

    /* A serial console starts in whatever mode the firmware left it. Put it
     * in a sane cooked mode; the Erlang shell switches to raw for editing. */
    struct termios t;
    if (tcgetattr(0, &t) == 0) {
        t.c_iflag |= ICRNL;
        t.c_oflag |= OPOST | ONLCR;
        t.c_lflag |= ISIG | ICANON | ECHO | ECHOE | ECHOK;
        tcsetattr(0, TCSANOW, &t);
    }
}

static void die(const char *why) {
    say("ssi_init: fatal: ");
    say(why);
    say("\nssi_init: rebooting in 10 seconds\n");
    sleep(10);
    reboot(RB_AUTOBOOT);
    for (;;) pause();
}

int main(void) {
    must_mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    must_mount("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    must_mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");
    must_mount("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC,
               "gid=5,mode=620,ptmxmode=666");
    must_mount("tmpfs", "/dev/shm", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    must_mount("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    must_mount("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755");
    attach_console();

    char erts[64] = {0}, rel[64] = {0};
    FILE *f = fopen(SSI_ROOT "/releases/start_erl.data", "r");
    if (!f || fscanf(f, "%63s %63s", erts, rel) != 2) die("no start_erl.data");
    fclose(f);

    char bindir[256], erlexec[256], boot[256], config[256], args[256];
    snprintf(bindir, sizeof bindir, SSI_ROOT "/erts-%s/bin", erts);
    snprintf(erlexec, sizeof erlexec, "%s/erlexec", bindir);
    snprintf(boot, sizeof boot, SSI_ROOT "/releases/%s/start", rel);
    snprintf(config, sizeof config, SSI_ROOT "/releases/%s/sys", rel);
    snprintf(args, sizeof args, SSI_ROOT "/releases/%s/vm.args", rel);

    /* erlexec reads these to locate the emulator; the rest are the variables
     * an Elixir release's own launcher script would have exported. */
    clearenv();
    setenv("ROOTDIR", SSI_ROOT, 1);
    setenv("BINDIR", bindir, 1);
    setenv("EMU", "beam", 1);
    setenv("PROGNAME", "ssi", 1);
    setenv("HOME", "/root", 1);
    setenv("TERM", "vt100", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("PATH", bindir, 1);
    setenv("RELEASE_ROOT", SSI_ROOT, 1);
    setenv("RELEASE_NAME", "ssi", 1);
    setenv("RELEASE_VSN", rel, 1);
    setenv("RELEASE_PROG", "ssi", 1);
    setenv("RELEASE_MODE", "embedded", 1);
    setenv("RELEASE_SYS_CONFIG", config, 1);
    setenv("RELEASE_TMP", "/tmp", 1);
    mkdir("/root", 0700);
    chdir("/root");

    char *const argv[] = {
        erlexec,
        "-boot", boot,
        "-boot_var", "RELEASE_LIB", SSI_ROOT "/lib",
        "-config", config,
        "-args_file", args,
        "-noshell",
        "-mode", "embedded",
        "-user", "elixir",
        "-extra", "--no-halt", "+iex",
        NULL,
    };
    execv(erlexec, argv);
    die("cannot exec the BEAM");
    return 1;
}
