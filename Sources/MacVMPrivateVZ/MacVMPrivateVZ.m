#import "MacVMPrivateVZ.h"
#import <dispatch/dispatch.h>

static NSString *const MacVMPrivateVZErrorDomain = @"com.twt.macvm.private-vz";

static NSError *MacVMErrorMake(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MacVMPrivateVZErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

#pragma mark - Private symbol declarations
//
// Typed forward-declarations of the real private Virtualization.framework VNC
// classes. These let the compiler emit correctly typed objc_msgSend calls, but we
// never reference the class literals directly — instances are obtained via
// NSClassFromString and cast to these types — so there is no link-time symbol
// dependency and a missing class fails as a clean runtime nil rather than a link
// error. Signatures verified against Tart, lume, and a class-dump of
// Virtualization.framework 259.6.4 (macOS 26.5.2); `port` is uint16_t, which a
// hand-written shim MUST match exactly.

@interface _VZVNCSecurityConfiguration : NSObject
@end

@interface _VZVNCAuthenticationSecurityConfiguration : _VZVNCSecurityConfiguration
- (instancetype)initWithPassword:(NSString *)password;
@end

@interface _VZVNCNoSecuritySecurityConfiguration : _VZVNCSecurityConfiguration
@end

@interface _VZVNCServer : NSObject
- (instancetype)initWithPort:(unsigned short)port
                       queue:(dispatch_queue_t)queue
       securityConfiguration:(_VZVNCSecurityConfiguration *)configuration;
@property (nonatomic, readonly) unsigned short port;
@property (nonatomic, strong) id virtualMachine;
- (void)start;
- (void)stop;
@end

#pragma mark - MacVMVNCServer

@implementation MacVMVNCServer {
    _VZVNCServer *_server;
    dispatch_queue_t _queue;
}

- (nullable instancetype)initWithVirtualMachine:(id)virtualMachine
                                           port:(NSUInteger)port
                                       password:(nullable NSString *)password
                                          error:(NSError **)error {
    self = [super init];
    if (!self) {
        return nil;
    }

    Class serverClass = NSClassFromString(@"_VZVNCServer");
    if (serverClass == nil) {
        if (error) {
            *error = MacVMErrorMake(1, @"_VZVNCServer is unavailable in this Virtualization.framework. The headless VNC path is only supported where the private API exists.");
        }
        return nil;
    }

    _VZVNCSecurityConfiguration *security = [self makeSecurityConfigurationWithPassword:password error:error];
    if (security == nil) {
        // makeSecurityConfiguration populated *error.
        return nil;
    }

    // The server runs its own work on this background queue; the VM stays bound to
    // its own (main) queue, which is where this initializer is expected to run.
    _queue = dispatch_queue_create("com.twt.macvm.vnc-server", DISPATCH_QUEUE_SERIAL);

    _VZVNCServer *server = (_VZVNCServer *)[serverClass alloc];
    if (![server respondsToSelector:@selector(initWithPort:queue:securityConfiguration:)]) {
        if (error) {
            *error = MacVMErrorMake(2, @"_VZVNCServer does not respond to initWithPort:queue:securityConfiguration:. The private VNC API signature has changed on this macOS build.");
        }
        return nil;
    }
    server = [server initWithPort:(unsigned short)port queue:_queue securityConfiguration:security];
    if (server == nil) {
        if (error) {
            *error = MacVMErrorMake(3, @"Failed to initialize _VZVNCServer.");
        }
        return nil;
    }

    if (![server respondsToSelector:@selector(setVirtualMachine:)]) {
        if (error) {
            *error = MacVMErrorMake(4, @"_VZVNCServer does not expose a virtualMachine property on this macOS build.");
        }
        return nil;
    }
    // Assign the VM before -start, on the VM's (this) queue.
    server.virtualMachine = virtualMachine;

    _server = server;
    return self;
}

/// Build the RFB security configuration: password auth when a password is given,
/// otherwise the no-authentication configuration.
- (nullable _VZVNCSecurityConfiguration *)makeSecurityConfigurationWithPassword:(nullable NSString *)password
                                                                          error:(NSError **)error {
    if (password != nil) {
        Class authClass = NSClassFromString(@"_VZVNCAuthenticationSecurityConfiguration");
        if (authClass == nil) {
            if (error) {
                *error = MacVMErrorMake(5, @"_VZVNCAuthenticationSecurityConfiguration is unavailable on this macOS build.");
            }
            return nil;
        }
        _VZVNCAuthenticationSecurityConfiguration *instance =
            (_VZVNCAuthenticationSecurityConfiguration *)[authClass alloc];
        if (![instance respondsToSelector:@selector(initWithPassword:)]) {
            if (error) {
                *error = MacVMErrorMake(6, @"_VZVNCAuthenticationSecurityConfiguration does not respond to initWithPassword:.");
            }
            return nil;
        }
        return [instance initWithPassword:password];
    }

    // No password: use the no-authentication configuration (note the doubled
    // 'Security' in the class name).
    Class noAuthClass = NSClassFromString(@"_VZVNCNoSecuritySecurityConfiguration");
    if (noAuthClass == nil) {
        if (error) {
            *error = MacVMErrorMake(7, @"_VZVNCNoSecuritySecurityConfiguration is unavailable on this macOS build. Provide a password to use authenticated VNC instead.");
        }
        return nil;
    }
    return [(_VZVNCSecurityConfiguration *)[noAuthClass alloc] init];
}

- (nullable NSNumber *)startAndReturnError:(NSError **)error {
    if (_server == nil) {
        if (error) {
            *error = MacVMErrorMake(8, @"VNC server was not initialized.");
        }
        return nil;
    }

    if (![_server respondsToSelector:@selector(start)]) {
        if (error) {
            *error = MacVMErrorMake(9, @"_VZVNCServer does not respond to start.");
        }
        return nil;
    }
    [_server start];

    // -start reports no error; the ephemeral port is assigned asynchronously on
    // the server's queue, so poll -port until it becomes non-zero.
    unsigned short port = 0;
    for (int attempt = 0; attempt < 200; attempt++) {
        port = _server.port;
        if (port != 0) {
            break;
        }
        usleep(25 * 1000); // 25ms; up to ~5s total
    }

    if (port == 0) {
        if (error) {
            *error = MacVMErrorMake(10, @"_VZVNCServer did not report a bound port after start (bind may have failed).");
        }
        return nil;
    }

    return @(port);
}

- (void)stop {
    if (_server != nil && [_server respondsToSelector:@selector(stop)]) {
        [_server stop];
    }
    _server = nil;
}

@end

#pragma mark - MacVMGuestProvisioning

@implementation MacVMGuestProvisioning

+ (BOOL)isAvailable {
    return NSClassFromString(@"VZMacGuestProvisioningOptions") != nil;
}

+ (BOOL)applyToStartOptions:(id)startOptions
                   fullName:(NSString *)fullName
                   username:(NSString *)username
                   password:(NSString *)password
         enablesRemoteLogin:(BOOL)enablesRemoteLogin
        logsInAutomatically:(BOOL)logsInAutomatically
                      error:(NSError **)error {
    Class optionsClass = NSClassFromString(@"VZMacGuestProvisioningOptions");
    if (optionsClass == nil) {
        if (error) {
            *error = MacVMErrorMake(20, @"VZMacGuestProvisioningOptions is unavailable. Native guest provisioning requires macOS 27 or later on both host and guest.");
        }
        return NO;
    }

    id options = [[optionsClass alloc] init];
    @try {
        [options setValue:fullName forKey:@"fullName"];
        [options setValue:username forKey:@"username"];
        [options setValue:password forKey:@"password"];
        [options setValue:@(enablesRemoteLogin) forKey:@"enablesRemoteLogin"];
        [options setValue:@(logsInAutomatically) forKey:@"logsInAutomatically"];
        [startOptions setValue:options forKey:@"guestProvisioningOptions"];
    } @catch (NSException *exception) {
        if (error) {
            *error = MacVMErrorMake(21, [NSString stringWithFormat:@"Failed to apply guest provisioning options: %@", exception.reason]);
        }
        return NO;
    }

    return YES;
}

@end
