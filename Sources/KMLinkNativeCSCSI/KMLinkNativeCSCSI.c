#include "KMLinkNativeCSCSI.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSICommandOperationCodes.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <stdlib.h>
#include <string.h>

enum {
    kKMLinkSCSIResultSuccess = 0,
    kKMLinkSCSIResultInvalidArgument = -1,
    kKMLinkSCSIResultPluginCreateFailed = -2,
    kKMLinkSCSIResultQueryFailed = -3,
    kKMLinkSCSIResultCommandFailed = -4,
    kKMLinkSCSIResultCreateTaskFailed = -5
};

static void resetResult(KMLinkSCSIInquiryResult *outResult) {
    memset(outResult, 0, sizeof(*outResult));
    outResult->result = kKMLinkSCSIResultInvalidArgument;
    outResult->pluginResult = 0;
    outResult->queryResult = 0;
    outResult->exclusiveResult = 0;
    outResult->commandResult = 0;
    outResult->serviceResponse = 0;
    outResult->taskStatus = 0;
    outResult->bytesTransferred = 0;
    outResult->dataLength = 0;
}

static void resetCommandResult(KMLinkSCSICommandResult *outResult) {
    memset(outResult, 0, sizeof(*outResult));
    outResult->result = kKMLinkSCSIResultInvalidArgument;
}

static void copyTrimmed(char *destination, size_t destinationSize, const char *source, size_t sourceSize) {
    if (destinationSize == 0) {
        return;
    }

    size_t start = 0;
    while (start < sourceSize && source[start] == ' ') {
        start++;
    }

    size_t end = sourceSize;
    while (end > start && source[end - 1] == ' ') {
        end--;
    }

    size_t length = end > start ? end - start : 0;
    if (length >= destinationSize) {
        length = destinationSize - 1;
    }

    if (length > 0) {
        memcpy(destination, source + start, length);
    }
    destination[length] = '\0';
}

static void fillInquiryStrings(KMLinkSCSIInquiryResult *outResult, const uint8_t *data, uint32_t length) {
    if (length < 36) {
        return;
    }

    copyTrimmed(outResult->vendor, sizeof(outResult->vendor), (const char *)(data + 8), 8);
    copyTrimmed(outResult->product, sizeof(outResult->product), (const char *)(data + 16), 16);
    copyTrimmed(outResult->revision, sizeof(outResult->revision), (const char *)(data + 32), 4);
}

struct KMLinkSCSICommandSession {
    MMCDeviceInterface **mmc;
    SCSITaskDeviceInterface **device;
    int didObtainExclusive;
};

static void runCommandOnDevice(
    SCSITaskDeviceInterface **device,
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
) {
    SCSITaskInterface **task = NULL;
    SCSI_Sense_Data sense;
    SCSITaskStatus taskStatus = kSCSITaskStatus_No_Status;
    UInt64 realized = 0;
    uint8_t mutableCDB[kSCSICDBSize_Maximum];
    uint8_t inlineTransferBuffer[512];
    uint8_t *transferBuffer = inlineTransferBuffer;
    uint8_t *allocatedTransferBuffer = NULL;

    if (outResult == NULL) {
        return;
    }
    resetCommandResult(outResult);
    if (capturedLength != NULL) {
        *capturedLength = 0;
    }

    if (device == NULL || cdb == NULL || cdbLength == 0 || cdbLength > kSCSICDBSize_Maximum) {
        strncpy(outResult->message, "invalid command arguments", sizeof(outResult->message) - 1);
        return;
    }
    memset(&sense, 0, sizeof(sense));
    memset(mutableCDB, 0, sizeof(mutableCDB));
    memset(inlineTransferBuffer, 0, sizeof(inlineTransferBuffer));
    memcpy(mutableCDB, cdb, cdbLength);

    uint32_t transferLength = direction == kSCSIDataTransfer_FromInitiatorToTarget ? payloadLength : receiveLength;
    if (transferLength > sizeof(inlineTransferBuffer)) {
        allocatedTransferBuffer = calloc(1, transferLength);
        if (allocatedTransferBuffer == NULL) {
            outResult->result = kKMLinkSCSIResultInvalidArgument;
            strncpy(outResult->message, "transfer allocation failed", sizeof(outResult->message) - 1);
            return;
        }
        transferBuffer = allocatedTransferBuffer;
    }
    if (direction == kSCSIDataTransfer_FromInitiatorToTarget && payload != NULL && transferLength > 0) {
        memcpy(transferBuffer, payload, transferLength);
    }

    task = (*device)->CreateSCSITask(device);
    if (task == NULL) {
        outResult->result = kKMLinkSCSIResultCreateTaskFailed;
        strncpy(outResult->message, "CreateSCSITask failed", sizeof(outResult->message) - 1);
        free(allocatedTransferBuffer);
        return;
    }

    IOReturn kr = (*task)->SetCommandDescriptorBlock(task, mutableCDB, cdbLength);
    if (kr == kIOReturnSuccess && direction != kSCSIDataTransfer_NoDataTransfer && transferLength > 0) {
        SCSITaskSGElement sg = { (mach_vm_address_t)transferBuffer, transferLength };
        kr = (*task)->SetScatterGatherEntries(task, &sg, 1, transferLength, direction);
    }
    if (kr == kIOReturnSuccess) {
        kr = (*task)->SetTimeoutDuration(task, 2000);
    }
    if (kr == kIOReturnSuccess) {
        kr = (*task)->ExecuteTaskSync(task, &sense, &taskStatus, &realized);
    }

    outResult->commandResult = kr;
    outResult->taskStatus = (uint32_t)taskStatus;
    outResult->bytesTransferred = realized;
    SCSIServiceResponse response = 0;
    if ((*task)->GetSCSIServiceResponse(task, &response) == kIOReturnSuccess) {
        outResult->serviceResponse = (uint32_t)response;
    }
    if (
        direction == kSCSIDataTransfer_FromTargetToInitiator &&
        captureBuffer != NULL &&
        captureCapacity > 0 &&
        realized > 0
    ) {
        UInt64 captured = realized < captureCapacity ? realized : captureCapacity;
        memcpy(captureBuffer, transferBuffer, (size_t)captured);
        if (capturedLength != NULL) {
            *capturedLength = (uint32_t)captured;
        }
    }

    if (kr == kIOReturnSuccess && taskStatus == kSCSITaskStatus_GOOD) {
        outResult->result = kKMLinkSCSIResultSuccess;
        UInt64 copiedLength = realized < sizeof(outResult->data) ? realized : sizeof(outResult->data);
        outResult->dataLength = (uint32_t)copiedLength;
        if (direction == kSCSIDataTransfer_FromTargetToInitiator && outResult->dataLength > 0) {
            memcpy(outResult->data, transferBuffer, outResult->dataLength);
        }
        strncpy(outResult->message, "SCSI command succeeded", sizeof(outResult->message) - 1);
    } else {
        outResult->result = kKMLinkSCSIResultCommandFailed;
        strncpy(outResult->message, "SCSI command failed", sizeof(outResult->message) - 1);
    }

    (*task)->Release(task);
    free(allocatedTransferBuffer);
}

static int runMMCInquiry(io_service_t service, KMLinkSCSIInquiryResult *outResult) {
    IOCFPlugInInterface **plugin = NULL;
    MMCDeviceInterface **device = NULL;
    SCSICmd_INQUIRY_StandardData inquiry;
    SCSI_Sense_Data sense;
    SCSITaskStatus taskStatus = kSCSITaskStatus_No_Status;
    SInt32 score = 0;

    memset(&inquiry, 0, sizeof(inquiry));
    memset(&sense, 0, sizeof(sense));
    strncpy(outResult->method, "MMC", sizeof(outResult->method) - 1);

    IOReturn kr = IOCreatePlugInInterfaceForService(
        service,
        kIOMMCDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    outResult->pluginResult = kr;
    if (kr != kIOReturnSuccess || plugin == NULL) {
        outResult->result = kKMLinkSCSIResultPluginCreateFailed;
        strncpy(outResult->message, "MMC plugin creation failed", sizeof(outResult->message) - 1);
        return 0;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID),
        (LPVOID *)&device
    );
    outResult->queryResult = (int32_t)hr;
    (*plugin)->Release(plugin);

    if (hr != S_OK || device == NULL) {
        outResult->result = kKMLinkSCSIResultQueryFailed;
        strncpy(outResult->message, "MMC QueryInterface failed", sizeof(outResult->message) - 1);
        return 0;
    }

    kr = (*device)->Inquiry(device, &inquiry, sizeof(inquiry), &taskStatus, &sense);
    outResult->commandResult = kr;
    outResult->taskStatus = (uint32_t)taskStatus;
    if (kr == kIOReturnSuccess && taskStatus == kSCSITaskStatus_GOOD) {
        outResult->result = kKMLinkSCSIResultSuccess;
        outResult->serviceResponse = kSCSIServiceResponse_TASK_COMPLETE;
        outResult->bytesTransferred = sizeof(inquiry);
        outResult->dataLength = sizeof(inquiry);
        memcpy(outResult->data, &inquiry, sizeof(inquiry));
        fillInquiryStrings(outResult, outResult->data, outResult->dataLength);
        strncpy(outResult->message, "MMC INQUIRY succeeded", sizeof(outResult->message) - 1);
    } else {
        outResult->result = kKMLinkSCSIResultCommandFailed;
        strncpy(outResult->message, "MMC INQUIRY failed", sizeof(outResult->message) - 1);
    }

    (*device)->Release(device);
    return outResult->result == kKMLinkSCSIResultSuccess;
}

static int runSCSITaskInquiry(io_service_t service, KMLinkSCSIInquiryResult *outResult) {
    IOCFPlugInInterface **plugin = NULL;
    SCSITaskDeviceInterface **device = NULL;
    SCSITaskInterface **task = NULL;
    SCSI_Sense_Data sense;
    SCSITaskStatus taskStatus = kSCSITaskStatus_No_Status;
    UInt64 realized = 0;
    SInt32 score = 0;
    int didObtainExclusive = 0;
    uint8_t buffer[96];
    uint8_t cdb[6] = { kSCSICmd_INQUIRY, 0, 0, 0, sizeof(buffer), 0 };

    memset(&sense, 0, sizeof(sense));
    memset(buffer, 0, sizeof(buffer));
    resetResult(outResult);
    strncpy(outResult->method, "SCSITask", sizeof(outResult->method) - 1);

    IOReturn kr = IOCreatePlugInInterfaceForService(
        service,
        kIOSCSITaskDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    outResult->pluginResult = kr;
    if (kr != kIOReturnSuccess || plugin == NULL) {
        outResult->result = kKMLinkSCSIResultPluginCreateFailed;
        strncpy(outResult->message, "SCSITask plugin creation failed", sizeof(outResult->message) - 1);
        return 0;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID),
        (LPVOID *)&device
    );
    outResult->queryResult = (int32_t)hr;
    (*plugin)->Release(plugin);

    if (hr != S_OK || device == NULL) {
        outResult->result = kKMLinkSCSIResultQueryFailed;
        strncpy(outResult->message, "SCSITask QueryInterface failed", sizeof(outResult->message) - 1);
        return 0;
    }

    kr = (*device)->ObtainExclusiveAccess(device);
    outResult->exclusiveResult = kr;
    if (kr != kIOReturnSuccess) {
        outResult->result = kKMLinkSCSIResultCommandFailed;
        strncpy(outResult->message, "SCSITask exclusive access failed", sizeof(outResult->message) - 1);
        (*device)->Release(device);
        return 0;
    }
    didObtainExclusive = 1;

    task = (*device)->CreateSCSITask(device);
    if (task == NULL) {
        outResult->result = kKMLinkSCSIResultCreateTaskFailed;
        strncpy(outResult->message, "CreateSCSITask failed", sizeof(outResult->message) - 1);
        if (didObtainExclusive) {
            (*device)->ReleaseExclusiveAccess(device);
        }
        (*device)->Release(device);
        return 0;
    }

    kr = (*task)->SetCommandDescriptorBlock(task, cdb, kSCSICDBSize_6Byte);
    if (kr == kIOReturnSuccess) {
        SCSITaskSGElement sg = { (mach_vm_address_t)buffer, sizeof(buffer) };
        kr = (*task)->SetScatterGatherEntries(
            task,
            &sg,
            1,
            sizeof(buffer),
            kSCSIDataTransfer_FromTargetToInitiator
        );
    }
    if (kr == kIOReturnSuccess) {
        kr = (*task)->SetTimeoutDuration(task, 1000);
    }
    if (kr == kIOReturnSuccess) {
        kr = (*task)->ExecuteTaskSync(task, &sense, &taskStatus, &realized);
    }

    outResult->commandResult = kr;
    outResult->taskStatus = (uint32_t)taskStatus;
    outResult->bytesTransferred = realized;
    SCSIServiceResponse response = 0;
    if ((*task)->GetSCSIServiceResponse(task, &response) == kIOReturnSuccess) {
        outResult->serviceResponse = (uint32_t)response;
    }

    if (kr == kIOReturnSuccess && taskStatus == kSCSITaskStatus_GOOD) {
        outResult->result = kKMLinkSCSIResultSuccess;
        outResult->dataLength = (uint32_t)((realized < sizeof(buffer)) ? realized : sizeof(buffer));
        memcpy(outResult->data, buffer, outResult->dataLength);
        fillInquiryStrings(outResult, outResult->data, outResult->dataLength);
        strncpy(outResult->message, "SCSITask INQUIRY succeeded", sizeof(outResult->message) - 1);
    } else {
        outResult->result = kKMLinkSCSIResultCommandFailed;
        strncpy(outResult->message, "SCSITask INQUIRY failed", sizeof(outResult->message) - 1);
    }

    (*task)->Release(task);
    if (didObtainExclusive) {
        (*device)->ReleaseExclusiveAccess(device);
    }
    (*device)->Release(device);
    return outResult->result == kKMLinkSCSIResultSuccess;
}

void KMLinkSCSIInquiry(io_service_t service, KMLinkSCSIInquiryResult *outResult) {
    if (outResult == NULL) {
        return;
    }
    resetResult(outResult);

    if (service == 0) {
        strncpy(outResult->message, "invalid io_service_t", sizeof(outResult->message) - 1);
        return;
    }

    if (runMMCInquiry(service, outResult)) {
        return;
    }

    KMLinkSCSIInquiryResult scsiResult;
    runSCSITaskInquiry(service, &scsiResult);
    if (scsiResult.result == kKMLinkSCSIResultSuccess || scsiResult.result != kKMLinkSCSIResultPluginCreateFailed) {
        *outResult = scsiResult;
    }
}

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
) {
    if (outResult == NULL) {
        return;
    }
    resetCommandResult(outResult);

    if (service == 0 || cdb == NULL || cdbLength == 0 || cdbLength > kSCSICDBSize_Maximum) {
        strncpy(outResult->message, "invalid command arguments", sizeof(outResult->message) - 1);
        return;
    }

    IOCFPlugInInterface **plugin = NULL;
    MMCDeviceInterface **mmc = NULL;
    SCSITaskDeviceInterface **device = NULL;
    SInt32 score = 0;
    int didObtainExclusive = 0;

    IOReturn kr = IOCreatePlugInInterfaceForService(
        service,
        kIOMMCDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    outResult->pluginResult = kr;
    if (kr != kIOReturnSuccess || plugin == NULL) {
        outResult->result = kKMLinkSCSIResultPluginCreateFailed;
        strncpy(outResult->message, "MMC plugin creation failed", sizeof(outResult->message) - 1);
        return;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID),
        (LPVOID *)&mmc
    );
    outResult->queryResult = (int32_t)hr;
    (*plugin)->Release(plugin);
    if (hr != S_OK || mmc == NULL) {
        outResult->result = kKMLinkSCSIResultQueryFailed;
        strncpy(outResult->message, "MMC QueryInterface failed", sizeof(outResult->message) - 1);
        return;
    }

    device = (*mmc)->GetSCSITaskDeviceInterface(mmc);
    if (device == NULL) {
        outResult->result = kKMLinkSCSIResultQueryFailed;
        strncpy(outResult->message, "GetSCSITaskDeviceInterface failed", sizeof(outResult->message) - 1);
        (*mmc)->Release(mmc);
        return;
    }

    kr = (*device)->ObtainExclusiveAccess(device);
    outResult->exclusiveResult = kr;
    if (kr != kIOReturnSuccess) {
        outResult->result = kKMLinkSCSIResultCommandFailed;
        strncpy(outResult->message, "exclusive access failed", sizeof(outResult->message) - 1);
        (*mmc)->Release(mmc);
        return;
    }
    didObtainExclusive = 1;

    runCommandOnDevice(
        device,
        cdb,
        cdbLength,
        payload,
        payloadLength,
        receiveLength,
        direction,
        captureBuffer,
        captureCapacity,
        capturedLength,
        outResult
    );

    if (didObtainExclusive) {
        (*device)->ReleaseExclusiveAccess(device);
    }
    (*mmc)->Release(mmc);
}

void KMLinkSCSICommand(
    io_service_t service,
    const uint8_t *cdb,
    uint8_t cdbLength,
    const uint8_t *payload,
    uint32_t payloadLength,
    uint32_t receiveLength,
    uint8_t direction,
    KMLinkSCSICommandResult *outResult
) {
    KMLinkSCSICommandWithDataBuffer(
        service,
        cdb,
        cdbLength,
        payload,
        payloadLength,
        receiveLength,
        direction,
        NULL,
        0,
        NULL,
        outResult
    );
}

KMLinkSCSICommandSession *KMLinkSCSISessionOpen(io_service_t service, KMLinkSCSICommandResult *outResult) {
    if (outResult != NULL) {
        resetCommandResult(outResult);
    }

    if (service == 0) {
        if (outResult != NULL) {
            strncpy(outResult->message, "invalid io_service_t", sizeof(outResult->message) - 1);
        }
        return NULL;
    }

    IOCFPlugInInterface **plugin = NULL;
    MMCDeviceInterface **mmc = NULL;
    SCSITaskDeviceInterface **device = NULL;
    SInt32 score = 0;

    IOReturn kr = IOCreatePlugInInterfaceForService(
        service,
        kIOMMCDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    if (outResult != NULL) {
        outResult->pluginResult = kr;
    }
    if (kr != kIOReturnSuccess || plugin == NULL) {
        if (outResult != NULL) {
            outResult->result = kKMLinkSCSIResultPluginCreateFailed;
            strncpy(outResult->message, "MMC plugin creation failed", sizeof(outResult->message) - 1);
        }
        return NULL;
    }

    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID),
        (LPVOID *)&mmc
    );
    if (outResult != NULL) {
        outResult->queryResult = (int32_t)hr;
    }
    (*plugin)->Release(plugin);
    if (hr != S_OK || mmc == NULL) {
        if (outResult != NULL) {
            outResult->result = kKMLinkSCSIResultQueryFailed;
            strncpy(outResult->message, "MMC QueryInterface failed", sizeof(outResult->message) - 1);
        }
        return NULL;
    }

    device = (*mmc)->GetSCSITaskDeviceInterface(mmc);
    if (device == NULL) {
        if (outResult != NULL) {
            outResult->result = kKMLinkSCSIResultQueryFailed;
            strncpy(outResult->message, "GetSCSITaskDeviceInterface failed", sizeof(outResult->message) - 1);
        }
        (*mmc)->Release(mmc);
        return NULL;
    }

    kr = (*device)->ObtainExclusiveAccess(device);
    if (outResult != NULL) {
        outResult->exclusiveResult = kr;
    }
    if (kr != kIOReturnSuccess) {
        if (outResult != NULL) {
            outResult->result = kKMLinkSCSIResultCommandFailed;
            strncpy(outResult->message, "exclusive access failed", sizeof(outResult->message) - 1);
        }
        (*mmc)->Release(mmc);
        return NULL;
    }

    KMLinkSCSICommandSession *session = calloc(1, sizeof(KMLinkSCSICommandSession));
    if (session == NULL) {
        if (outResult != NULL) {
            outResult->result = kKMLinkSCSIResultInvalidArgument;
            strncpy(outResult->message, "session allocation failed", sizeof(outResult->message) - 1);
        }
        (*device)->ReleaseExclusiveAccess(device);
        (*mmc)->Release(mmc);
        return NULL;
    }

    session->mmc = mmc;
    session->device = device;
    session->didObtainExclusive = 1;
    if (outResult != NULL) {
        outResult->result = kKMLinkSCSIResultSuccess;
        strncpy(outResult->message, "SCSI session opened", sizeof(outResult->message) - 1);
    }
    return session;
}

void KMLinkSCSISessionClose(KMLinkSCSICommandSession *session) {
    if (session == NULL) {
        return;
    }

    if (session->device != NULL && session->didObtainExclusive) {
        (*session->device)->ReleaseExclusiveAccess(session->device);
    }
    if (session->mmc != NULL) {
        (*session->mmc)->Release(session->mmc);
    }
    free(session);
}

void KMLinkSCSISessionCommand(
    KMLinkSCSICommandSession *session,
    const uint8_t *cdb,
    uint8_t cdbLength,
    const uint8_t *payload,
    uint32_t payloadLength,
    uint32_t receiveLength,
    uint8_t direction,
    KMLinkSCSICommandResult *outResult
) {
    KMLinkSCSISessionCommandWithDataBuffer(
        session,
        cdb,
        cdbLength,
        payload,
        payloadLength,
        receiveLength,
        direction,
        NULL,
        0,
        NULL,
        outResult
    );
}

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
) {
    if (outResult == NULL) {
        return;
    }
    resetCommandResult(outResult);
    if (capturedLength != NULL) {
        *capturedLength = 0;
    }
    if (session == NULL || session->device == NULL) {
        strncpy(outResult->message, "invalid SCSI session", sizeof(outResult->message) - 1);
        return;
    }

    runCommandOnDevice(
        session->device,
        cdb,
        cdbLength,
        payload,
        payloadLength,
        receiveLength,
        direction,
        captureBuffer,
        captureCapacity,
        capturedLength,
        outResult
    );
}
