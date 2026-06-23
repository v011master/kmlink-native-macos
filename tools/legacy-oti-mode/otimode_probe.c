#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int OTi_Open(void);
extern int OTi_Close(void);
extern int OTi_ReadDevicesInfo(CFArrayRef *);
extern int OTi_GetDeviceMode(unsigned char *);
extern int OTi_SetDeviceMode(unsigned char);
extern int OTi_GetFunctionType(unsigned char *);
extern int OTi_GetSideType(unsigned char *);

static void print_usage(const char *argv0) {
    fprintf(stderr, "usage: %s [--set-mode 0|1] [--keep-open]\n", argv0);
}

static void register_framework_bundle(const char *argv0) {
    char framework_path[2048];
    snprintf(
        framework_path,
        sizeof(framework_path),
        "%s/../../Frameworks/OTiTransfer.framework",
        argv0
    );

    CFStringRef path = CFStringCreateWithCString(NULL, framework_path, kCFStringEncodingUTF8);
    if (path == NULL) {
        return;
    }
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, path, kCFURLPOSIXPathStyle, true);
    CFRelease(path);
    if (url == NULL) {
        return;
    }

    CFBundleRef bundle = CFBundleCreate(NULL, url);
    CFRelease(url);
    if (bundle == NULL) {
        return;
    }

    if (!CFBundleIsExecutableLoaded(bundle)) {
        CFBundleLoadExecutable(bundle);
    }
    CFRelease(bundle);
}

static void print_cfarray_summary(CFArrayRef array) {
    if (array == NULL) {
        printf("devices.count: 0\n");
        return;
    }

    CFIndex count = CFArrayGetCount(array);
    printf("devices.count: %ld\n", (long)count);

    for (CFIndex index = 0; index < count; index++) {
        const void *value = CFArrayGetValueAtIndex(array, index);
        if (value == NULL || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
            printf("devices[%ld].type: unexpected\n", (long)index);
            continue;
        }

        CFDictionaryRef dict = (CFDictionaryRef)value;
        CFStringRef description = CFCopyDescription(dict);
        if (description == NULL) {
            printf("devices[%ld].description: <none>\n", (long)index);
            continue;
        }

        char buffer[1024];
        if (CFStringGetCString(description, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            printf("devices[%ld].description: %s\n", (long)index, buffer);
        } else {
            printf("devices[%ld].description: <utf8-failed>\n", (long)index);
        }
        CFRelease(description);
    }
}

int main(int argc, char **argv) {
    int requested_set_mode = -1;
    int keep_open = 0;

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--set-mode") == 0) {
            if (index + 1 >= argc) {
                print_usage(argv[0]);
                return 2;
            }
            requested_set_mode = atoi(argv[++index]);
            if (requested_set_mode != 0 && requested_set_mode != 1) {
                fprintf(stderr, "invalid mode: %d\n", requested_set_mode);
                return 2;
            }
        } else if (strcmp(argv[index], "--keep-open") == 0) {
            keep_open = 1;
        } else {
            print_usage(argv[0]);
            return 2;
        }
    }

    register_framework_bundle(argv[0]);

    CFArrayRef devices = NULL;
    int devices_result = OTi_ReadDevicesInfo(&devices);
    printf("readDevices.result: %d\n", devices_result);
    print_cfarray_summary(devices);

    int open_result = OTi_Open();
    printf("open.result: %d\n", open_result);
    if (!open_result) {
        if (devices != NULL) {
            CFRelease(devices);
        }
        return 1;
    }

    unsigned char function_type = 0xFF;
    unsigned char side_type = 0xFF;
    unsigned char mode_before = 0xFF;
    int function_result = OTi_GetFunctionType(&function_type);
    int side_result = OTi_GetSideType(&side_type);
    int mode_before_result = OTi_GetDeviceMode(&mode_before);

    printf("functionType.result: %d\n", function_result);
    printf("functionType.value: %u\n", (unsigned)function_type);
    printf("sideType.result: %d\n", side_result);
    printf("sideType.value: %u\n", (unsigned)side_type);
    printf("modeBefore.result: %d\n", mode_before_result);
    printf("modeBefore.value: %u\n", (unsigned)mode_before);

    if (requested_set_mode != -1) {
        int set_result = OTi_SetDeviceMode((unsigned char)requested_set_mode);
        unsigned char mode_after = 0xFF;
        int mode_after_result = OTi_GetDeviceMode(&mode_after);
        printf("setMode.requested: %d\n", requested_set_mode);
        printf("setMode.result: %d\n", set_result);
        printf("modeAfter.result: %d\n", mode_after_result);
        printf("modeAfter.value: %u\n", (unsigned)mode_after);
    }

    if (!keep_open) {
        int close_result = OTi_Close();
        printf("close.result: %d\n", close_result);
    }

    if (devices != NULL) {
        CFRelease(devices);
    }
    return 0;
}
