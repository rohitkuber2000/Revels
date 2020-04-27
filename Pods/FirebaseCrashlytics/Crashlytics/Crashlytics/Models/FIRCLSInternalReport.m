// Copyright 2019 Google
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "FIRCLSInternalReport.h"

#import "FIRCLSFile.h"
#import "FIRCLSFileManager.h"
#import "FIRCLSLogger.h"

NSString *const CLSReportBinaryImageFile = @"binary_images.clsrecord";
NSString *const CLSReportExceptionFile = @"exception.clsrecord";
NSString *const CLSReportCustomExceptionAFile = @"custom_exception_a.clsrecord";
NSString *const CLSReportCustomExceptionBFile = @"custom_exception_b.clsrecord";
NSString *const CLSReportSignalFile = @"signal.clsrecord";
#if CLS_MACH_EXCEPTION_SUPPORTED
NSString *const CLSReportMachExceptionFile = @"mach_exception.clsrecord";
#endif
NSString *const CLSReportMetadataFile = @"metadata.clsrecord";
NSString *const CLSReportErrorAFile = @"errors_a.clsrecord";
NSString *const CLSReportErrorBFile = @"errors_b.clsrecord";
NSString *const CLSReportInternalIncrementalKVFile = @"internal_incremental_kv.clsrecord";
NSString *const CLSReportInternalCompactedKVFile = @"internal_compacted_kv.clsrecord";
NSString *const CLSReportUserIncrementalKVFile = @"user_incremental_kv.clsrecord";
NSString *const CLSReportUserCompactedKVFile = @"user_compacted_kv.clsrecord";

@interface FIRCLSInternalReport () {
  NSString *_identifier;
  NSString *_path;
  NSArray *_metadataSections;
}

@end

@implementation FIRCLSInternalReport

+ (instancetype)reportWithPath:(NSString *)path {
  return [[self alloc] initWithPath:path];
}

#pragma mark - Initialization
/**
 * Initializes a new report, i.e. one without metadata on the file system yet.
 */
- (instancetype)initWithPath:(NSString *)path executionIdentifier:(NSString *)identifier {
  self = [super init];
  if (!self) {
    return self;
  }

  if (!path || !identifier) {
    return nil;
  }

  [self setPath:path];

  _identifier = [identifier copy];

  return self;
}

/**
 * Initializes a pre-existing report, i.e. one with metadata on the file system.
 */
- (instancetype)initWithPath:(NSString *)path {
  NSString *metadataPath = [path stringByAppendingPathComponent:CLSReportMetadataFile];
  NSString *identifier = [[[[self.class readFIRCLSFileAtPath:metadataPath] objectAtIndex:0]
      objectForKey:@"identity"] objectForKey:@"session_id"];
  if (!identifier) {
    FIRCLSErrorLog(@"Unable to read identifier at path %@", path);
  }
  return [self initWithPath:path executionIdentifier:identifier];
}

#pragma mark - Path Helpers
- (NSString *)directoryName {
  return self.path.lastPathComponent;
}

- (NSString *)pathForContentFile:(NSString *)name {
  return [[self path] stringByAppendingPathComponent:name];
}

- (NSString *)metadataPath {
  return [[self path] stringByAppendingPathComponent:CLSReportMetadataFile];
}

- (NSString *)binaryImagePath {
  return [self pathForContentFile:CLSReportBinaryImageFile];
}

#pragma mark - Processing Methods
- (BOOL)needsToBeSubmitted {
  NSArray *reportFiles = @[
    CLSReportExceptionFile, CLSReportSignalFile, CLSReportCustomExceptionAFile,
    CLSReportCustomExceptionBFile,
#if CLS_MACH_EXCEPTION_SUPPORTED
    CLSReportMachExceptionFile,
#endif
    CLSReportErrorAFile, CLSReportErrorBFile
  ];
  return [self checkExistenceOfAtLeastOnceFileInArray:reportFiles];
}

- (NSArray *)crashFilenames {
  static NSArray *files;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    files = @[
      CLSReportExceptionFile,
#if CLS_MACH_EXCEPTION_SUPPORTED
      CLSReportMachExceptionFile,
#endif
      CLSReportSignalFile
    ];
  });
  return files;
}

- (BOOL)isCrash {
  NSArray *crashFiles = [self crashFilenames];
  return [self checkExistenceOfAtLeastOnceFileInArray:crashFiles];
}

- (BOOL)checkExistenceOfAtLeastOnceFileInArray:(NSArray *)files {
  NSFileManager *manager = [NSFileManager defaultManager];

  for (NSString *fileName in files) {
    NSString *path = [self pathForContentFile:fileName];

    if ([manager fileExistsAtPath:path]) {
      return YES;
    }
  }

  return NO;
}

- (void)enumerateSymbolicatableFilesInContent:(void (^)(NSString *path))block {
  for (NSString *fileName in [self crashFilenames]) {
    NSString *path = [self pathForContentFile:fileName];

    block(path);
  }
}

#pragma mark - Metadata helpers
+ (NSArray *)readFIRCLSFileAtPath:(NSString *)path {
  NSArray *sections = FIRCLSFileReadSections([path fileSystemRepresentation], false, nil);

  if ([sections count] == 0) {
    return nil;
  }

  return sections;
}

- (NSArray *)metadataSections {
  if (!_metadataSections) {
    _metadataSections = [self.class readFIRCLSFileAtPath:self.metadataPath];
  }
  return _metadataSections;
}

- (NSString *)orgID {
  return
      [[[self.metadataSections objectAtIndex:0] objectForKey:@"identity"] objectForKey:@"org_id"];
}

- (NSDictionary *)customKeys {
  return nil;
}

- (NSString *)bundleVersion {
  return [[[self.metadataSections objectAtIndex:2] objectForKey:@"application"]
      objectForKey:@"build_version"];
}

- (NSString *)bundleShortVersionString {
  return [[[self.metadataSections objectAtIndex:2] objectForKey:@"application"]
      objectForKey:@"display_version"];
}

- (NSDate *)dateCreated {
  NSUInteger unixtime = [[[[self.metadataSections objectAtIndex:0] objectForKey:@"identity"]
      objectForKey:@"started_at"] unsignedIntegerValue];

  return [NSDate dateWithTimeIntervalSince1970:unixtime];
}

- (NSDate *)crashedOnDate {
  if (!self.isCrash) {
    return nil;
  }

#if CLS_MACH_EXCEPTION_SUPPORTED
  // try the mach exception first, because it is more common
  NSDate *date = [self timeFromCrashContentFile:CLSReportMachExceptionFile
                                    sectionName:@"mach_exception"];
  if (date) {
    return date;
  }
#endif

  return [self timeFromCrashContentFile:CLSReportSignalFile sectionName:@"signal"];
}

- (NSDate *)timeFromCrashContentFile:(NSString *)fileName sectionName:(NSString *)sectionName {
  // This works because both signal and mach exception files have the same structure to extract
  // the "time" component
  NSString *path = [self pathForContentFile:fileName];

  NSNumber *timeValue = [[[[self.class readFIRCLSFileAtPath:path] objectAtIndex:0]
      objectForKey:sectionName] objectForKey:@"time"];
  if (timeValue == nil) {
    return nil;
  }

  return [NSDate dateWithTimeIntervalSince1970:[timeValue unsignedIntegerValue]];
}

- (NSString *)OSVersion {
  return [[[self.metadataSections objectAtIndex:1] objectForKey:@"host"]
      objectForKey:@"os_display_version"];
}

- (NSString *)OSBuildVersion {
  return [[[self.metadataSections objectAtIndex:1] objectForKey:@"host"]
      objectForKey:@"os_build_version"];
}

@end
