#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <React/RCTBridgeModule.h>

// App side of the passkey provider (src/passkey/native.ts). Writes the non-secret snapshot to the
// App Group for the extension (ios/PubkyRingCredentialProvider) and keeps the system's passkey
// identity store in step with it. Passkey APIs need iOS 17; the app itself supports 15.1.

static NSString *const kSnapshotFileName = @"passkey_snapshot.json";
static NSString *const kRegisteredRpIdsKey = @"passkey.registeredRpIds";
static NSString *const kErrorDomain = @"pubky_passkey";

static NSString *AppGroup(void)
{
  NSString *group = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"PubkyAppGroup"];
  return group.length > 0 ? group : nil;
}

// SHA-256("pubky-ring-credential-v1" || 0 || rpId || 0 || pubky), first 16 bytes.
// Same as PasskeyShared.credentialId (Swift) and PubkyWebAuthn.credentialId (Android).
static NSData *CredentialId(NSString *rpId, NSString *pubky)
{
  NSMutableData *input = [[@"pubky-ring-credential-v1" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  uint8_t zero = 0;
  [input appendBytes:&zero length:1];
  [input appendData:[rpId dataUsingEncoding:NSUTF8StringEncoding]];
  [input appendBytes:&zero length:1];
  [input appendData:[pubky dataUsingEncoding:NSUTF8StringEncoding]];
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
  return [NSData dataWithBytes:digest length:16];
}

static NSString *ShortPubky(NSString *pubky)
{
  if (pubky.length <= 12) {
    return pubky;
  }
  return [NSString stringWithFormat:@"%@…%@", [pubky substringToIndex:6], [pubky substringFromIndex:pubky.length - 6]];
}

@interface PubkyPasskey : NSObject <RCTBridgeModule>
@end

@implementation PubkyPasskey

RCT_EXPORT_MODULE();

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (BOOL)providerSupported
{
  if (@available(iOS 17.0, *)) {
    return AppGroup() != nil;
  }
  return NO;
}

RCT_EXPORT_METHOD(writeSnapshot:(NSString *)json
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  NSString *group = AppGroup();
  NSURL *container = group ? [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:group] : nil;
  if (!container) {
    reject(kErrorDomain, @"App Group is not configured (RING_APP_GROUP in ios/Config/Signing.xcconfig)", nil);
    return;
  }
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  NSError *error = nil;
  NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (![snapshot isKindOfClass:[NSDictionary class]]) {
    reject(kErrorDomain, @"Snapshot is not a JSON object", error);
    return;
  }
  NSURL *url = [container URLByAppendingPathComponent:kSnapshotFileName];
  if (![data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error]) {
    reject(kErrorDomain, @"Failed to write passkey snapshot", error);
    return;
  }
  if (@available(iOS 17.0, *)) {
    [self syncIdentities:snapshot group:group];
  }
  resolve(@YES);
}

// One identity per pubky for every rpId Ring knows (PASSKEY_KNOWN_RP_IDS) plus every rpId the user
// registered through navigator.credentials.create() (written by the extension).
- (void)syncIdentities:(NSDictionary *)snapshot group:(NSString *)group API_AVAILABLE(ios(17.0))
{
  NSArray *knownRpIds = [snapshot[@"knownRpIds"] isKindOfClass:[NSArray class]] ? snapshot[@"knownRpIds"] : @[];
  NSArray *identities = [snapshot[@"identities"] isKindOfClass:[NSArray class]] ? snapshot[@"identities"] : @[];
  NSDictionary *registered = [[[NSUserDefaults alloc] initWithSuiteName:group] dictionaryForKey:kRegisteredRpIdsKey] ?: @{};

  NSMutableArray<ASPasskeyCredentialIdentity *> *entries = [NSMutableArray array];
  for (NSDictionary *identity in identities) {
    NSString *pubky = [identity isKindOfClass:[NSDictionary class]] ? identity[@"pubky"] : nil;
    if (![pubky isKindOfClass:[NSString class]] || pubky.length == 0) {
      continue;
    }
    NSString *name = [identity[@"name"] isKindOfClass:[NSString class]] && [identity[@"name"] length] > 0
      ? identity[@"name"]
      : ShortPubky(pubky);
    NSMutableOrderedSet<NSString *> *rpIds = [NSMutableOrderedSet orderedSetWithArray:knownRpIds];
    NSArray *extra = [registered[pubky] isKindOfClass:[NSArray class]] ? registered[pubky] : @[];
    [rpIds addObjectsFromArray:extra];
    for (NSString *rpId in rpIds) {
      if (![rpId isKindOfClass:[NSString class]]) {
        continue;
      }
      [entries addObject:[[ASPasskeyCredentialIdentity alloc]
                           initWithRelyingPartyIdentifier:rpId
                                                 userName:name
                                             credentialID:CredentialId(rpId, pubky)
                                               userHandle:[pubky dataUsingEncoding:NSUTF8StringEncoding]
                                         recordIdentifier:pubky]];
    }
  }
  [[ASCredentialIdentityStore sharedStore] replaceCredentialIdentityEntries:entries
                                                                completion:^(BOOL success, NSError *error) {
    if (!success) {
      NSLog(@"[PubkyPasskey] Identity store sync failed: %@", error);
    }
  }];
}

RCT_EXPORT_METHOD(getProviderStatus:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  BOOL supported = [self providerSupported];
  BOOL prfSupported = NO;
  if (@available(iOS 18.0, *)) {
    prfSupported = supported;
  }
  if (!supported) {
    resolve(@{@"supported": @NO, @"enabled": [NSNull null], @"prfSupported": @NO});
    return;
  }
  [[ASCredentialIdentityStore sharedStore] getCredentialIdentityStoreStateWithCompletion:^(ASCredentialIdentityStoreState *state) {
    resolve(@{@"supported": @YES, @"enabled": @(state.enabled), @"prfSupported": @(prfSupported)});
  }];
}

RCT_EXPORT_METHOD(openProviderSettings:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (@available(iOS 17.0, *)) {
    [ASSettingsHelper openCredentialProviderAppSettingsWithCompletionHandler:^(NSError *error) {
      resolve(@(error == nil));
    }];
    return;
  }
  resolve(@NO);
}

// Android-only: the iOS consent screen is native, inside the extension.
RCT_EXPORT_METHOD(completeRequest:(NSString *)requestId
                  pubky:(NSString *)pubky
                  userVerified:(BOOL)userVerified
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(@NO);
}

RCT_EXPORT_METHOD(cancelRequest:(NSString *)requestId
                  message:(NSString *)message
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(@NO);
}

@end
