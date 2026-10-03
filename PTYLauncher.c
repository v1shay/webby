#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

// forkpty creates a controlling terminal for interactive shells and TUI apps.
int WBSpawnShell(int *master, int columns, int rows) {
    struct winsize size = {0};
    size.ws_col = (unsigned short)(columns > 0 ? columns : 80);
    size.ws_row = (unsigned short)(rows > 0 ? rows : 24);

    const char *old_path = getenv("PATH");
    const char *prefix = "/opt/homebrew/bin:/usr/local/bin:";
    size_t path_length = strlen(prefix) + (old_path ? strlen(old_path) : 0) + 1;
    char *new_path = malloc(path_length);
    if (!new_path) return -1;
    strcpy(new_path, prefix);
    if (old_path) strcat(new_path, old_path);

    size_t count = 0;
    while (environ[count]) count++;
    char **environment = calloc(count + 4, sizeof(char *));
    if (!environment) { free(new_path); return -1; }
    size_t next = 0;
    for (size_t index = 0; index < count; index++) {
        if (strncmp(environ[index], "PATH=", 5) &&
            strncmp(environ[index], "TERM=", 5) &&
            strncmp(environ[index], "COLORTERM=", 10)) {
            environment[next++] = environ[index];
        }
    }
    char *path_entry = malloc(strlen(new_path) + 6);
    if (!path_entry) { free(environment); free(new_path); return -1; }
    strcpy(path_entry, "PATH=");
    strcat(path_entry, new_path);
    environment[next++] = path_entry;
    environment[next++] = "TERM=xterm-256color";
    environment[next++] = "COLORTERM=truecolor";
    environment[next] = NULL;

    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        char *const arguments[] = {"zsh", "-l", "-i", NULL};
        execve("/bin/zsh", arguments, environment);
        _exit(127);
    }
    int saved_error = errno;
    free(path_entry);
    free(new_path);
    free(environment);
    errno = saved_error;
    return (int)pid;
}
