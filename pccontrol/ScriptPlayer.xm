#import "ScriptPlayer.h"
#include <roothide.h>
#include "Play.h"
#include "SocketServer.h"
#include "Process.h"
#include "Task.h"
#include "AlertBox.h"
#include "Config.h"
#include "Common.h"
#import <sys/stat.h>
#include <errno.h>
#include <stdlib.h>

static BOOL isPlaying = false;

static NSString *ZXShellQuote(NSString *value)
{
    if (!value) return @"''";
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *ZXFirstExecutablePath(NSArray<NSString *> *candidates)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if (path.length > 0 && [fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSString *ZXPythonPath(void)
{
    // Prefer specific versions before the generic `python3` symlink. If a
    // previous install of ZXTouch (or another package) pointed `python3` at a
    // broken interpreter (e.g. Procursus 3.7 whose libpython lives at a path
    // dyld can't resolve on rootless), a versioned binary is more likely to
    // actually load. 3.7 is dropped entirely — it aborts at dyld on 15+.
    return ZXFirstExecutablePath(@[
        jbroot(@"/usr/bin/python3.12"),
        jbroot(@"/usr/bin/python3.11"),
        jbroot(@"/usr/bin/python3.10"),
        jbroot(@"/usr/bin/python3.9"),
        jbroot(@"/usr/bin/python3.8"),
        jbroot(@"/usr/bin/python3"),
        @"/var/jb/usr/bin/python3.12",
        @"/var/jb/usr/bin/python3.11",
        @"/var/jb/usr/bin/python3.10",
        @"/var/jb/usr/bin/python3.9",
        @"/var/jb/usr/bin/python3.8",
        @"/var/jb/usr/bin/python3",
        @"/usr/bin/python3.12",
        @"/usr/bin/python3.11",
        @"/usr/bin/python3.10",
        @"/usr/bin/python3.9",
        @"/usr/bin/python3.8",
        @"/usr/bin/python3"
    ]);
}

static NSString *ZXShellPath(void)
{
    return ZXFirstExecutablePath(@[
        jbroot(@"/bin/sh"),
        jbroot(@"/usr/bin/sh"),
        @"/var/jb/bin/sh",
        @"/var/jb/usr/bin/sh",
        @"/bin/sh",
        @"/usr/bin/sh"
    ]) ?: @"/bin/sh";
}

static NSString *ZXPythonModulePath(void)
{
    // The zxtouch module ships under /usr/share/zxtouch/python and the postinst
    // also copies it into every installed Python's site/dist-packages. Include
    // the share path unconditionally so scripts still find `import zxtouch`
    // even if the copy step skipped a Python version installed later.
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *path in @[
        jbroot(@"/usr/share/zxtouch/python"),
        jbroot(@"/usr/lib/python3/site-packages"),
        jbroot(@"/usr/lib/python3/dist-packages"),
        @"/var/jb/usr/share/zxtouch/python",
        @"/var/jb/usr/lib/python3/site-packages",
        @"/var/jb/usr/lib/python3/dist-packages",
        @"/usr/lib/python3/site-packages",
        @"/usr/lib/python3/dist-packages"
    ]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [paths addObject:path];
        }
    }
    return [paths componentsJoinedByString:@":"];
}

@implementation ScriptPlayer
{
    int repeatTime;
    float interval;
    float speed;
    NSString* scriptBundlePath;
    UIWindow *_playIndicator;
    int currentScriptType; // -1 no task has specified; 0 not playing but has upcoming task; 1 raw file playing; 2 py file playing
    NSTimer *replayTimer;
    UIView *circleView;
    Boolean scriptPlayForceStop;
    volatile sig_atomic_t scriptStopRequested;
    pid_t pythonProcessGroup;
    Boolean switchAppBeforePlaying;
}

- (BOOL)isPlaying {
    return isPlaying;
}

- (NSString*)getCurrentBundlePath {
    if (!scriptBundlePath)
    {
        return @"";
    }
    return scriptBundlePath;
}

- (void)setPath:(NSString*)path {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change script path because a script is playing.");
        return;
    }
    scriptBundlePath = path;
}

- (void)setRepeatTime:(int)rt {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change repeat time because a script is playing.");
        return;
    }
    repeatTime = rt;
}

- (void)setInterval:(float)intv {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change interval because a script is playing.");
        return;
    }
    interval = intv;
}

- (void)setSpeed:(float)sp {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change speed because a script is playing.");
        return;
    }
    speed = sp;
}

- (void)setSwitchApp:(BOOL)value {
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: cannot change speed because a script is playing.");
        return;
    }
    switchAppBeforePlaying = value;
}


- (id)init {
    self = [super init];
    if (self)
    {
        [self clear];
        scriptStopRequested = 0;
        pythonProcessGroup = 0;
    }
    return self;
}

- (id)initWithPath:(NSString*)path {
    self = [super init];
    if (self)
    {
        scriptBundlePath = path;
        currentScriptType = -1;
        scriptStopRequested = 0;
        pythonProcessGroup = 0;
    }
    return self;
}

-(int)runScript:(NSError**)error {
    scriptStopRequested = 0;
    pythonProcessGroup = 0;

    if (!scriptBundlePath)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. ScriptBundlePath not set.");
        logScriptEvent(@"ERROR", @"cannot run script: bundle path not set");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. ScriptBundlePath not set.\r\n"}];
        return -1;
    }

    BOOL isDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:scriptBundlePath isDirectory:&isDir] || !isDir)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Path not found or it is not a directory.");
        logScriptEvent(@"ERROR", @"cannot run script '%@': path not found or not a directory", scriptBundlePath);
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Path not found or it is not a directory.\r\n"}];
        return -1;
    }

    // read info.plist into dictionary
    NSString *infoFilePath = [NSString stringWithFormat:@"%@/info.plist", scriptBundlePath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:infoFilePath isDirectory:&isDir])
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Info.plist not found.");
        logScriptEvent(@"ERROR", @"cannot run script '%@': info.plist not found", scriptBundlePath);
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Info.plist not found.\r\n"}];
        return -1;
    }
    NSDictionary *scriptInfo = [NSDictionary dictionaryWithContentsOfFile:infoFilePath];
    // get entry file extension
    NSString *entryFileName = scriptInfo[@"Entry"];
    NSString *fileExtension = [entryFileName pathExtension];

    NSString *foregroundApp = scriptInfo[@"FrontApp"];
    // call different functions depending on file extension

    if (![fileExtension isEqualToString:@"raw"] && ![fileExtension isEqualToString:@"py"])
    {
        // Nothing would play, so no indicator, no isPlaying, and no END event
        // would ever be logged. Reject before any state is touched.
        logScriptEvent(@"ERROR", @"cannot run script '%@': unsupported entry type '%@'", scriptBundlePath, fileExtension);
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Unsupported entry file type.\r\n"}];
        return -1;
    }

    // show indicator
    dispatch_async(dispatch_get_main_queue(), ^{
        _playIndicator = [[UIWindow alloc] initWithFrame:CGRectMake(0,0,10*2,10*2)];
        _playIndicator.windowLevel = UIWindowLevelStatusBar;
        _playIndicator.hidden = NO;
        [_playIndicator setBackgroundColor:[UIColor clearColor]];
        [_playIndicator setUserInteractionEnabled:NO];

        circleView = [[UIView alloc] initWithFrame:CGRectMake(0,0,10*2,10*2)];

        //circleView.alpha = 1;
        circleView.layer.cornerRadius = 10;  // half the width/height
        circleView.backgroundColor = [UIColor greenColor];
        [_playIndicator addSubview:circleView];
    });

    NSString *entryFilePath = [scriptBundlePath stringByAppendingPathComponent:entryFileName];
    NSLog(@"com.zjx.sprinboard: currently playing: %@. Repeat time: %d", entryFilePath, repeatTime);
    logScriptEvent(@"START", @"script: %@ | type: %@ | repeat: %d | speed: %.1f",
                   scriptBundlePath, fileExtension.uppercaseString, repeatTime, speed);

    // Mark playing synchronously, BEFORE dispatching. Callers hold the
    // scriptPlayer lock (Play.xm), so once this is set a second play() fails
    // its isPlaying check immediately instead of passing it while the first
    // run is still queued — both runs used to start concurrently sharing
    // scriptBundlePath/speed/repeatTime/pythonProcessGroup. The async
    // functions below no longer set it on entry; they only clear it on
    // failure or completion.
    isPlaying = true;

    if ([fileExtension isEqualToString:@"raw"])
    {
        currentScriptType = 1;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            [self playFromRawFile:entryFilePath foregroundApp:foregroundApp err:&err];
        });
    }
    else // "py" — validated above
    {
        currentScriptType = 2;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSError *err = nil;
            [self playFromPythonFile:entryFilePath foregroundApp:foregroundApp err:&err];
        });
    }

    return 0;
}

// play the script
- (int)play:(NSError**)error
{
    if (isPlaying)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Another script is currently running.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Another script is currently running.\r\n"}];
        return -1;
    }
    return [self runScript:error];
}


-(void)playFromRawFile:(NSString*) filePath foregroundApp:(NSString*)foregroundApp err:(NSError**)err
{
    // isPlaying was already set synchronously by runScript: before dispatch.
    if (switchAppBeforePlaying)
    {
        bringAppForeground(foregroundApp);
    }

    FILE *file = fopen([filePath UTF8String], "r");

    if (!file)
    {
        logScriptEvent(@"ERROR", @"cannot open raw file: %@", filePath);
        showAlertBox(@"Error", [NSString stringWithFormat:@"Cannot play this script because zxtouch cannot open the file. File path: %@", filePath], 999);
        isPlaying = false;
        return;
    }
    
    // getline() grows the buffer as needed. The previous fixed 256-byte
    // fgets() buffer silently split longer lines (e.g. long toast texts in
    // hand-written scripts) into two malformed commands.
    char *buffer = NULL;
    size_t bufferCapacity = 0;

    BOOL stoppedByUser = NO;
    while (getline(&buffer, &bufferCapacity, file) != -1)
    {
        if (scriptPlayForceStop)
        {
            scriptPlayForceStop = false;
            stoppedByUser = YES;
            break;
        }
        if (speed > 0 && speed != 1)
        {
            // check whether need to speed up
            int type, sleepTime;
            sscanf(buffer, "%2d", &type);
            if (type == TASK_USLEEP)
            {
                sscanf(buffer, "%2d%d", &type, &sleepTime);
                sleepTime = sleepTime / speed; // truncate the float part
                processTask((UInt8*)[[NSString stringWithFormat:@"18%d", sleepTime] UTF8String], NULL);
            }
            else
            {
                processTask((UInt8*)buffer, NULL);
            }
        }
        else
        {
            processTask((UInt8*)buffer, NULL);
        }

    }
    free(buffer);
    fclose(file);

    if (stoppedByUser)
    {
        logScriptEvent(@"STOP", @"script stopped by user (raw): %@", scriptBundlePath);
    }
    else
    {
        logScriptEvent(@"END", @"script finished (raw): %@", scriptBundlePath);
    }

    if (!stoppedByUser) [self playHasStopped];
}

-(void) playFromPythonFile:(NSString*) filePath foregroundApp:(NSString*) foregroundApp err:(NSError**) err
{
    // isPlaying was already set synchronously by runScript: before dispatch.

    if (switchAppBeforePlaying)
    {
        bringAppForeground(foregroundApp);
    }
    
    NSString *pythonPath = ZXPythonPath();
    if (!pythonPath)
    {
        logScriptEvent(@"ERROR", @"python3 not found on device (script: %@)", scriptBundlePath);
        showAlertBox(@"Python not installed",
                     @"ZXTouch could not find a working python3 on this device.\n\nOpen Sileo and install the 'python3' package from Procursus, then reinstall ZXTouch so it can register the new interpreter.",
                     999);
        isPlaying = false;
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
    {
        logScriptEvent(@"ERROR", @"script file not found in bdl folder: %@", filePath);
        showAlertBox(@"Error", [NSString stringWithFormat:@"Cannot play this script. Script file not found in bdl folder. Script path: %@", filePath], 999);
        isPlaying = false;
        return;
    }
    // Ensure output log file exists so the >> redirect doesn't fail
    NSString *outputLog = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output";
    if (![[NSFileManager defaultManager] fileExistsAtPath:outputLog])
        [@"" writeToFile:outputLog atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSString *dateWrapper = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/add_datetime.sh";
    NSString *shellPath = ZXShellPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:dateWrapper]) {
        NSString *wrapper = [NSString stringWithFormat:@"#!%@\nOUTPUT=/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output\nDATE=/var/jb/usr/bin/date\nif [ ! -x \"$DATE\" ]; then DATE=/usr/bin/date; fi\nif [ ! -x \"$DATE\" ]; then DATE=/bin/date; fi\necho \"$($DATE '+%%m-%%d-%%Y %%T'): Start running script. Script path: $1\" >> \"$OUTPUT\"\nwhile IFS= read -r line; do\n    echo \"$($DATE '+%%m-%%d-%%Y %%T'): $line\" >> \"$OUTPUT\"\ndone\n", shellPath];
        [wrapper writeToFile:dateWrapper atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(dateWrapper.UTF8String, 0755);
    }

    NSString *scriptDir = [filePath stringByDeletingLastPathComponent];
    NSString *statusFile = @"/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/last_python_status";
    NSString *pythonModulePath = ZXPythonModulePath();
    NSString *envPrefix = pythonModulePath.length > 0 ? [NSString stringWithFormat:@"PYTHONPATH=%@ ", ZXShellQuote(pythonModulePath)] : @"";
    NSString *commandToRun = [NSString stringWithFormat:@"rm -f %@; (cd %@ && %@%@ -u %@ 2>&1; echo $? > %@) | %@ %@ %@; exit $(cat %@ 2>/dev/null || echo 1)",
                              ZXShellQuote(statusFile),
                              ZXShellQuote(scriptDir),
                              envPrefix,
                              ZXShellQuote(pythonPath),
                              ZXShellQuote(filePath),
                              ZXShellQuote(statusFile),
                              ZXShellQuote(shellPath),
                              ZXShellQuote(dateWrapper),
                              ZXShellQuote(filePath),
                              ZXShellQuote(statusFile)];
    NSLog(@"com.zjx.springboard: command to run for running py file %@", commandToRun);

    int shellExitCode = system2Cancelable([commandToRun UTF8String], NULL, NULL,
                                          &pythonProcessGroup, &scriptStopRequested);
    BOOL stoppedByUser = scriptStopRequested != 0;
    scriptStopRequested = 0;
    NSString *statusText = [NSString stringWithContentsOfFile:statusFile encoding:NSUTF8StringEncoding error:nil];
    int pythonExitCode = statusText ? [statusText intValue] : shellExitCode;
    if (!stoppedByUser && pythonExitCode != 0) {
        NSString *title = @"Script Error";
        NSString *message;
        NSString *logTail = [NSString stringWithContentsOfFile:outputLog encoding:NSUTF8StringEncoding error:nil] ?: @"";
        BOOL dyldLibpythonMissing = [logTail rangeOfString:@"Library not loaded" options:0].location != NSNotFound &&
                                    [logTail rangeOfString:@"libpython" options:0].location != NSNotFound;
        if (statusText == nil && shellExitCode < 0) {
            // system2 failed before python could run — spawn was denied or the
            // shell was unusable. Common on semi-jailbreaks with stripped
            // entitlements. Check Console.app for `system2` NSLog output.
            title = @"Script could not launch";
            message = @"ZXTouch could not start a shell to run the script (posix_spawn failed).\n\nOpen Console.app (or `oslog`) and search for `com.zjx.springboard: system2` to see the exact error.";
        } else if (pythonExitCode == 134 && dyldLibpythonMissing) {
            // 134 = SIGABRT. Dyld couldn't find libpython — the interpreter
            // was linked against a path that doesn't exist on this JB (classic
            // Procursus python3.7 on rootless).
            title = @"Python interpreter is broken";
            message = @"The installed python3 aborted at launch because dyld cannot find its libpython dylib.\n\nInstall the 'python3' package (3.9 or newer) from Sileo (Procursus), then reinstall ZXTouch so it re-picks the working interpreter.";
        } else {
            message = [NSString stringWithFormat:@"Python script exited with code %d. Open Logs for the traceback.", pythonExitCode];
        }
        NSLog(@"com.zjx.springboard: %@ — %@", title, message);
        showAlertBox(title, message, 999);
    }

    if (stoppedByUser)
    {
        logScriptEvent(@"STOP", @"script stopped by user (py): %@", scriptBundlePath);
    }
    else if (pythonExitCode != 0)
    {
        // Traceback of the Python run is captured in outputLog — point the
        // user at it so the execution log alone is enough to diagnose.
        logScriptEvent(@"ERROR", @"script exited with code %d (py): %@ | output: %@",
                       pythonExitCode, scriptBundlePath, outputLog);
    }
    else
    {
        logScriptEvent(@"END", @"script finished (py): %@", scriptBundlePath);
    }

    if (!stoppedByUser) [self playHasStopped];
}

- (void)replay:(NSTimer*)nstimer {
    NSLog(@"com.zjx.springboard: script is replaying...");
    NSError *err = nil;

    // Take the same lock Play.xm uses for start/stop so the synchronous
    // isPlaying = true inside runScript: is not racing a concurrent
    // forceStop/play from another thread.
    @synchronized(self)
    {
        [self runScript:&err];
    }

    CFRunLoopStop(CFRunLoopGetCurrent());
}

-(void) playHasStopped
{
    // If forceStop already called clear(), isPlaying is false — nothing to do
    if (!isPlaying) return;

    NSLog(@"com.zjx.springboard: script has finished");

    // check whether need to replay
    if (repeatTime != 0)
    {    
        dispatch_async(dispatch_get_main_queue(), ^{
            circleView.backgroundColor = [UIColor orangeColor];
        });

        NSLog(@"com.zjx.springboard: need replay. Replay time: %d", repeatTime);

        replayTimer = [NSTimer scheduledTimerWithTimeInterval:interval
         target:self selector:@selector(replay:) 
         userInfo:nil repeats:NO];
        repeatTime--;

        currentScriptType = 0;

        CFRunLoopRun();
    }
    else
    {
        [self clear];
    }
}

- (void)clear {
    repeatTime = 0;
    interval = 0.0f;
    speed = 1.0f;
    scriptBundlePath = nil;
    isPlaying = false;
    currentScriptType = -1;
    //scriptPlayForceStop = false;

    // remove indicator
    dispatch_async(dispatch_get_main_queue(), ^{
        _playIndicator.hidden = YES;
        _playIndicator = nil;
    });

    if (replayTimer)
        [replayTimer invalidate];

    replayTimer = nil;
}

- (void)forceStop:(NSError**)error {
    if (currentScriptType == -1)
    {
        NSLog(@"com.zjx.springboard: Cannot stop playing script. No script is playing.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Cannot stop script. No script is playing.\r\n"}];
        return;
    }

    if (currentScriptType == 0)
    {
        [self clear];
    }
    else if (currentScriptType == 1)
    {
        // make stop to be true
        scriptPlayForceStop = true;
        [self clear];
    }
    else if (currentScriptType == 2)
    {
        scriptStopRequested = 1;
        pid_t processGroup = pythonProcessGroup;
        if (processGroup > 0 && kill(-processGroup, SIGKILL) != 0 && errno != ESRCH) {
            NSLog(@"com.zjx.springboard: failed to stop Python process group %d: errno %d",
                  processGroup, errno);
        }
        [self clear];
    }
    else
    {
        NSLog(@"com.zjx.springboard: unknown currently playing script type.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Cannot stop script. Unkonwn currently playing script type.\r\n"}];
        return;
    }

}

@end
