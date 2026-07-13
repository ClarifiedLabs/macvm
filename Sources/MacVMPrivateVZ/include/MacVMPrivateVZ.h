#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin, typed wrappers over PRIVATE Virtualization.framework symbols.
///
/// Every reference to an underscored/private class (`_VZVNCServer`,
/// `_VZVNCAuthenticationSecurityConfiguration`) and to the macOS 27 public
/// `VZMacGuestProvisioningOptions` (which isn't in the macOS 26 SDK) is confined
/// to `MacVMPrivateVZ.m`. Classes are resolved at runtime via `NSClassFromString`
/// so there is no link-time dependency; if a symbol is missing on the host the
/// initializer fails cleanly with an error instead of crashing.
///
/// `id` is used for Virtualization objects so this header never imports the
/// framework and stays usable from the macOS 26 SDK.
@interface MacVMVNCServer : NSObject

/// Create a loopback VNC server for `virtualMachine` (a `VZVirtualMachine`).
///
/// `port` is the TCP port to bind; pass 0 to let the framework auto-assign one.
/// Pass a non-nil `password` to enable RFB password authentication; pass nil to
/// request the no-authentication configuration when the framework exposes one.
/// Returns nil (with `error` populated) if the private symbols are unavailable.
- (nullable instancetype)initWithVirtualMachine:(id)virtualMachine
                                           port:(NSUInteger)port
                                       password:(nullable NSString *)password
                                          error:(NSError **)error;

/// Start serving and return the bound TCP port.
///
/// The port is auto-assigned by the framework; this blocks briefly polling until
/// it becomes non-zero. Returns nil (with `error`) if no port is bound. Must be
/// called on the same dispatch queue that owns the virtual machine.
- (nullable NSNumber *)startAndReturnError:(NSError **)error;

/// Stop serving and release the underlying server.
- (void)stop;

@end

/// Runtime bridge to the macOS 27 `VZMacGuestProvisioningOptions` API, which
/// natively drives Setup Assistant (account creation, auto-login, Remote Login)
/// on the first boot after restore.
@interface MacVMGuestProvisioning : NSObject

/// Whether `VZMacGuestProvisioningOptions` exists on this host (macOS 27+).
+ (BOOL)isAvailable;

/// Build guest-provisioning options and attach them to `startOptions` (a
/// `VZMacOSVirtualMachineStartOptions`) through its validated setter. Returns NO
/// (with `error`) if the API is unavailable or rejects the values.
+ (BOOL)applyToStartOptions:(id)startOptions
                   fullName:(NSString *)fullName
                   username:(NSString *)username
                   password:(NSString *)password
         enablesRemoteLogin:(BOOL)enablesRemoteLogin
        logsInAutomatically:(BOOL)logsInAutomatically
                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
