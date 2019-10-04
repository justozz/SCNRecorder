//
//  VideoRecorder.swift
//  SCNRecorder
//
//  Created by Vladislav Grigoryev on 11/03/2019.
//  Copyright (c) 2019 GORA Studio. https://gora.studio
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import AVFoundation

extension VideoRecorder {
    
    enum Error: Swift.Error {
        
        case fileAlreadyExists
        
        case notStarted
        
        case wrongState
    }
}

final class VideoRecorder: NSObject {
    
    let timeScale: CMTimeScale
    
    let assetWriter: AVAssetWriter
    
    let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    let audioAssetWriterInput: AVAssetWriterInput?
    
    let queue: DispatchQueue
    
    var audioRecorder: AVAudioRecorder?
    
    private class var audioRecorderSettings: [String: Any] {
        return [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
    }
    
    var state: State = .ready {
        didSet {
            recording?.state = state.recordingState
            
            if state.isFinal {
                onFinalState()
            }
        }
    }
    
    var duration: TimeInterval = 0.0 {
        didSet {
            recording?.duration = duration
        }
    }
    
    var startSeconds: TimeInterval = 0.0
    
    weak var recording: Recording?
    
    var onFinalState: () -> Void = { }
    
    init(url: URL,
         fileType: AVFileType,
         videoSettings: [String: Any],
         videoSourceFormatHint: CMFormatDescription?,
         audioSettings: [String: Any],
         audioSourceFormatHint: CMFormatDescription?,
         timeScale: CMTimeScale,
         queue: DispatchQueue = DispatchQueue.init(label: "VideoRecorder", qos: .userInitiated)) throws {
        
        self.timeScale = timeScale
        assetWriter = try AVAssetWriter(url: url, fileType: fileType)
        
        let videoAssetWriterInput = AVAssetWriterInput(mediaType: .video,
                                                       outputSettings: videoSettings,
                                                       sourceFormatHint: nil)
        videoAssetWriterInput.expectsMediaDataInRealTime = true
        
        if assetWriter.canAdd(videoAssetWriterInput) {
            assetWriter.add(videoAssetWriterInput)
            
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoAssetWriterInput,
                                                                      sourcePixelBufferAttributes: nil)
        }
        else {
            pixelBufferAdaptor = nil
        }
        
        let audioAssetWriterInput = AVAssetWriterInput(mediaType: .audio,
                                                       outputSettings: nil,
                                                       sourceFormatHint: audioSourceFormatHint)
        audioAssetWriterInput.expectsMediaDataInRealTime = true
        
        if assetWriter.canAdd(audioAssetWriterInput) {
            assetWriter.add(audioAssetWriterInput)
            self.audioAssetWriterInput = audioAssetWriterInput
        }
        else {
            self.audioAssetWriterInput = nil
        }
        
        self.queue = queue
        
        let audioUrl = URL(fileURLWithPath: "\(NSTemporaryDirectory())\(UUID().uuidString)\(UUID().uuidString).m4a")
        audioRecorder = try? AVAudioRecorder(url: audioUrl, settings: VideoRecorder.audioRecorderSettings)
        
        super.init()
        
        if audioRecorder != nil {
            audioRecorder!.delegate = self
        }
        
        audioRecorder?.record()
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? Error.notStarted
        }
        
        
    }
    
    deinit {
        audioRecorder?.stop()
        
        if let url = audioRecorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        
        audioRecorder = nil
        state = state.cancel(self)
    }
}

extension VideoRecorder {
    
    func startSession(at seconds: TimeInterval) {
        startSeconds = seconds + 0.2
        audioRecorder?.record()
        assetWriter.startSession(atSourceTime: timeFromSeconds(seconds))
    }
    
    func endSession(at seconds: TimeInterval) {
        audioRecorder?.pause()
        assetWriter.endSession(atSourceTime: timeFromSeconds(seconds))
    }
    
    func finishWriting(completionHandler handler: @escaping () -> Void) {
        audioRecorder?.stop()
        assetWriter.finishWriting { [weak self] in
            guard let strongSelf = self, let audioUrl = self?.audioRecorder?.url else {
                self?.audioRecorder = nil
                handler()
                return
            }
            
            self?.audioRecorder = nil
            
            strongSelf.mergeVideoWithAudio(videoUrl: strongSelf.assetWriter.outputURL, audioUrl: audioUrl, success: { (url) in
                _ = try? FileManager.default.replaceItemAt(strongSelf.assetWriter.outputURL, withItemAt: url)
                try? FileManager.default.removeItem(at: audioUrl)
                try? FileManager.default.removeItem(at: url)
                handler()
            }) { _ in
                handler()
            }
        }
    }
    
    func cancelWriting() {
        audioRecorder?.stop()
        audioRecorder = nil
        assetWriter.cancelWriting()
    }
    
    func append(_ pixelBuffer: CVPixelBuffer, withSeconds seconds: TimeInterval) {
        duration = seconds - startSeconds
        
        guard let adaptor = pixelBufferAdaptor else {
            return
        }
        
        guard adaptor.assetWriterInput.isReadyForMoreMediaData else {
            return
        }
        
        guard adaptor.append(pixelBuffer, withPresentationTime: timeFromSeconds(seconds)) else {
            return
        }
    }
    
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let input = audioAssetWriterInput else {
            return
        }
        
        guard input.isReadyForMoreMediaData else {
            return
        }
        
        guard input.append(sampleBuffer) else {
            return
        }
    }
}


extension VideoRecorder {
    
    func makeRecording() -> VideoRecording {
        let recording = Recording(videoRecorder: self)
        self.recording = recording
        return recording
    }
}

extension VideoRecorder {
    
    func resume(onError: @escaping (Swift.Error) -> Void) {
        queue.async { [weak self] in
            do {
                guard let `self` = self else { return }
                self.state = try self.state.resume(self)
            }
            catch {
                onError(error)
            }
        }
    }
    
    func pause() {
        queue.async { [weak self] in
            guard let `self` = self else { return }
            self.state = self.state.pause(self)
        }
    }
    
    func finish(completionHandler handler: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let `self` = self else { return }
            self.state = self.state.finish(self, completionHandler: handler)
        }
    }
    
    func cancel() {
        queue.async { [weak self] in
            guard let `self` = self else { return }
            self.state = self.state.cancel(self)
        }
    }
}

extension VideoRecorder: VideoInfoProvider {
    
    var url: URL {
        return assetWriter.outputURL
    }
    
    var fileType: AVFileType {
        return assetWriter.outputFileType
    }
}

extension VideoRecorder: PixelBufferConsumer {
    
    func setPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        state = state.setPixelBuffer(pixelBuffer, at: time, to: self)
    }
}

extension VideoRecorder: AudioSampleBufferConsumer {
    
    func setAudioSampleBuffer(_ audioSampleBuffer: CMSampleBuffer) {
        state = state.setAudioSampleBuffer(audioSampleBuffer, to: self)
    }
}

extension VideoRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        audioRecorder?.stop()
        audioRecorder = nil
    }
}

fileprivate extension VideoRecorder {
    func timeFromSeconds(_ seconds: TimeInterval) -> CMTime {
        return CMTime(seconds: seconds, preferredTimescale: timeScale)
    }
    
    func mergeVideoWithAudio(videoUrl: URL, audioUrl: URL, success: @escaping ((URL) -> Void), failure: @escaping ((Swift.Error?) -> Void)) {
        let mixComposition: AVMutableComposition = AVMutableComposition()
        var mutableCompositionVideoTrack: [AVMutableCompositionTrack] = []
        var mutableCompositionAudioTrack: [AVMutableCompositionTrack] = []
        let totalVideoCompositionInstruction : AVMutableVideoCompositionInstruction = AVMutableVideoCompositionInstruction()

        let aVideoAsset: AVAsset = AVAsset(url: videoUrl)
        let aAudioAsset: AVAsset = AVAsset(url: audioUrl)

        if let videoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid), let audioTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            mutableCompositionVideoTrack.append(videoTrack)
            mutableCompositionAudioTrack.append(audioTrack)

            if let aVideoAssetTrack: AVAssetTrack = aVideoAsset.tracks(withMediaType: .video).first, let aAudioAssetTrack: AVAssetTrack = aAudioAsset.tracks(withMediaType: .audio).first {
                do {
                    try mutableCompositionVideoTrack.first?.insertTimeRange(CMTimeRangeMake(start: CMTime.zero, duration: aVideoAssetTrack.timeRange.duration), of: aVideoAssetTrack, at: CMTime.zero)
                    try mutableCompositionAudioTrack.first?.insertTimeRange(CMTimeRangeMake(start: CMTime.zero, duration: aVideoAssetTrack.timeRange.duration), of: aAudioAssetTrack, at: CMTime.zero)
                       videoTrack.preferredTransform = aVideoAssetTrack.preferredTransform

                } catch{
                    print(error)
                }


               totalVideoCompositionInstruction.timeRange = CMTimeRangeMake(start: CMTime.zero,duration: aVideoAssetTrack.timeRange.duration)
            }
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString)\(UUID().uuidString).mp4")
            if let exportSession = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) {
                exportSession.outputURL = outputURL
                exportSession.outputFileType = AVFileType.mp4
                exportSession.shouldOptimizeForNetworkUse = true

                /// try to export the file and handle the status cases
                exportSession.exportAsynchronously(completionHandler: {
                    switch exportSession.status {
                    case .failed:
                        if let _error = exportSession.error {
                            failure(_error)
                        }

                    case .cancelled:
                        if let _error = exportSession.error {
                            failure(_error)
                        }

                    default:
                        print("finished")
                        success(outputURL)
                    }
                })
            } else {
                failure(nil)
            }
    }
}
