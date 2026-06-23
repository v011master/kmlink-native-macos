#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *g_log_file = NULL;

static FILE *log_stream(void) {
    if (g_log_file != NULL) {
        return g_log_file;
    }

    const char *path = getenv("OTI_SENDDATA_LOG");
    if (path != NULL && path[0] != '\0') {
        g_log_file = fopen(path, "a");
    }
    if (g_log_file == NULL) {
        g_log_file = stderr;
    }
    return g_log_file;
}

static void log_line(const char *text) {
    FILE *stream = log_stream();
    fputs(text, stream);
    fflush(stream);
}

typedef int (*OTiSendDataFn)(const void *);
typedef int (*TransporterSendDataFn)(void *, const void *, unsigned char);

__attribute__((constructor))
static void logger_loaded(void) {
    log_line("OTI_SENDDATA logger loaded\n");
}

static void dump_prefix(const uint8_t *bytes, size_t count) {
    FILE *stream = log_stream();
    size_t limit = count < 64 ? count : 64;
    for (size_t index = 0; index < limit; index++) {
        fprintf(stream, "%02X", bytes[index]);
    }
}

static uint32_t read_le_u32(const uint8_t *bytes) {
    return (uint32_t)bytes[0]
        | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16)
        | ((uint32_t)bytes[3] << 24);
}

static uint32_t read_be_u32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24)
        | ((uint32_t)bytes[1] << 16)
        | ((uint32_t)bytes[2] << 8)
        | (uint32_t)bytes[3];
}

static void dump_ascii_excerpt(const uint8_t *bytes, size_t count) {
    FILE *stream = log_stream();
    size_t limit = count < 192 ? count : 192;
    fputs(" ascii=\"", stream);
    for (size_t index = 0; index < limit; index++) {
        uint8_t byte = bytes[index];
        if (byte >= 32 && byte <= 126) {
            fputc((int)byte, stream);
        } else {
            fputc('.', stream);
        }
    }
    fputs("\"\n", stream);
}

static void dump_xml_excerpt(const uint8_t *bytes, size_t count) {
    FILE *stream = log_stream();
    const uint8_t *xml = memchr(bytes, '<', count);
    if (xml == NULL) {
        return;
    }

    size_t max_len = (size_t)(bytes + count - xml);
    if (max_len > 256) {
        max_len = 256;
    }

    fputs(" xml=\"", stream);
    for (size_t index = 0; index < max_len; index++) {
        uint8_t byte = xml[index];
        if (byte == '\n' || byte == '\r' || byte == '\t') {
            fputc(' ', stream);
        } else if (byte >= 32 && byte <= 126) {
            fputc((int)byte, stream);
        } else {
            fputc('.', stream);
        }
    }
    fputs("\"\n", stream);
}

static void log_payload(const char *label, const void *payload, int maybe_dummy) {
    FILE *stream = log_stream();
    if (payload == NULL) {
        fprintf(stream, "%s payload=NULL dummy=%d\n", label, maybe_dummy);
    } else {
        const uint8_t *bytes = (const uint8_t *)payload;
        fprintf(stream, "%s payload=non-null dummy=%d prefix=", label, maybe_dummy);
        dump_prefix(bytes, 0xFFEC);
        fputc('\n', stream);

        uint32_t packet_serial = read_le_u32(bytes + 0);
        uint32_t session_id = read_le_u32(bytes + 4);
        uint32_t chunk_index = read_le_u32(bytes + 8);
        uint32_t chunk_total = read_le_u32(bytes + 12);
        uint32_t command_length = read_le_u32(bytes + 16);
        fprintf(
            stream,
            " header packetSerial=%u sessionID=%u chunk=%u/%u commandLength=%u\n",
            packet_serial,
            session_id,
            chunk_index,
            chunk_total,
            command_length
        );

        if (command_length >= 5 && command_length < 0xFFEC) {
            const uint8_t *command = bytes + 20;
            uint8_t command_id = command[0];
            uint32_t xml_length = read_be_u32(command + 1);
            fprintf(stream, " command id=0x%02X xmlLength=%u\n", command_id, xml_length);
            dump_ascii_excerpt(command, command_length);
            if (command_id == 0x39 && xml_length <= command_length - 5) {
                dump_xml_excerpt(command + 5, xml_length);
            } else {
                dump_xml_excerpt(command, command_length);
            }
        } else {
            dump_ascii_excerpt(bytes + 20, 128);
        }
    }
    fflush(stream);
}

int OTi_SendData(const void *payload) {
    static OTiSendDataFn next = NULL;
    if (next == NULL) {
        next = (OTiSendDataFn)dlsym(RTLD_NEXT, "OTi_SendData");
    }

    log_payload("OTI_SENDDATA_C", payload, -1);

    if (next == NULL) {
        fprintf(log_stream(), "OTI_SENDDATA next=NULL\n");
        return -1;
    }
    int result = next(payload);
    fprintf(log_stream(), "OTI_SENDDATA result=%d\n", result);
    fflush(log_stream());
    return result;
}

int OTiTransporter_SendData(void *self, const void *payload, unsigned char is_dummy)
    __asm__("__ZN14OTiTransporter8SendDataEPKhb");

int OTiTransporter_SendData(void *self, const void *payload, unsigned char is_dummy) {
    static TransporterSendDataFn next = NULL;
    if (next == NULL) {
        next = (TransporterSendDataFn)dlsym(RTLD_NEXT, "__ZN14OTiTransporter8SendDataEPKhb");
    }

    log_payload("OTI_SENDDATA_CPP", payload, (int)is_dummy);

    if (next == NULL) {
        fprintf(log_stream(), "OTI_SENDDATA_CPP next=NULL self=%p\n", self);
        fflush(log_stream());
        return -1;
    }

    int result = next(self, payload, is_dummy);
    fprintf(log_stream(), "OTI_SENDDATA_CPP result=%d self=%p dummy=%u\n", result, self, (unsigned)is_dummy);
    fflush(log_stream());
    return result;
}
