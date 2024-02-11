//
//  DanaKitSettingsView.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 03/01/2024.
//  Copyright © 2024 Randall Knutson. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct DanaKitSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.dismissAction) private var dismiss
    @Environment(\.insulinTintColor) var insulinTintColor
    
    @ObservedObject var viewModel: DanaKitSettingsViewModel
    @State var loadingLogs = false
    
    var supportedInsulinTypes: [InsulinType]
    var imageName: String
    
    var removePumpManagerActionSheet: ActionSheet {
        ActionSheet(title: Text(LocalizedString("Remove Pump", comment: "Title for Dana-i/RS PumpManager deletion action sheet.")),
                    message: Text(LocalizedString("Are you sure you want to stop using Dana-i/RS?", comment: "Message for Dana-i/RS PumpManager deletion action sheet")),
                    buttons: [
                        .destructive(Text(LocalizedString("Delete pump", comment: "Button text to confirm Dana-i/RS PumpManager deletion"))) {
                            viewModel.stopUsingDana()
                        },
                        .cancel()
        ])
    }
    
    var syncPumpTime: ActionSheet {
        ActionSheet(title: Text(LocalizedString("Time Change Detected", comment: "Title for pod sync time action sheet.")),
                    message: Text(LocalizedString("The time on your pump is different from the current time. Do you want to update the time on your pump to the current time?", comment: "Message for pod sync time action sheet")), buttons: [
            .default(Text(LocalizedString("Yes, Sync to Current Time", comment: "Button text to confirm pump time sync"))) {
                self.viewModel.syncPumpTime()
            },
            .cancel(Text(LocalizedString("No, Keep Pump As Is", comment: "Button text to cancel pump time sync")))
        ])
    }
    
    var body: some View {
        List {
            Section() {
                HStack(){
                    Spacer()
                    Image(uiImage: UIImage(named: imageName, in: Bundle(for: DanaKitHUDProvider.self), compatibleWith: nil)!)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal)
                        .frame(height: 200)
                    Spacer()
                }
                
                HStack(alignment: .top) {
                    deliveryStatus
                    Spacer()
                    reservoirStatus
                }
                .padding(.bottom, 5)
                
                if viewModel.showPumpTimeSyncWarning {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedString("Time Change Detected", comment: "title for time change detected notice"))
                            .font(Font.subheadline.weight(.bold))
                        Text(LocalizedString("The time on your pump is different from the current time. Your pump’s time controls your scheduled therapy settings. Scroll down to Pump Time row to review the time difference and configure your pump.", comment: "description for time change detected notice"))
                            .font(Font.footnote.weight(.semibold))
                    }.padding(.vertical, 8)
                }
            }
            
            Section {
                Button(action: {
                    viewModel.suspendResumeButtonPressed()
                }) {
                    HStack {
                        Text($viewModel.basalButtonText.wrappedValue)
                        Spacer()
                        if viewModel.isUpdatingPumpState {
                            ActivityIndicator(isAnimating: .constant(true), style: .medium)
                        }
                    }
                }
                .disabled(viewModel.isUpdatingPumpState || viewModel.isSyncing)
                
                Button(action: {
                    viewModel.syncData()
                }) {
                    HStack {
                        Text(LocalizedString("Sync pump data", comment: "DanaKit sync pump"))
                        Spacer()
                        if viewModel.isSyncing {
                            ActivityIndicator(isAnimating: .constant(true), style: .medium)
                        }
                    }
                }
                .disabled(viewModel.isUpdatingPumpState || viewModel.isSyncing)
                
                Button(action: {
                    shareLogs()
                }) {
                    HStack {
                        Text(LocalizedString("Share Dana pump logs", comment: "DanaKit share logs"))
                        Spacer()
                        if self.loadingLogs {
                            ActivityIndicator(isAnimating: .constant(true), style: .medium)
                        }
                    }
                }
                .disabled(self.loadingLogs)
                
                HStack {
                    Text(LocalizedString("Last sync", comment: "Text for last sync")).foregroundColor(Color.primary)
                    Spacer()
                    Text(String(viewModel.formatDate(viewModel.lastSync)))
                        .foregroundColor(.secondary)
                }
            }
            
            Section(header: SectionHeader(label: LocalizedString("Configuration", comment: "The title of the configuration section in DanaKit settings")))
            {
                NavigationLink(destination: InsulinTypeSetting(initialValue: viewModel.insulineType, supportedInsulinTypes: supportedInsulinTypes, allowUnsetInsulinType: false, didChange: viewModel.didChangeInsulinType)) {
                    HStack {
                        Text(LocalizedString("Insulin Type", comment: "Text for confidence reminders navigation link")).foregroundColor(Color.primary)
                        Spacer()
                        Text(viewModel.insulineType.brandName)
                            .foregroundColor(.secondary)
                        }
                }
                NavigationLink(destination: DanaKitSettingsPumpSpeed(value: Int(viewModel.bolusSpeed.rawValue), didChange: viewModel.didBolusSpeedChanged)) {
                    HStack {
                        Text(LocalizedString("Delivery speed", comment: "Title for delivery speed")).foregroundColor(Color.primary)
                        Spacer()
                        Text(viewModel.bolusSpeed.format())
                            .foregroundColor(.secondary)
                        }
                }
                NavigationLink(destination: viewModel.userOptionsView) {
                    Text(LocalizedString("User options", comment: "Title for user options"))
                        .foregroundColor(Color.primary)
                }
            }
            
            Section {
                HStack {
                    Text(LocalizedString("Pump name", comment: "Text for Dana pump name")).foregroundColor(Color.primary)
                    Spacer()
                    Text(viewModel.deviceName ?? "")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(LocalizedString("Hardware model", comment: "Text for hardware model")).foregroundColor(Color.primary)
                    Spacer()
                    Text(String(viewModel.hardwareModel ?? 0))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(LocalizedString("Firmware version", comment: "Text for firmware version")).foregroundColor(Color.primary)
                    Spacer()
                    Text(String(viewModel.firmwareVersion ?? 0))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(LocalizedString("Battery level", comment: "Text for Battery level")).foregroundColor(Color.primary)
                    Spacer()
                    Text(String(viewModel.batteryLevel) + "%")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(LocalizedString("Pump time", comment: "Text for pump time")).foregroundColor(Color.primary)
                    Spacer()
                    if viewModel.showPumpTimeSyncWarning {
                        Image(systemName: "clock.fill")
                            .foregroundColor(guidanceColors.warning)
                    }
                    Text(String(viewModel.formatDate(viewModel.pumpTime)))
                        .foregroundColor(viewModel.showPumpTimeSyncWarning ? guidanceColors.warning : .secondary)
                }
                
                if viewModel.showPumpTimeSyncWarning {
                    Button(action: {
                        viewModel.showingTimeSyncConfirmation = true
                    }) {
                        Text(LocalizedString("Sync Pump time", comment: "Label for syncing the time on the pump"))
                            .foregroundColor(.accentColor)
                    }
                    .disabled(viewModel.isSyncing)
                    .actionSheet(isPresented: $viewModel.showingTimeSyncConfirmation) {
                        syncPumpTime
                    }
                }
            }
            
            Section() {
                Button(action: {
                    viewModel.showingDeleteConfirmation = true
                }) {
                    Text(LocalizedString("Delete Pump", comment: "Label for PumpManager deletion button"))
                        .foregroundColor(guidanceColors.critical)
                }
                .actionSheet(isPresented: $viewModel.showingDeleteConfirmation) {
                    removePumpManagerActionSheet
                }
            }
        }
        .insetGroupedListStyle()
        .navigationBarItems(trailing: doneButton)
        .navigationBarTitle(viewModel.pumpModel)
    }
    
    private var doneButton: some View {
        Button("Done", action: {
            dismiss()
        })
    }
    
    var reservoirStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedString("Insulin Remaining", comment: "Header for insulin remaining on pod settings screen"))
                .foregroundColor(Color(UIColor.secondaryLabel))
            if let reservoirLevel = viewModel.reservoirLevel {
                HStack {
                    ReservoirView(reservoirLevel: reservoirLevel, fillColor: reservoirColor(reservoirLevel))
                        .frame(width: 23, height: 32)
                    Text(viewModel.reservoirText(for: reservoirLevel))
                        .font(.system(size: 28))
                        .fontWeight(.heavy)
                        .fixedSize()
                }
            }
        }
    }
    
    var deliveryStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(deliverySectionTitle)
                .foregroundColor(Color(UIColor.secondaryLabel))
            if viewModel.isSuspended {
                HStack(alignment: .center) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(viewModel.isSuspended ? guidanceColors.warning : Color.accentColor)
                    Text(LocalizedString("Insulin\nSuspended", comment: "Text shown in insulin delivery space when insulin suspended"))
                        .fontWeight(.bold)
                        .fixedSize()
                }
            } else if let basalRate = self.viewModel.basalRate {
                HStack(alignment: .center) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(viewModel.basalRateFormatter.string(from: basalRate) ?? "")
                            .font(.system(size: 28))
                            .fontWeight(.heavy)
                            .fixedSize()
                        Text(LocalizedString("U/hr", comment: "Units for showing temp basal rate"))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack(alignment: .center) {
                    Image(systemName: "x.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(guidanceColors.warning)
                    Text(LocalizedString("Unknown", comment: "Text shown in basal rate space when delivery status is unknown"))
                        .fontWeight(.bold)
                        .fixedSize()
                }
            }
        }
    }
    
    var deliverySectionTitle: String {
        if !self.viewModel.isSuspended {
            return LocalizedString("Scheduled Basal", comment: "Title of insulin delivery section")
        } else {
            return LocalizedString("Insulin Delivery", comment: "Title of insulin delivery section")
        }
    }
    
    private func reservoirColor(_ reservoirLevel: Double) -> Color {
        if reservoirLevel > viewModel.reservoirLevelWarning {
            return insulinTintColor
        }
        
        if reservoirLevel > 0 {
            return guidanceColors.warning
        }
        
        return guidanceColors.critical
    }
    
    private func shareLogs() {
        self.loadingLogs = true
        DispatchQueue.global(qos: .userInitiated).async {
            guard let logging = viewModel.getLogs().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                DispatchQueue.main.async {
                    self.loadingLogs = false
                }
                return
            }
            
            let mailto = "mailto:verhaar.bastiaan@gmail.com?subject=Dana%20logs&body=" + logging
            guard let url = URL(string: mailto) else {
                DispatchQueue.main.async {
                    self.loadingLogs = false
                }
                return
            }
            
            DispatchQueue.main.async {
                self.loadingLogs = false
                openURL(url)
            }
        }
    }
}

#Preview {
    DanaKitSettingsView(viewModel: DanaKitSettingsViewModel(nil, nil), supportedInsulinTypes: InsulinType.allCases, imageName: "danai")
}
