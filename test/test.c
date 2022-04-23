#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv) {

    for (int i = 1; i < argc; i++) {
        printf("%s", argv[i]);
        if (i != argc - 1) {
            printf(" ");
        }
    }

    char cwd_path[4096];
    getcwd(cwd_path, 4095);
    cwd_path[4095] = 0;
    fprintf(stderr, "%s", cwd_path);

    return 69;
}
