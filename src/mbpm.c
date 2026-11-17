/*
 * mbpm -- MUSLBOX binary package manager.
 *
 * Packages are gzip-compressed tarballs (.mbp) containing a `manifest` and a
 * `payload/` tree.  Installs are staged in /tmp, verified with SHA256, then
 * copied atomically into the target root.  A flat-file DB lives at
 * /var/lib/mbpm/installed/<name>/{manifest,files}.
 *
 * Commands: init | list | info <pkg> | files <pkg> | verify <pkg> |
 *           install <file.mbp> | remove <pkg> | query <path>
 * Env: MBPM_ROOT=<dir> or -r <dir> selects an alternative target root.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define LINE_MAX_LEN 1024
#define PATH_MAX_LEN 2048

static char root_path[PATH_MAX_LEN] = "/";

static void die(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "mbpm: ");
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

static int run(const char *fmt, ...) {
	char cmd[PATH_MAX_LEN * 2];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(cmd, sizeof(cmd), fmt, ap);
	va_end(ap);
	if (getenv("MBPM_VERBOSE"))
		printf("  $ %s\n", cmd);
	return system(cmd);
}

static int safe_name(const char *s) {
	if (!s || !*s)
		return 0;
	for (; *s; s++)
		if (!(isalnum((unsigned char)*s) || *s == '_' || *s == '-' ||
		      *s == '.' || *s == '+'))
			return 0;
	return 1;
}

static int safe_path(const char *s) {
	if (!s || !*s || *s == '/')
		return 0;
	if (strstr(s, ".."))
		return 0;
	for (; *s; s++)
		if (!(isalnum((unsigned char)*s) || strchr("._/-+", *s)))
			return 0;
	return 1;
}

static void join(char *out, size_t n, const char *a, const char *b) {
	snprintf(out, n, "%s/%s", a, b);
}

static char *db_dir(const char *name, char *out, size_t n) {
	char base[PATH_MAX_LEN];
	join(base, sizeof(base), root_path, "var/lib/mbpm/installed");
	join(out, n, base, name);
	return out;
}

static void cmd_init(void) {
	char db[PATH_MAX_LEN];
	join(db, sizeof(db), root_path, "var/lib/mbpm/installed");
	if (run("mkdir -p '%s'", db) != 0)
		die("cannot initialise database");
	printf("mbpm: database ready at %s\n", db);
}

static void cmd_list(void) {
	char db[PATH_MAX_LEN];
	join(db, sizeof(db), root_path, "var/lib/mbpm/installed");
	char cmd[PATH_MAX_LEN + 64];
	snprintf(cmd, sizeof(cmd), "ls -1 '%s' 2>/dev/null", db);
	FILE *p = popen(cmd, "r");
	if (!p)
		die("cannot list database");
	char line[LINE_MAX_LEN];
	int count = 0;
	while (fgets(line, sizeof(line), p)) {
		fputs(line, stdout);
		count++;
	}
	pclose(p);
	if (!count)
		printf("(no packages installed)\n");
}

static char *manifest_value(const char *manifest_path, const char *key,
                            char *out, size_t n) {
	FILE *f = fopen(manifest_path, "r");
	if (!f)
		return NULL;
	char line[LINE_MAX_LEN];
	size_t klen = strlen(key);
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
			char *v = line + klen + 1;
			v[strcspn(v, "\r\n")] = '\0';
			snprintf(out, n, "%s", v);
			fclose(f);
			return out;
		}
	}
	fclose(f);
	return NULL;
}

static void cmd_info(const char *name) {
	if (!safe_name(name))
		die("invalid package name");
	char dir[PATH_MAX_LEN], mf[PATH_MAX_LEN];
	db_dir(name, dir, sizeof(dir));
	join(mf, sizeof(mf), dir, "manifest");
	FILE *f = fopen(mf, "r");
	if (!f)
		die("package '%s' is not installed", name);
	char line[LINE_MAX_LEN];
	while (fgets(line, sizeof(line), f))
		fputs(line, stdout);
	fclose(f);
}

static void cmd_files(const char *name) {
	if (!safe_name(name))
		die("invalid package name");
	char dir[PATH_MAX_LEN], fl[PATH_MAX_LEN];
	db_dir(name, dir, sizeof(dir));
	join(fl, sizeof(fl), dir, "files");
	FILE *f = fopen(fl, "r");
	if (!f)
		die("package '%s' is not installed", name);
	char line[LINE_MAX_LEN];
	while (fgets(line, sizeof(line), f))
		fputs(line, stdout);
	fclose(f);
}

static int verify_hashes(const char *manifest_path, const char *base) {
	FILE *f = fopen(manifest_path, "r");
	if (!f)
		die("manifest not found: %s", manifest_path);
	char line[LINE_MAX_LEN];
	int checked = 0, failed = 0;
	while (fgets(line, sizeof(line), f)) {
		char *v = line;
		if (strncmp(v, "SHA256=", 7) != 0)
			continue;
		v += 7;
		char *colon = strchr(v, ':');
		if (!colon)
			continue;
		*colon = '\0';
		char expected[65], rel[PATH_MAX_LEN];
		snprintf(rel, sizeof(rel), "%s", v);
		snprintf(expected, sizeof(expected), "%s", colon + 1);
		rel[strcspn(rel, "\r\n")] = '\0';
		expected[strcspn(expected, "\r\n")] = '\0';
		if (!safe_path(rel)) {
			fprintf(stderr, "mbpm: unsafe path in manifest: %s\n", rel);
			failed++;
			continue;
		}
		char file[PATH_MAX_LEN], cmd[PATH_MAX_LEN * 2];
		join(file, sizeof(file), base, rel);
		snprintf(cmd, sizeof(cmd), "sha256sum '%s' 2>/dev/null | cut -d' ' -f1", file);
		FILE *p = popen(cmd, "r");
		char actual[65] = "";
		if (p && fgets(actual, sizeof(actual), p))
			actual[strcspn(actual, "\r\n")] = '\0';
		if (p)
			pclose(p);
		checked++;
		if (strcmp(actual, expected) != 0) {
			fprintf(stderr, "mbpm: checksum FAIL %s\n", rel);
			failed++;
		}
	}
	fclose(f);
	if (failed)
		die("%d of %d files failed verification", failed, checked);
	printf("mbpm: verified %d file(s)\n", checked);
	return checked;
}

static void cmd_verify(const char *name) {
	if (!safe_name(name))
		die("invalid package name");
	char dir[PATH_MAX_LEN], mf[PATH_MAX_LEN];
	db_dir(name, dir, sizeof(dir));
	join(mf, sizeof(mf), dir, "manifest");
	verify_hashes(mf, root_path);
}

static void cmd_install(const char *pkg) {
	if (!safe_path(pkg) && !strchr(pkg, '/'))
		die("invalid package path");

	char stage[] = "/tmp/mbpm.XXXXXX";
	if (!mkdtemp(stage))
		die("cannot create staging directory");

	char cmd[PATH_MAX_LEN * 3];
	snprintf(cmd, sizeof(cmd), "tar -xzf '%s' -C '%s'", pkg, stage);
	if (run("%s", cmd) != 0) {
		run("rm -rf '%s'", stage);
		die("cannot extract package '%s'", pkg);
	}

	char mf[PATH_MAX_LEN], payload[PATH_MAX_LEN];
	join(mf, sizeof(mf), stage, "manifest");
	join(payload, sizeof(payload), stage, "payload");
	if (access(mf, R_OK) != 0 || access(payload, R_OK) != 0) {
		run("rm -rf '%s'", stage);
		die("malformed package: manifest or payload missing");
	}

	char name[PATH_MAX_LEN];
	if (!manifest_value(mf, "NAME", name, sizeof(name)) || !safe_name(name)) {
		run("rm -rf '%s'", stage);
		die("malformed package: bad NAME in manifest");
	}

	verify_hashes(mf, payload);

	/* Remove destination paths that a previous package may have provided as
	 * symlinks.  cp(1) follows destination symlinks, which would otherwise
	 * write a new file through an old applet link (e.g. /sbin/init -> busybox). */
	{
		FILE *lst = fopen(mf, "r");
		if (lst) {
			char line[LINE_MAX_LEN];
			while (fgets(line, sizeof(line), lst)) {
				char *v = line;
				if (strncmp(v, "SHA256=", 7) != 0)
					continue;
				v += 7;
				char *colon = strchr(v, ':');
				if (!colon)
					continue;
				*colon = '\0';
				v[strcspn(v, "\r\n")] = '\0';
				if (!safe_path(v))
					continue;
				char full[PATH_MAX_LEN];
				join(full, sizeof(full), root_path, v);
				run("rm -f '%s'", full);
			}
			fclose(lst);
		}
	}

	/* Copy payload into the target root. */
	snprintf(cmd, sizeof(cmd), "cp -a '%s'/. '%s'/", payload, root_path);
	if (run("%s", cmd) != 0) {
		run("rm -rf '%s'", stage);
		die("cannot install payload into %s", root_path);
	}

	/* Record the package in the database. */
	char dir[PATH_MAX_LEN], dst_mf[PATH_MAX_LEN], files[PATH_MAX_LEN];
	db_dir(name, dir, sizeof(dir));
	join(files, sizeof(files), dir, "files");
	snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", dir);
	run("%s", cmd);
	join(dst_mf, sizeof(dst_mf), dir, "manifest");
	snprintf(cmd, sizeof(cmd), "cp '%s' '%s'", mf, dst_mf);
	run("%s", cmd);

	/* Build the file list from the manifest SHA256 entries. */
	FILE *in = fopen(mf, "r");
	FILE *out = fopen(files, "w");
	if (in && out) {
		char line[LINE_MAX_LEN];
		while (fgets(line, sizeof(line), in)) {
			char *v = line;
			if (strncmp(v, "SHA256=", 7) != 0)
				continue;
			v += 7;
			char *colon = strchr(v, ':');
			if (!colon)
				continue;
			*colon = '\0';
			fprintf(out, "%s\n", v);
		}
	}
	if (in) fclose(in);
	if (out) fclose(out);

	printf("mbpm: installed %s\n", name);
	run("rm -rf '%s'", stage);
}

static void cmd_remove(const char *name) {
	if (!safe_name(name))
		die("invalid package name");
	char dir[PATH_MAX_LEN], fl[PATH_MAX_LEN];
	db_dir(name, dir, sizeof(dir));
	join(fl, sizeof(fl), dir, "files");
	FILE *f = fopen(fl, "r");
	if (!f)
		die("package '%s' is not installed", name);
	char line[LINE_MAX_LEN];
	while (fgets(line, sizeof(line), f)) {
		char rel[PATH_MAX_LEN], full[PATH_MAX_LEN];
		snprintf(rel, sizeof(rel), "%s", line);
		rel[strcspn(rel, "\r\n")] = '\0';
		if (!safe_path(rel))
			continue;
		join(full, sizeof(full), root_path, rel);
		run("rm -f '%s'", full);
		/* Clean empty parent directories, bottom-up. */
		char path[PATH_MAX_LEN];
		snprintf(path, sizeof(path), "%s", full);
		for (int i = 0; i < 6; i++) {
			char *slash = strrchr(path, '/');
			if (!slash || slash == path)
				break;
			*slash = '\0';
			if (strncmp(path, root_path, strlen(root_path)) != 0)
				break;
			if (run("rmdir '%s' 2>/dev/null", path) != 0)
				break;
		}
	}
	fclose(f);
	run("rm -rf '%s'", dir);
	printf("mbpm: removed %s\n", name);
}

static void cmd_query(const char *path) {
	char base[PATH_MAX_LEN], cmd[PATH_MAX_LEN + 128];
	join(base, sizeof(base), root_path, "var/lib/mbpm/installed");
	snprintf(cmd, sizeof(cmd), "grep -rl -- '%s' '%s' 2>/dev/null | sed 's|.*/installed/||; s|/files$||'",
		 path, base);
	FILE *p = popen(cmd, "r");
	if (!p)
		die("query failed");
	char line[LINE_MAX_LEN];
	int found = 0;
	while (fgets(line, sizeof(line), p)) {
		fputs(line, stdout);
		found = 1;
	}
	pclose(p);
	if (!found)
		printf("(not owned by any package)\n");
}

static void usage(void) {
	printf("Usage: mbpm [-r ROOT] <command> [args]\n"
	       "  init                     initialise package database\n"
	       "  list                     list installed packages\n"
	       "  info <pkg>               show package metadata\n"
	       "  files <pkg>              list files owned by a package\n"
	       "  verify <pkg>             verify installed file checksums\n"
	       "  install <file.mbp>       install a binary package\n"
	       "  remove <pkg>             remove an installed package\n"
	       "  query <path>             find the owner of a path\n");
}

int main(int argc, char **argv) {
	int i = 1;
	if (argc > 1 && strcmp(argv[1], "-r") == 0) {
		if (argc < 3)
			die("-r needs a path");
		snprintf(root_path, sizeof(root_path), "%s", argv[2]);
		i += 2;
	}
	if (getenv("MBPM_ROOT"))
		snprintf(root_path, sizeof(root_path), "%s", getenv("MBPM_ROOT"));
	if (i >= argc) {
		usage();
		return 1;
	}

	const char *cmd = argv[i++];
	if (strcmp(cmd, "init") == 0)
		cmd_init();
	else if (strcmp(cmd, "list") == 0)
		cmd_list();
	else if (strcmp(cmd, "info") == 0 && i < argc)
		cmd_info(argv[i]);
	else if (strcmp(cmd, "files") == 0 && i < argc)
		cmd_files(argv[i]);
	else if (strcmp(cmd, "verify") == 0 && i < argc)
		cmd_verify(argv[i]);
	else if (strcmp(cmd, "install") == 0 && i < argc)
		cmd_install(argv[i]);
	else if (strcmp(cmd, "remove") == 0 && i < argc)
		cmd_remove(argv[i]);
	else if (strcmp(cmd, "query") == 0 && i < argc)
		cmd_query(argv[i]);
	else if (strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0)
		usage();
	else
		die("unknown or incomplete command '%s'", cmd);
	return 0;
}
