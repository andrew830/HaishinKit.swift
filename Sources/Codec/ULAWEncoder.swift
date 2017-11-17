import Foundation
import AVFoundation

protocol ULAWAudioEncoderDelegate: class {
    func didSetFormatDescription(audio formatDescription:CMFormatDescription?)
    func sampleOutput(audio sampleBuffer: CMSampleBuffer)
}

final class ULAWEncoder: NSObject {
    static let supportedSettingsKeys:[String] = [
        "muted",
        "bitrate",
        "profile",
        "sampleRate", // down,up sampleRate not supported yet #58
    ]
    
    static let packetSize:UInt32 = 64 * 1024
    static let sizeOfUInt32:UInt32 = UInt32(MemoryLayout<UInt32>.size)
    static let framesPerPacket:UInt32 = 960
    
    static let defaultProfile:UInt32 = UInt32(MPEG4ObjectID.AAC_LC.rawValue)
    static let defaultBitrate:UInt32 = 64 * 1024
    // 0 means according to a input source
    static let defaultChannels:UInt32 = 1
    // 0 means according to a input source
    static let defaultSampleRate:Double = 8_000
    static let defaultMaximumBuffers:Int = 1
    static let defaultBufferListSize:Int = AudioBufferList.sizeInBytes(maximumBuffers: 1)
    #if os(iOS)
    static let defaultInClassDescriptions:[AudioClassDescription] = [
        AudioClassDescription(mType: kAudioEncoderComponentType, mSubType: kAudioFormatULaw, mManufacturer: kAppleSoftwareAudioCodecManufacturer),
        AudioClassDescription(mType: kAudioEncoderComponentType, mSubType: kAudioFormatULaw, mManufacturer: kAppleHardwareAudioCodecManufacturer)
    ]
    #else
    static let defaultInClassDescriptions:[AudioClassDescription] = []
    #endif
    
    var muted:Bool = false
    
    var bitrate:UInt32 = ULAWEncoder.defaultBitrate {
        didSet {
            lockQueue.async {
                guard let converter:AudioConverterRef = self._converter else {
                    return
                }
                var bitrate:UInt32 = self.bitrate * self.inDestinationFormat.mChannelsPerFrame
                AudioConverterSetProperty(
                    converter,
                    kAudioConverterEncodeBitRate,
                    ULAWEncoder.sizeOfUInt32, &bitrate
                )
            }
        }
    }
    
    var profile:UInt32 = ULAWEncoder.defaultProfile
    var channels:UInt32 = ULAWEncoder.defaultChannels
    var sampleRate:Double = ULAWEncoder.defaultSampleRate
    var inClassDescriptions:[AudioClassDescription] = ULAWEncoder.defaultInClassDescriptions
    var formatDescription:CMFormatDescription? = nil {
        didSet {
            if (!CMFormatDescriptionEqual(formatDescription, oldValue)) {
                delegate?.didSetFormatDescription(audio: formatDescription)
            }
        }
    }
    var lockQueue:DispatchQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.ULAWEncoder.lock")
    weak var delegate:ULAWAudioEncoderDelegate?
    internal(set) var running:Bool = false
    fileprivate var maximumBuffers:Int = ULAWEncoder.defaultMaximumBuffers
    fileprivate var bufferListSize:Int = ULAWEncoder.defaultBufferListSize
    fileprivate var currentBufferList:UnsafeMutableAudioBufferListPointer? = nil
    fileprivate var inSourceFormat:AudioStreamBasicDescription? {
        didSet {
            logger.info("\(String(describing: self.inSourceFormat))")
            guard let inSourceFormat:AudioStreamBasicDescription = self.inSourceFormat else {
                return
            }
            let nonInterleaved:Bool = inSourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            maximumBuffers = nonInterleaved ? Int(inSourceFormat.mChannelsPerFrame) : ULAWEncoder.defaultMaximumBuffers
            bufferListSize = nonInterleaved ? AudioBufferList.sizeInBytes(maximumBuffers: maximumBuffers) : ULAWEncoder.defaultBufferListSize
        }
    }
    fileprivate var _inDestinationFormat:AudioStreamBasicDescription?
    fileprivate var inDestinationFormat:AudioStreamBasicDescription {
        get {
            if (_inDestinationFormat == nil) {
                _inDestinationFormat = AudioStreamBasicDescription()
                _inDestinationFormat!.mSampleRate = 8_000
                _inDestinationFormat!.mFormatID = kAudioFormatULaw
                _inDestinationFormat!.mFormatFlags = 0
                _inDestinationFormat!.mBytesPerPacket = 0
                _inDestinationFormat!.mFramesPerPacket = ULAWEncoder.framesPerPacket
                _inDestinationFormat!.mBytesPerFrame = 8
                _inDestinationFormat!.mChannelsPerFrame = 1
                _inDestinationFormat!.mBitsPerChannel = 16
                
                CMAudioFormatDescriptionCreate(
                    kCFAllocatorDefault, &_inDestinationFormat!, 0, nil, 0, nil, nil, &formatDescription
                )
            }
            return _inDestinationFormat!
        }
        set {
            _inDestinationFormat = newValue
        }
    }
    
    fileprivate var inputDataProc:AudioConverterComplexInputDataProc = {(
        converter:AudioConverterRef,
        ioNumberDataPackets:UnsafeMutablePointer<UInt32>,
        ioData:UnsafeMutablePointer<AudioBufferList>,
        outDataPacketDescription:UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
        inUserData:UnsafeMutableRawPointer?) in
        return Unmanaged<ULAWEncoder>.fromOpaque(inUserData!).takeUnretainedValue().onInputDataForAudioConverter(
            ioNumberDataPackets,
            ioData: ioData,
            outDataPacketDescription: outDataPacketDescription
        )
    }
    
    fileprivate var _converter:AudioConverterRef?
    fileprivate var converter:AudioConverterRef {
        var status:OSStatus = noErr
        if (_converter == nil) {
            var converter:AudioConverterRef? = nil
            status = AudioConverterNewSpecific(
                &inSourceFormat!,
                &inDestinationFormat,
                UInt32(inClassDescriptions.count),
                &inClassDescriptions,
                &converter
            )
            _converter = converter
        }
        if (status != noErr) {
            logger.warn("\(status)")
        }
        return _converter!
    }
    
    func encodeSampleBuffer(_ sampleBuffer:CMSampleBuffer) {
        guard let format:CMAudioFormatDescription = sampleBuffer.formatDescription, running else {
            return
        }
        
        guard let data:Data = sampleBuffer.dataBuffer?.data else {
            return
        }
        
        if (inSourceFormat == nil) {
            inSourceFormat = format.streamBasicDescription?.pointee
        }
        
        var blockBuffer:CMBlockBuffer? = nil
        currentBufferList = AudioBufferList.allocate(maximumBuffers: maximumBuffers)
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            nil,
            currentBufferList!.unsafeMutablePointer,
            bufferListSize,
            kCFAllocatorDefault,
            kCFAllocatorDefault,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &blockBuffer
        )
        
        guard let blockData:Data = blockBuffer?.data else {
            return
        }
        
        if (muted) {
            for i in 0..<currentBufferList!.count {
                memset(currentBufferList![i].mData, 0, Int(currentBufferList![i].mDataByteSize))
            }
        }
        
        //        var packetsPerBuffer: UInt32 = 0
        var maxOutputPacketSize: UInt32 = 0
        var outputBufferSize: UInt32 = 1024 * 50
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        
        let result:OSStatus = AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &propSize, &maxOutputPacketSize)
        if (result != noErr)
        {
            logger.warn("\(result)")
            maxOutputPacketSize = outputBufferSize
        }
        //        if (maxOutputPacketSize > outputBufferSize)
        //        {
        //            outputBufferSize = maxOutputPacketSize
        //        }
        //        packetsPerBuffer = outputBufferSize / maxOutputPacketSize
        
        
        let dataLength:Int = blockBuffer!.dataLength * 2
        var ioOutputDataPacketSize:UInt32 = 1024 * 64
        let outOutputData:UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(maximumBuffers: 1)
        outOutputData[0].mNumberChannels = 1
        outOutputData[0].mDataByteSize = 512
        outOutputData[0].mData = UnsafeMutableRawPointer.allocate(bytes: dataLength, alignedTo: 0)
        
        let status:OSStatus = AudioConverterFillComplexBuffer(
            converter,
            inputDataProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &ioOutputDataPacketSize,
            outOutputData.unsafeMutablePointer,
            nil
        )
        
        // XXX: perhaps mistake. but can support macOS BuiltIn Mic #61
        if (0 <= status) {
            var result:CMSampleBuffer?
            var timing:CMSampleTimingInfo = CMSampleTimingInfo(sampleBuffer: sampleBuffer)
            let numSamples:CMItemCount = 24000
            CMSampleBufferCreate(kCFAllocatorDefault, nil, false, nil, nil, formatDescription, numSamples, 1, &timing, 0, nil, &result)
            CMSampleBufferSetDataBufferFromAudioBufferList(result!, kCFAllocatorDefault, kCFAllocatorDefault, 0, outOutputData.unsafePointer)
            guard let createdData:Data = result?.dataBuffer?.data else {
                return
            }
            delegate?.sampleOutput(audio: result!)
        }
        
        for i in 0..<outOutputData.count {
            free(outOutputData[i].mData)
        }
        
        free(outOutputData.unsafeMutablePointer)
    }
    
    func invalidate() {
        lockQueue.async {
            self.inSourceFormat = nil
            self._inDestinationFormat = nil
            if let converter:AudioConverterRef = self._converter {
                AudioConverterDispose(converter)
            }
            self._converter = nil
        }
    }
    
    func onInputDataForAudioConverter(
        _ ioNumberDataPackets:UnsafeMutablePointer<UInt32>,
        ioData:UnsafeMutablePointer<AudioBufferList>,
        outDataPacketDescription:UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        
        guard let bufferList:UnsafeMutableAudioBufferListPointer = currentBufferList else {
            ioNumberDataPackets.pointee = 0
            return -1
        }
        
        memcpy(ioData, bufferList.unsafePointer, bufferListSize)
        ioNumberDataPackets.pointee = 1
        free(bufferList.unsafeMutablePointer)
        currentBufferList = nil
        
        return noErr
    }
}

extension ULAWEncoder: Runnable {
    // MARK: Runnable
    func startRunning() {
        lockQueue.async {
            self.running = true
        }
    }
    func stopRunning() {
        lockQueue.async {
            if let convert:AudioQueueRef = self._converter {
                AudioConverterDispose(convert)
                self._converter = nil
            }
            self.inSourceFormat = nil
            self.formatDescription = nil
            self._inDestinationFormat = nil
            self.currentBufferList = nil
            self.running = false
        }
    }
}

