//
//  DanaKitScanViewModel.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 28/12/2023.
//  Copyright © 2023 Randall Knutson. All rights reserved.
//

import SwiftUI
import os.log
import LoopKit
import CoreBluetooth

struct ScanResultItem: Identifiable {
    let id = UUID()
    var name: String
    let bleIdentifier: String
}

class DanaKitScanViewModel : ObservableObject {
    @Published var scannedDevices: [ScanResultItem] = []
    @Published var isScanning = false
    @Published var connectedDeviceName = ""
    @Published var isConnecting = false
    @Published var isPresentingBle5KeysError = false
     
    private let log = OSLog(category: "ScanView")
    private var pumpManager: DanaKitPumpManager?
    private var nextStep: () -> Void
    private var foundDevices: [String:CBPeripheral] = [:]
    
    init(_ pumpManager: DanaKitPumpManager? = nil, nextStep: @escaping () -> Void) {
        self.pumpManager = pumpManager
        self.nextStep = nextStep
        
        self.pumpManager?.addScanDeviceObserver(self, queue: .main)
        self.pumpManager?.addStateObserver(self, queue: .main)
        
        do {
            try self.pumpManager?.startScan()
            self.isScanning = true
        } catch {
            log.error("Failed to start scan action: %{public}@", error.localizedDescription)
        }
    }
    
    func connect(_ item: ScanResultItem) {
        guard let device = self.foundDevices[item.bleIdentifier] else {
            return
        }
        
        self.stopScan()
        
        self.connectedDeviceName = item.name
        self.pumpManager?.connect(device)
        self.isConnecting = true
    }
    
    func stopScan() {
        self.pumpManager?.stopScan()
        self.isScanning = false
    }
}

extension DanaKitScanViewModel: StateObserver {
    func deviceScanDidUpdate(_ device: DanaPumpScan) {
        self.scannedDevices.append(ScanResultItem(name: device.name, bleIdentifier: device.bleIdentifier))
        self.foundDevices[device.bleIdentifier] = device.peripheral
    }
    
    func stateDidUpdate(_ state: DanaKitPumpManagerState, _ oldState: DanaKitPumpManagerState) {
        if (!oldState.deviceSendInvalidBLE5Keys && state.deviceSendInvalidBLE5Keys) {
            self.isConnecting = false
            self.isPresentingBle5KeysError = true
            return
        }
        
        if (state.isConnected && state.deviceName != nil) {
            self.isConnecting = false
            self.nextStep()
        }
    }
}
