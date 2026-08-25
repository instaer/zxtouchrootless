#include "Play.h"
#include "SocketServer.h"
#include "Process.h"
#include "Task.h"
#include "AlertBox.h"
#include "Config.h"
#import "ScriptPlayer.h"
#include "Common.h"

static BOOL switchAppBeforeRunScript = true;
ScriptPlayer *scriptPlayer;

void initScriptPlayer()
{
    scriptPlayer = [[ScriptPlayer alloc] init];
}

void updateSwtichAppBeforeRunScript(BOOL value)
{
    switchAppBeforeRunScript = value;
}

int playScript(UInt8* path, NSError **error)
{
    if (!scriptPlayer)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Internal error. scriptPlayer is null.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Internal error. scriptPlayer is null.\r\n"}];
        return -1;
    }
    // read config file to get repeat time etc
    int repeatTime = 0;
    float sleepBetweenRun = 0;
    float playSpeed = 1.0f;
    
    NSLog(@"com.zjx.springboard: path: %s", path);
    NSDictionary *config = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:SCRIPT_PLAY_CONFIG_PATH])
        config = [[NSDictionary alloc] initWithContentsOfFile:SCRIPT_PLAY_CONFIG_PATH];

    if (config)
    {
        // App-launched scripts only use per-script settings written by the app.
        // Floating panel settings are handled separately so they do not leak.
        NSDictionary *individualConfigs = config[@"individual_configs"];
        NSDictionary *scriptInfo = [individualConfigs valueForKey:[NSString stringWithFormat:@"%s", path]];

        if (scriptInfo)
        {
            repeatTime = [scriptInfo[@"repeat_times"] intValue];
            sleepBetweenRun = [scriptInfo[@"interval"] floatValue];
            float sp = [scriptInfo[@"speed"] floatValue];
            if (sp > 0) playSpeed = sp;
        }
    }

    return playScriptWithSettings(path, repeatTime, playSpeed, sleepBetweenRun, error);
}

int playScriptWithSettings(UInt8* path, int repeatTime, float playSpeed, float sleepBetweenRun, NSError **error)
{
    if (!scriptPlayer)
    {
        NSLog(@"com.zjx.springboard: Unable to run the script. Internal error. scriptPlayer is null.");
        *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unable to run the script. Internal error. scriptPlayer is null.\r\n"}];
        return -1;
    }
    if (playSpeed <= 0) playSpeed = 1.0f;

    // Commands from different clients can now run concurrently (per-
    // connection queues in SocketServer). Serialize configure+start and
    // stop against each other so one client can't start a script while
    // another's settings are half-applied.
    @synchronized(scriptPlayer)
    {
        [scriptPlayer setPath:[NSString stringWithFormat:@"%s", path]];
        [scriptPlayer setRepeatTime:repeatTime];
        [scriptPlayer setSpeed:playSpeed];
        [scriptPlayer setInterval:sleepBetweenRun];
        [scriptPlayer setSwitchApp:switchAppBeforeRunScript];

        [scriptPlayer play:error];
    }

    return 0;
}


void stopScriptPlaying(NSError **error)
{
    @synchronized(scriptPlayer)
    {
        [scriptPlayer forceStop:error];
    }
}

BOOL isScriptPlaying()
{
    return scriptPlayer && [scriptPlayer isPlaying];
}
