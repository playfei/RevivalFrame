#import "SMB2ClientWrapper.h"

#include <fcntl.h>
#include "smb2/smb2.h"
#include "smb2/libsmb2.h"

static NSString * const SMB2ClientWrapperErrorDomain = @"RevivalFrame.SMB2Client";

@implementation SMB2FileEntry
@end

@interface SMB2ClientWrapper ()
@property (nonatomic, assign) struct smb2_context *context;
@property (nonatomic, copy, readwrite) NSString *displayName;
@property (nonatomic, copy, readwrite) NSString *rootPath;
@end

@implementation SMB2ClientWrapper

- (instancetype)initWithURLString:(NSString *)urlString
                         username:(NSString *)username
                         password:(NSString *)password
                            error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _context = smb2_init_context();
    if (_context == NULL) {
        [self setError:error message:@"Unable to initialize SMB2 context."];
        return nil;
    }

    if (username.length > 0) {
        smb2_set_user(_context, username.UTF8String);
    }
    if (password.length > 0) {
        smb2_set_password(_context, password.UTF8String);
    }

    NSString *urlWithOptions = [self normalizedURLString:urlString];
    struct smb2_url *url = smb2_parse_url(_context, urlWithOptions.UTF8String);
    if (url == NULL) {
        [self setLastSMBError:error fallback:@"Enter an SMB URL like smb://server/share/folder."];
        [self disconnect];
        return nil;
    }

    if (smb2_connect_share(_context, url->server, url->share, url->user) != 0) {
        [self setLastSMBError:error fallback:@"Unable to connect to SMB share."];
        smb2_destroy_url(url);
        [self disconnect];
        return nil;
    }

    NSString *server = [NSString stringWithUTF8String:url->server ?: ""];
    NSString *share = [NSString stringWithUTF8String:url->share ?: ""];
    NSString *path = [NSString stringWithUTF8String:url->path ?: ""];
    _rootPath = path;
    _displayName = [self displayPathWithServer:server share:share path:_rootPath];
    smb2_destroy_url(url);

    return self;
}

- (void)dealloc
{
    [self disconnect];
}

- (nullable NSArray<SMB2FileEntry *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error
{
    struct smb2dir *dir = smb2_opendir(_context, path.UTF8String);
    if (dir == NULL) {
        [self setLastSMBError:error fallback:@"Unable to read SMB directory."];
        return nil;
    }

    NSMutableArray<SMB2FileEntry *> *entries = [NSMutableArray array];
    struct smb2dirent *entry = NULL;
    while ((entry = smb2_readdir(_context, dir)) != NULL) {
        if (entry->name == NULL || entry->name[0] == '.') {
            continue;
        }
        SMB2FileEntry *file = [[SMB2FileEntry alloc] init];
        file.name = [NSString stringWithUTF8String:entry->name];
        file.path = [self path:path appending:file.name];
        file.directory = entry->st.smb2_type == SMB2_TYPE_DIRECTORY;
        [entries addObject:file];
    }
    smb2_closedir(_context, dir);
    return [entries copy];
}

- (nullable NSArray<NSString *> *)photoPathsRecursivelyAtPath:(NSString *)path
                                           supportedExtensions:(NSSet<NSString *> *)extensions
                                                        error:(NSError **)error
{
    NSArray<SMB2FileEntry *> *entries = [self contentsOfDirectoryAtPath:path error:error];
    if (!entries) {
        return nil;
    }

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (SMB2FileEntry *entry in entries) {
        if (entry.directory) {
            NSArray<NSString *> *childPaths = [self photoPathsRecursivelyAtPath:entry.path supportedExtensions:extensions error:error];
            if (!childPaths) {
                return nil;
            }
            [paths addObjectsFromArray:childPaths];
        } else if ([extensions containsObject:entry.name.pathExtension.lowercaseString]) {
            [paths addObject:entry.path];
        }
    }
    return [paths copy];
}

- (BOOL)downloadFileAtPath:(NSString *)path toLocalPath:(NSString *)localPath error:(NSError **)error
{
    struct smb2fh *file = smb2_open(_context, path.UTF8String, O_RDONLY);
    if (file == NULL) {
        [self setLastSMBError:error fallback:@"Unable to open SMB file."];
        return NO;
    }

    [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
    if (![[NSFileManager defaultManager] createFileAtPath:localPath contents:nil attributes:nil]) {
        smb2_close(_context, file);
        [self setError:error message:@"Unable to create local cache file."];
        return NO;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:localPath];
    if (!handle) {
        smb2_close(_context, file);
        [self setError:error message:@"Unable to write local cache file."];
        return NO;
    }

    uint8_t buffer[1024 * 256];
    while (true) {
        int readCount = smb2_read(_context, file, buffer, sizeof(buffer));
        if (readCount < 0) {
            [handle closeFile];
            smb2_close(_context, file);
            [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
            [self setLastSMBError:error fallback:@"Unable to read SMB file."];
            return NO;
        }
        if (readCount == 0) {
            break;
        }
        NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)readCount];
        [handle writeData:data];
    }

    [handle closeFile];
    smb2_close(_context, file);
    return YES;
}

- (void)disconnect
{
    if (_context != NULL) {
        smb2_destroy_context(_context);
        _context = NULL;
    }
}

- (NSString *)normalizedURLString:(NSString *)urlString
{
    NSString *trimmed = [urlString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed containsString:@"?"]) {
        return trimmed;
    }
    return [trimmed stringByAppendingString:@"?sec=ntlmssp"];
}

- (NSString *)displayPathWithServer:(NSString *)server share:(NSString *)share path:(NSString *)path
{
    NSString *cleanPath = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (cleanPath.length == 0) {
        return [NSString stringWithFormat:@"smb://%@/%@", server, share];
    }
    return [NSString stringWithFormat:@"smb://%@/%@/%@", server, share, cleanPath];
}

- (NSString *)path:(NSString *)path appending:(NSString *)component
{
    NSString *base = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (base.length == 0) {
        return component;
    }
    if ([base hasSuffix:@"/"]) {
        return [base stringByAppendingString:component];
    }
    return [[base stringByAppendingString:@"/"] stringByAppendingString:component];
}

- (void)setLastSMBError:(NSError **)error fallback:(NSString *)fallback
{
    const char *message = _context ? smb2_get_error(_context) : NULL;
    NSString *text = message && strlen(message) > 0 ? [NSString stringWithUTF8String:message] : fallback;
    [self setError:error message:text];
}

- (void)setError:(NSError **)error message:(NSString *)message
{
    if (error == NULL) {
        return;
    }
    *error = [NSError errorWithDomain:SMB2ClientWrapperErrorDomain
                                 code:1
                             userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
