//
//  LongDistance.swift
//  OptiScanBarcodeReader
//
//  Created by Dineshkumar Kandasamy on 30/05/22.
//  Copyright © 2022 Optisol Business Solution. All rights reserved.
//

import Foundation
import UIKit


class LongDistance {
    
    private static var MIN_UPSCALE_WIDTH_QR = 13.0
    private static var MIN_UPSCALE_HEIGHT_QR = 9.0
    private static var MIN_UPSCALE_WIDTH_BARCODE = 64.0
    private static var MIN_UPSCALE_HEIGHT_BARCODE = 16.0
    
    func isLongDistanceQRImage(
        cropImageWidth: CGFloat,
        cropImageHeight: CGFloat,
        previewWidth: CGFloat,
        previewHeight: CGFloat
    ) -> Bool {
        DebugPrint(message: "dist width min \(((cropImageWidth / previewWidth) * 100.0).rounded())", function: .longDistance)
        DebugPrint(message: "dist height min \(((cropImageHeight / previewHeight) * 100).rounded())", function: .longDistance)

        return (((cropImageWidth / previewWidth) * 100.0).rounded() < LongDistance.MIN_UPSCALE_WIDTH_QR) || (((cropImageHeight / previewHeight) * 100).rounded() < LongDistance.MIN_UPSCALE_HEIGHT_QR)
    }

    func isLongDistanceBarcodeImage(
        cropImageWidth: CGFloat,
        cropImageHeight: CGFloat,
        previewWidth: CGFloat,
        previewHeight: CGFloat
    ) -> Bool {
        DebugPrint(message: "dist bar width min \(((cropImageWidth / previewWidth) * 100.0).rounded())", function: .longDistance)
        DebugPrint(message: "dist bar height min \(((cropImageHeight / previewHeight) * 100).rounded())", function: .longDistance)

        return (((cropImageWidth / previewWidth) * 100).rounded() < LongDistance.MIN_UPSCALE_WIDTH_BARCODE) || (((cropImageHeight / previewHeight) * 100).rounded() < LongDistance.MIN_UPSCALE_HEIGHT_BARCODE)
    }
    
}
