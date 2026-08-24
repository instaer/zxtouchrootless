// TODO: multiple client write back support


#include "SocketServer.h"
#include "Task.h"
#include <string.h>
#include <errno.h>


CFSocketRef socketRef;
static NSMutableDictionary *socketClients = NULL;       // readStream -> writeStream (wrapped in NSNumber)
static NSMutableDictionary *socketClientBuffers = NULL; // readStream -> NSMutableData (incomplete command data)
static NSMutableDictionary *socketClientQueues = NULL;  // readStream -> dispatch_queue_t (per-connection serial queue)

// Each connection gets its own serial queue. Commands from the same client
// keep their arrival order, but a slow command (usleep, shell, OCR) on one
// connection no longer blocks every other client — that was the behavior of
// the original single-threaded runloop and of a global serial queue.

/*
Remove every resource of a client connection. Must only be called on the
runloop thread that schedules the streams. Safe to call more than once.
*/
static void closeClientConnection(CFReadStreamRef readStream)
{
    NSNumber *clientNumber = [socketClients objectForKey:@((long)readStream)];
    if (clientNumber == nil)
        return; // already cleaned up

    [socketClients removeObjectForKey:@((long)readStream)];
    [socketClientBuffers removeObjectForKey:@((long)readStream)];
    [socketClientQueues removeObjectForKey:@((long)readStream)];

    CFWriteStreamRef writeStream = (CFWriteStreamRef)[clientNumber longValue];
    if (writeStream != NULL)
    {
        // Both streams own the native socket (ShouldCloseNativeSocket); the
        // second close hits an already-closed FD and harmlessly returns EBADF
        // — no other FD can be opened in between on this same runloop thread.
        CFWriteStreamClose(writeStream);
        CFRelease(writeStream);
    }

    CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    CFReadStreamClose(readStream);
    CFRelease(readStream);
}

// Reference: https://www.jianshu.com/p/9353105a9129

void socketServer()
{
    @autoreleasepool {
        CFSocketRef _socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, kCFSocketAcceptCallBack, TCPServerAcceptCallBack, NULL);

        if (_socket == NULL) {
            NSLog(@"### com.zjx.springboard: failed to create socket.");
            return;
        }

        UInt32 reused = 1;

        setsockopt(CFSocketGetNative(_socket), SOL_SOCKET, SO_REUSEADDR, (const void *)&reused, sizeof(reused));

        struct sockaddr_in Socketaddr;
        memset(&Socketaddr, 0, sizeof(Socketaddr));
        Socketaddr.sin_len = sizeof(Socketaddr);
        Socketaddr.sin_family = AF_INET;

        Socketaddr.sin_addr.s_addr = inet_addr(ADDR);

        Socketaddr.sin_port = htons(PORT);

        CFDataRef address = CFDataCreate(kCFAllocatorDefault,  (UInt8 *)&Socketaddr, sizeof(Socketaddr));

        if (CFSocketSetAddress(_socket, address) != kCFSocketSuccess) {
            NSLog(@"### com.zjx.springboard: failed to bind socket on port %d", PORT);
            [@"socket-bind-failed" writeToFile:@"/var/mobile/d_sockfail.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if (_socket) CFRelease(_socket);
            return;
        }
        [@"socket-bound-ok" writeToFile:@"/var/mobile/d_sockbound.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];

        socketClients = [[NSMutableDictionary alloc] init];
        socketClientBuffers = [[NSMutableDictionary alloc] init];
        socketClientQueues = [[NSMutableDictionary alloc] init];

        NSLog(@"### com.zjx.springboard: connection waiting");
        CFRunLoopRef cfrunLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceRef source = CFSocketCreateRunLoopSource(kCFAllocatorDefault, _socket, 0);

        CFRunLoopAddSource(cfrunLoop, source, kCFRunLoopCommonModes);

        CFRelease(source);
        CFRunLoopRun();
    }

}

static void readStream(CFReadStreamRef readStream, CFStreamEventType eventype, void * clientCallBackInfo)
{
    @autoreleasepool {
        if (eventype == kCFStreamEventErrorOccurred || eventype == kCFStreamEventEndEncountered)
        {
            closeClientConnection(readStream);
            return;
        }

        if (eventype != kCFStreamEventHasBytesAvailable)
            return;

        // Read on the scheduling thread. Leave one byte for NUL termination.
        UInt8 readDataBuff[2048];
        CFIndex hasRead = CFReadStreamRead(readStream, readDataBuff, sizeof(readDataBuff) - 1);

        if (hasRead < 0)
        {
            closeClientConnection(readStream);
            return;
        }

        if (hasRead == 0)
            return; // nothing to do right now

        readDataBuff[hasRead] = 0;

        // Append to the per-connection buffer so that commands split across
        // multiple reads are reassembled before being processed.
        NSMutableData *buffer = [socketClientBuffers objectForKey:@((long)readStream)];
        if (buffer == nil)
        {
            buffer = [NSMutableData data];
            [socketClientBuffers setObject:buffer forKey:@((long)readStream)];
        }
        [buffer appendBytes:readDataBuff length:hasRead];

        // Drop garbage connections that never send a terminator.
        if (buffer.length > 64 * 1024)
        {
            [buffer setData:[NSData data]];
            return;
        }

        // Commands are framed by the exact "\r\n" sequence; data containing a
        // lone '\r' or '\n' stays inside the command instead of splitting it.
        NSData *separator = [@"\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange separatorRange = [buffer rangeOfData:separator options:0 range:NSMakeRange(0, buffer.length)];

        while (separatorRange.location != NSNotFound)
        {
            NSUInteger commandLength = separatorRange.location;
            NSData *commandData = [buffer subdataWithRange:NSMakeRange(0, commandLength)];
            [buffer replaceBytesInRange:NSMakeRange(0, commandLength + separator.length) withBytes:NULL length:0];

            if (commandData.length > 0)
            {
                // processTask and its callees expect a NUL terminated C string
                NSMutableData *command = [commandData mutableCopy];
                [command appendBytes:"\0" length:1];

                NSNumber *clientNumber = [socketClients objectForKey:@((long)readStream)];
                CFWriteStreamRef client = (clientNumber != nil) ? (CFWriteStreamRef)[clientNumber longValue] : NULL;
                if (client != NULL) CFRetain(client); // keep the stream alive while the task is queued

                // Dispatch on this connection's own serial queue so command
                // order is preserved per client without blocking others.
                dispatch_queue_t clientQueue = [socketClientQueues objectForKey:@((long)readStream)];
                if (clientQueue == nil)
                {
                    // Queue normally created at accept time; recreate lazily
                    // in case the connection map was reset.
                    clientQueue = dispatch_queue_create("com.zjx.springboard.socket.client", DISPATCH_QUEUE_SERIAL);
                    [socketClientQueues setObject:clientQueue forKey:@((long)readStream)];
                }

                dispatch_async(clientQueue, ^{
                    @autoreleasepool {
                        processTask((UInt8*)command.mutableBytes, client);
                        if (client != NULL) CFRelease(client);
                    }
                });
            }

            if (buffer.length == 0)
                break;
            separatorRange = [buffer rangeOfData:separator options:0 range:NSMakeRange(0, buffer.length)];
        }
    }
}

int notifyClient(UInt8* msg, CFWriteStreamRef client)
{
    int result = -1;
    //NSLog(@"com.zjx.springboard: client: %x", client);
    if (client != 0)
    {
        result = CFWriteStreamWrite(client, msg, strlen((char*)msg));
    }
    return result;
}

static void TCPServerAcceptCallBack(CFSocketRef socket, CFSocketCallBackType type, CFDataRef address, const void *data, void *info)
{
    if (kCFSocketAcceptCallBack == type) {

        CFSocketNativeHandle  nativeSocketHandle = *(CFSocketNativeHandle *)data;

        uint8_t name[SOCK_MAXADDRLEN];
        socklen_t namelen = sizeof(name);

        if (getpeername(nativeSocketHandle, (struct sockaddr *)name, &namelen) != 0) {

            // Never exit() here: this runs inside SpringBoard, and one bad
            // connection must not take the whole UI down. Just drop it.
            NSLog(@"### com.zjx.springboard: getpeername failed, dropping connection: %s", strerror(errno));

            close(nativeSocketHandle);
            return;
        }

        struct sockaddr_in *addr_in = (struct sockaddr_in *)name;
        NSLog(@"### com.zjx.springboard: connection from %s:%d", inet_ntoa(addr_in->sin_addr), ntohs(addr_in->sin_port));

        CFReadStreamRef newReadStream = NULL;
        CFWriteStreamRef newWriteStream = NULL;

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, nativeSocketHandle, &newReadStream, &newWriteStream);

        if (newReadStream && newWriteStream) {
            // Streams created from an existing native socket do NOT take
            // ownership of the FD by default (kCFStreamPropertyShouldCloseNative-
            // Socket is false), so closing the streams on disconnect used to
            // leak the FD. Dashboard status queries open short connections in
            // a loop, so this leaks for real. Transfer ownership to the
            // streams so CFReadStreamClose/CFWriteStreamClose release the FD.
            CFReadStreamSetProperty(newReadStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
            CFWriteStreamSetProperty(newWriteStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);

            CFReadStreamOpen(newReadStream);
            CFWriteStreamOpen(newWriteStream);

            CFStreamClientContext context = {0, NULL, NULL, NULL, NULL };

            if (!CFReadStreamSetClient(newReadStream, kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered, readStream, &context)) {
                NSLog(@"### com.zjx.springboard: error 1");
                CFReadStreamClose(newReadStream); // closes the native socket too
                CFRelease(newReadStream);
                CFWriteStreamClose(newWriteStream);
                CFRelease(newWriteStream);
                return;
            }

            CFReadStreamScheduleWithRunLoop(newReadStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

            // One serial command queue per connection.
            dispatch_queue_t clientQueue = dispatch_queue_create(
                [[NSString stringWithFormat:@"com.zjx.springboard.socket.client.%d", nativeSocketHandle] UTF8String],
                DISPATCH_QUEUE_SERIAL);

			[socketClients setObject:@((long)newWriteStream) forKey:@((long)newReadStream)];
            [socketClientQueues setObject:clientQueue forKey:@((long)newReadStream)];
            //const char *str = "+++welcome++++\n";

            //CFWriteStreamWrite(writeStreamRef, (UInt8 *)str, strlen(str) + 1);
        }
        else
        {
            // Partial creation (one stream, or none): release whatever was
            // created. Ownership was not transferred to the streams yet, so
            // the native socket still has to be closed here.
            if (newReadStream) { CFReadStreamClose(newReadStream); CFRelease(newReadStream); }
            if (newWriteStream) { CFWriteStreamClose(newWriteStream); CFRelease(newWriteStream); }
            close(nativeSocketHandle);
        }

    }

}
