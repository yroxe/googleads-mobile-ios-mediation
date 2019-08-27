//
//  Copyright © 2018 Google. All rights reserved.
//

#import "GADMAdapterAdColonyInitializer.h"

#import "GADMAdapterAdColonyConstants.h"
#import "GADMAdapterAdColonyHelper.h"

@implementation GADMAdapterAdColonyInitializer {
  /// AdColony zones that has already been configures.
  NSSet *_configuredZones;

  /// AdColony SDK init state.
  GADMAdapterAdColonyInitState _adColonyAdapterInitState;

  /// AdColony zones that needs configuration.
  NSSet *_zonesToBeConfigured;

  /// An array of AdColony adapter initialization completion handler.
  NSMutableArray<GADMAdapterAdColonyInitCompletionHandler> *_callbacks;

  /// Holds whether there are new zones that need to be configured or not.
  BOOL _hasNewZones;

  /// Holds whether the AdColony SDK configuration is called within the last 5 seconds or not.
  BOOL _calledConfigureInLastFiveSeconds;

  /// Serial dispatch queue.
  dispatch_queue_t _lockQueue;
}

+ (nonnull GADMAdapterAdColonyInitializer *)sharedInstance {
  static dispatch_once_t onceToken;
  static GADMAdapterAdColonyInitializer *instance;
  dispatch_once(&onceToken, ^{
    instance = [[GADMAdapterAdColonyInitializer alloc] init];
  });
  return instance;
}

- (nonnull instancetype)init {
  self = [super init];
  if (self) {
    _configuredZones = [NSSet set];
    _zonesToBeConfigured = [NSMutableSet set];
    _callbacks = [[NSMutableArray alloc] init];
    _adColonyAdapterInitState = GADMAdapterAdColonyUninitialized;
    _lockQueue = dispatch_queue_create("adColony-initializer", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)initializeAdColonyWithAppId:(nonnull NSString *)appId
                              zones:(nonnull NSArray *)newZones
                            options:(nonnull AdColonyAppOptions *)options
                           callback:(nonnull GADMAdapterAdColonyInitCompletionHandler)callback {
  dispatch_async(_lockQueue, ^{
    NSSet *newZonesSet = [NSSet setWithArray:newZones];
    self->_hasNewZones = ![newZonesSet isSubsetOfSet:self->_configuredZones];

    if (!self->_hasNewZones) {
      if (options) {
        [AdColony setAppOptions:options];
      }

      if (self->_adColonyAdapterInitState == GADMAdapterAdColonyInitialized) {
        callback(nil);
      } else if (self->_adColonyAdapterInitState == GADMAdapterAdColonyInitializing) {
        GADMAdapterAdColonyMutableArrayAddObject(self->_callbacks, callback);
      }

      return;
    }

    self->_zonesToBeConfigured = [self->_configuredZones setByAddingObjectsFromSet:newZonesSet];
    if (self->_calledConfigureInLastFiveSeconds) {
      NSError *error = [NSError
          errorWithDomain:kGADMAdapterAdColonyErrorDomain
                     code:0
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"The AdColony SDK does not support being configured twice "
                       @"within a five second period. This error can be mitigated by waiting "
                       @"for the Google Mobile Ads SDK's initialization completion "
                       @"handler to be called prior to loading ads."
                 }];
      callback(error);
      return;
    }

    self->_adColonyAdapterInitState = GADMAdapterAdColonyInitializing;
    GADMAdapterAdColonyMutableArrayAddObject(self->_callbacks, callback);
    [self configureWithAppID:appId zoneIDs:[self->_zonesToBeConfigured allObjects] options:options];
    self->_zonesToBeConfigured = [[NSSet alloc] init];
  });
}

- (void)configureWithAppID:(NSString *)appID
                   zoneIDs:(NSArray *)zoneIDs
                   options:(AdColonyAppOptions *)options {
  GADMAdapterAdColonyInitializer *__weak weakSelf = self;

  NSLogDebug(@"zones: %@", [_zones allObjects]);
  _calledConfigureInLastFiveSeconds = YES;
  [AdColony configureWithAppID:appID
                       zoneIDs:zoneIDs
                       options:options
                    completion:^(NSArray<AdColonyZone *> *_Nonnull zones) {
                      GADMAdapterAdColonyInitializer *strongSelf = weakSelf;
                      if (!strongSelf) {
                        return;
                      }
                      dispatch_async(strongSelf->_lockQueue, ^{
                        if (zones.count < 1) {
                          strongSelf->_adColonyAdapterInitState = GADMAdapterAdColonyUninitialized;
                          NSError *error = [NSError
                              errorWithDomain:kGADMAdapterAdColonyErrorDomain
                                         code:0
                                     userInfo:@{
                                       NSLocalizedDescriptionKey : @"Failed to configure any zones."
                                     }];
                          for (GADMAdapterAdColonyInitCompletionHandler callback in strongSelf
                                   ->_callbacks) {
                            callback(error);
                          }
                          return;
                        }
                        strongSelf->_adColonyAdapterInitState = GADMAdapterAdColonyInitialized;
                        for (GADMAdapterAdColonyInitCompletionHandler callback in strongSelf
                                 ->_callbacks) {
                          callback(nil);
                        }
                        strongSelf->_configuredZones =
                            [strongSelf->_configuredZones setByAddingObjectsFromArray:zoneIDs];
                        [strongSelf->_callbacks removeAllObjects];
                      });
                    }];

  dispatch_async(dispatch_get_main_queue(), ^{
    [NSTimer scheduledTimerWithTimeInterval:5.0
                                     target:self
                                   selector:@selector(clearCalledConfigureInLastFiveSeconds)
                                   userInfo:nil
                                    repeats:NO];
  });
}

- (void)clearCalledConfigureInLastFiveSeconds {
  _calledConfigureInLastFiveSeconds = NO;
}

@end
