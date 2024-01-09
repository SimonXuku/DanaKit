//
//  DanaUICoordinator.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 18/12/2023.
//  Copyright © 2023 Randall Knutson. All rights reserved.
//

import UIKit
import SwiftUI
import Combine
import LoopKit
import LoopKitUI

enum DanaUIScreen {
    case debugView
    case firstRunScreen
    case insulinConfirmationScreen
    case bolusSpeedScreen
    case deviceScanningScreen
    case setupComplete
    case settings
    
    func next() -> DanaUIScreen? {
        switch self {
        case .debugView:
            return .firstRunScreen
        case .firstRunScreen:
            return .insulinConfirmationScreen
        case .insulinConfirmationScreen:
            return .bolusSpeedScreen
        case .bolusSpeedScreen:
            return .deviceScanningScreen
        case .deviceScanningScreen:
            return .setupComplete
        case .setupComplete:
            return nil
        case .settings:
            return nil
        }
    }
}

protocol DanaUINavigator: AnyObject {
    func navigateTo(_ screen: DanaUIScreen)
}

class DanaUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying, UINavigationControllerDelegate {
    var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
    
    var completionDelegate: CompletionDelegate?
    
    var screenStack = [DanaUIScreen]()
    var currentScreen: DanaUIScreen {
        return screenStack.last!
    }
    
    private let colorPalette: LoopUIColorPalette

    private var pumpManager: DanaKitPumpManager?
    
    private var allowedInsulinTypes: [InsulinType]
    
    private var allowDebugFeatures: Bool
    
    init(pumpManager: DanaKitPumpManager? = nil, colorPalette: LoopUIColorPalette, pumpManagerSettings: PumpManagerSetupSettings? = nil, allowDebugFeatures: Bool, allowedInsulinTypes: [InsulinType] = [])
    {
        if pumpManager == nil {
            self.pumpManager = DanaKitPumpManager(state: DanaKitPumpManagerState(rawValue: [:]))
        } else {
            self.pumpManager = pumpManager
        }
        
        self.colorPalette = colorPalette

        self.allowDebugFeatures = allowDebugFeatures
        
        self.allowedInsulinTypes = allowedInsulinTypes
        
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if screenStack.isEmpty {
            screenStack = [getInitialScreen()]
            let viewController = viewControllerForScreen(currentScreen)
            viewController.isModalInPresentation = false
            setViewControllers([viewController], animated: false)
        }
    }
    
    private func hostingController<Content: View>(rootView: Content) -> DismissibleHostingController {
        return DismissibleHostingController(rootView: rootView, colorPalette: colorPalette)
    }
    
    private func viewControllerForScreen(_ screen: DanaUIScreen) -> UIViewController {
        switch(screen) {
        case .debugView:
            let viewModel = DanaKitDebugViewModel(self.pumpManager)
            let view = hostingController(rootView: DanaKitDebugView(viewModel: viewModel))
            viewModel.setView(view)
            
            return view
        case .firstRunScreen:
            let view = DanaKitSetupView(nextAction: self.stepFinished, debugAction: { self.navigateTo(.debugView) }) //self.allowDebugFeatures ? { self.navigateTo(.debugView) } : {})
            return hostingController(rootView: view)
        case .insulinConfirmationScreen:
            let confirm: (InsulinType) -> Void = { confirmedType in
                self.pumpManager?.state.insulinType = confirmedType
                self.stepFinished()
            }
            let view = InsulinTypeConfirmation(initialValue: self.allowedInsulinTypes[0], supportedInsulinTypes: self.allowedInsulinTypes, didConfirm: confirm)
            return hostingController(rootView: view)
        case .bolusSpeedScreen:
            let next: (BolusSpeed) -> Void = { bolusSpeed in
                self.pumpManager?.state.bolusSpeed = bolusSpeed
                self.stepFinished()
            }
            let view = DanaKitPumpSpeed(next: next)
            
            return hostingController(rootView: view)
        case .deviceScanningScreen:
            let viewModel = DanaKitScanViewModel(self.pumpManager, nextStep: self.stepFinished)
            let view = hostingController(rootView: DanaKitScanView(viewModel: viewModel))
            viewModel.setView(view)
            
            return view
        case .setupComplete:
            pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: self.pumpManager!)
            
            let nextStep: () -> Void = {
                self.pumpManager?.state.isOnBoarded = true
                self.pumpManager?.notifyStateDidChange()
                self.stepFinished()
            }
            
            let view = DanaKitSetupCompleteView(finish: nextStep, friendlyPumpModelName: self.pumpManager?.state.getFriendlyDeviceName() ?? "", imageName: getDanaPumpImageName())
            return hostingController(rootView: view)
        case .settings:
            let view = DanaKitSettingsView(viewModel: DanaKitSettingsViewModel(self.pumpManager, self.stepFinished), imageName: getDanaPumpImageName())
            return hostingController(rootView: view)
        }
    }
    
    func stepFinished() {
        if let nextStep = currentScreen.next() {
            navigateTo(nextStep)
        } else {
            completionDelegate?.completionNotifyingDidComplete(self)
        }
    }
    
    func getInitialScreen() -> DanaUIScreen {
        guard let pumpManager = self.pumpManager else {
            return .firstRunScreen
        }
        
        if (pumpManager.isOnboarded) {
            return .settings
        }
        
        if (pumpManager.state.insulinType != nil) {
            return .deviceScanningScreen
        }
        
        return .firstRunScreen
    }
    
    func getDanaPumpImageName() -> String {
        guard let pumpManager = self.pumpManager else {
            return "danai"
        }
        
        switch (pumpManager.state.hwModel) {
        case 0x03:
            return "danars"
        case 0x05:
            return "danars"
        case 0x06:
            return "danars"
            
        case 0x07:
            return "danai"
        case 0x09:
            return "danai"
        case 0x0a:
            return "danai"
            
        default:
            return "danai"
        }
    }
}

extension DanaUICoordinator: DanaUINavigator {
    func navigateTo(_ screen: DanaUIScreen) {
        screenStack.append(screen)
        let viewController = viewControllerForScreen(screen)
        viewController.isModalInPresentation = false
        self.pushViewController(viewController, animated: true)
        viewController.view.layoutSubviews()
    }
}
