//
//  DanaGeneralSetPumpTimeUtcWithTimezone.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 13/12/2023.
//  Copyright © 2023 Randall Knutson. All rights reserved.
//

struct PacketGeneralSetPumpTimeUtcWithTimezone {
    var time: Date
    var zoneOffset: UInt8
}

let CommandGeneralSetPumpTimeUtcWithTimezone =
    (DanaPacketType.TYPE_RESPONSE & 0xff << 8) + (DanaPacketType.OPCODE_OPTION__SET_PUMP_UTC_AND_TIME_ZONE & 0xff)

func generatePacketGeneralSetPumpTimeUtcWithTimezone(options: PacketGeneralSetPumpTimeUtcWithTimezone) -> DanaGeneratePacket {
    var data = Data(count: 7)
    data.addDate(at: 0, date: options.time, usingUTC: true)
    data[6] = (options.zoneOffset < 0 ? 0b10000000 : 0x0) | (options.zoneOffset & 0x7f)

    return DanaGeneratePacket(
        opCode: DanaPacketType.OPCODE_OPTION__SET_PUMP_UTC_AND_TIME_ZONE,
        data: data
    )
}

func parsePacketGeneralSetPumpTimeUtcWithTimezone(data: Data) -> DanaParsePacket<Any?> {
    return DanaParsePacket(
        success: data[DataStart] == 0,
        data: nil
    )
}
