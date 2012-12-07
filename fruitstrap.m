//TODO: don't copy/mount DeveloperDiskImage.dmg if it's already done - Xcode checks this somehow

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <stdio.h>
#include <signal.h>
#include <getopt.h>
#include "MobileDevice.h"

#define FDVENDOR_PATH  "/tmp/fruitstrap-remote-debugserver"
#define PREP_CMDS_PATH "/tmp/fruitstrap-gdb-prep-cmds"
#define GDB_SHELL      "`xcode-select -print-path`/Platforms/iPhoneOS.platform/Developer/usr/libexec/gdb/gdb-arm-apple-darwin --arch armv7f -i mi -q -x " PREP_CMDS_PATH

#define PRINT(...) if (!quiet) { printf(__VA_ARGS__); fflush(stdout); }

// approximation of what Xcode does:
#define GDB_PREP_CMDS "set mi-show-protections off\n\
set auto-raise-load-levels 1\n\
set shlib-path-substitutions /usr \"{ds_path}/Symbols/usr\" /System \"{ds_path}/Symbols/System\" \"{device_container}\" \"{disk_container}\" \"/private{device_container}\" \"{disk_container}\" /Developer \"{ds_path}/Symbols/Developer\"\n\
set remote max-packet-size 1024\n\
set sharedlibrary check-uuids on\n\
set env NSUnbufferedIO YES\n\
set minimal-signal-handling 1\n\
set sharedlibrary load-rules \\\".*\\\" \\\".*\\\" container\n\
set inferior-auto-start-dyld 0\n\
file \"{disk_app}\"\n\
set remote executable-directory {device_app}\n\
set remote noack-mode 1\n\
set trust-readonly-sections 1\n\
target remote-mobile " FDVENDOR_PATH "\n\
mem 0x1000 0x3fffffff cache\n\
mem 0x40000000 0xffffffff none\n\
mem 0x00000000 0x0fff none\n\
run {args}\n\
set minimal-signal-handling 0\n\
set inferior-auto-start-cfm off\n\
set sharedLibrary load-rules dyld \".*libobjc.*\" all dyld \".*CoreFoundation.*\" all dyld \".*Foundation.*\" all dyld \".*libSystem.*\" all dyld \".*AppKit.*\" all dyld \".*PBGDBIntrospectionSupport.*\" all dyld \".*/usr/lib/dyld.*\" all dyld \".*CarbonDataFormatters.*\" all dyld \".*libauto.*\" all dyld \".*CFDataFormatters.*\" all dyld \"/System/Library/Frameworks\\\\\\\\|/System/Library/PrivateFrameworks\\\\\\\\|/usr/lib\" extern dyld \".*\" all exec \".*\" all\n\
sharedlibrary apply-load-rules all\n\
set inferior-auto-start-dyld 1\n\
continue\n\
quit"

typedef enum {
    OP_NONE,
    OP_INSTALL,
    OP_UNINSTALL,
    OP_LIST_DEVICES,
    OP_UPLOAD_FILE,
    OP_LIST_FILES
} operation_t;

typedef struct am_device * AMDeviceRef;

bool found_device = false, debug = false, verbose = false, quiet = false;
NSString *app_path = nil;
NSString *device_id = nil;
NSString *doc_file_path = nil;
NSString *target_filename = nil;
NSString *bundle_id = nil;
NSString *args = nil;
int timeout = 0;
operation_t operation = OP_INSTALL;
NSString *last_path = nil;
service_conn_t gdbfd;

void Log(NSString *format, ...) {
    va_list argList;
    va_start(argList, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:argList];
    printf("%s", [message UTF8String]);
    va_end(argList);
}

BOOL path_exists(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    return [url checkResourceIsReachableAndReturnError:nil];
}

NSString *copy_xcode_dev_path() {
	FILE *fpipe = NULL;
	char *command = "xcode-select -print-path";
    
	if (!(fpipe = (FILE *)popen(command, "r")))
	{
		perror("Error encountered while opening pipe");
		exit(EXIT_FAILURE);
	}
    
	char buffer[256] = { '\0' };
    
	fgets(buffer, sizeof(buffer), fpipe);
	pclose(fpipe);
    
	strtok(buffer, "\n");
	return [[NSString alloc] initWithUTF8String:buffer];
}

NSString *copy_device_support_path(AMDeviceRef device) {
    NSString *version = (__bridge_transfer NSString *)AMDeviceCopyValue(device, 0, CFSTR("ProductVersion"));
    NSString *build = (__bridge_transfer NSString *)AMDeviceCopyValue(device, 0, CFSTR("BuildVersion"));
    NSString *home = @(getenv("HOME"));
    NSString *path;
    BOOL found = NO;
    
	NSString *xcodeDevPath = copy_xcode_dev_path();
    
	path = [[NSString alloc] initWithFormat:@"%@/Library/Developer/Xcode/iOS DeviceSupport/%@ (%@)", home, version, build];
	found = path_exists(path);
    
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Library/Developer/Xcode/iOS DeviceSupport/%@", home, version];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Library/Developer/Xcode/iOS DeviceSupport/Latest", home];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Platforms/iPhoneOS.platform/DeviceSupport/%@ (%@)", xcodeDevPath, version, build];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Platforms/iPhoneOS.platform/DeviceSupport/%@", xcodeDevPath, version];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Platforms/iPhoneOS.platform/DeviceSupport/Latest", xcodeDevPath];
		found = path_exists(path);
	}
    
	if (!found)
	{
		Log(@"[ !! ] Unable to locate DeviceSupport directory.\n");
		exit(EXIT_FAILURE);
	}
    
	return path;
}

NSString *copy_developer_disk_image_path(AMDeviceRef device) {
    NSString *version = (__bridge_transfer NSString *)AMDeviceCopyValue(device, 0, CFSTR("ProductVersion"));
    NSString *build = (__bridge_transfer NSString *)AMDeviceCopyValue(device, 0, CFSTR("BuildVersion"));
    NSString *home = @(getenv("HOME"));
    NSString *path;
    BOOL found = NO;
    
	NSString *xcodeDevPath = copy_xcode_dev_path();
    
	path = [[NSString alloc] initWithFormat:@"%@/Library/Developer/Xcode/iOS DeviceSupport/%@ (%@)/DeveloperDiskImage.dmg", home, version, build];
	found = path_exists(path);
    
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Library/Developer/Xcode/iOS DeviceSupport/%@/DeveloperDiskImage.dmg", home, version];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Library/Developer/Xcode/iOS DeviceSupport/Latest/DeveloperDiskImage.dmg", home];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Platforms/iPhoneOS.platform/DeviceSupport/%@ (%@)/DeveloperDiskImage.dmg", xcodeDevPath, version, build];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Platforms/iPhoneOS.platform/DeviceSupport/%@/DeveloperDiskImage.dmg", xcodeDevPath, version];
		found = path_exists(path);
	}
	if (!found)
	{
		path = [[NSString alloc] initWithFormat:@"%@/Platforms/iPhoneOS.platform/DeviceSupport/Latest/DeveloperDiskImage.dmg", xcodeDevPath];
		found = path_exists(path);
	}
    
    if (!found)
	{
		Log(@"[ !! ] Unable to locate DeviceSupport directory containing DeveloperDiskImage.dmg.\n");
		Log(@"[ !! ] Last path checked: %@\n", path);
		exit(EXIT_FAILURE);
	}
    
	return path;
}

void mount_callback(CFDictionaryRef dict_cf, int arg) {
    (void)arg; // no-unused
    NSDictionary *dict = (__bridge NSDictionary *)dict_cf;
    NSString *status = dict[@"Status"];
    
    if ([status isEqual:@"LookingUpImage"]) {
        Log(@"[  0%%] Looking up developer disk image\n");
    } else if ([status isEqual:@"CopyingIMage"]) {
        Log(@"[ 30%%] Copying DeveloperDiskImage.dmg to device\n");
    } else if ([status isEqual:@"MountingUpImage"]) {
        Log(@"[ 90%%] Mounting developer disk image\n");
    }
}

void mount_developer_image(AMDeviceRef device) {
    NSString *ds_path = copy_device_support_path(device);
    NSString *image_path = copy_developer_disk_image_path(device);
    NSString *sig_path = [[NSString alloc] initWithFormat:@"%@.signature", image_path];
    
    if (verbose) {
        Log(@"Device support path: %@\n", ds_path);
        Log(@"Developer disk image: %@\n", image_path);
    }
    
    FILE* sig = fopen([sig_path UTF8String], "rb");
    void *sig_buf = malloc(128);
    assert(fread(sig_buf, 1, 128, sig) == 128);
    fclose(sig);
    NSData *sig_data = [[NSData alloc] initWithBytesNoCopy:sig_buf length:128];
    
    NSDictionary *options = @{@"ImageSignature":sig_data, @"ImageType":@"Developer"};
    
    int result = AMDeviceMountImage(device, (__bridge CFStringRef)image_path, (__bridge CFDictionaryRef)options, &mount_callback, 0);
    if (result == 0) {
        Log(@"[ 95%%] Developer disk image mounted successfully\n");
    } else if ((unsigned int)result == 0xe8000076 /* already mounted */) {
        Log(@"[ 95%%] Developer disk image already mounted\n");
    } else {
        Log(@"[ !! ] Unable to mount developer disk image. (%x)\n", result);
        exit(EXIT_FAILURE);
    }
}

void transfer_callback(CFDictionaryRef dict_cf, int arg) {
    (void)arg; // no-unused
    NSDictionary *dict = (__bridge NSDictionary *)dict_cf;
    NSString *status = dict[@"Status"];
    
    if ([status isEqual:@"CopyingFile"]) {
        NSString *path = dict[@"Path"];
        
        if ((last_path == nil || ![path isEqual:last_path]) && ![path hasSuffix:@".ipa"]) {
            Log(@"[%3d%%] Copying %@ to device\n", [dict[@"PercentComplete"] intValue] / 2, path);
        }
        last_path = path;
    }
}

void operation_callback(CFDictionaryRef dict_cf, int arg) {
    (void)arg; // no-unused
    NSDictionary *dict = (__bridge NSDictionary *)dict_cf;
    NSString *status = dict[@"Status"];
    NSNumber *percent = dict[@"PercentComplete"];
    Log(@"[%3d%%] %@\n", ([percent intValue] / 2) + 50, status);
}

void fdvendor_callback(CFSocketRef s, CFSocketCallBackType callbackType, CFDataRef address_cf, const void *data, void *info) {
    (void)callbackType, (void)address_cf, (void)info; // no-unused
    CFSocketNativeHandle socket = (CFSocketNativeHandle)(*((CFSocketNativeHandle *)data));
    
    struct msghdr message;
    struct iovec iov[1];
    struct cmsghdr *control_message = NULL;
    char ctrl_buf[CMSG_SPACE(sizeof(int))];
    char dummy_data[1];
    
    memset(&message, 0, sizeof(struct msghdr));
    memset(ctrl_buf, 0, CMSG_SPACE(sizeof(int)));
    
    dummy_data[0] = ' ';
    iov[0].iov_base = dummy_data;
    iov[0].iov_len = sizeof(dummy_data);
    
    message.msg_name = NULL;
    message.msg_namelen = 0;
    message.msg_iov = iov;
    message.msg_iovlen = 1;
    message.msg_controllen = CMSG_SPACE(sizeof(int));
    message.msg_control = ctrl_buf;
    
    control_message = CMSG_FIRSTHDR(&message);
    control_message->cmsg_level = SOL_SOCKET;
    control_message->cmsg_type = SCM_RIGHTS;
    control_message->cmsg_len = CMSG_LEN(sizeof(int));
    
    *((int *) CMSG_DATA(control_message)) = gdbfd;
    
    sendmsg(socket, &message, 0);
    CFSocketInvalidate(s);
    CFRelease(s);
}

NSURL *copy_device_app_url(AMDeviceRef device, NSString *identifier) {
    CFDictionaryRef result_cf;
    NSDictionary *result;
    assert(AMDeviceLookupApplications(device, 0, &result_cf) == 0);
    result = (__bridge NSDictionary *)result_cf;
    
    NSDictionary *app_dict = result[identifier];
    
    assert(app_dict != nil);
    
    NSString *app_path = app_dict[@"Path"];
    assert(app_path != nil);
    
    return [NSURL fileURLWithPath:app_path];
}

NSString *copy_disk_app_identifier(NSURL *disk_app_url) {
    NSURL *plist_url = [disk_app_url URLByAppendingPathComponent:@"Info.plist"];
    NSInputStream *plist_stream = [[NSInputStream alloc] initWithURL:plist_url];
    [plist_stream open];
    NSPropertyListFormat format;
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithStream:plist_stream options:NSPropertyListImmutable format:&format error:nil];
    NSString *bundle_identifier = plist[@"CFBundleIdentifier"];
    [plist_stream close];
    return bundle_identifier;
}

void write_gdb_prep_cmds(AMDeviceRef device, NSURL *disk_app_url) {
    NSString *cmds = [@GDB_PREP_CMDS copy];
    NSString *ds_path = copy_device_support_path(device);
    cmds = [cmds stringByReplacingOccurrencesOfString:@"{ds_path}" withString:ds_path];
    
    if (args == nil) {
        args = @"";
    }
    
    cmds = [cmds stringByReplacingOccurrencesOfString:@"{args}" withString:args];
    
    NSString *bundle_identifier = copy_disk_app_identifier(disk_app_url);
    NSURL *device_app_url = copy_device_app_url(device, bundle_identifier);
    cmds = [cmds stringByReplacingOccurrencesOfString:@"{device_app}" withString:[device_app_url path]];
    
    cmds = [cmds stringByReplacingOccurrencesOfString:@"{disk_app}" withString:[disk_app_url path]];
    
    NSURL *device_container_url = [device_app_url URLByDeletingLastPathComponent];
    NSString *device_container_path = [device_container_url path];
    device_container_path = [device_container_path stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
    cmds = [cmds stringByReplacingOccurrencesOfString:@"{device_container}" withString:device_container_path];
    
    NSURL *disk_container_url = [disk_app_url URLByDeletingLastPathComponent];
    NSString *disk_container_path = [disk_container_url path];
    cmds = [cmds stringByReplacingOccurrencesOfString:@"{disk_container}" withString:disk_container_path];
    
    NSData *cmds_data = [cmds dataUsingEncoding:NSUTF8StringEncoding];
    [cmds_data writeToFile:@PREP_CMDS_PATH atomically:NO];
}

void start_remote_debug_server(AMDeviceRef device) {
    assert(AMDeviceStartService(device, CFSTR("com.apple.debugserver"), &gdbfd, NULL) == 0);
    
    CFSocketRef fdvendor = CFSocketCreate(NULL, AF_UNIX, 0, 0, kCFSocketAcceptCallBack, &fdvendor_callback, NULL);
    
    int yes = 1;
    setsockopt(CFSocketGetNative(fdvendor), SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, FDVENDOR_PATH);
    address.sun_len = SUN_LEN(&address);
    CFDataRef address_data = CFDataCreate(NULL, (const UInt8 *)&address, sizeof(address));
    
    unlink(FDVENDOR_PATH);
    
    CFSocketSetAddress(fdvendor, address_data);
    CFRelease(address_data);
    CFRunLoopSourceRef rlsrc = CFSocketCreateRunLoopSource(NULL, fdvendor, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), rlsrc, kCFRunLoopCommonModes);
    CFRelease(rlsrc);
}

void gdb_ready_handler(int signum)
{
    (void)signum; // no-unused
	_exit(EXIT_SUCCESS);
}

void read_dir(service_conn_t afcFd, afc_connection* afc_conn_p, const char* dir)
{
    char *dir_ent;
    
    afc_connection afc_conn;
    if (!afc_conn_p) {
        afc_conn_p = &afc_conn;
        AFCConnectionOpen(afcFd, 0, &afc_conn_p);
        
    }
    
    printf("%s\n", dir);
    fflush(stdout);
    
    afc_dictionary afc_dict;
    afc_dictionary* afc_dict_p = &afc_dict;
    AFCFileInfoOpen(afc_conn_p, dir, &afc_dict_p);
    
    afc_directory afc_dir;
    afc_directory* afc_dir_p = &afc_dir;
    afc_error_t err = AFCDirectoryOpen(afc_conn_p, dir, &afc_dir_p);
    
    if (err != 0)
    {
        // Couldn't open dir - was probably a file
        return;
    }
    
    while(true) {
        AFCDirectoryRead(afc_conn_p, afc_dir_p, &dir_ent);
        
        if (!dir_ent)
            break;
        
        if (strcmp(dir_ent, ".") == 0 || strcmp(dir_ent, "..") == 0)
            continue;
        
        char* dir_joined = malloc(strlen(dir) + strlen(dir_ent) + 2);
        strcpy(dir_joined, dir);
        if (dir_joined[strlen(dir)-1] != '/')
            strcat(dir_joined, "/");
        strcat(dir_joined, dir_ent);
        read_dir(afcFd, afc_conn_p, dir_joined);
        free(dir_joined);
    }
    
    AFCDirectoryClose(afc_conn_p, afc_dir_p);
}

service_conn_t start_afc_service(AMDeviceRef device) {
    AMDeviceConnect(device);
    assert(AMDeviceIsPaired(device));
    assert(AMDeviceValidatePairing(device) == 0);
    assert(AMDeviceStartSession(device) == 0);
    
    service_conn_t afcFd;
    assert(AMDeviceStartService(device, AMSVC_AFC, &afcFd, NULL) == 0);
    
    assert(AMDeviceStopSession(device) == 0);
    assert(AMDeviceDisconnect(device) == 0);
    return afcFd;
}

service_conn_t start_install_proxy_service(AMDeviceRef device) {
    AMDeviceConnect(device);
    assert(AMDeviceIsPaired(device));
    assert(AMDeviceValidatePairing(device) == 0);
    assert(AMDeviceStartSession(device) == 0);
    
    service_conn_t installFd;
    assert(AMDeviceStartService(device, CFSTR("com.apple.mobile.installation_proxy"), &installFd, NULL) == 0);
    
    assert(AMDeviceStopSession(device) == 0);
    assert(AMDeviceDisconnect(device) == 0);
    
    return installFd;
}

// Used to send files to app-specific sandbox (Documents dir)
service_conn_t start_house_arrest_service(AMDeviceRef device) {
    AMDeviceConnect(device);
    assert(AMDeviceIsPaired(device));
    assert(AMDeviceValidatePairing(device) == 0);
    assert(AMDeviceStartSession(device) == 0);
    
    service_conn_t houseFd;
    
    if (AMDeviceStartHouseArrestService(device, (__bridge CFStringRef)bundle_id, 0, &houseFd, 0) != 0)
    {
        Log(@"Unable to find bundle with id: %@\n", bundle_id);
        exit(1);
    }
    
    assert(AMDeviceStopSession(device) == 0);
    assert(AMDeviceDisconnect(device) == 0);
    
    return houseFd;
}

void install_app(AMDeviceRef device) {
    service_conn_t afcFd = start_afc_service(device);
        
    assert(AMDeviceTransferApplication(afcFd, (__bridge CFStringRef)app_path, NULL, transfer_callback, NULL) == 0);
    close(afcFd);
    
    service_conn_t installFd = start_install_proxy_service(device);
    
    NSDictionary *options = @{@"PackageType":@"Developer"};
    mach_error_t result = AMDeviceInstallApplication (installFd, (__bridge CFStringRef)app_path, (__bridge CFDictionaryRef)options, operation_callback, NULL);
    if (result != 0)
    {
        Log(@"AMDeviceInstallApplication failed: %d\n", result);
        exit(1);
    }
    
    close(installFd);
}

void uninstall_app(AMDeviceRef device) {    
    service_conn_t installFd = start_install_proxy_service(device);
    
    mach_error_t result = AMDeviceUninstallApplication (installFd, (__bridge CFStringRef)bundle_id, NULL, operation_callback, NULL);
    if (result != 0)
    {
        Log(@"AMDeviceUninstallApplication failed: %d\n", result);
        exit(1);
    }
    
    close(installFd);
}

NSString *get_filename_from_path(NSString *path)
{
    return [[NSURL fileURLWithPath:path] lastPathComponent];
}

const void* read_file_to_memory(NSString *path, size_t* file_size)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    *file_size = [data length];
    return [data bytes];
}

void list_files(AMDeviceRef device)
{
    service_conn_t houseFd = start_house_arrest_service(device);
    
    afc_connection afc_conn;
    afc_connection* afc_conn_p = &afc_conn;
    AFCConnectionOpen(houseFd, 0, &afc_conn_p);
    
    read_dir(houseFd, afc_conn_p, "/");
}

void upload_file(AMDeviceRef device) {
    service_conn_t houseFd = start_house_arrest_service(device);
    
    afc_file_ref file_ref;
    
    afc_connection afc_conn;
    afc_connection* afc_conn_p = &afc_conn;
    AFCConnectionOpen(houseFd, 0, &afc_conn_p);
    
    //        read_dir(houseFd, NULL, "/");
    
    if (target_filename == nil)
    {
        target_filename = get_filename_from_path(doc_file_path);
    }
    NSString *target_path = [NSString pathWithComponents:@[@"/Documents/", target_filename]];
    
    size_t file_size;
    const void* file_content = read_file_to_memory(doc_file_path, &file_size);
    
    if (!file_content)
    {
        Log(@"Could not open file: %@\n", doc_file_path);
        exit(-1);
    }
    
    assert(AFCFileRefOpen(afc_conn_p, [target_path UTF8String], 3, &file_ref) == 0);
    assert(AFCFileRefWrite(afc_conn_p, file_ref, file_content, (unsigned int)file_size) == 0);
    assert(AFCFileRefClose(afc_conn_p, file_ref) == 0);
    assert(AFCConnectionClose(afc_conn_p) == 0);
}

void do_debug(AMDeviceRef device) {
    NSURL *relative_url = [[NSURL alloc] initFileURLWithPath:app_path];
    NSURL *url = [relative_url absoluteURL];
    
    AMDeviceConnect(device);
    assert(AMDeviceIsPaired(device));
    assert(AMDeviceValidatePairing(device) == 0);
    assert(AMDeviceStartSession(device) == 0);
    
    Log(@"------ Debug phase ------\n");
    
    mount_developer_image(device);      // put debugserver on the device
    start_remote_debug_server(device);  // start debugserver
    write_gdb_prep_cmds(device, url);   // dump the necessary gdb commands into a file
    
    Log(@"[100%%] Connecting to remote debug server\n");
    Log(@"-------------------------\n");
    
    signal(SIGHUP, gdb_ready_handler);
    
    pid_t parent = getpid();
    int pid = fork();
    if (pid == 0) {
        system(GDB_SHELL);      // launch gdb
        kill(parent, SIGHUP);  // "No. I am your father."
        _exit(EXIT_SUCCESS);
    }
}

void handle_device(AMDeviceRef device) {
    if (found_device) return; // handle one device only
    
    NSString *found_device_id = (__bridge_transfer NSString *)AMDeviceCopyDeviceIdentifier(device);
    
    Log(@"found device id\n");
    if (device_id != nil) {
        if ([device_id isEqual:found_device_id]) {
            found_device = YES;
        } else {
            return;
        }
    } else {
        if (operation == OP_LIST_DEVICES) {
            Log(@"%@\n", found_device_id);
            return;
        }
        found_device = YES;
    }
    
    if (operation == OP_INSTALL) {
        Log(@"[  0%%] Found device (%@), beginning install\n", found_device_id);
        
        install_app(device);
        
        Log(@"[100%%] Installed package %@\n", app_path);
        
        if (debug)
            do_debug(device);
        
    } else if (operation == OP_UNINSTALL) {
        Log(@"[  0%%] Found device (%@), beginning uninstall\n", found_device_id);
        
        uninstall_app(device);
        
        Log(@"[100%%] uninstalled package %@\n", bundle_id);
        
    } else if (operation == OP_UPLOAD_FILE) {
        Log(@"[  0%%] Found device (%@), sending file\n", found_device_id);
        
        upload_file(device);
        
        Log(@"[100%%] file sent %s\n", doc_file_path);
        
    } else if (operation == OP_LIST_FILES) {
        Log(@"[  0%%] Found device (%@), listing / ...\n", found_device_id);
        
        list_files(device);
        
        Log(@"[100%%] done.\n");
    }
    exit(0);
}

void device_callback(struct am_device_notification_callback_info *info, void *arg) {
    (void)arg; // no-unused
    switch (info->msg) {
        case ADNCI_MSG_CONNECTED:
			if( info->dev->lockdown_conn ) {
				handle_device(info->dev);
			}
        default:
            break;
    }
}

void timeout_callback(CFRunLoopTimerRef timer, void *info) {
    (void)timer, (void)info; // no-unused
    if (!found_device) {
        Log(@"Timed out waiting for device.\n");
        exit(EXIT_FAILURE);
    }
}

void usage(const char* app) {
    printf ("usage: %s [-q/--quiet] [-t/--timeout timeout(seconds)] [-v/--verbose] <command> [<args>] \n\n", app);
    printf ("Commands available:\n");
    printf ("   install    [--id=device_id] --bundle=bundle.app [--debug] [--args=arguments] \n");
    printf ("    * Install the specified app with optional arguments to the specified device, or all\n");
    printf ("      attached devices if none are specified. \n\n");
    printf ("   uninstall  [--id=device_id] --bundle-id=<bundle id> \n");
    printf ("    * Removes the specified bundle identifier (eg com.foo.MyApp) from the specified device,\n");
    printf ("      or all attached devices if none are specified. \n\n");
    printf ("   upload     [--id=device_id] --bundle-id=<bundle id> --file=filename [--target=filename]\n");
    printf ("    * Uploads a file to the documents directory of the app specified with the bundle \n");
    printf ("      identifier (eg com.foo.MyApp) to the specified device, or all attached devices if\n");
    printf ("      none are specified. \n\n");
    printf ("   list-files [--id=device_id] --bundle-id=<bundle id> \n");
    printf ("    * Lists the the files in the app-specific sandbox  specified with the bundle \n");
    printf ("      identifier (eg com.foo.MyApp) on the specified device, or all attached devices if\n");
    printf ("      none are specified. \n\n");
    printf ("   list-devices  \n");
    printf ("    * List all attached devices. \n\n");
}

bool args_are_valid() {
    return (operation == OP_INSTALL && app_path) ||
    (operation == OP_UNINSTALL && bundle_id) ||
    (operation == OP_UPLOAD_FILE && bundle_id && doc_file_path) ||
    (operation == OP_LIST_FILES && bundle_id) ||
    (operation == OP_LIST_DEVICES);
}

int main(int argc, char *argv[]) {
    static struct option global_longopts[]= {
        { "quiet", no_argument, NULL, 'q' },
        { "verbose", no_argument, NULL, 'v' },
        { "timeout", required_argument, NULL, 't' },
        
        { "id", required_argument, NULL, 'i' },
        { "bundle", required_argument, NULL, 'b' },
        { "file", required_argument, NULL, 'f' },
        { "target", required_argument, NULL, 1 },
        { "bundle-id", required_argument, NULL, 0 },
        
        { "debug", no_argument, NULL, 'd' },
        { "args", required_argument, NULL, 'a' },
        
        { NULL, 0, NULL, 0 },
    };
    
    char ch;
    while ((ch = getopt_long(argc, argv, "qvi:b:f:da:t:", global_longopts, NULL)) != -1)
    {
        switch (ch) {
            case 0:
                bundle_id = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'q':
                quiet = 1;
                break;
            case 'v':
                verbose = 1;
                break;
            case 'd':
                debug = 1;
                break;
            case 't':
                timeout = atoi(optarg);
                break;
            case 'b':
                app_path = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'f':
                doc_file_path = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 1:
                target_filename = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'a':
                args = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'i':
                device_id = [[NSString alloc] initWithUTF8String:optarg];
                break;
                
            default:
                usage(argv[0]);
                return 1;
        }
    }
    
    if (optind >= argc) {
        usage(argv [0]);
        exit(EXIT_SUCCESS);
    }
    
    operation = OP_NONE;
    if (strcmp (argv [optind], "install") == 0) {
        operation = OP_INSTALL;
    } else if (strcmp (argv [optind], "uninstall") == 0) {
        operation = OP_UNINSTALL;
    } else if (strcmp (argv [optind], "list-devices") == 0) {
        operation = OP_LIST_DEVICES;
    } else if (strcmp (argv [optind], "upload") == 0) {
        operation = OP_UPLOAD_FILE;
    } else if (strcmp (argv [optind], "list-files") == 0) {
        operation = OP_LIST_FILES;
    } else {
        usage (argv [0]);
        exit (0);
    }
    
    if (!args_are_valid()) {
        usage(argv[0]);
        exit(0);
    }
    
    if (operation == OP_INSTALL)
        assert([[[NSURL alloc] initFileURLWithPath:app_path] checkResourceIsReachableAndReturnError:nil] == YES);
    
    AMDSetLogLevel(1+4+2+8+16+32+64+128); // otherwise syslog gets flooded with crap
    if (timeout > 0)
    {
        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + timeout, 0, 0, 0, timeout_callback, NULL);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
        Log(@"[....] Waiting up to %d seconds for iOS device to be connected\n", timeout);
    }
    else
    {
        Log(@"[....] Waiting for iOS device to be connected\n");
    }
    
    struct am_device_notification *notify;
    AMDeviceNotificationSubscribe(&device_callback, 0, 0, NULL, &notify);
    
    CFRunLoopRun();
}
