// CodexMicroVHid — virtual HID device (IOHIDUserDevice) emulating the Work Louder
// Codex Micro so ChatGPT Desktop's node-hid enumeration detects it exactly like
// real hardware (VID 0x303A / PID 0x8360 / usage page 0xFF00, report ID 6).
// Protocol reference: docs/codex-micro-protocol.md
//
// Build:  clang -fobjc-arc -framework Foundation -framework IOKit tools/CodexMicroVHid/main.m -o tools/CodexMicroVHid/vhid
// Run:    ./tools/CodexMicroVHid/vhid
// Stdin:  ag0..ag5 [press|release] | fast approve decline fork mic send |
//         up down left right [press|release] | enc cw|cc|press | json <raw>

#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/IOHIDUserDevice.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static const char *kFwVersion = "0.1.0-vhid-emu";

// Same vendor-defined report map as real hardware: report ID 6, 63-byte in/out.
static const uint8_t kReportMap[] = {
    0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x06,
    0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x3F,
    0x09, 0x01, 0x81, 0x02, 0x95, 0x3F, 0x09, 0x02, 0x91,
    0x02, 0xC0,
};

@interface VHid : NSObject
@property(nonatomic, assign) IOHIDUserDeviceRef device;
@property(nonatomic, assign) BOOL modern;
@property(nonatomic, strong) NSMutableData *rpcBuffer;
- (void)onSetReport:(uint32_t)reportID bytes:(NSData *)bytes;
- (void)sendJson:(NSDictionary *)obj;
@end

// Legacy callback typedefs (pre-10.15 API, still exported by IOKit).
typedef void (*LegacySetReportCb)(void *context, IOReturn result, void *sender,
                                  IOHIDReportType type, uint32_t reportID,
                                  uint8_t *report, CFIndex reportLength);
typedef IOHIDUserDeviceRef (*CreateFn)(CFAllocatorRef, CFDictionaryRef);
typedef void (*ScheduleFn)(IOHIDUserDeviceRef, CFRunLoopRef, CFStringRef);
typedef void (*SetReportCbFn)(IOHIDUserDeviceRef, LegacySetReportCb);
typedef IOReturn (*HandleReportFn)(IOHIDUserDeviceRef, const uint8_t *, CFIndex);

static CreateFn pCreate;
static ScheduleFn pSchedule;
static SetReportCbFn pSetReportCb;
static HandleReportFn pHandleReport;

static void legacySetReportTrampoline(void *context, IOReturn result, void *sender,
                                      IOHIDReportType type, uint32_t reportID,
                                      uint8_t *report, CFIndex reportLength) {
    VHid *me = (__bridge VHid *)context;
    [me onSetReport:reportID bytes:[NSData dataWithBytes:report length:reportLength]];
}

@implementation VHid

- (BOOL)start {
    NSDictionary *props = @{
        @kIOHIDReportDescriptorKey: [NSData dataWithBytes:kReportMap length:sizeof(kReportMap)],
        @kIOHIDVendorIDKey: @0x303A,
        @kIOHIDProductIDKey: @0x8360,
        @kIOHIDManufacturerKey: @"Work Louder",
        @kIOHIDProductKey: @"Codex Micro",
        @kIOHIDSerialNumberKey: @"CMEMU0001",
        @kIOHIDVersionNumberKey: @0x0101,
        @kIOHIDPrimaryUsagePageKey: @0xFF00,
        @kIOHIDPrimaryUsageKey: @0x01,
    };
    _rpcBuffer = [NSMutableData data];

    // 1) Modern API (macOS 10.15+). May require com.apple.developer.hid.virtual.device.
    _device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, (__bridge CFDictionaryRef)props, 0);
    if (_device) {
        _modern = YES;
        __weak VHid *weakSelf = self;
        IOHIDUserDeviceRegisterSetReportBlock(_device, ^IOReturn(IOHIDReportType type, uint32_t reportID, const uint8_t *report, CFIndex reportLength) {
            [weakSelf onSetReport:reportID bytes:[NSData dataWithBytes:report length:reportLength]];
            return kIOReturnSuccess;
        });
        IOHIDUserDeviceRegisterGetReportBlock(_device, ^IOReturn(IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex *reportLength) {
            return kIOReturnUnsupported;
        });
        IOHIDUserDeviceSetDispatchQueue(_device, dispatch_get_main_queue());
        IOHIDUserDeviceActivate(_device);
        printf("[vhid] created via modern API (CreateWithProperties)\n");
    } else {
        // 2) Legacy API fallback (no entitlement check on older codepath).
        printf("[vhid] modern create failed (entitlement?), trying legacy IOHIDUserDeviceCreate\n");
        pCreate = (CreateFn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceCreate");
        pSchedule = (ScheduleFn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceScheduleWithRunLoop");
        pSetReportCb = (SetReportCbFn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceRegisterSetReportCallback");
        pHandleReport = (HandleReportFn)dlsym(RTLD_DEFAULT, "IOHIDUserDeviceHandleReport");
        if (!pCreate || !pSchedule || !pSetReportCb || !pHandleReport) {
            printf("[vhid] legacy symbols missing: %p %p %p %p\n", pCreate, pSchedule, pSetReportCb, pHandleReport);
            return NO;
        }
        _device = pCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)props);
        if (!_device) {
            printf("[vhid] legacy create failed too\n");
            return NO;
        }
        _modern = NO;
        pSetReportCb(_device, legacySetReportTrampoline);
        pSchedule(_device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        printf("[vhid] created via legacy API\n");
    }
    printf("[vhid] virtual device registered: Work Louder Codex Micro 303A:8360 usagePage=FF00\n");
    return YES;
}

// Host -> device (output report). IOKit strips the report ID: 63-byte body.
- (void)onSetReport:(uint32_t)reportID bytes:(NSData *)bytes {
    if (reportID != 6 || bytes.length < 2) return;
    const uint8_t *b = bytes.bytes;
    if (b[0] != 2) { // channel 1 = debug log, channel 2 = RPC
        if (b[0] == 1 && bytes.length > 2) {
            printf("[dev-log-ch1] %.*s\n", (int)MIN((NSUInteger)b[1], bytes.length - 2), (const char *)b + 2);
        }
        return;
    }
    NSUInteger len = MIN((NSUInteger)b[1], 61);
    if (bytes.length < 2 + len) return;
    NSData *frag = [bytes subdataWithRange:NSMakeRange(2, len)];
    NSString *fragStr = [[NSString alloc] initWithData:frag encoding:NSUTF8StringEncoding];
    if ([fragStr hasPrefix:@"{\"method\""]) [_rpcBuffer setLength:0];
    [_rpcBuffer appendData:frag];
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:_rpcBuffer options:0 error:&err];
    if (!obj) {
        if (![[NSString alloc] initWithData:_rpcBuffer encoding:NSUTF8StringEncoding]) [_rpcBuffer setLength:0];
        return; // incomplete JSON: wait for more fragments
    }
    [_rpcBuffer setLength:0];
    NSData *flat = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    printf("[host->dev] %s\n", [[NSString alloc] initWithData:flat encoding:NSUTF8StringEncoding].UTF8String);
    [self handleRpc:obj];
}

- (void)handleRpc:(NSDictionary *)obj {
    id rid = obj[@"id"] ?: [NSNull null];
    NSString *method = obj[@"method"] ?: @"";
    if ([method isEqualToString:@"sys.version"]) {
        [self sendJson:@{@"id": rid, @"result": @{@"version": @(kFwVersion)}}];
    } else if ([method isEqualToString:@"device.status"]) {
        [self sendJson:@{@"id": rid, @"result": @{
            @"version": @(kFwVersion), @"profile_index": @0, @"layer_index": @1,
            @"battery": @100, @"is_charging": @YES}}];
    } else if ([method isEqualToString:@"v.oai.thstatus"]) {
        id params = obj[@"params"];
        if ([params isKindOfClass:[NSArray class]]) {
            for (NSDictionary *t in (NSArray *)params) {
                printf("  [light] agent %s color=#%06X bright=%s effect=%s speed=%s\n",
                       [t[@"id"] description].UTF8String, [t[@"c"] unsignedIntValue],
                       [t[@"b"] description].UTF8String ?: "",
                       [t[@"e"] description].UTF8String ?: "",
                       [t[@"s"] description].UTF8String ?: "");
            }
        }
        [self sendJson:@{@"id": rid, @"result": @{@"ok": @YES}}];
    } else if ([method isEqualToString:@"v.oai.rgbcfg"] || [method isEqualToString:@"lights.preview"] ||
               [method isEqualToString:@"host.focused_app"] || [method isEqualToString:@"sys.bootloader"] ||
               [method isEqualToString:@"sys.selftest"]) {
        [self sendJson:@{@"id": rid, @"result": @{@"ok": @YES}}];
    } else {
        [self sendJson:@{@"id": rid, @"error": @{@"code": @-32601, @"message": @"Method not found"}}];
    }
}

// Device -> host: inject input report (64 bytes including report ID).
- (void)sendJson:(NSDictionary *)obj {
    if (!_device) return;
    NSMutableData *payload = [[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] mutableCopy];
    if (!payload) return;
    [payload appendBytes:"\n" length:1];
    NSUInteger offset = 0;
    while (offset < payload.length) {
        NSUInteger chunk = MIN((NSUInteger)61, payload.length - offset);
        uint8_t report[64] = {0};
        report[0] = 6; // report ID
        report[1] = 2; // channel RPC
        report[2] = (uint8_t)chunk;
        memcpy(report + 3, payload.bytes + offset, chunk);
        IOReturn kr;
        if (_modern) {
            kr = IOHIDUserDeviceHandleReportWithTimeStamp(_device, mach_absolute_time(), report, sizeof(report));
        } else {
            kr = pHandleReport(_device, report, sizeof(report));
        }
        if (kr != kIOReturnSuccess) printf("[vhid] HandleReport failed: 0x%08X\n", kr);
        offset += chunk;
        usleep(4000);
    }
    printf("[dev->host] %s\n",
           [[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]
               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].UTF8String);
}

@end

static void sendKey(VHid *vhid, NSString *key, int act, NSNumber *agent) {
    NSMutableDictionary *params = [@{@"k": key, @"act": @(act)} mutableCopy];
    if (agent) params[@"ag"] = agent;
    [vhid sendJson:@{@"method": @"v.oai.hid", @"params": params}];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        VHid *vhid = [VHid new];
        if (![vhid start]) return 1;

        NSDictionary *keyMap = @{
            @"ag0": @[@"AG00", @0], @"ag1": @[@"AG01", @1], @"ag2": @[@"AG02", @2],
            @"ag3": @[@"AG03", @3], @"ag4": @[@"AG04", @4], @"ag5": @[@"AG05", @5],
            @"fast": @[@"ACT06"], @"approve": @[@"ACT07"], @"decline": @[@"ACT08"],
            @"fork": @[@"ACT09"], @"mic": @[@"ACT10"], @"send": @[@"ACT12"],
        };
        NSDictionary *joyMap = @{@"right": @0.0, @"down": @0.25, @"left": @0.5, @"up": @0.75};

        printf("Commands: ag0..ag5 [press|release] | fast approve decline fork mic send |\n"
               "          up down left right [press|release] | enc cw|cc|press | json <raw>\n");

        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            char lineBuf[4096];
            while (fgets(lineBuf, sizeof(lineBuf), stdin)) {
                NSString *line = [[NSString stringWithUTF8String:lineBuf]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (line.length == 0) continue;
                NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
                if ([line hasPrefix:@"json "]) {
                    NSData *d = [[line substringFromIndex:5] dataUsingEncoding:NSUTF8StringEncoding];
                    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                    if (o) [vhid sendJson:o];
                    continue;
                }
                NSString *actStr = parts.count > 1 ? parts[1] : @"tap";
                if ([parts[0] isEqualToString:@"enc"] && parts.count > 1) {
                    if ([parts[1] isEqualToString:@"cw"]) sendKey(vhid, @"ENC_CW", 2, nil);
                    else if ([parts[1] isEqualToString:@"cc"]) sendKey(vhid, @"ENC_CC", 2, nil);
                    else { sendKey(vhid, @"ENC", 1, nil); usleep(50000); sendKey(vhid, @"ENC", 0, nil); }
                    continue;
                }
                NSArray *km = keyMap[parts[0]];
                if (km) {
                    NSNumber *agent = km.count > 1 ? km[1] : nil;
                    if ([actStr isEqualToString:@"press"]) sendKey(vhid, km[0], 1, agent);
                    else if ([actStr isEqualToString:@"release"]) sendKey(vhid, km[0], 0, agent);
                    else { sendKey(vhid, km[0], 1, agent); usleep(50000); sendKey(vhid, km[0], 0, agent); }
                    continue;
                }
                NSNumber *angle = joyMap[parts[0]];
                if (angle) {
                    void (^send)(double) = ^(double d) {
                        [vhid sendJson:@{@"method": @"v.oai.rad", @"params": @{@"a": angle, @"d": @(d)}}];
                    };
                    if ([actStr isEqualToString:@"press"]) send(1.0);
                    else if ([actStr isEqualToString:@"release"]) send(0.0);
                    else { send(1.0); usleep(50000); send(0.0); }
                    continue;
                }
                printf("unknown command\n");
            }
        });

        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
