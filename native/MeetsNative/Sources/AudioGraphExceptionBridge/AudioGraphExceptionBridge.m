#import "AudioGraphExceptionBridge.h"

static NSString *const MeetsAudioGraphErrorDomain = @"MeetsAudioGraph";

static NSError *MeetsAudioGraphExceptionError(NSException *exception, NSString *operation) {
    return [NSError errorWithDomain:MeetsAudioGraphErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"%@ failed: %@", operation,
                                           exception.reason ?: exception.name]}];
}

@interface MeetsAudioInputState ()
@property(nonatomic, readwrite, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readwrite, nullable) NSError *error;
@end

@implementation MeetsAudioInputState
@end

MeetsAudioInputState *MeetsAudioGraphReadInputState(AVAudioEngine *engine) {
    MeetsAudioInputState *state = [[MeetsAudioInputState alloc] init];
    @try {
        AVAudioFormat *format = [engine.inputNode outputFormatForBus:0];
        if (format.streamDescription == NULL) {
            state.error = [NSError errorWithDomain:MeetsAudioGraphErrorDomain
                                              code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                         @"The microphone input format is unavailable"}];
        } else {
            state.outputFormat = format;
        }
    } @catch (NSException *exception) {
        state.error = MeetsAudioGraphExceptionError(exception, @"Read microphone input state");
    }
    return state;
}

NSError *MeetsAudioGraphSetInputDevice(AVAudioEngine *engine, AudioObjectID deviceID) {
    @try {
        AudioUnit audioUnit = engine.inputNode.audioUnit;
        if (audioUnit == NULL) {
            return [NSError errorWithDomain:MeetsAudioGraphErrorDomain
                                       code:4
                                   userInfo:@{NSLocalizedDescriptionKey:
                                                  @"No audio unit is available for preferred input routing"}];
        }
        OSStatus status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            sizeof(deviceID)
        );
        if (status != noErr) {
            return [NSError errorWithDomain:NSOSStatusErrorDomain
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey:
                                                  @"Could not select the requested microphone"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return MeetsAudioGraphExceptionError(exception, @"Select microphone input device");
    }
}

NSError *MeetsAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *format,
    AVAudioNodeTapBlock block
) {
    @try {
        [engine.inputNode installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return nil;
    } @catch (NSException *exception) {
        return MeetsAudioGraphExceptionError(exception, @"Install microphone tap");
    }
}

NSError *MeetsAudioGraphPrepareEngine(AVAudioEngine *engine) {
    @try {
        [engine prepare];
        return nil;
    } @catch (NSException *exception) {
        return MeetsAudioGraphExceptionError(exception, @"Prepare audio engine");
    }
}

NSError *MeetsAudioGraphStartEngine(AVAudioEngine *engine) {
    @try {
        NSError *error = nil;
        if (![engine startAndReturnError:&error]) {
            return error ?: [NSError errorWithDomain:MeetsAudioGraphErrorDomain
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Start audio engine failed"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return MeetsAudioGraphExceptionError(exception, @"Start audio engine");
    }
}

NSError *MeetsAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus) {
    @try {
        [engine.inputNode removeTapOnBus:bus];
        return nil;
    } @catch (NSException *exception) {
        return MeetsAudioGraphExceptionError(exception, @"Remove microphone tap");
    }
}

NSError *MeetsAudioGraphStopEngine(AVAudioEngine *engine) {
    @try {
        [engine stop];
        return nil;
    } @catch (NSException *exception) {
        return MeetsAudioGraphExceptionError(exception, @"Stop audio engine");
    }
}
