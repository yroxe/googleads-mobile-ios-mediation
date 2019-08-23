#import <Foundation/Foundation.h>
#import <GoogleMobileAds/GoogleMobileAds.h>
#import "GADMoPubNetworkExtras.h"
#import "MPNativeAd.h"

/// MoPub's native ad wrapper.
@interface GADMAdapterMopubUnifiedNativeAd : NSObject <GADMediatedUnifiedNativeAd>

/// Initializes GADMAdapterMopubUnifiedNativeAd class.
- (nonnull instancetype)initWithMoPubNativeAd:(nonnull MPNativeAd *)mopubNativeAd
                                  mappedImage:(nullable GADNativeAdImage *)mappedImage
                                   mappedIcon:(nullable GADNativeAdImage *)mappedIcon
                          nativeAdViewOptions:
                              (nonnull GADNativeAdViewAdOptions *)nativeAdViewOptions
                                networkExtras:(nullable GADMoPubNetworkExtras *)networkExtras;

@end
