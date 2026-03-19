//
//  ViewController.m
//  whisper.objc
//
//  Created by Georgi Gerganov on 23.10.22.
//  Modified for Whisper iOS Lectures app.
//

#import "ViewController.h"
#import <whisper/whisper.h>

#define NUM_BYTES_PER_BUFFER 16*1024

void AudioInputCallback(void * inUserData,
                        AudioQueueRef inAQ,
                        AudioQueueBufferRef inBuffer,
                        const AudioTimeStamp * inStartTime,
                        UInt32 inNumberPacketDescriptions,
                        const AudioStreamPacketDescription * inPacketDescs);

@interface ViewController ()

@property (weak, nonatomic) IBOutlet UILabel    *labelStatusInp;
@property (weak, nonatomic) IBOutlet UIButton   *buttonToggleCapture;
@property (weak, nonatomic) IBOutlet UIButton   *buttonTranscribe;
@property (weak, nonatomic) IBOutlet UIButton   *buttonRealtime;
@property (weak, nonatomic) IBOutlet UIButton   *buttonShare;
@property (weak, nonatomic) IBOutlet UITextView *textviewResult;

@end

@implementation ViewController

- (void)setupAudioFormat:(AudioStreamBasicDescription*)format
{
    format->mSampleRate       = WHISPER_SAMPLE_RATE;
    format->mFormatID         = kAudioFormatLinearPCM;
    format->mFramesPerPacket  = 1;
    format->mChannelsPerFrame = 1;
    format->mBytesPerFrame    = 2;
    format->mBytesPerPacket   = 2;
    format->mBitsPerChannel   = 16;
    format->mReserved         = 0;
    format->mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // whisper.cpp initialization
    {
        NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"ggml-medium" ofType:@"bin"];

        if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
            NSLog(@"Model file not found");
            _labelStatusInp.text = @"Ошибка: модель не найдена";
            return;
        }

        NSLog(@"Loading model from %@", modelPath);
        _labelStatusInp.text = @"Загрузка модели...";

        struct whisper_context_params cparams = whisper_context_default_params();
#if TARGET_OS_SIMULATOR
        cparams.use_gpu = false;
        NSLog(@"Running on simulator, using CPU");
#endif
        stateInp.ctx = whisper_init_from_file_with_params([modelPath UTF8String], cparams);

        if (stateInp.ctx == NULL) {
            NSLog(@"Failed to load model");
            _labelStatusInp.text = @"Ошибка загрузки модели";
            return;
        }

        _labelStatusInp.text = @"Готово к записи";
    }

    // initialize audio format and buffers
    {
        [self setupAudioFormat:&stateInp.dataFormat];

        stateInp.n_samples = 0;
        stateInp.audioBufferI16 = malloc(MAX_AUDIO_SEC * SAMPLE_RATE * sizeof(int16_t));
        stateInp.audioBufferF32 = malloc(MAX_AUDIO_SEC * SAMPLE_RATE * sizeof(float));

        NSError *error = nil;

        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:&error];
        if (error) {
            NSLog(@"Error setting audio session category: %@", error);
        }

        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        if (error) {
            NSLog(@"Error activating audio session: %@", error);
        }
    }

    stateInp.isTranscribing = false;
    stateInp.isRealtime = false;

    // Share button initially disabled
    _buttonShare.enabled = NO;
    _buttonShare.alpha = 0.5;
}

-(IBAction) stopCapturing {
    NSLog(@"Stop capturing");

    float recordedSeconds = (float)stateInp.n_samples / (float)stateInp.dataFormat.mSampleRate;
    int minutes = (int)recordedSeconds / 60;
    int seconds = (int)recordedSeconds % 60;
    _labelStatusInp.text = [NSString stringWithFormat:@"Записано %d:%02d", minutes, seconds];

    [_buttonToggleCapture setTitle:@"Начать запись" forState:UIControlStateNormal];
    [_buttonToggleCapture setBackgroundColor:[UIColor systemGrayColor]];

    stateInp.isCapturing = false;

    AudioQueueStop(stateInp.queue, true);
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueFreeBuffer(stateInp.queue, stateInp.buffers[i]);
    }

    AudioQueueDispose(stateInp.queue, true);
}

- (IBAction)toggleCapture:(id)sender {
    if (stateInp.isCapturing) {
        [self stopCapturing];
        return;
    }

    NSLog(@"Start capturing");

    stateInp.n_samples = 0;
    stateInp.vc = (__bridge void *)(self);

    OSStatus status = AudioQueueNewInput(&stateInp.dataFormat,
                                         AudioInputCallback,
                                         &stateInp,
                                         CFRunLoopGetCurrent(),
                                         kCFRunLoopCommonModes,
                                         0,
                                         &stateInp.queue);

    if (status == 0) {
        for (int i = 0; i < NUM_BUFFERS; i++) {
            AudioQueueAllocateBuffer(stateInp.queue, NUM_BYTES_PER_BUFFER, &stateInp.buffers[i]);
            AudioQueueEnqueueBuffer (stateInp.queue, stateInp.buffers[i], 0, NULL);
        }

        stateInp.isCapturing = true;
        status = AudioQueueStart(stateInp.queue, NULL);
        if (status == 0) {
            _labelStatusInp.text = @"Запись...";
            [sender setTitle:@"Остановить" forState:UIControlStateNormal];
            [_buttonToggleCapture setBackgroundColor:[UIColor systemRedColor]];
        }
    }

    if (status != 0) {
        [self stopCapturing];
    }
}

- (IBAction)onTranscribePrepare:(id)sender {
    _textviewResult.text = @"Обработка — подождите...";

    if (stateInp.isRealtime) {
        [self onRealtime:(id)sender];
    }

    if (stateInp.isCapturing) {
        [self stopCapturing];
    }
}

- (IBAction)onRealtime:(id)sender {
    stateInp.isRealtime = !stateInp.isRealtime;

    if (stateInp.isRealtime) {
        [_buttonRealtime setBackgroundColor:[UIColor systemGreenColor]];
    } else {
        [_buttonRealtime setBackgroundColor:[UIColor systemGrayColor]];
    }

    NSLog(@"Realtime: %@", stateInp.isRealtime ? @"ON" : @"OFF");
}

- (IBAction)onTranscribe:(id)sender {
    if (stateInp.isTranscribing) {
        return;
    }

    NSLog(@"Processing %d samples", stateInp.n_samples);

    stateInp.isTranscribing = true;

    dispatch_async(dispatch_get_main_queue(), ^{
        self->_labelStatusInp.text = @"Распознавание...";
        self->_buttonShare.enabled = NO;
        self->_buttonShare.alpha = 0.5;
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // convert I16 to F32
        for (int i = 0; i < self->stateInp.n_samples; i++) {
            self->stateInp.audioBufferF32[i] = (float)self->stateInp.audioBufferI16[i] / 32768.0f;
        }

        struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);

        const int max_threads = MIN(8, (int)[[NSProcessInfo processInfo] processorCount]);

        params.print_realtime   = true;
        params.print_progress   = false;
        params.print_timestamps = true;
        params.print_special    = false;
        params.translate        = false;
        params.language         = "ru";
        params.n_threads        = max_threads;
        params.offset_ms        = 0;
        params.no_context       = true;
        params.single_segment   = self->stateInp.isRealtime;
        params.no_timestamps    = params.single_segment;

        CFTimeInterval startTime = CACurrentMediaTime();

        whisper_reset_timings(self->stateInp.ctx);

        if (whisper_full(self->stateInp.ctx, params, self->stateInp.audioBufferF32, self->stateInp.n_samples) != 0) {
            NSLog(@"Failed to run the model");
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_textviewResult.text = @"Ошибка распознавания";
                self->_labelStatusInp.text = @"Ошибка";
                self->stateInp.isTranscribing = false;
            });
            return;
        }

        whisper_print_timings(self->stateInp.ctx);

        CFTimeInterval endTime = CACurrentMediaTime();

        NSLog(@"\nProcessing time: %5.3f, on %d threads", endTime - startTime, params.n_threads);

        NSString *result = @"";

        int n_segments = whisper_full_n_segments(self->stateInp.ctx);
        for (int i = 0; i < n_segments; i++) {
            const char * text_cur = whisper_full_get_segment_text(self->stateInp.ctx, i);
            result = [result stringByAppendingString:[NSString stringWithUTF8String:text_cur]];
        }

        const float tRecording = (float)self->stateInp.n_samples / (float)self->stateInp.dataFormat.mSampleRate;

        result = [result stringByAppendingString:[NSString stringWithFormat:@"\n\n[время записи:     %5.1f с]", tRecording]];
        result = [result stringByAppendingString:[NSString stringWithFormat:@"\n[время обработки:  %5.1f с]", endTime - startTime]];

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_textviewResult.text = result;
            self->_labelStatusInp.text = @"Готово";
            self->stateInp.isTranscribing = false;

            // Enable share button
            self->_buttonShare.enabled = YES;
            self->_buttonShare.alpha = 1.0;
        });
    });
}

- (IBAction)onShare:(id)sender {
    NSString *textToShare = _textviewResult.text;
    if (textToShare.length == 0) {
        return;
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc]
        initWithActivityItems:@[textToShare]
        applicationActivities:nil];

    // For iPad
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = _buttonShare;
        activityVC.popoverPresentationController.sourceRect = _buttonShare.bounds;
    }

    [self presentViewController:activityVC animated:YES completion:nil];
}

//
// Callback implementation
//

void AudioInputCallback(void * inUserData,
                        AudioQueueRef inAQ,
                        AudioQueueBufferRef inBuffer,
                        const AudioTimeStamp * inStartTime,
                        UInt32 inNumberPacketDescriptions,
                        const AudioStreamPacketDescription * inPacketDescs)
{
    StateInp * stateInp = (StateInp*)inUserData;

    if (!stateInp->isCapturing) {
        NSLog(@"Not capturing, ignoring audio");
        return;
    }

    const int n = inBuffer->mAudioDataByteSize / 2;

    if (stateInp->n_samples + n > MAX_AUDIO_SEC * SAMPLE_RATE) {
        NSLog(@"Audio buffer full, stopping capture");

        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController * vc = (__bridge ViewController *)(stateInp->vc);
            [vc stopCapturing];
        });

        return;
    }

    for (int i = 0; i < n; i++) {
        stateInp->audioBufferI16[stateInp->n_samples + i] = ((short*)inBuffer->mAudioData)[i];
    }

    stateInp->n_samples += n;

    // Update recording time on UI
    if (stateInp->n_samples % (SAMPLE_RATE * 5) < n) {
        float recordedSeconds = (float)stateInp->n_samples / (float)SAMPLE_RATE;
        int minutes = (int)recordedSeconds / 60;
        int seconds = (int)recordedSeconds % 60;
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController * vc = (__bridge ViewController *)(stateInp->vc);
            vc->_labelStatusInp.text = [NSString stringWithFormat:@"Запись... %d:%02d", minutes, seconds];
        });
    }

    AudioQueueEnqueueBuffer(stateInp->queue, inBuffer, 0, NULL);

    if (stateInp->isRealtime) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ViewController * vc = (__bridge ViewController *)(stateInp->vc);
            [vc onTranscribe:nil];
        });
    }
}

@end
