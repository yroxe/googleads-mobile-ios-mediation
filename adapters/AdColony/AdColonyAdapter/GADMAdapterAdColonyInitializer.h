//
//  Copyright © 2018 Google. All rights reserved.
//

#import <AdColony/AdColony.h>
#import <Foundation/Foundation.h>
#import <GoogleMobileAds/GoogleMobileAds.h>

#define DEBUG_LOGGING 0

#if DEBUG_LOGGING
#define NSLogDebug(...) NSLog(__VA_ARGS__)
#else
#define NSLogDebug(...)
#endif

/// AdColony SDK init state.
typedef NS_ENUM(NSInteger, GADMAdapterAdColonyInitState) {
  GADMAdapterAdColonyUninitialized,
  GADMAdapterAdColonyInitialized,
  GADMAdapterAdColonyInitializing
};

/// AdColony adapter initialization completion handler.
typedef void (^GADMAdapterAdColonyInitCompletionHandler)(NSError *_Nullable error);

@interface GADMAdapterAdColonyInitializer : NSObject

/// The shared GADMAdapterAdColonyInitializer instance.
@property(class, atomic, readonly, nonnull) GADMAdapterAdColonyInitializer *sharedInstance;

/// Initilizes AdColony SDK with the provided app ID, zone IDs and AdColonyAppOptions.
- (void)initializeAdColonyWithAppId:(nonnull NSString *)appId
                              zones:(nonnull NSArray *)newZones
                            options:(nonnull AdColonyAppOptions *)options
                           callback:(nonnull GADMAdapterAdColonyInitCompletionHandler)callback;

@end
