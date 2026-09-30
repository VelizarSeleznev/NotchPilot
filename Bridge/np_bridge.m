// Loaded into /usr/bin/perl by NotchPilot. Since macOS 15.4 MediaRemote only answers
// Apple-signed clients, so this bridge runs inside perl and speaks JSON lines over stdio.
// stdout: one JSON object per now-playing change. stdin: "cmd <n>" | "seek <sec>".
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPid)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetPid getPid;
static MRGetPlaying getPlaying;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;
static NSString *lastLine;
static NSString *lastArtworkId;
static dispatch_queue_t queue;
static double lastElapsed, lastStamp, lastRate;

static void emit(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id jsonable(id v) {
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    return nil;
}

static void refresh(void) {
    getInfo(queue, ^(NSDictionary *info) {
        getPid(queue, ^(int pid) {
            getPlaying(queue, ^(Boolean playing) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"pid"] = @(pid);
                out[@"playing"] = @(playing);
                NSData *artwork = nil;
                for (NSString *key in info) {
                    if (![key hasPrefix:@"kMRMediaRemoteNowPlayingInfo"]) continue;
                    NSString *name = [key substringFromIndex:28];
                    id v = info[key];
                    if ([name isEqualToString:@"ArtworkData"] && [v isKindOfClass:[NSData class]]) { artwork = v; continue; }
                    id j = jsonable(v);
                    if (j) out[name] = j;
                }
                // Compare without the ever-moving timestamps so identical states are not re-sent.
                NSMutableDictionary *cmp = [out mutableCopy];
                [cmp removeObjectForKey:@"Timestamp"];
                for (NSString *k in @[@"CurrentPlaybackDate", @"ContentItemIdentifier", @"ArtworkDataWidth", @"ArtworkDataHeight", @"UniqueIdentifier"]) {
                    [cmp removeObjectForKey:k];
                    [out removeObjectForKey:k];
                }
                // Elapsed time ticks every second while playing; only a jump (seek) is news.
                double elapsed = [out[@"ElapsedTime"] doubleValue];
                double stamp = [out[@"Timestamp"] doubleValue];
                double rate = [out[@"PlaybackRate"] doubleValue];
                double expected = lastElapsed + (stamp - lastStamp) * lastRate;
                BOOL seeked = fabs(elapsed - expected) > 1.5;
                [cmp removeObjectForKey:@"ElapsedTime"];
                if (seeked) cmp[@"seekMark"] = @(elapsed);
                else if (lastLine) cmp[@"seekMark"] = @0;
                NSString *artId = out[@"ArtworkIdentifier"] ?: (artwork ? [NSString stringWithFormat:@"len%lu", (unsigned long)artwork.length] : @"");
                NSString *line = [NSString stringWithFormat:@"%@|%@", cmp, artId];
                BOOL artworkChanged = artwork && ![artId isEqualToString:lastArtworkId ?: @""];
                if ([line isEqualToString:lastLine ?: @""] && !artworkChanged) return;
                lastLine = line;
                lastElapsed = elapsed; lastStamp = stamp; lastRate = rate;
                if (artworkChanged) {
                    lastArtworkId = artId;
                    out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                }
                out[@"artworkKey"] = artId;
                emit(out);
            });
        });
    });
}

static void readCommands(void) {
    char buf[256];
    while (fgets(buf, sizeof buf, stdin)) {
        int cmd; double sec;
        if (sscanf(buf, "cmd %d", &cmd) == 1) sendCommand(cmd, nil);
        else if (sscanf(buf, "seek %lf", &sec) == 1) setElapsed(sec);
        else if (strncmp(buf, "refresh", 7) == 0) { lastLine = nil; lastArtworkId = nil; }
        // Always report after a command so the app's optimistic state gets corrected.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), queue, ^{ lastLine = nil; refresh(); });
    }
    exit(0); // parent went away
}

void np_run(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { emit(@{@"error": @"MediaRemote unavailable"}); exit(1); }
    getInfo = (MRGetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPid = (MRGetPid)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    getPlaying = (MRGetPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (MRSendCommand)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(h, "MRMediaRemoteSetElapsedTime");
    MRRegister reg = (MRRegister)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    queue = dispatch_queue_create("np.bridge", DISPATCH_QUEUE_SERIAL);
    reg(queue);
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { dispatch_async(queue, ^{ refresh(); }); }];
    }
    // Safety net: some players change state without notifying.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, 500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ refresh(); });
    dispatch_resume(timer);
    [NSThread detachNewThreadWithBlock:^{ readCommands(); }];
    CFRunLoopRun();
}
