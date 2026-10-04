/*
 * ssi_sys_nif — the Linux system calls the BEAM has no portable API for.
 *
 * Each function is a thin, policy-free wrapper; deciding *when* to mount a
 * filesystem, which address an interface gets, or which module a device needs
 * is Elixir's job (SSI.Sys and its callers). Blocking calls run on dirty I/O
 * schedulers. Errors return {error, Errno} with Errno an atom such as enoent.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/klog.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <termios.h>
#include <unistd.h>

#include <erl_nif.h>

static ERL_NIF_TERM atom_ok, atom_error;

static ERL_NIF_TERM errno_term(ErlNifEnv *env, int err) {
    char name[32];
    const char *s;
    switch (err) {
    case ENOENT: s = "enoent"; break;
    case EEXIST: s = "eexist"; break;
    case EBUSY: s = "ebusy"; break;
    case EINVAL: s = "einval"; break;
    case EPERM: s = "eperm"; break;
    case EACCES: s = "eacces"; break;
    case ENODEV: s = "enodev"; break;
    case ENOTDIR: s = "enotdir"; break;
    case ENOEXEC: s = "enoexec"; break;
    case ENOMEM: s = "enomem"; break;
    case ENXIO: s = "enxio"; break;
    case ESRCH: s = "esrch"; break;
    case ENETUNREACH: s = "enetunreach"; break;
    default:
        snprintf(name, sizeof name, "errno_%d", err);
        s = name;
    }
    return enif_make_tuple2(env, atom_error, enif_make_atom(env, s));
}

/* Copy an iolist/binary argument into a NUL-terminated C string. An empty
 * binary maps to NULL so callers can omit optional mount arguments. */
static int cstr(ErlNifEnv *env, ERL_NIF_TERM t, char *buf, size_t len, char **out) {
    ErlNifBinary b;
    if (!enif_inspect_iolist_as_binary(env, t, &b) || b.size >= len) return 0;
    memcpy(buf, b.data, b.size);
    buf[b.size] = 0;
    *out = b.size ? buf : NULL;
    return 1;
}

static ERL_NIF_TERM nif_mount(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char src[256], dst[256], type[64], data[512];
    char *psrc, *pdst, *ptype, *pdata;
    unsigned long flags;
    if (!cstr(env, argv[0], src, sizeof src, &psrc) ||
        !cstr(env, argv[1], dst, sizeof dst, &pdst) ||
        !cstr(env, argv[2], type, sizeof type, &ptype) ||
        !enif_get_ulong(env, argv[3], &flags) ||
        !cstr(env, argv[4], data, sizeof data, &pdata) || !pdst)
        return enif_make_badarg(env);
    if (mount(psrc ? psrc : "none", pdst, ptype, flags, pdata) != 0)
        return errno_term(env, errno);
    return atom_ok;
}

static ERL_NIF_TERM nif_umount(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char dst[256];
    char *pdst;
    if (!cstr(env, argv[0], dst, sizeof dst, &pdst) || !pdst) return enif_make_badarg(env);
    if (umount2(pdst, MNT_DETACH) != 0) return errno_term(env, errno);
    return atom_ok;
}

static ERL_NIF_TERM nif_reboot(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char how[16];
    int cmd;
    if (!enif_get_atom(env, argv[0], how, sizeof how, ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    if (!strcmp(how, "restart")) cmd = RB_AUTOBOOT;
    else if (!strcmp(how, "poweroff")) cmd = RB_POWER_OFF;
    else if (!strcmp(how, "halt")) cmd = RB_HALT_SYSTEM;
    else return enif_make_badarg(env);
    sync();
    reboot(cmd);
    return errno_term(env, errno);
}

static ERL_NIF_TERM nif_sync(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    sync();
    return atom_ok;
}

static ERL_NIF_TERM nif_sethostname(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char name[65];
    char *p;
    if (!cstr(env, argv[0], name, sizeof name, &p) || !p) return enif_make_badarg(env);
    if (sethostname(p, strlen(p)) != 0) return errno_term(env, errno);
    return atom_ok;
}

static int ifreq_for(ErlNifEnv *env, ERL_NIF_TERM t, struct ifreq *ifr) {
    char name[IFNAMSIZ];
    char *p;
    memset(ifr, 0, sizeof *ifr);
    if (!cstr(env, t, name, sizeof name, &p) || !p) return 0;
    strncpy(ifr->ifr_name, p, IFNAMSIZ - 1);
    return 1;
}

static int get_ipv4(ErlNifEnv *env, ERL_NIF_TERM t, struct sockaddr *sa) {
    ErlNifBinary b;
    struct sockaddr_in *in = (struct sockaddr_in *)sa;
    if (!enif_inspect_binary(env, t, &b) || b.size != 4) return 0;
    memset(in, 0, sizeof *in);
    in->sin_family = AF_INET;
    memcpy(&in->sin_addr, b.data, 4);
    return 1;
}

/* if_up(Name, Up) — set or clear IFF_UP. */
static ERL_NIF_TERM nif_if_up(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    struct ifreq ifr;
    int up, fd, rc = 0;
    if (!ifreq_for(env, argv[0], &ifr) || !enif_get_int(env, argv[1], &up))
        return enif_make_badarg(env);
    if ((fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)) < 0) return errno_term(env, errno);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) {
        if (up) ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
        else ifr.ifr_flags &= ~IFF_UP;
        rc = ioctl(fd, SIOCSIFFLAGS, &ifr);
    } else {
        rc = -1;
    }
    int err = errno;
    close(fd);
    return rc ? errno_term(env, err) : atom_ok;
}

/* if_set_ipv4(Name, <<A,B,C,D>>, <<Mask:4/binary>>) */
static ERL_NIF_TERM nif_if_set_ipv4(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    struct ifreq ifr;
    int fd, rc;
    if (!ifreq_for(env, argv[0], &ifr)) return enif_make_badarg(env);
    if ((fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)) < 0) return errno_term(env, errno);
    rc = !get_ipv4(env, argv[1], &ifr.ifr_addr) ? -2 : ioctl(fd, SIOCSIFADDR, &ifr);
    if (rc == 0)
        rc = !get_ipv4(env, argv[2], &ifr.ifr_netmask) ? -2 : ioctl(fd, SIOCSIFNETMASK, &ifr);
    int err = errno;
    close(fd);
    if (rc == -2) return enif_make_badarg(env);
    return rc ? errno_term(env, err) : atom_ok;
}

/* route_add(Name, <<Dest>>, <<Mask>>, <<Gateway>>) — gateway 0.0.0.0 means on-link. */
static ERL_NIF_TERM nif_route_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    struct rtentry rt;
    char dev[IFNAMSIZ];
    char *pdev;
    int fd, rc;
    memset(&rt, 0, sizeof rt);
    if (!cstr(env, argv[0], dev, sizeof dev, &pdev) || !pdev ||
        !get_ipv4(env, argv[1], &rt.rt_dst) || !get_ipv4(env, argv[2], &rt.rt_genmask) ||
        !get_ipv4(env, argv[3], &rt.rt_gateway))
        return enif_make_badarg(env);
    rt.rt_flags = RTF_UP;
    if (((struct sockaddr_in *)&rt.rt_gateway)->sin_addr.s_addr) rt.rt_flags |= RTF_GATEWAY;
    rt.rt_dev = pdev;
    if ((fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)) < 0) return errno_term(env, errno);
    rc = ioctl(fd, SIOCADDRT, &rt);
    int err = errno;
    close(fd);
    return rc && err != EEXIST ? errno_term(env, err) : atom_ok;
}

/* finit_module(Path, Params) — load a kernel module from the initramfs. */
static ERL_NIF_TERM nif_finit_module(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char path[512], params[256];
    char *ppath, *pparams;
    if (!cstr(env, argv[0], path, sizeof path, &ppath) || !ppath ||
        !cstr(env, argv[1], params, sizeof params, &pparams))
        return enif_make_badarg(env);
    int fd = open(ppath, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno_term(env, errno);
    long rc = syscall(SYS_finit_module, fd, pparams ? pparams : "", 0);
    int err = errno;
    close(fd);
    if (rc != 0 && err != EEXIST) return errno_term(env, err);
    return atom_ok;
}

/* statvfs(Path) -> {ok, {BlockSize, Blocks, Free, Available}} */
static ERL_NIF_TERM nif_statvfs(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char path[512];
    char *p;
    struct statvfs s;
    if (!cstr(env, argv[0], path, sizeof path, &p) || !p) return enif_make_badarg(env);
    if (statvfs(p, &s) != 0) return errno_term(env, errno);
    return enif_make_tuple2(env, atom_ok,
        enif_make_tuple4(env, enif_make_uint64(env, s.f_frsize),
                         enif_make_uint64(env, s.f_blocks),
                         enif_make_uint64(env, s.f_bfree),
                         enif_make_uint64(env, s.f_bavail)));
}

/* open_tty(Path) -> {ok, Fd}: a terminal in cooked mode for an Erlang fd
 * port. The kernel line discipline does editing and echo; signals are off
 * (there is no process group to signal), CR/LF are mapped both ways. */
static ERL_NIF_TERM nif_open_tty(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char path[256];
    char *p;
    struct termios t;
    if (!cstr(env, argv[0], path, sizeof path, &p) || !p) return enif_make_badarg(env);
    int fd = open(p, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno_term(env, errno);
    if (tcgetattr(fd, &t) == 0) {
        t.c_iflag |= ICRNL;
        t.c_iflag &= ~(IXON | INLCR | IGNCR);
        t.c_oflag |= OPOST | ONLCR;
        t.c_lflag |= ICANON | ECHO | ECHOE | ECHOK;
        t.c_lflag &= ~ISIG;
        tcsetattr(fd, TCSANOW, &t);
    }
    return enif_make_tuple2(env, atom_ok, enif_make_int(env, fd));
}

/* dmesg() -> binary: the kernel ring buffer (syslog(2) READ_ALL). */
static ERL_NIF_TERM nif_dmesg(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    int size = klogctl(10, NULL, 0); /* SYSLOG_ACTION_SIZE_BUFFER */
    if (size <= 0) size = 1 << 17;
    ERL_NIF_TERM bin;
    unsigned char *buf = enif_make_new_binary(env, (size_t)size, &bin);
    int n = klogctl(3, (char *)buf, size); /* SYSLOG_ACTION_READ_ALL */
    if (n < 0) return errno_term(env, errno);
    return enif_make_sub_binary(env, bin, 0, (size_t)n);
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");
    return 0;
}

static ErlNifFunc funcs[] = {
    {"raw_mount", 5, nif_mount, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"umount", 1, nif_umount, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"reboot", 1, nif_reboot, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"sync", 0, nif_sync, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"sethostname", 1, nif_sethostname, 0},
    {"if_up", 2, nif_if_up, 0},
    {"if_set_ipv4", 3, nif_if_set_ipv4, 0},
    {"route_add", 4, nif_route_add, 0},
    {"finit_module", 2, nif_finit_module, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"statvfs", 1, nif_statvfs, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"dmesg", 0, nif_dmesg, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"open_tty", 1, nif_open_tty, 0},
};

ERL_NIF_INIT(Elixir.SSI.Sys, funcs, load, NULL, NULL, NULL)
