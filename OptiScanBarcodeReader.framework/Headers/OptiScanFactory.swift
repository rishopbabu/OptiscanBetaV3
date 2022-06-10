//
//  OptiScanFactory.swift
//  OptiScan
//
//  Created by Dineshkumar Kandasamy on 28/02/22.
//  Copyright © 2022 Optisol Business Solution. All rights reserved.

import UIKit

public class OptiScanFactory: NSObject {

    public static func createScanSession(scanView: UIView,events:ICameraScanCallback,scannerType:ScannerType) -> ICameraScan {
        return CameraScan(view: scanView,events: events, scannerType: scannerType)
     }
}
