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

/* A suspended spawn is assigned before its first instruction executes. */
void *moonstone_job_create(void) {
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (!job) return NULL;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        CloseHandle(job);
        return NULL;
    }
    return job;
}
int moonstone_job_assign(void *job, void *process) {
    return AssignProcessToJobObject(job, process) != 0;
}
int moonstone_thread_resume(void *thread) {
    return ResumeThread(thread) != (DWORD)-1;
}
void moonstone_job_close(void *job) { CloseHandle(job); }

int moonstone_process_alive(uint32_t pid) {
    HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (!process) return GetLastError() == ERROR_INVALID_PARAMETER ? 0 : -1;
    DWORD result = WaitForSingleObject(process, 0);
    CloseHandle(process);
    return result == WAIT_TIMEOUT ? 1 : (result == WAIT_OBJECT_0 ? 0 : -1);
}
