#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <wchar.h>

#define HELPER_HOST "127.0.0.1"
#define HELPER_PORT "7999"
#define PIPE_COUNT 10

static void json_escape(const char *input, char *output, size_t output_size) {
    size_t used = 0;
    for (; *input && used + 2 < output_size; ++input) {
        unsigned char c = (unsigned char)*input;
        if (c == '"' || c == '\\') {
            output[used++] = '\\';
            output[used++] = (char)c;
        } else if (c >= 0x20) {
            output[used++] = (char)c;
        }
    }
    output[used] = '\0';
}

static void client_image(DWORD pid, char *path, size_t path_size) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    wchar_t wide_path[32768] = L"";
    DWORD length = (DWORD)(sizeof(wide_path) / sizeof(wide_path[0]));
    if (process && QueryFullProcessImageNameW(process, 0, wide_path, &length)) {
        WideCharToMultiByte(CP_UTF8, 0, wide_path, -1, path, (int)path_size, NULL, NULL);
    } else {
        _snprintf(path, path_size, "Windows PID %lu", (unsigned long)pid);
        path[path_size - 1] = '\0';
    }
    if (process) CloseHandle(process);
}

static void report_client(DWORD pid) {
    char image[32768], escaped[65536], escaped_name[32768], *name, body[70000], request[71000];
    struct addrinfo hints, *result = NULL;
    SOCKET socket_fd = INVALID_SOCKET;

    client_image(pid, image, sizeof(image));
    name = strrchr(image, '\\');
    if (!name) name = strrchr(image, '/');
    name = name ? name + 1 : image;
    json_escape(image, escaped, sizeof(escaped));
    json_escape(name, escaped_name, sizeof(escaped_name));
    _snprintf(body, sizeof(body),
              "{\"id\":\"wine-rpc-%lu\",\"name\":\"%s\",\"pid\":%lu,\"executable\":\"%s\"}",
              (unsigned long)pid, escaped_name, (unsigned long)pid, escaped);
    body[sizeof(body) - 1] = '\0';
    _snprintf(request, sizeof(request),
              "POST /wine-rpc-client HTTP/1.1\r\nHost: " HELPER_HOST ":" HELPER_PORT
              "\r\nContent-Type: application/json\r\nContent-Length: %u\r\nConnection: close\r\n\r\n%s",
              (unsigned)strlen(body), body);
    request[sizeof(request) - 1] = '\0';

    ZeroMemory(&hints, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(HELPER_HOST, HELPER_PORT, &hints, &result) != 0) return;
    socket_fd = socket(result->ai_family, result->ai_socktype, result->ai_protocol);
    if (socket_fd != INVALID_SOCKET && connect(socket_fd, result->ai_addr, (int)result->ai_addrlen) == 0)
        send(socket_fd, request, (int)strlen(request), 0);
    if (socket_fd != INVALID_SOCKET) closesocket(socket_fd);
    freeaddrinfo(result);
    printf("Discord RPC pipe client: PID %lu, %s\n", (unsigned long)pid, image);
}

static DWORD WINAPI serve_pipe(LPVOID parameter) {
    int index = (int)(INT_PTR)parameter;
    wchar_t pipe_name[64];
    _snwprintf(pipe_name, sizeof(pipe_name) / sizeof(pipe_name[0]), L"\\\\.\\pipe\\discord-ipc-%d", index);

    for (;;) {
        HANDLE pipe = CreateNamedPipeW(
            pipe_name, PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, NULL);
        BOOL connected;
        DWORD pid = 0, received = 0;
        char buffer[4096];
        if (pipe == INVALID_HANDLE_VALUE) {
            fprintf(stderr, "CreateNamedPipeW failed for discord-ipc-%d: %lu\n", index, GetLastError());
            Sleep(1000);
            continue;
        }
        connected = ConnectNamedPipe(pipe, NULL) || GetLastError() == ERROR_PIPE_CONNECTED;
        if (connected && GetNamedPipeClientProcessId(pipe, &pid) && pid) {
            report_client(pid);
            while (ReadFile(pipe, buffer, sizeof(buffer), &received, NULL) && received) {
            }
        }
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }
    return 0;
}

int main(void) {
    WSADATA winsock;
    HANDLE threads[PIPE_COUNT];
    int index;
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) return 1;
    puts("Wine Discord RPC pipe watcher started (detector mode).");
    for (index = 0; index < PIPE_COUNT; ++index)
        threads[index] = CreateThread(NULL, 0, serve_pipe, (LPVOID)(INT_PTR)index, 0, NULL);
    WaitForMultipleObjects(PIPE_COUNT, threads, TRUE, INFINITE);
    WSACleanup();
    return 0;
}
