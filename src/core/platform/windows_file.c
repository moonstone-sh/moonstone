#include <windows.h>
#include <stdint.h>
#include <stdlib.h>

int moonstone_file_exists_w(const wchar_t *path, DWORD *out_error) {
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        *out_error = GetLastError();
        return 0;
    }

    *out_error = ERROR_SUCCESS;
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

int moonstone_read_file_w(const wchar_t *path, char **out_bytes, size_t *out_len, size_t limit, DWORD *out_error) {
    *out_error = ERROR_SUCCESS;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        *out_error = GetLastError();
        return 0;
    }

    LARGE_INTEGER size;
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 0 || (unsigned long long)size.QuadPart > limit) {
        *out_error = size.QuadPart < 0 || (unsigned long long)size.QuadPart > limit ? ERROR_FILE_TOO_LARGE : GetLastError();
        CloseHandle(file);
        return 0;
    }

    size_t length = (size_t)size.QuadPart;
    char *bytes = malloc(length == 0 ? 1 : length);
    if (bytes == NULL) {
        *out_error = ERROR_NOT_ENOUGH_MEMORY;
        CloseHandle(file);
        return 0;
    }

    size_t offset = 0;
    while (offset < length) {
        DWORD chunk = (DWORD)((length - offset) > UINT32_MAX ? UINT32_MAX : (length - offset));
        DWORD read = 0;
        if (!ReadFile(file, bytes + offset, chunk, &read, NULL) || read == 0) {
            *out_error = GetLastError();
            free(bytes);
            CloseHandle(file);
            return 0;
        }
        offset += read;
    }
    CloseHandle(file);

    *out_bytes = bytes;
    *out_len = length;
    return 1;
}

void moonstone_free_file_w(char *bytes) {
    free(bytes);
}
