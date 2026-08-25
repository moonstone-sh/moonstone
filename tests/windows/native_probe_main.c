#include <windows.h>
#include <stdio.h>

typedef const char *(__cdecl *native_probe_message_fn)(void);

int main(void) {
    HMODULE library = LoadLibraryA("nativeprobe.dll");
    if (library == NULL) return 1;
    native_probe_message_fn message = (native_probe_message_fn)GetProcAddress(library, "native_probe_message");
    if (message == NULL) return 1;
    puts(message());
    FreeLibrary(library);
    return 0;
}
