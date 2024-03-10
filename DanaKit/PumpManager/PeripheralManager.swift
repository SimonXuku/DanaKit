//
//  PeripheralManager.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 21/12/2023.
//  Copyright © 2023 Randall Knutson. All rights reserved.
//

import CoreBluetooth
import os.log
import SwiftUI

class PeripheralManager: NSObject {
    private let log = Logger(category: "PeripheralManager")
    
    private let connectedDevice: CBPeripheral
    private let bluetoothManager: BluetoothManager
    private var completion: (Error?) -> Void
    
    private var pumpManager: DanaKitPumpManager
    private var readBuffer = Data([])
    
    private let okCharCodes: [UInt8] = [0x4f, 0x4b] // O, K
    private let pumpCharCodes: [UInt8] = [0x50, 0x55, 0x4d, 0x50] // P, U, M, P
    private let busyCharCodes: [UInt8] = [0x42, 0x55, 0x53, 0x59] // B, U, S, Y
    
    private let PACKET_START_BYTE: UInt8 = 0xa5
    private let PACKET_END_BYTE: UInt8 = 0x5a
    private let ENCRYPTED_START_BYTE: UInt8 = 0xaa
    private let ENCRYPTED_END_BYTE: UInt8 = 0xee
    
    public static let SERVICE_UUID = CBUUID(string: "FFF0")
    private let READ_CHAR_UUID = CBUUID(string: "FFF1")
    private var readCharacteristic: CBCharacteristic!
    private let WRITE_CHAR_UUID = CBUUID(string: "FFF2")
    private var writeCharacteristic: CBCharacteristic!
    
    private var writeQueue: Dictionary<UInt8, (Timer, CheckedContinuation<(any DanaParsePacketProtocol), Error>)> = [:]
    
    private var historyLog: [HistoryItem] = []
    
    private var encryptionMode: EncryptionType = .DEFAULT {
        didSet {
            DanaRSEncryption.setEnhancedEncryption(encryptionMode.rawValue)
        }
    }
    
    private var deviceName: String {
        get {
            return self.pumpManager.state.deviceName ?? ""
        }
    }
    
    public init(_ peripheral: CBPeripheral, _ bluetoothManager: BluetoothManager, _ pumpManager: DanaKitPumpManager,_ completion: @escaping (Error?) -> Void) {
        self.connectedDevice = peripheral
        self.encryptionMode = .DEFAULT
        self.bluetoothManager = bluetoothManager
        self.pumpManager = pumpManager
        self.completion = completion
        
        super.init()
        
        peripheral.delegate = self
    }
    
    func writeMessage(_ packet: DanaGeneratePacket) async throws -> (any DanaParsePacketProtocol)  {
        let command = (UInt16((packet.type ?? DanaPacketType.TYPE_RESPONSE)) << 8) + UInt16(packet.opCode)
        guard self.writeQueue[packet.opCode] == nil else {
            throw NSError(domain: "This command is already running. Please wait", code: 0, userInfo: nil)
        }
        
        let isHistoryPacket = self.isHistoryPacket(opCode: command)
        if (isHistoryPacket && !self.pumpManager.state.isInFetchHistoryMode) {
            throw NSError(domain: "Pump is not in history fetch mode", code: 0, userInfo: nil)
        }
        
        // Make sure we have the correct state
        if (packet.opCode == CommandGeneralSetHistoryUploadMode && packet.data != nil) {
            self.pumpManager.state.isInFetchHistoryMode = packet.data![0] == 0x01
        } else {
            self.pumpManager.state.isInFetchHistoryMode = false
        }
        
        
        var data = DanaRSEncryption.encodePacket(operationCode: packet.opCode, buffer: packet.data, deviceName: self.deviceName)
//        log.info("\(#function): Encrypted data: \(data.base64EncodedString())")
        
        if (self.encryptionMode != .DEFAULT) {
            data = DanaRSEncryption.encodeSecondLevel(data: data)
//            log.info("\(#function): Second level encrypted data: \(data.base64EncodedString())")
        }
        
        // Now schedule a 6 sec timeout (or 21 when in fetchHistoryMode) for the pump to send its message back
        // This timeout will be cancelled by `processMessage` once it received the message
        // If this timeout expired, disconnect from the pump and prompt an error...
        return try await withCheckedThrowingContinuation { continuation in
            let sendingTimer = Timer.scheduledTimer(withTimeInterval: !isHistoryPacket ? 6 : 21, repeats: false) { _ in
                guard let queueItem = self.writeQueue[packet.opCode] else {
                    return
                }
                
                queueItem.1.resume(throwing: NSError(domain: "Message write timeout", code: 0, userInfo: nil))
                self.writeQueue[packet.opCode] = nil
            }
            
            self.writeQueue[packet.opCode] = (sendingTimer, continuation)
            
            while (data.count != 0) {
                let end = min(20, data.count)
                let message = data.subdata(in: 0..<end)
                
                self.writeQ(message)
                data = data.subdata(in: end..<data.count)
            }
        }
    }
}

extension PeripheralManager : CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            log.error("\(#function): \(error!.localizedDescription)")
            self.bluetoothManager.disconnect(peripheral)
            
            DispatchQueue.main.async {
                self.completion(error!)
            }
            return
        }
        
        let service = peripheral.services?.first(where: { $0.uuid == PeripheralManager.SERVICE_UUID })
        if (service == nil) {
            log.error("\(#function): Failed to discover dana data service...")
            self.bluetoothManager.disconnect(peripheral)
            
            DispatchQueue.main.async {
                self.completion(NSError(domain: "Failed to discover dana data service...", code: 0, userInfo: nil))
            }
            return
        }
        
//        log.info("\(#function): Discovered service \(SERVICE_UUID)")
        
        peripheral.discoverCharacteristics([READ_CHAR_UUID, WRITE_CHAR_UUID], for: service!)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log.error("\(#function): \(error!.localizedDescription)")
            self.bluetoothManager.disconnect(peripheral)
            
            DispatchQueue.main.async {
                self.completion(error!)
            }
            return
        }
        
        let service = peripheral.services!.first(where: { $0.uuid == PeripheralManager.SERVICE_UUID })!
        self.readCharacteristic = service.characteristics?.first(where: { $0.uuid == READ_CHAR_UUID })
        self.writeCharacteristic = service.characteristics?.first(where: { $0.uuid == WRITE_CHAR_UUID })
        
        if (self.writeCharacteristic == nil || self.readCharacteristic == nil) {
            log.error("\(#function): Failed to discover dana write or read characteristic")
            self.bluetoothManager.disconnect(peripheral)
            
            DispatchQueue.main.async {
                self.completion(NSError(domain: "Failed to discover dana write or read characteristic", code: 0, userInfo: nil))
            }
            return
        }
        
//        log.info("\(#function): Discovered characteristics \(READ_CHAR_UUID) and \(WRITE_CHAR_UUID)")
        peripheral.setNotifyValue(true, for: self.readCharacteristic)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?)  {
        guard error == nil else {
            log.error("\(#function): \(error!.localizedDescription)")
            self.bluetoothManager.disconnect(peripheral)
            
            DispatchQueue.main.async {
                self.completion(error!)
            }
            return
        }
        
//        log.info("\(#function): Notifications has been enabled. Sending starting handshake")
        self.sendFirstMessageEncryption()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            log.error("\(#function): \(error!.localizedDescription)")
            self.bluetoothManager.disconnect(peripheral)
            
            DispatchQueue.main.async {
                self.completion(error!)
            }
            return
        }
        
        guard let data = characteristic.value else {
            return
        }
        
//        log.info("\(#function): Receiving data: \(data.base64EncodedString())")
        self.parseReceivedValue(data)
    }
    
    private func writeQ(_ data: Data) {
//        log.info("\(#function): Writing data \(data.base64EncodedString())")
        self.connectedDevice.writeValue(data, for: self.writeCharacteristic, type: .withoutResponse)
    }
}

// MARK: - Encryption/Connection functions
extension PeripheralManager {
    private func sendFirstMessageEncryption() {
        let data = DanaRSEncryption.encodePacket(operationCode: DanaPacketType.OPCODE_ENCRYPTION__PUMP_CHECK, buffer: nil, deviceName: self.deviceName)
        
//        log.info("\(#function): Sending Initial encryption request. Data: \(data.base64EncodedString())")
        self.writeQ(data)
    }
    
    private func sendTimeInfo() {
        let data = DanaRSEncryption.encodePacket(operationCode: DanaPacketType.OPCODE_ENCRYPTION__TIME_INFORMATION, buffer: nil, deviceName: self.deviceName)
        
//        log.info("\(#function): Sending normal time information. Data: \(data.base64EncodedString())")
        self.writeQ(data)
    }
    
    private func sendV3PairingInformation(_ requestNewPairing: UInt8) {
        let data = DanaRSEncryption.encodePacket(operationCode: DanaPacketType.OPCODE_ENCRYPTION__TIME_INFORMATION, buffer: Data([requestNewPairing]), deviceName: self.deviceName)
        
//        log.info("\(#function): Sending RSv3 time information. Data: \(data.base64EncodedString())")
        self.writeQ(data)
    }
    
    private func sendV3PairingInformationEmpty() {
        let (pairingKey, randomPairingKey) = DanaRSEncryption.getPairingKeys()
        
        let command: UInt8 = pairingKey.count == 0 || randomPairingKey.count == 0 ? 1 : 0
        self.sendV3PairingInformation(command)
    }
    
    private func sendPairingRequest() {
        let data = DanaRSEncryption.encodePacket(operationCode: DanaPacketType.OPCODE_ENCRYPTION__PASSKEY_REQUEST, buffer: nil, deviceName: self.deviceName)
        
//        log.info("\(#function): Sending pairing request. Data: \(data.base64EncodedString())")
        self.writeQ(data)
    }
    
    private func sendEasyMenuCheck() {
        let data = DanaRSEncryption.encodePacket(operationCode: DanaPacketType.OPCODE_ENCRYPTION__GET_EASYMENU_CHECK, buffer: nil, deviceName: self.deviceName)
        
//        log.info("\(#function): Sending easy menu check. Data: \(data.base64EncodedString())")
        self.writeQ(data)
    }
    
    private func sendBLE5PairingInformation() {
        let data = DanaRSEncryption.encodePacket(operationCode: DanaPacketType.OPCODE_ENCRYPTION__TIME_INFORMATION, buffer: Data([0, 0, 0, 0]), deviceName: self.deviceName)
        
//        log.info("\(#function): Sending BLE5 time information. Data: \(Data([0, 0, 0, 0]).base64EncodedString())")
        self.writeQ(data)
    }
    
    private func sendPassKeyCheck(_ pairingKey: Data) {
        let data = DanaRSEncryption.encodePacket(operationCode: DanaPacketType.OPCODE_ENCRYPTION__CHECK_PASSKEY, buffer: pairingKey, deviceName: self.deviceName)
        
//        log.info("\(#function): Sending Passkey check. Data: \(data.base64EncodedString())")
        self.writeQ(data)
    }
    
    /// Used after entering PIN codes (only for DanaRS v3)
    private func finishV3Pairing(_ pairingKey: Data, _ randomPairingKey: Data) {
        log.info("\(#function): Storing security keys: Pairing key: \(pairingKey.base64EncodedString()), random pairing key: \(randomPairingKey.base64EncodedString())")
        DanaRSEncryption.setPairingKeys(pairingKey: pairingKey, randomPairingKey: randomPairingKey, randomSyncKey: 0)
        self.sendV3PairingInformation(0)
    }
    
    private func processEasyMenuCheck(_ data: Data) {
        if (self.encryptionMode == .RSv3) {
            self.sendV3PairingInformationEmpty()
        } else {
            self.sendTimeInfo()
        }
    }
    
    private func processPairingRequest(_ data: Data) {
        if (data[2] == 0x00) {
            // Everything is order. Waiting for pump to send OPCODE_ENCRYPTION__PASSKEY_RETURN
            return
        }
        
        log.error("\(#function): Passkey request failed. Data: \(data.base64EncodedString())")
        self.bluetoothManager.disconnect(self.connectedDevice)
        
        DispatchQueue.main.async {
            self.completion(NSError(domain: "Passkey request failed", code: 0, userInfo: nil))
        }
    }
    
    private func processPairingRequest2(_ data: Data) {
        self.sendTimeInfo()
        
        let pairingKey = data.subdata(in: 2..<4)
        DanaRSEncryption.setPairingKeys(pairingKey: pairingKey, randomPairingKey: Data(), randomSyncKey: 0)
    }
    
    private func processConnectResponse(_ data: Data) {
        if (data.count == 4 && self.isOk(data)) {
            // response OK v1
            self.encryptionMode = .DEFAULT
//            log.info("\(#function): Setting encryption mode to DEFAULT")
            
            self.pumpManager.state.ignorePassword = false;
            
            let (pairingKey, _) = DanaRSEncryption.getPairingKeys()
            if (pairingKey.count > 0) {
                self.sendPassKeyCheck(pairingKey)
            } else {
                self.sendPairingRequest()
            }
        } else if (data.count == 9 && self.isOk(data)) {
            // response OK v3, 2nd layer encryption
            self.encryptionMode = .RSv3
//            log.info("\(#function): Setting encryption mode to RSv3")
            
            self.pumpManager.state.ignorePassword = true;
            
            self.pumpManager.state.hwModel = data[5]
            self.pumpManager.state.pumpProtocol = data[7]
            
            if (self.pumpManager.state.hwModel == 0x05) {
                self.sendV3PairingInformationEmpty()
            } else if (self.pumpManager.state.hwModel == 0x06) {
                self.sendEasyMenuCheck()
            } else {
                log.error("\(#function): Got invalid hwModel \(self.pumpManager.state.hwModel)")
                self.bluetoothManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Invalid hwModel", code: 0, userInfo: nil))
                }
            }
        } else if (data.count == 14 && self.isOk(data)) {
            self.encryptionMode = .BLE_5
//            log.info("\(#function): Setting encryption mode to BLE5")
            
            self.pumpManager.state.hwModel = data[5]
            self.pumpManager.state.pumpProtocol = data[7]
            
            guard (self.pumpManager.state.hwModel == 0x09 || self.pumpManager.state.hwModel == 0x0a) else {
                log.error("\(#function): Got invalid hwModel \(self.pumpManager.state.hwModel)")
                self.bluetoothManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Invalid hwModel", code: 0, userInfo: nil))
                }
                return
            }
            
            var ble5Keys = data.subdata(in: 8..<14)
            if ble5Keys.filter({ $0 == 0 }).count != 0 {
                // Try to get keys from previous session
                ble5Keys = self.pumpManager.state.ble5Keys
            }
            
            guard ble5Keys.filter({ $0 == 0 }).count == 0 else {
                log.error("\(#function): Invalid BLE-5 keys. Please unbound device and try again.")
                
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Invalid ble5 keys", code: 0, userInfo: nil))
                    
                    // Need to manually show error, since pumpDelegate hasnt been attached yet...
                    let dialogMessage = UIAlertController(
                        title:LocalizedString("ERROR: Failed to pair device", comment: "Dana-i invalid ble5 keys"),
                        message: LocalizedString("Failed to pair to ", comment: "Dana-i failed to pair p1") + (self.pumpManager.state.deviceName ?? "<NO_NAME>") + LocalizedString(". Please go to your bluetooth settings, forget this device, and try again", comment: "Dana-i failed to pair p2"),
                        preferredStyle: .alert)
                    
                    dialogMessage.addAction(UIAlertAction(
                        title: LocalizedString("Oke", comment: "Dana-RS v3 pincode prompt oke"),
                        style: .default
                    ))
                    
                    guard let view = UIApplication.shared.windows.last?.rootViewController else {
                        self.log.error("No views are found to prompt ble 5 error")
                        return
                    }
                    
                    view.present(dialogMessage, animated: true, completion: nil)
                }
                return
            }
            
            DanaRSEncryption.setBle5Key(ble5Key: ble5Keys)
            self.pumpManager.state.ble5Keys = ble5Keys
            self.sendBLE5PairingInformation()
        } else if (data.count == 6 && self.isPump(data)) {
            log.error("\(#function): PUMP_CHECK error. Data: \(data.base64EncodedString())")
            DispatchQueue.main.async {
                self.completion(NSError(domain: "PUMP_CHECK error", code: 0, userInfo: nil))
            }
        } else if (data.count == 6 && isBusy(data)) {
            log.error("\(#function): PUMP_CHECK_BUSY error. Data: \(data.base64EncodedString())")
            DispatchQueue.main.async {
                self.completion(NSError(domain: "PUMP_CHECK_BUSY error", code: 0, userInfo: nil))
            }
        } else {
            log.error("\(#function): PUMP_CHECK error, wrong serial number. Data: \(data.base64EncodedString())")
            DispatchQueue.main.async {
                self.completion(NSError(domain: "PUMP_CHECK error, wrong serial number", code: 0, userInfo: nil))
            }
        }
    }
    
    private func processEncryptionResponse(_ data: Data) {
        if (self.encryptionMode == .BLE_5) {
            Task {
                await self.updateInitialState()
            }
            
        } else if (self.encryptionMode == .RSv3) {
            // data[2] : 0x00 OK  0x01 Error, No pairing
            if (data[2] == 0x00) {
                let (pairingKey, randomPairingKey) = DanaRSEncryption.getPairingKeys()
                if (pairingKey.count == 0 || randomPairingKey.count == 0) {
//                    log.info("\(#function): Device is requesting pincode")
                    self.promptPincode(nil)
                    return
                }
                
                Task {
                    await self.updateInitialState()
                }
            } else {
                self.sendV3PairingInformation(1)
            }
        } else {
            let highByte = UInt16((data[data.count - 1] & 0xff) << 8)
            let lowByte = UInt16(data[data.count - 2] & 0xff)
            let password = (highByte + lowByte) ^ 0x0d87
            if (password != self.pumpManager.state.devicePassword && !self.pumpManager.state.ignorePassword) {
                log.error("\(#function): Invalid password")
                self.bluetoothManager.disconnect(self.connectedDevice)
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Invalid password", code: 0, userInfo: nil))
                }
                return
            }
            
            Task {
                await self.updateInitialState()
            }
        }
    }
    
    private func promptPincode(_ errorMessage: String?) {
        DispatchQueue.main.async {
            let dialogMessage = UIAlertController(
                title: LocalizedString("Dana-RS v3 found!", comment: "Dana-RS v3 found"),
                message: errorMessage ?? LocalizedString("Pincode required", comment: "Dana-RS v3 pincode prompt body"),
                preferredStyle: .alert)
            
            dialogMessage.addTextField(configurationHandler: { textField in
                textField.placeholder = LocalizedString("Pin 1", comment: "Dana-RS v3 pincode prompt pin 1")
            })
            
            dialogMessage.addTextField(configurationHandler: { textField in
                textField.placeholder = LocalizedString("Pin 2", comment: "Dana-RS v3 pincode prompt pin 2")
            })
            
            dialogMessage.addAction(UIAlertAction(
                title: LocalizedString("Oke", comment: "Dana-RS v3 pincode prompt oke"),
                style: .default,
                handler: { _ in
                    guard let pin1Str = dialogMessage.textFields?[0].text, let pin2Str = dialogMessage.textFields?[1].text else {
                        self.log.error("\(#function): Missing textfields")
                        return
                    }
                    
                    guard pin1Str.count == 12, pin2Str.count == 8 else {
                        self.promptPincode(LocalizedString("Received invalid pincode lengths. Try again", comment: "Dana-RS v3 pincode prompt error invalid length"))
                        return
                    }
                    
                    guard let pin1 = Data(hexString: pin1Str), let pin2 = Data(hexString: pin2Str) else {
                        self.promptPincode(LocalizedString("Received invalid hex strings. Try again", comment: "Dana-RS v3 pincode prompt error invalid hex"))
                        return
                    }
                    
                    let randomPairingKey = pin2.prefix(3)
                    let checkSum = pin2.dropFirst(3).prefix(1)
                    
                    var pairingKeyCheckSum: UInt8 = 0
                    for byte in pin1 {
                        pairingKeyCheckSum ^= byte
                    }
                    
                    for byte in randomPairingKey {
                        pairingKeyCheckSum ^= byte
                    }
                    
                    guard checkSum.first == pairingKeyCheckSum else {
                        self.promptPincode(LocalizedString("Checksum failed. Try again", comment: "Dana-RS v3 pincode prompt error checksum failed"))
                        return
                    }
                    
                    self.finishV3Pairing(pin1, randomPairingKey)
                }
            ))
            
            guard let view = UIApplication.shared.windows.last?.rootViewController else {
                return
            }
            
            view.present(dialogMessage, animated: true, completion: nil)
        }
    }
    
    private func isOk(_ data: Data) -> Bool {
        return data[2] == okCharCodes[0] && data[3] == okCharCodes[1]
    }
    
    private func isPump(_ data: Data) -> Bool {
        return data[2] == pumpCharCodes[0] && data[3] == pumpCharCodes[1] && data[4] == pumpCharCodes[2] && data[5] == pumpCharCodes[3]
    }
    
    private func isBusy(_ data: Data) -> Bool {
        return data[2] == busyCharCodes[0] && data[3] == busyCharCodes[1] && data[4] == busyCharCodes[2] && data[5] == busyCharCodes[3]
    }
    
    public func updateInitialState() async {
        do {
            self.pumpManager.state.isConnected = true
//            log.info("\(#function): Sending keep connection")
            
            let keepConnection = generatePacketGeneralKeepConnection()
            let resultKeepConnection = try await self.writeMessage(keepConnection)
            guard resultKeepConnection.success else {
                log.error("\(#function): Failed to send keep connection...")
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Failed to send keep connection", code: 0, userInfo: nil))
                }
                return
            }
            
            
//            log.info("\(#function): Getting initial state")
            let initialScreenPacket = generatePacketGeneralGetInitialScreenInformation()
            let resultInitialScreenInformation = try await self.writeMessage(initialScreenPacket)
            
            guard resultInitialScreenInformation.success else {
                log.error("\(#function): Failed to fetch Initial screen...")
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Failed to fetch Initial screen", code: 0, userInfo: nil))
                }
                return
            }
            
            
            guard let data = resultInitialScreenInformation.data as? PacketGeneralGetInitialScreenInformation else {
                log.error("\(#function): No data received (initial screen)...")
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "No data received (initial screen)", code: 0, userInfo: nil))
                }
                return
            }
            
//            log.info("\(#function): Getting user options")
            let userOptionPacket = generatePacketGeneralGetUserOption()
            let userOptionResult = try await self.writeMessage(userOptionPacket)
            guard userOptionResult.success else {
                log.error("\(#function): Failed to fetch user options...")
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Failed to fetch user options", code: 0, userInfo: nil))
                }
                return
            }
            
            guard let dataUserOption = userOptionResult.data as? PacketGeneralGetUserOption else {
                log.error("\(#function): No data received (user option)...")
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "No data received (user option)", code: 0, userInfo: nil))
                }
                return
            }
            
//            log.info("\(#function): Getting pump time with timezone")
            let timeUtcWithTimezonePacket = generatePacketGeneralGetPumpTimeUtcWithTimezone()
            let resultTimeUtcWithTimezone = try await self.writeMessage(timeUtcWithTimezonePacket)
            guard resultInitialScreenInformation.success else {
                log.error("\(#function): Failed to fetch pump time...")
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "Failed to fetch pump time", code: 0, userInfo: nil))
                }
                return
            }
            
            
            guard let dataTimeUtc = resultTimeUtcWithTimezone.data as? PacketGeneralGetPumpTimeUtcWithTimezone else {
                log.error("\(#function): No data received (time utc with timezone)...")
                self.pumpManager.disconnect(self.connectedDevice)
                
                DispatchQueue.main.async {
                    self.completion(NSError(domain: "No data received (time utc with timezone)", code: 0, userInfo: nil))
                }
                return
            }
            
            self.pumpManager.state.reservoirLevel = data.reservoirRemainingUnits
            self.pumpManager.state.batteryRemaining = data.batteryRemaining
            self.pumpManager.state.isPumpSuspended = data.isPumpSuspended
            self.pumpManager.state.isTempBasalInProgress = data.isTempBasalInProgress
            self.pumpManager.state.basalDeliveryOrdinal = data.isTempBasalInProgress ? .tempBasal : data.isPumpSuspended ? .suspended : .active
            self.pumpManager.state.lowReservoirRate = dataUserOption.lowReservoirRate
            self.pumpManager.state.isTimeDisplay24H = dataUserOption.isTimeDisplay24H
            self.pumpManager.state.isButtonScrollOnOff = dataUserOption.isButtonScrollOnOff
            self.pumpManager.state.beepAndAlarm = dataUserOption.beepAndAlarm
            self.pumpManager.state.lcdOnTimeInSec = dataUserOption.lcdOnTimeInSec
            self.pumpManager.state.backlightOnTimInSec = dataUserOption.backlightOnTimInSec
            self.pumpManager.state.selectedLanguage = dataUserOption.selectedLanguage
            self.pumpManager.state.units = dataUserOption.units
            self.pumpManager.state.shutdownHour = dataUserOption.shutdownHour
            self.pumpManager.state.cannulaVolume = dataUserOption.cannulaVolume
            self.pumpManager.state.refillAmount = dataUserOption.refillAmount
            self.pumpManager.state.targetBg = dataUserOption.targetBg
            self.pumpManager.state.units = dataUserOption.units
            self.pumpManager.state.bolusState = .noBolus
            self.pumpManager.state.pumpTime = dataTimeUtc.time
            self.pumpManager.notifyStateDidChange()
            
            log.info("\(#function): Connection and encryption successful!")
            
            DispatchQueue.main.async {
                self.completion(nil)
                self.completion = { _ in }
            }
        } catch {
            log.error("\(#function): Caught error during sending the message. error: \(error.localizedDescription, privacy: .public)")
            self.pumpManager.disconnect(self.connectedDevice)
            DispatchQueue.main.async {
                self.completion(error)
            }
        }
    }
}

// MARK: Parsers for incomming messages
extension PeripheralManager {
    private func parseReceivedValue(_ receievedData: Data) {
        var data = receievedData
        if (self.pumpManager.state.isConnected && self.encryptionMode != .DEFAULT) {
            data = DanaRSEncryption.decodeSecondLevel(data: data)
        }
        
        self.readBuffer.append(data)
        guard (self.readBuffer.count >= 6) else {
            // Buffer is not ready to be processed
            return
        }
        
        if (
            !(self.readBuffer[0] == self.PACKET_START_BYTE || self.readBuffer[0] == self.ENCRYPTED_START_BYTE) ||
            !(self.readBuffer[1] == self.PACKET_START_BYTE || self.readBuffer[1] == self.ENCRYPTED_START_BYTE)
        ) {
            // The buffer does not start with the opening bytes. Check if the buffer is filled with old data
            if let indexStartByte = self.readBuffer.firstIndex(of: self.PACKET_START_BYTE) {
                self.readBuffer = self.readBuffer.subdata(in: indexStartByte..<self.readBuffer.count)
            } else if let indexEncryptedStartByte = self.readBuffer.firstIndex(of: self.ENCRYPTED_START_BYTE) {
                self.readBuffer = self.readBuffer.subdata(in: indexEncryptedStartByte..<self.readBuffer.count)
            } else {
                log.error("\(#function): Received invalid packets. Starting bytes do not exists in message. Data: \(self.readBuffer.base64EncodedString())")
                self.readBuffer = Data([])
                return
            }
        }
        
        let length = Int(self.readBuffer[2])
        guard (length + 7 == self.readBuffer.count) else {
            // Not all packets have been received yet...
            return
        }
        
        guard (
            (self.readBuffer[length + 5] == self.PACKET_END_BYTE || self.readBuffer[length + 5] == self.ENCRYPTED_END_BYTE) &&
            (self.readBuffer[length + 6] == self.PACKET_END_BYTE || self.readBuffer[length + 6] == self.ENCRYPTED_END_BYTE)
          ) else {
            // Invalid packets received...
            log.error("\(#function): Received invalid packets. Ending bytes do not match. Data: \(self.readBuffer.base64EncodedString())")
            self.readBuffer = Data([])
            return
          }
        
//        log.info("\(#function): Received message! Starting to decrypt data: \(self.readBuffer.base64EncodedString())")
        let decryptedData = DanaRSEncryption.decodePacket(buffer: self.readBuffer, deviceName: self.deviceName)
        self.readBuffer = Data([])
        
        guard decryptedData.count > 0 else {
            log.error("\(#function): Decryption failed...")
            return
        }
        
//        log.info("\(#function): Decoding successful! Data: \(decryptedData.base64EncodedString())")
        if (decryptedData[0] == DanaPacketType.TYPE_ENCRYPTION_RESPONSE) {
            switch(decryptedData[1]) {
            case DanaPacketType.OPCODE_ENCRYPTION__PUMP_CHECK:
                self.processConnectResponse(decryptedData)
                return
            case DanaPacketType.OPCODE_ENCRYPTION__TIME_INFORMATION:
                self.processEncryptionResponse(decryptedData)
                return
            case DanaPacketType.OPCODE_ENCRYPTION__CHECK_PASSKEY:
                if (decryptedData[2] == 0x05) {
                    self.sendTimeInfo()
                } else {
                    self.sendPairingRequest()
                }
                return
            case DanaPacketType.OPCODE_ENCRYPTION__PASSKEY_REQUEST:
                self.processPairingRequest(decryptedData)
                return
            case DanaPacketType.OPCODE_ENCRYPTION__PASSKEY_RETURN:
                self.processPairingRequest2(decryptedData)
                return
            case DanaPacketType.OPCODE_ENCRYPTION__GET_PUMP_CHECK:
                if (decryptedData[2] == 0x05) {
                    self.sendTimeInfo()
                } else {
                    self.sendEasyMenuCheck()
                }
                return
            case DanaPacketType.OPCODE_ENCRYPTION__GET_EASYMENU_CHECK:
                self.processEasyMenuCheck(decryptedData)
                return
            default:
                log.error("\(#function): Received invalid encryption command type \(decryptedData[1])")
                return
            }
        }
        
        guard(decryptedData[0] == DanaPacketType.TYPE_RESPONSE || decryptedData[0] == DanaPacketType.TYPE_NOTIFY) else {
            log.error("\(#function): Received invalid packet type \(decryptedData[0])")
            return
        }
        
        self.processMessage(decryptedData)
    }
    
    private func processMessage(_ data: Data) {
        let message = parseMessage(data: data)
        guard let message = message else {
            log.error("\(#function): Received unparsable message. Data: \(data.base64EncodedString())")
            return
        }
        
        if (message.notifyType != nil) {
            switch message.notifyType {
            case CommandNotifyDeliveryComplete:
                let data = message.data as! PacketNotifyDeliveryComplete
                self.pumpManager.notifyBolusDone(deliveredUnits: data.deliveredInsulin)
                return
            case CommandNotifyDeliveryRateDisplay:
                let data = message.data as! PacketNotifyDeliveryRateDisplay
                self.pumpManager.notifyBolusDidUpdate(deliveredUnits: data.deliveredInsulin)
                return
            case CommandNotifyAlarm:
                let data = message.data as! PacketNotifyAlarm
                self.pumpManager.notifyBolusError()
                self.pumpManager.notifyAlert(data.alert)
                return
            default:
                self.pumpManager.notifyBolusError()
                return
            }
        }
        
        // Message received and dequeueing timeout
        guard let queueItem = self.writeQueue[message.opCode ?? 0] else {
            log.error("\(#function): No continuation token found to send this message back...")
            return
        }
        
        queueItem.0.invalidate()
        
        if let data = message.data as? HistoryItem {
            if data.code == HistoryCode.RECORD_TYPE_DONE_UPLOAD {
                queueItem.1.resume(returning: DanaParsePacket<[HistoryItem]>(success: true, rawData: Data([]), data: self.historyLog.map({ $0 })))
                self.historyLog = []
            } else {
                self.historyLog.append(data)
            }

            return
        }
        
        queueItem.1.resume(returning: message)
        self.writeQueue[message.opCode ?? 0] = nil
    }
    
    private func isHistoryPacket(opCode: UInt16) -> Bool {
        return opCode > CommandHistoryBolus && opCode < CommandHistoryAll
    }
}
