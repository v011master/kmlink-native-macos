#ifndef KMLINK_NATIVE_CSCSI_H
#define KMLINK_NATIVE_CSCSI_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>

typedef struct KMLinkSCSIInquiryResult {
    int32_t result;
    int32_t pluginResult;
    int32_t queryResult;
    int32_t exclusiveResult;
    int32_t commandResult;
    uint32_t serviceResponse;
    uint32_t taskStatus;
    uint64_t bytesTransferred;
    uint32_t dataLength;
    uint8_t data[96];
    char method[16];
    char vendor[9];
    char product[17];
    char revision[5];
    char message[256];
} KMLinkSCSIInquiryResult;

typedef struct KMLinkSCSICommandResult {
    int32_t result;
    int32_t pluginResult;
    int32_t queryResult;
    int32_t exclusiveResult;
    int32_t commandResult;
    uint32_t serviceResponse;
    uint32_t taskStatus;
    uint64_t bytesTransferred;
    uint32_t dataLength;
    uint8_t data[512];
    char message[256];
} KMLinkSCSICommandResult;

typedef struct KMLinkSCSICommandSession KMLinkSCSICommandSession;

void KMLinkSCSIInquiry(io_service_t service, KMLinkSCSIInquiryResult *outResult);
void KMLinkSCSICommand(
    io_service_t service,
    const uint8_t *cdb,
    uint8_t cdbLength,
    const uint8_t *payload,
    uint32_t payloadLength,
    uint32_t receiveLength,
    uint8_t direction,
    KMLinkSCSICommandResult *outResult
);
void KMLinkSCSICommandWithDataBuffer(
    io_service_t service,
    const uint8_t *cdb,
    uint8_t cdbLength,
    const uint8_t *payload,
    uint32_t payloadLength,
    uint32_t receiveLength,
    uint8_t direction,
    uint8_t *captureBuffer,
    uint32_t captureCapacity,
    uint32_t *capturedLength,
    KMLinkSCSICommandResult *outResult
);
KMLinkSCSICommandSession *KMLinkSCSISessionOpen(io_service_t service, KMLinkSCSICommandResult *outResult);
void KMLinkSCSISessionClose(KMLinkSCSICommandSession *session);
void KMLinkSCSISessionCommand(
    KMLinkSCSICommandSession *session,
    const uint8_t *cdb,
    uint8_t cdbLength,
    const uint8_t *payload,
    uint32_t payloadLength,
    uint32_t receiveLength,
    uint8_t direction,
    KMLinkSCSICommandResult *outResult
);
void KMLinkSCSISessionCommandWithDataBuffer(
    KMLinkSCSICommandSession *session,
    const uint8_t *cdb,
    uint8_t cdbLength,
    const uint8_t *payload,
    uint32_t payloadLength,
    uint32_t receiveLength,
    uint8_t direction,
    uint8_t *captureBuffer,
    uint32_t captureCapacity,
    uint32_t *capturedLength,
    KMLinkSCSICommandResult *outResult
);

#endif
