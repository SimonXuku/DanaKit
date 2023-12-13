//
//  DanaPacketBase.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 10/12/2023.
//  Copyright © 2023 Randall Knutson. All rights reserved.
//

struct DanaGeneratePacket {
    let type: UInt8? = nil
    let opCode: UInt8
    let data: Data?
}

struct DanaParsePacket<T> {
    let success: Bool
    var notifyType: UInt8? = nil
    let data: T?
}

let TypeIndex = 0;
let OpCodeIndex = 1;
let DataStart = 2;