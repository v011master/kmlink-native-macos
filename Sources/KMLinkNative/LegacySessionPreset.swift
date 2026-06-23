import Foundation

enum LegacySessionPreset {
    static let initialA1 = bytes(
        "a101000000000000000000000000000000000003000000004f5356455253494f4e1500000000000000000000"
    )

    static let a4 = bytes(
        "a4080000120012001200120012001200120011001a004d006100630069006e0074006f0073006800200048004400000004002f000000060056004d00000026002f00530079007300740065006d002f0056006f006c0075006d00650073002f0056004d000000100050007200650062006f006f007400000030002f00530079007300740065006d002f0056006f006c0075006d00650073002f0050007200650062006f006f00740000000e0055007000640061007400650000002e002f00530079007300740065006d002f0056006f006c0075006d00650073002f0055007000640061007400650000000a00780041005200540000002c002f00530079007300740065006d002f0056006f006c0075006d00650073002f00780061007200740073000000160069005300430050007200650062006f006f007400000036002f00530079007300740065006d002f0056006f006c0075006d00650073002f0069005300430050007200650062006f006f0074000000120048006100720064007700610072006500000032002f00530079007300740065006d002f0056006f006c0075006d00650073002f004800610072006400770061007200650000000a0068006f006d006500000034002f00530079007300740065006d002f0056006f006c0075006d00650073002f0044006100740061002f0068006f006d00650000"
    )

    static let postDirectoryA1 = bytes(
        "a1040000000000000000000000000000000000000000000000000000000000000000"
    )

    static let a2 = bytes(
        "a200000000c45f8ac00000"
    )

    static let notifySwitchToRemoteXML = #"<OTIMSG><NP_Cmd>Cmd_Notify_KM_Switch_To_Remote</NP_Cmd><NP_Up_Notice_NamePipe_Name>\\.\pipe\OTI_ClipboardAgent</NP_Up_Notice_NamePipe_Name><Param_Move_Out_Info><OTIMSG><Param_Point_Event_Data>00000000000F0000700800000000000000000000000000008007000080070000</Param_Point_Event_Data><Param_Move_Out_Direction>0</Param_Move_Out_Direction><Param_Move_Out_X>1920</Param_Move_Out_X><Param_Move_Out_Y>1080</Param_Move_Out_Y><Param_Move_Out_KM_Switch_Option>2</Param_Move_Out_KM_Switch_Option><Param_Move_Out_Use_Hotkey_Switch_Only>0</Param_Move_Out_Use_Hotkey_Switch_Only><Param_Other_PC_Position_Option>2</Param_Other_PC_Position_Option><Param_Remote_Screen_Width>3840</Param_Remote_Screen_Width><Param_Remote_Screen_Height>2160</Param_Remote_Screen_Height><Param_KM_Setting_Info>&lt;OTIMSG&gt;&lt;Param_Move_Out_Direction&gt;2&lt;/Param_Move_Out_Direction&gt;&lt;Param_Move_Out_KM_Switch_Option&gt;2&lt;/Param_Move_Out_KM_Switch_Option&gt;&lt;Param_Move_Out_Use_Hotkey_Switch_Only&gt;0&lt;/Param_Move_Out_Use_Hotkey_Switch_Only&gt;&lt;/OTIMSG&gt;</Param_KM_Setting_Info></OTIMSG></Param_Move_Out_Info><Param_Clipboard_Info_2></Param_Clipboard_Info_2></OTIMSG>"#

    static func domainFoldersCommand() -> [UInt8] {
        let miscURL = ensureMiscInfoFile()
        let folderRecords: [(id: UInt16, path: String)] = [
            (0, userDirectoryPath(.desktopDirectory)),
            (1, userDirectoryPath(.documentDirectory)),
            (3, userDirectoryPath(.musicDirectory)),
            (4, userDirectoryPath(.picturesDirectory)),
            (2, miscURL.path)
        ]

        var payload: [UInt8] = [0xAD]
        payload.append(contentsOf: UInt16LE(folderRecords.count))

        for record in folderRecords {
            payload.append(contentsOf: [0x0F, 0xF0])
            payload.append(contentsOf: UInt16LE(record.id))
            let pathBytes = utf16LEBytes(record.path, includeTerminator: true)
            payload.append(contentsOf: UInt32LE(pathBytes.count))
            payload.append(contentsOf: pathBytes)
        }

        return payload
    }

    static func localDrivesCommand() -> [UInt8] {
        a4
    }

    private static func userDirectoryPath(_ directory: FileManager.SearchPathDirectory) -> String {
        let url = FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return url.path
    }

    @discardableResult
    private static func ensureMiscInfoFile() -> URL {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("GBMiscInfoFile.xml")
        let computerName = Host.current().localizedName ?? Host.current().name ?? "Mac"
        let wallpaperPath = "/System/Library/Wallpapers/.default/DefaultAerial.heic"
        let xml = """
        <OTIMSG><ComputerName>\(escapeXML(computerName))</ComputerName><WallpaperPath>\(escapeXML(wallpaperPath))</WallpaperPath><ScrollDirection>Normal</ScrollDirection></OTIMSG>
        """
        try? xml.data(using: .utf8)?.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private static func utf16LEBytes(_ string: String, includeTerminator: Bool) -> [UInt8] {
        var data = Array(string.utf16.littleEndianBytes)
        if includeTerminator {
            data.append(contentsOf: [0x00, 0x00])
        }
        return data
    }

    private static func UInt16LE(_ value: Int) -> [UInt8] {
        UInt16(value).littleEndianBytes
    }

    private static func UInt16LE(_ value: UInt16) -> [UInt8] {
        value.littleEndianBytes
    }

    private static func UInt32LE(_ value: Int) -> [UInt8] {
        UInt32(value).littleEndianBytes
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return result
    }
}

private extension Sequence where Element == UInt16 {
    var littleEndianBytes: [UInt8] {
        flatMap { $0.littleEndianBytes }
    }
}

private extension UInt16 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian, Array.init)
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.littleEndian, Array.init)
    }
}
