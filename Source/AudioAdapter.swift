//
//  AudioAdapter.swift
//  SCNRecorder
//
//  Created by Vladimir Knyazev on 04/10/2019.
//  Copyright © 2019 GORA Studio. All rights reserved.
//

import Foundation
import AVFoundation

public class AudioAdapter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    typealias Callback = (_ sampleBuffer: CMSampleBuffer) -> Void
    
    let session: AVCaptureSession?
    let queue: DispatchQueue
    let callback: Callback
    
    init(queue: DispatchQueue, callback: @escaping Callback) {
        self.queue = queue
        self.callback = callback
        
        session = AVCaptureSession()
        super.init()
        
        if let device = AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified),
            let input = try? AVCaptureDeviceInput(device: device) {
            
            if session!.canAddInput(input) {
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: queue)
                
                if session!.canAddOutput(output) {
                    session!.addOutput(output)
                }
            }
        }
    }
    
    @objc func captureOutput(_ output: AVCaptureOutput,
                             didOutput sampleBuffer: CMSampleBuffer,
                             from connection: AVCaptureConnection) {
        print("::Buffer received")
        callback(sampleBuffer)
    }
    
    func startSession() {
        print("::Start session")
        session?.startRunning()
    }
    
    func endSession() {
        print("::End session")
        session?.stopRunning()
    }
}
