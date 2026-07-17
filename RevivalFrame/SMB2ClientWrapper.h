#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SMB2FileEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL directory;
@end

@interface SMB2ClientWrapper : NSObject
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly) NSString *rootPath;

- (nullable instancetype)initWithURLString:(NSString *)urlString
                                  username:(NSString *)username
                                  password:(NSString *)password
                                     error:(NSError **)error;
- (nullable NSArray<SMB2FileEntry *> *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error;
- (nullable NSArray<NSString *> *)photoPathsRecursivelyAtPath:(NSString *)path
                                           supportedExtensions:(NSSet<NSString *> *)extensions
                                                        error:(NSError **)error;
- (BOOL)downloadFileAtPath:(NSString *)path toLocalPath:(NSString *)localPath error:(NSError **)error;
- (void)disconnect;
@end

NS_ASSUME_NONNULL_END
