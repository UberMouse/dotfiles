/* op-1p-shim -- runs the 1Password CLI under a name worth showing in a prompt.
 *
 * WHY THIS EXISTS
 * 1Password's authorization dialog ("Allow X to get CLI access") names the
 * process it believes is calling `op`, and remembers the grant against it. On
 * Linux the actual security check is unrelated -- it is the `onepassword-cli`
 * GID of the socket peer -- so that name is purely an identity label, resolved
 * from the process tree. op-cached-daemon is Python, so the dialog used to read
 * "/nix/store/...-python3-3.13.14/bin/python3.13": useless to anyone reading it,
 * and it pinned one shared grant to the interpreter every caller runs under.
 *
 * WHICH ANCESTOR DOES IT PICK?
 * Not the direct parent -- that was measured, not assumed. An earlier version of
 * this shim was `op`'s direct parent and the dialog still named python3.13. The
 * daemon it sat under was, at the same time, the session leader, the process
 * group leader, AND the root of its process tree (start_new_session plus
 * reparenting to init), so any of those rules would explain the result and this
 * one observation cannot separate them.
 *
 * Rather than guess, this shim makes itself ALL of them, so it wins whichever
 * rule 1Password actually applies:
 *   1. fork, and let the intermediate parent exit    -> reparented to init, so
 *                                                       it roots its own tree
 *   2. setsid                                        -> session AND process
 *                                                       group leader
 *   3. fork `op` from there and wait for it          -> `op`'s direct parent
 * Merely exec'ing `op` would satisfy none of them: exec replaces this image, so
 * the tree would look exactly as if the shim were never here.
 *
 * The double fork means the daemon's Popen returns as soon as step 1 completes,
 * long before `op` finishes, so the exit status cannot come back through
 * waitpid. It is written to a caller-supplied fd instead; `op`'s own stdout and
 * stderr are inherited untouched and the daemon reads them to EOF.
 *
 * Usage: op-1p-<caller> STATUS_FD COMMAND [ARG...]
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

static void write_status(int fd, int code)
{
    char buf[16];
    int n = snprintf(buf, sizeof buf, "%d\n", code);
    if (n > 0)
        (void)!write(fd, buf, (size_t)n);
    close(fd);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "%s: usage: %s STATUS_FD COMMAND [ARG...]\n",
                argv[0], argv[0]);
        return 2;
    }

    char *end = NULL;
    long status_fd = strtol(argv[1], &end, 10);
    if (!end || *end != '\0' || status_fd < 0) {
        fprintf(stderr, "%s: bad STATUS_FD %s\n", argv[0], argv[1]);
        return 2;
    }

    /* Step 1: orphan ourselves so init adopts us and we root our own tree. */
    pid_t outer = fork();
    if (outer < 0) {
        perror("op-1p-shim: fork");
        write_status((int)status_fd, 127);
        return 1;
    }
    if (outer > 0)
        _exit(0);   /* _exit, not exit: the child owns the inherited stdio */

    /* Step 2: lead our own session and process group. */
    if (setsid() < 0)
        perror("op-1p-shim: setsid");   /* not fatal; keep going */

    /* Step 3: become the direct parent of `op`. */
    pid_t child = fork();
    if (child < 0) {
        perror("op-1p-shim: fork");
        write_status((int)status_fd, 127);
        _exit(1);
    }
    if (child == 0) {
        execvp(argv[2], &argv[2]);
        perror("op-1p-shim: exec");
        _exit(127);
    }

    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            perror("op-1p-shim: waitpid");
            write_status((int)status_fd, 127);
            _exit(1);
        }
    }

    int code = 1;
    if (WIFEXITED(status))
        code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status))
        code = 128 + WTERMSIG(status);

    write_status((int)status_fd, code);
    _exit(code);
}
