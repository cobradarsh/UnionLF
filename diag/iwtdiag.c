/*
 * iwtdiag: a look at the whole phone for one stretch of time, from a root shell.
 *
 *   iwtdiag [seconds]        (default 20)
 *
 * It answers the questions "which processes are burning CPU", "into how many processes is a
 * given tweak library loaded" and "how much power is the phone drawing", so that the same
 * numbers can be read with the original IWantTranslucent installed and with the lean rebuild.
 *
 * For every process it reads:
 *   - CPU time and wake-ups used during the stretch            (proc_pid_rusage)
 *   - the code signing flags, CS_DEBUGGED among them           (csops)
 *     RootHide's patch loader asks for that flag (JIT) in every process into which a converted
 *     rootless tweak is loaded; a native RootHide build never does
 *   - whether the process is traced                            (proc_pidinfo)
 *   - which tweak libraries are mapped into it                 (proc_pidinfo, file-backed regions)
 * and for the phone: thermal pressure level, battery temperature, current, voltage and, where
 * the battery reports it, the power telemetry (system load).
 *
 * Nothing is changed anywhere; the tool only reads. Not part of the package: it is copied to
 * the phone, run, and deleted again (tools/phone.sh diag).
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
#include <errno.h>
#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/param.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <CoreFoundation/CoreFoundation.h>

/* libproc and csops: in libSystem on iOS, but their headers are not in the iOS SDK */
int proc_listallpids(void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

/* IOKit: the framework is in the SDK, its headers are not */
typedef mach_port_t iwt_io_object_t;
CFMutableDictionaryRef IOServiceMatching(const char *name);
iwt_io_object_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
CFTypeRef IORegistryEntryCreateCFProperty(iwt_io_object_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options);
kern_return_t IOObjectRelease(iwt_io_object_t object);

#define IWT_CS_OPS_STATUS        0
#define IWT_CS_VALID             0x00000001u
#define IWT_CS_GET_TASK_ALLOW    0x00000004u
#define IWT_CS_PLATFORM_BINARY   0x04000000u
#define IWT_CS_DEBUGGED          0x10000000u

#ifndef PROC_PIDREGIONPATHINFO2
#define PROC_PIDREGIONPATHINFO2 22
#endif
#ifndef PROC_FLAG_TRACED
#define PROC_FLAG_TRACED 2
#endif

#define MAX_PIDS 4096

enum { LIB_TWEAK = 1, LIB_AUTOPATCH = 2, LIB_PATCHLOADER = 4, LIB_HOOKLIB = 8 };

struct sample {
    int pid;
    uint64_t cpu;            /* user + system, in mach time units */
    uint64_t wakeups;
    uint64_t energy;         /* nJ billed to the process, where the kernel keeps count */
};

struct row {
    int pid;
    char name[64];
    double cpu_ms;
    uint64_t wakeups;
    double energy_mj;
    uint32_t csflags;
    int have_csflags;
    int traced;
    int libs;                /* LIB_* */
    int other_tweaks;        /* other libraries from a DynamicLibraries folder */
    int scanned;
};

static mach_timebase_info_data_t gTimebase;

static double mach_to_ms(uint64_t t) {
    return (double)t * (double)gTimebase.numer / (double)gTimebase.denom / 1e6;
}

static int read_usage(int pid, struct sample *s) {
    struct rusage_info_v4 ri;
    memset(&ri, 0, sizeof(ri));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
    s->pid = pid;
    s->cpu = ri.ri_user_time + ri.ri_system_time;
    s->wakeups = ri.ri_pkg_idle_wkups + ri.ri_interrupt_wkups;
    s->energy = ri.ri_billed_energy;
    return 0;
}

static int take_samples(struct sample *out, int max) {
    static int pids[MAX_PIDS];
    int n = proc_listallpids(pids, (int)sizeof(pids));
    int count = 0;
    for (int i = 0; i < n && count < max; i++) {
        if (pids[i] <= 0) continue;
        if (read_usage(pids[i], &out[count]) == 0) count++;
    }
    return count;
}

static const struct sample *find_sample(const struct sample *list, int n, int pid) {
    for (int i = 0; i < n; i++) if (list[i].pid == pid) return &list[i];
    return NULL;
}

/* Walks the file-backed mappings below the shared cache and notes the tweak libraries among them. */
static void scan_libraries(struct row *r) {
    uint64_t address = 0;
    char seen[24][96];
    int nseen = 0;
    struct proc_regionwithpathinfo info;
    for (int guard = 0; guard < 4000; guard++) {
        memset(&info, 0, sizeof(info));
        int got = proc_pidinfo(r->pid, PROC_PIDREGIONPATHINFO2, address, &info, (int)sizeof(info));
        if (got <= 0) break;
        r->scanned = 1;
        uint64_t next = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size;
        if (next <= address) break;
        address = next;
        const char *path = info.prp_vip.vip_path;
        if (!path[0]) continue;
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (strstr(base, "IWantTranslucent")) r->libs |= LIB_TWEAK;
        else if (strstr(base, "AutoPatches")) r->libs |= LIB_AUTOPATCH;
        else if (strstr(base, "roothidepatch")) r->libs |= LIB_PATCHLOADER;
        else if (strstr(base, "ellekit") || strstr(base, "CydiaSubstrate") || strstr(base, "libsubstrate")) r->libs |= LIB_HOOKLIB;
        else if (strstr(path, "/DynamicLibraries/")) {
            int known = 0;
            for (int i = 0; i < nseen; i++) if (!strncmp(seen[i], base, sizeof(seen[i]) - 1)) known = 1;
            if (!known && nseen < 24) {
                strlcpy(seen[nseen++], base, sizeof(seen[0]));
                r->other_tweaks++;
            }
        }
    }
}

static int by_cpu(const void *a, const void *b) {
    double d = ((const struct row *)b)->cpu_ms - ((const struct row *)a)->cpu_ms;
    return d > 0 ? 1 : d < 0 ? -1 : 0;
}

static void print_number(const void *key, const void *value, void *context) {
    (void)context;
    if (CFGetTypeID(value) != CFNumberGetTypeID() || CFGetTypeID(key) != CFStringGetTypeID()) return;
    char name[96];
    long long number = 0;
    if (!CFStringGetCString((CFStringRef)key, name, sizeof(name), kCFStringEncodingUTF8)) return;
    CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &number);
    printf(" %s=%lld", name, number);
}

static int battery_number(iwt_io_object_t battery, const char *key, long long *out) {
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef value = IORegistryEntryCreateCFProperty(battery, name, NULL, 0);
    CFRelease(name);
    if (!value) return 0;
    int ok = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) ok = CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, out);
    else if (CFGetTypeID(value) == CFBooleanGetTypeID()) { *out = CFBooleanGetValue((CFBooleanRef)value); ok = 1; }
    CFRelease(value);
    return ok;
}

static void print_power(const char *label) {
    printf("%s:", label);
    int token = 0;
    uint64_t level = 0;
    if (notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK) {
        if (notify_get_state(token, &level) == NOTIFY_STATUS_OK) {
            const char *word = level == 0 ? "nominal" : level <= 10 ? "light" : level <= 20 ? "moderate" : level <= 30 ? "heavy" : "critical";
            printf(" thermal-pressure=%llu(%s)", (unsigned long long)level, word);
        }
        notify_cancel(token);
    }
    iwt_io_object_t battery = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOPMPowerSource"));
    if (!battery) {
        printf(" (no battery service)\n");
        return;
    }
    long long temperature = 0, amperage = 0, voltage = 0, value = 0;
    if (battery_number(battery, "Temperature", &temperature)) printf(" battery=%.2fC", (double)temperature / 100.0);
    int have_amps = battery_number(battery, "InstantAmperage", &amperage);
    int have_volts = battery_number(battery, "Voltage", &voltage);
    if (have_amps) printf(" current=%lldmA", amperage);
    if (have_volts) printf(" voltage=%lldmV", voltage);
    if (have_amps && have_volts) printf(" battery-power=%.0fmW", (double)amperage * (double)voltage / 1000.0);
    if (battery_number(battery, "CurrentCapacity", &value)) printf(" charge=%lld%%", value);
    if (battery_number(battery, "ExternalConnected", &value)) printf(" external=%lld", value);
    if (battery_number(battery, "IsCharging", &value)) printf(" charging=%lld", value);
    printf("\n");
    CFTypeRef telemetry = IORegistryEntryCreateCFProperty(battery, CFSTR("PowerTelemetryData"), NULL, 0);
    if (telemetry) {
        if (CFGetTypeID(telemetry) == CFDictionaryGetTypeID()) {
            printf("%s telemetry:", label);
            CFDictionaryApplyFunction((CFDictionaryRef)telemetry, print_number, NULL);
            printf("\n");
        }
        CFRelease(telemetry);
    }
    IOObjectRelease(battery);
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 20;
    if (seconds < 1) seconds = 1;
    if (seconds > 600) seconds = 600;
    mach_timebase_info(&gTimebase);

    static struct sample before[MAX_PIDS], after[MAX_PIDS];
    static struct row rows[MAX_PIDS];

    time_t now = time(NULL);
    char stamp[64];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", localtime(&now));
    printf("iwtdiag: %s, watching for %d s\n", stamp, seconds);
    print_power("power at start");

    int nbefore = take_samples(before, MAX_PIDS);
    uint64_t t0 = mach_absolute_time();
    sleep((unsigned)seconds);
    int nafter = take_samples(after, MAX_PIDS);
    double wall_ms = mach_to_ms(mach_absolute_time() - t0);
    print_power("power at end");

    int nrows = 0;
    int self = getpid();
    for (int i = 0; i < nafter; i++) {
        struct row *r = &rows[nrows];
        memset(r, 0, sizeof(*r));
        r->pid = after[i].pid;
        const struct sample *old = find_sample(before, nbefore, r->pid);
        uint64_t cpu0 = old ? old->cpu : 0, wake0 = old ? old->wakeups : 0, energy0 = old ? old->energy : 0;
        r->cpu_ms = mach_to_ms(after[i].cpu >= cpu0 ? after[i].cpu - cpu0 : 0);
        r->wakeups = after[i].wakeups >= wake0 ? after[i].wakeups - wake0 : 0;
        r->energy_mj = (double)(after[i].energy >= energy0 ? after[i].energy - energy0 : 0) / 1e6;

        char path[MAXPATHLEN];
        path[0] = 0;
        if (proc_pidpath(r->pid, path, sizeof(path)) > 0) {
            const char *base = strrchr(path, '/');
            strlcpy(r->name, base ? base + 1 : path, sizeof(r->name));
        } else {
            struct proc_bsdinfo bsd;
            if (proc_pidinfo(r->pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd)) == (int)sizeof(bsd)) strlcpy(r->name, bsd.pbi_comm, sizeof(r->name));
            else strlcpy(r->name, "?", sizeof(r->name));
        }
        struct proc_bsdinfo bsd;
        if (proc_pidinfo(r->pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd)) == (int)sizeof(bsd)) r->traced = (bsd.pbi_flags & PROC_FLAG_TRACED) != 0;
        uint32_t flags = 0;
        if (csops(r->pid, IWT_CS_OPS_STATUS, &flags, sizeof(flags)) == 0) {
            r->csflags = flags;
            r->have_csflags = 1;
        }
        if (r->pid != self) scan_libraries(r);
        nrows++;
    }

    double total_ms = 0, total_mj = 0;
    uint64_t total_wakeups = 0;
    int n_tweak = 0, n_autopatch = 0, n_patchloader = 0, n_hooklib = 0, n_debugged = 0, n_traced = 0, n_scanned = 0;
    int n_tweak_debugged = 0, n_plain_debugged = 0;
    for (int i = 0; i < nrows; i++) {
        struct row *r = &rows[i];
        total_ms += r->cpu_ms;
        total_wakeups += r->wakeups;
        total_mj += r->energy_mj;
        n_scanned += r->scanned;
        if (r->libs & LIB_TWEAK) n_tweak++;
        if (r->libs & LIB_AUTOPATCH) n_autopatch++;
        if (r->libs & LIB_PATCHLOADER) n_patchloader++;
        if (r->libs & LIB_HOOKLIB) n_hooklib++;
        if (r->traced) n_traced++;
        if (r->have_csflags && (r->csflags & IWT_CS_DEBUGGED)) {
            n_debugged++;
            if (r->libs & LIB_TWEAK) n_tweak_debugged++; else n_plain_debugged++;
        }
    }

    printf("\n%d processes (%d could be looked into), %.1f s\n", nrows, n_scanned, wall_ms / 1000.0);
    printf("CPU used by all of them: %.0f ms = %.1f%% of one core; wake-ups %llu (%.0f a second)",
           total_ms, wall_ms > 0 ? 100.0 * total_ms / wall_ms : 0, (unsigned long long)total_wakeups,
           wall_ms > 0 ? (double)total_wakeups * 1000.0 / wall_ms : 0);
    if (total_mj > 0) printf("; energy billed %.0f mJ = %.0f mW", total_mj, wall_ms > 0 ? total_mj * 1000.0 / wall_ms : 0);
    printf("\n");
    printf("IWantTranslucent.dylib is mapped into %d processes\n", n_tweak);
    printf("AutoPatches.dylib (RootHide's patch for converted rootless tweaks) is mapped into %d processes\n", n_autopatch);
    printf("RootHide's patch loader is mapped into %d processes\n", n_patchloader);
    printf("a hooking library (ElleKit / CydiaSubstrate) is mapped into %d processes\n", n_hooklib);
    printf("CS_DEBUGGED (the JIT / debugger flag) is set on %d processes: %d of them have IWantTranslucent.dylib, %d do not\n",
           n_debugged, n_tweak_debugged, n_plain_debugged);
    printf("traced processes: %d\n", n_traced);

    qsort(rows, (size_t)nrows, sizeof(rows[0]), by_cpu);
    printf("\nbusiest processes   (D = CS_DEBUGGED, T = traced; libs: iwt = IWantTranslucent, ap = AutoPatches,\n");
    printf("                     pl = patch loader, hook = ElleKit/Substrate, +n = other tweak libraries)\n");
    printf("%7s %9s %6s %8s %-3s %-22s %s\n", "pid", "cpu ms", "%core", "wakeups", "", "libs", "process");
    for (int i = 0; i < nrows && i < 25; i++) {
        struct row *r = &rows[i];
        if (r->cpu_ms < 1.0 && i >= 8) break;
        char libs[64] = "";
        if (r->libs & LIB_TWEAK) strlcat(libs, "iwt ", sizeof(libs));
        if (r->libs & LIB_AUTOPATCH) strlcat(libs, "ap ", sizeof(libs));
        if (r->libs & LIB_PATCHLOADER) strlcat(libs, "pl ", sizeof(libs));
        if (r->libs & LIB_HOOKLIB) strlcat(libs, "hook ", sizeof(libs));
        if (r->other_tweaks) {
            char more[16];
            snprintf(more, sizeof(more), "+%d", r->other_tweaks);
            strlcat(libs, more, sizeof(libs));
        }
        char marks[4] = "";
        if (r->have_csflags && (r->csflags & IWT_CS_DEBUGGED)) strlcat(marks, "D", sizeof(marks));
        if (r->traced) strlcat(marks, "T", sizeof(marks));
        printf("%7d %9.1f %6.1f %8llu %-3s %-22s %s\n", r->pid, r->cpu_ms, wall_ms > 0 ? 100.0 * r->cpu_ms / wall_ms : 0,
               (unsigned long long)r->wakeups, marks, libs, r->name);
    }

    printf("\nprocesses with IWantTranslucent.dylib (D = CS_DEBUGGED, ap = with AutoPatches):\n ");
    int printed = 0;
    for (int i = 0; i < nrows; i++) {
        struct row *r = &rows[i];
        if (!(r->libs & LIB_TWEAK)) continue;
        printf(" %s%s%s", r->name, (r->have_csflags && (r->csflags & IWT_CS_DEBUGGED)) ? "[D]" : "", (r->libs & LIB_AUTOPATCH) ? "[ap]" : "");
        if (++printed % 6 == 0) printf("\n ");
    }
    if (!printed) printf(" (none)");
    printf("\n");
    return 0;
}
