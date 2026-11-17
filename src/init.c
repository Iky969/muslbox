/*
 * MUSLBOX init -- custom PID 1, statically linked against musl.
 *
 * Responsibilities:
 *   - mount proc / sys / devtmpfs / tmpfs
 *   - set hostname, configure the serial console
 *   - bring up loopback and virtio-net with a deterministic QEMU user-net IP
 *   - spawn a shell on /dev/console (no login, fast boot)
 *   - reap orphaned children (SIGCHLD) and handle poweroff/reboot signals
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t pending_signal = 0;

static void on_signal(int sig) {
	if (sig == SIGCHLD) {
		/* Reap every dead child without blocking in the handler. */
		while (waitpid(-1, NULL, WNOHANG) > 0)
			;
		return;
	}
	pending_signal = sig;
}

static void install_handlers(void) {
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
	sigaction(SIGCHLD, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGUSR1, &sa, NULL);
}

static void mount_or_warn(const char *src, const char *dst, const char *type) {
	if (mount(src, dst, type, 0, NULL) == 0) {
		printf("[init] mounted %-9s on %s\n", type, dst);
	} else if (errno != EBUSY) {
		fprintf(stderr, "[init] warn: mount %s on %s: %s\n",
			type, dst, strerror(errno));
	}
}

static void setup_filesystems(void) {
	mkdir("/dev", 0755);
	mkdir("/proc", 0555);
	mkdir("/sys", 0555);
	mkdir("/tmp", 1777);
	mkdir("/run", 0755);
	mount_or_warn("proc", "/proc", "proc");
	mount_or_warn("sysfs", "/sys", "sysfs");
	mount_or_warn("devtmpfs", "/dev", "devtmpfs");
	mount_or_warn("tmpfs", "/tmp", "tmpfs");
	mount_or_warn("tmpfs", "/run", "tmpfs");
}

static void setup_network(void) {
	const char *name = "muslbox";
	sethostname(name, strlen(name));

	/* virtio-net is a module in the Alpine -virt kernel.  Load the small
	 * dependency chain shipped in the `modules` package. */
	system("/sbin/insmod /lib/modules/failover.ko 2>/dev/null");
	system("/sbin/insmod /lib/modules/net_failover.ko 2>/dev/null");
	system("/sbin/insmod /lib/modules/virtio_net.ko 2>/dev/null");

	/* Deterministic QEMU user-mode networking: 10.0.2.15/24 via 10.0.2.2.
	 * udhcpc is shipped in the image for real DHCP deployments. */
	system("/sbin/ip link set lo up 2>/dev/null");
	system("/sbin/ip addr add 10.0.2.15/24 dev eth0 2>/dev/null");
	system("/sbin/ip link set eth0 up 2>/dev/null");
	system("/sbin/ip route add default via 10.0.2.2 2>/dev/null");
	printf("[init] network: eth0 10.0.2.15/24 (QEMU user-net)\n");
}

static pid_t spawn_shell(void) {
	pid_t pid = fork();
	if (pid < 0) {
		perror("[init] fork");
		return -1;
	}
	if (pid == 0) {
		int fd = open("/dev/console", O_RDWR);
		if (fd >= 0) {
			dup2(fd, STDIN_FILENO);
			dup2(fd, STDOUT_FILENO);
			dup2(fd, STDERR_FILENO);
			if (fd > STDERR_FILENO)
				close(fd);
		}
		setsid();
		execl("/bin/sh", "sh", NULL);
		perror("[init] exec /bin/sh");
		_exit(127);
	}
	return pid;
}

int main(void) {
	pid_t shell;

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);

	install_handlers();
	setup_filesystems();
	setup_network();

	printf("\n=== MUSLBOX v0.1.0 (musl static) ===\n");
	printf("[init] pid=%d ppid=%d uname=muslbox\n", getpid(), getppid());

	shell = spawn_shell();
	if (shell > 0) {
		printf("[init] shell pid=%d on /dev/console\n", shell);
		double uptime = 0.0;
		FILE *u = fopen("/proc/uptime", "r");
		if (u) { fscanf(u, "%lf", &uptime); fclose(u); }
		printf("MUSLBOX_SHELL_READY uptime=%.2f\n", uptime);
	}

	/* PID 1 main loop: reap children and honour poweroff/reboot requests. */
	for (;;) {
		if (pending_signal == SIGINT || pending_signal == SIGTERM) {
			printf("[init] poweroff requested\n");
			sync();
			reboot(RB_POWER_OFF);
			pause();
		}
		if (pending_signal == SIGUSR1) {
			printf("[init] reboot requested\n");
			sync();
			reboot(RB_AUTOBOOT);
			pause();
		}
		pause();
	}
	return 0;
}
