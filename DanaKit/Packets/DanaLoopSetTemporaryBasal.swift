//
//  DanaLoopSetTemporaryBasal.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 13/12/2023.
//  Copyright © 2023 Randall Knutson. All rights reserved.
//

struct PacketLoopSetTemporaryBasal {
    var percent: UInt16
}

struct TemporaryBasalDuration {
    static let PARAM_30_MIN: UInt8 = 160
    static let PARAM_15_MIN: UInt8 = 150
}

let CommandLoopSetTemporaryBasal = (DanaPacketType.TYPE_RESPONSE & 0xff << 8) + (DanaPacketType.OPCODE_BASAL__APS_SET_TEMPORARY_BASAL & 0xff)

func generatePacketLoopSetTemporaryBasal(options: PacketLoopSetTemporaryBasal) -> DanaGeneratePacket {
    var percent = options.percent

    if percent > 500 {
        percent = 500
    }

    let data = Data([
        UInt8(percent & 0xff),
        UInt8((percent >> 8) & 0xff),
        UInt8((percent < 100 ? TemporaryBasalDuration.PARAM_30_MIN : TemporaryBasalDuration.PARAM_15_MIN) & 0xff),
    ])

    return DanaGeneratePacket(
        opCode: DanaPacketType.OPCODE_BASAL__APS_SET_TEMPORARY_BASAL,
        data: data
    )
}

func parsePacketLoopSetTemporaryBasal(data: Data) -> DanaParsePacket<Any?> {
    return DanaParsePacket(
        success: data[DataStart] == 0,
        data: nil
    )
}
