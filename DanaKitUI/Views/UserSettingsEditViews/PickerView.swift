//
//  PickerView.swift
//  DanaKit
//
//  Created by Bastiaan Verhaar on 29/01/2024.
//  Copyright © 2024 Randall Knutson. All rights reserved.
//

import SwiftUI
import LoopKitUI

struct PickerView: View {
    @Environment(\.dismissAction) private var dismiss
    
    @State var currentOption: Int = 0
    var allowedOptions: [Int]
    var formatter: (Int) -> String
    var didChange: ((Int) -> Void)?
    
    var title: String
    var description: String?
    
    
    var body: some View {
        VStack(alignment: .leading) {
            titleView
            content
        }
        .padding(.horizontal)
        .navigationBarHidden(false)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(LocalizedString("Cancel", comment: "Cancel button title"), action: {
                    self.dismiss()
                })
            }
        }
    }
    
    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 15) {
            if description != nil {
                Text(description!).fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            ResizeablePicker(selection: $currentOption,
                             data: self.allowedOptions,
                             formatter: { formatter($0) })
            .padding()
        }
        .padding(.vertical, 8)
        
    }
    
    @ViewBuilder
    private var titleView: some View {
        Text(title)
            .font(.title)
            .bold()
    }
}

#Preview {
    PickerView(currentOption: 0, allowedOptions: [0, 1, 2, 3], formatter: { _ in ""}, didChange: { _ in }, title: "Preview Title", description: "Preview description")
}
