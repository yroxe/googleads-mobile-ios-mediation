#import "GADMAdapterMoPub.h"

#import "GADMAdapterMoPubConstants.h"
#import "GADMAdapterMoPubSingleton.h"
#import "GADMAdapterMoPubUtils.h"
#import "GADMAdapterMopubUnifiedNativeAd.h"
#import "GADMoPubNetworkExtras.h"
#import "MPAdView.h"
#import "MPImageDownloadQueue.h"
#import "MPInterstitialAdController.h"
#import "MPLogging.h"
#import "MPNativeAd.h"
#import "MPNativeAdConstants.h"
#import "MPNativeAdDelegate.h"
#import "MPNativeAdRequest.h"
#import "MPNativeAdRequestTargeting.h"
#import "MPNativeAdUtils.h"
#import "MPNativeCache.h"
#import "MPStaticNativeAdRenderer.h"
#import "MPStaticNativeAdRendererSettings.h"
#import "MoPub.h"

static NSMapTable<NSString *, GADMAdapterMoPub *> *GADMAdapterMoPubInterstitialDelegates;

@interface GADMAdapterMoPub () <MPNativeAdDelegate,
                                MPAdViewDelegate,
                                MPInterstitialAdControllerDelegate>
@end

@implementation GADMAdapterMoPub {
  /// Connector from Google Mobile Ads SDK to receive ad configurations.
  __weak id<GADMAdNetworkConnector> _connector;

  /// Array of ad loader options.
  NSArray<GADAdLoaderOptions *> *_nativeAdOptions;

  /// MoPub banner ad.
  MPAdView *_bannerAd;

  /// MoPub interstitial ad.
  MPInterstitialAdController *_interstitialAd;

  /// MoPub native ad.
  MPNativeAd *_nativeAd;

  /// MoPub native ad wrapper.
  GADMAdapterMopubUnifiedNativeAd *_mediatedAd;

  /// MoPub's image download queue.
  MPImageDownloadQueue *_imageDownloadQueue;

  /// A dictionary that contains the icon and image assets for the native ad.
  NSMutableDictionary<NSString *, GADNativeAdImage *> *_imagesDictionary;

  /// Ad loader options for configuring the view of native ads.
  GADNativeAdViewAdOptions *_nativeAdViewAdOptions;

  /// Indicates whether the image assets should be downloaded or not.
  BOOL _shouldDownloadImages;

  /// Serializes GADMAdapterMoPubInterstitialDelegates usage.
  dispatch_queue_t _lockQueue;
}

+ (void)load {
  GADMAdapterMoPubInterstitialDelegates =
      [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory
                            valueOptions:NSPointerFunctionsWeakMemory];
}

+ (NSString *)adapterVersion {
  return kGADMAdapterMoPubVersion;
}

+ (Class<GADAdNetworkExtras>)networkExtrasClass {
  return [GADMoPubNetworkExtras class];
}

- (instancetype)initWithGADMAdNetworkConnector:(id<GADMAdNetworkConnector>)connector {
  self = [super init];
  if (self) {
    _connector = connector;
    _imageDownloadQueue = [[MPImageDownloadQueue alloc] init];
    _lockQueue = dispatch_queue_create("mopub-interstitialAdapterDelegates", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)stopBeingDelegate {
  _bannerAd.delegate = nil;
  _interstitialAd.delegate = nil;
}

/// Keywords passed from AdMob are separated into 1) personally identifiable,
/// and 2) non-personally identifiable categories before they are forwarded to MoPub due to GDPR.

- (nonnull NSString *)getKeywords:(BOOL)intendedForPII {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  NSDate *birthday = [strongConnector userBirthday];
  NSString *ageString = @"";

  if (birthday) {
    NSInteger ageInteger = [self ageFromBirthday:birthday];
    ageString = [@"m_age:" stringByAppendingString:[@(ageInteger) stringValue]];
  }

  GADGender gender = [strongConnector userGender];
  NSString *genderString = @"";

  if (gender == kGADGenderMale) {
    genderString = @"m_gender:m";
  } else if (gender == kGADGenderFemale) {
    genderString = @"m_gender:f";
  }
  NSString *keywordsBuilder =
      [NSString stringWithFormat:@"%@,%@,%@", kGADMAdapterMoPubTpValue, ageString, genderString];

  if (intendedForPII) {
    if ([[MoPub sharedInstance] canCollectPersonalInfo]) {
      return [self keywordsContainUserData:strongConnector] ? keywordsBuilder : @"";
    } else {
      return @"";
    }
  } else {
    return [self keywordsContainUserData:strongConnector] ? @"" : keywordsBuilder;
  }
}

- (NSInteger)ageFromBirthday:(nonnull NSDate *)birthdate {
  NSDate *today = [NSDate date];
  NSDateComponents *ageComponents = [[NSCalendar currentCalendar] components:NSCalendarUnitYear
                                                                    fromDate:birthdate
                                                                      toDate:today
                                                                     options:0];
  return ageComponents.year;
}

- (BOOL)keywordsContainUserData:(id<GADMAdNetworkConnector>)connector {
  return [connector userGender] || [connector userBirthday] || [connector userHasLocation];
}

#pragma mark - Interstitial Ads

- (void)getInterstitial {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  NSString *publisherID = strongConnector.credentials[kGADMAdapterMoPubPubIdKey];

  dispatch_async(_lockQueue, ^{
    if ([GADMAdapterMoPubInterstitialDelegates objectForKey:publisherID]) {
      NSError *adapterError = [NSError
          errorWithDomain:kGADMAdapterMoPubErrorDomain
                     code:kGADErrorInvalidRequest
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to request a second ad using the same "
                                               @"publisher ID while the first ad is still active."
                 }];
      [strongConnector adapter:self didFailAd:adapterError];
      return;
    } else {
      GADMAdapterMoPubMapTableSetObjectForKey(GADMAdapterMoPubInterstitialDelegates, publisherID,
                                              self);
    }
  });

  CLLocation *currentlocation = [[CLLocation alloc] initWithLatitude:strongConnector.userLatitude
                                                           longitude:strongConnector.userLongitude];

  _interstitialAd = [MPInterstitialAdController interstitialAdControllerForAdUnitId:publisherID];
  _interstitialAd.delegate = self;
  _interstitialAd.keywords = [self getKeywords:NO];
  _interstitialAd.userDataKeywords = [self getKeywords:YES];
  _interstitialAd.location = currentlocation;

  MPLogDebug(@"Requesting Interstitial Ad from MoPub Ad Network.");
  [[GADMAdapterMoPubSingleton sharedInstance] initializeMoPubSDKWithAdUnitID:publisherID
                                                           completionHandler:^{
                                                             [self->_interstitialAd loadAd];
                                                           }];
}

- (void)presentInterstitialFromRootViewController:(UIViewController *)rootViewController {
  if (_interstitialAd.ready) {
    [_interstitialAd showFromViewController:rootViewController];
  }
}

#pragma mark MoPub Interstitial Ads delegate methods

- (void)interstitialDidLoadAd:(MPInterstitialAdController *)interstitial {
  [_connector adapterDidReceiveInterstitial:self];
}

- (void)interstitialDidFailToLoadAd:(MPInterstitialAdController *)interstitial {
  NSError *adapterError = [NSError errorWithDomain:kGADMAdapterMoPubErrorDomain
                                              code:kGADErrorMediationNoFill
                                          userInfo:nil];
  dispatch_async(_lockQueue, ^{
    GADMAdapterMoPubMapTableRemoveObjectForKey(GADMAdapterMoPubInterstitialDelegates,
                                               interstitial.adUnitId);
  });
  [_connector adapter:self didFailAd:adapterError];
}

- (void)interstitialWillAppear:(MPInterstitialAdController *)interstitial {
  [_connector adapterWillPresentInterstitial:self];
}

- (void)interstitialWillDisappear:(MPInterstitialAdController *)interstitial {
  [_connector adapterWillDismissInterstitial:self];
}

- (void)interstitialDidDisappear:(MPInterstitialAdController *)interstitial {
  dispatch_async(_lockQueue, ^{
    GADMAdapterMoPubMapTableRemoveObjectForKey(GADMAdapterMoPubInterstitialDelegates,
                                               interstitial.adUnitId);
  });
  [_connector adapterDidDismissInterstitial:self];
}

- (void)interstitialDidReceiveTapEvent:(MPInterstitialAdController *)interstitial {
  [_connector adapterDidGetAdClick:self];
}

#pragma mark - Banner Ads

- (void)getBannerWithSize:(GADAdSize)adSize {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  NSString *publisherID = strongConnector.credentials[kGADMAdapterMoPubPubIdKey];

  CLLocation *currentlocation = [[CLLocation alloc] initWithLatitude:strongConnector.userLatitude
                                                           longitude:strongConnector.userLongitude];

  _bannerAd = [[MPAdView alloc] initWithAdUnitId:publisherID];
  _bannerAd.delegate = self;
  _bannerAd.keywords = [self getKeywords:NO];
  _bannerAd.userDataKeywords = [self getKeywords:YES];
  _bannerAd.location = currentlocation;

  MPLogDebug(@"Requesting Banner Ad from MoPub Ad Network.");
  [[GADMAdapterMoPubSingleton sharedInstance]
      initializeMoPubSDKWithAdUnitID:publisherID
                   completionHandler:^{
                     [self->_bannerAd loadAdWithMaxAdSize:adSize.size];
                   }];
}

#pragma mark MoPub Ads View delegate methods

- (void)adViewDidLoadAd:(MPAdView *)view adSize:(CGSize)adSize {
  [_connector adapter:self didReceiveAdView:view];
}

- (void)adViewDidFailToLoadAd:(MPAdView *)view {
  NSString *errorDescription = [NSString stringWithFormat:@"Mopub failed to fill the ad."];
  NSDictionary *errorInfo =
      [NSDictionary dictionaryWithObjectsAndKeys:errorDescription, NSLocalizedDescriptionKey, nil];

  [_connector adapter:self
            didFailAd:[NSError errorWithDomain:kGADErrorDomain
                                          code:kGADErrorInvalidRequest
                                      userInfo:errorInfo]];
}

- (void)willLeaveApplicationFromAd:(MPAdView *)view {
  [_connector adapterWillLeaveApplication:self];
}

- (void)willPresentModalViewForAd:(MPAdView *)view {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  [strongConnector adapterDidGetAdClick:self];
  [strongConnector adapterWillPresentFullScreenModal:self];
}

- (void)didDismissModalViewForAd:(MPAdView *)view {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  [strongConnector adapterWillDismissFullScreenModal:self];
  [strongConnector adapterDidDismissFullScreenModal:self];
}

- (BOOL)isBannerAnimationOK:(GADMBannerAnimationType)animType {
  return YES;
}

#pragma mark - Native Ads

- (void)getNativeAdWithAdTypes:(NSArray<GADAdLoaderAdType> *)adTypes
                       options:(NSArray<GADAdLoaderOptions *> *)options {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  MPStaticNativeAdRendererSettings *settings = [[MPStaticNativeAdRendererSettings alloc] init];
  MPNativeAdRendererConfiguration *config =
      [MPStaticNativeAdRenderer rendererConfigurationWithRendererSettings:settings];

  NSString *publisherID = strongConnector.credentials[kGADMAdapterMoPubPubIdKey];
  MPNativeAdRequest *adRequest = [MPNativeAdRequest requestWithAdUnitIdentifier:publisherID
                                                         rendererConfigurations:@[ config ]];

  MPNativeAdRequestTargeting *targeting = [MPNativeAdRequestTargeting targeting];
  targeting.keywords = [self getKeywords:NO];
  targeting.userDataKeywords = [self getKeywords:YES];
  CLLocation *currentlocation = [[CLLocation alloc] initWithLatitude:strongConnector.userLatitude
                                                           longitude:strongConnector.userLongitude];
  targeting.location = currentlocation;
  NSSet *desiredAssets = [NSSet
      setWithObjects:kAdTitleKey, kAdTextKey, kAdIconImageKey, kAdMainImageKey, kAdCTATextKey, nil];
  targeting.desiredAssets = desiredAssets;

  adRequest.targeting = targeting;
  _nativeAdOptions = options;

  [[GADMAdapterMoPubSingleton sharedInstance] initializeMoPubSDKWithAdUnitID:publisherID
                                                           completionHandler:^{
                                                             [self requestNative:adRequest];
                                                           }];
}

- (void)requestNative:(nonnull MPNativeAdRequest *)adRequest {
  MPLogDebug(@"Requesting Native Ad from MoPub Ad Network.");
  [adRequest startWithCompletionHandler:^(MPNativeAdRequest *request, MPNativeAd *response,
                                          NSError *error) {
    [self handleNativeAdOptions:request
                   withResponse:response
                      withError:error
                    withOptions:self->_nativeAdOptions];
  }];
}

- (void)handleNativeAdOptions:(MPNativeAdRequest *)request
                 withResponse:(MPNativeAd *)response
                    withError:(NSError *)error
                  withOptions:(NSArray<GADAdLoaderOptions *> *)options {
  if (error) {
    [_connector adapter:self didFailAd:error];
  } else {
    _nativeAd = response;
    _nativeAd.delegate = self;
    _shouldDownloadImages = YES;

    if (options != nil) {
      for (GADAdLoaderOptions *loaderOptions in options) {
        if ([loaderOptions isKindOfClass:[GADNativeAdImageAdLoaderOptions class]]) {
          GADNativeAdImageAdLoaderOptions *imageOptions =
              (GADNativeAdImageAdLoaderOptions *)loaderOptions;
          _shouldDownloadImages = !imageOptions.disableImageLoading;
        } else if ([loaderOptions isKindOfClass:[GADNativeAdViewAdOptions class]]) {
          _nativeAdViewAdOptions = (GADNativeAdViewAdOptions *)loaderOptions;
        }
      }
    }
    [self loadNativeAdImages];
  }
}

#pragma mark - Helper methods for downloading images

- (void)loadNativeAdImages {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  NSMutableArray<NSURL *> *imageURLs = [[NSMutableArray alloc] init];
  NSError *adapterError = [NSError
      errorWithDomain:kGADMAdapterMoPubErrorDomain
                 code:kGADErrorReceivedInvalidResponse
             userInfo:@{
               NSLocalizedDescriptionKey : @"Can't find the image assests of the MoPub native ad."
             }];

  for (NSString *key in [_nativeAd.properties allKeys]) {
    if ([key.lowercaseString hasSuffix:@"image"] &&
        [_nativeAd.properties[key] isKindOfClass:[NSString class]]) {
      if (_nativeAd.properties[key]) {
        NSURL *URL = [NSURL URLWithString:_nativeAd.properties[key]];
        if (URL != nil) {
          GADMAdapterMoPubMutableArrayAddObject(imageURLs, URL);
        } else {
          [strongConnector adapter:self didFailAd:adapterError];
          return;
        }
      } else {
        [strongConnector adapter:self didFailAd:adapterError];
        return;
      }
    }
  }
  [self precacheImagesWithURL:imageURLs];
}

- (NSString *)returnImageKey:(NSString *)imageURL {
  for (NSString *key in [_nativeAd.properties allKeys]) {
    if ([key.lowercaseString hasSuffix:@"image"] &&
        [_nativeAd.properties[key] isKindOfClass:[NSString class]]) {
      if ([_nativeAd.properties[key] isEqualToString:imageURL]) {
        return key;
      }
    }
  }
  return nil;
}

- (void)precacheImagesWithURL:(NSArray<NSURL *> *)imageURLs {
  id<GADMAdNetworkConnector> strongConnector = _connector;
  _imagesDictionary = [[NSMutableDictionary alloc] init];

  for (NSURL *imageURL in imageURLs) {
    NSData *cachedImageData =
        [[MPNativeCache sharedCache] retrieveDataForKey:imageURL.absoluteString];

    UIImage *image = [UIImage imageWithData:cachedImageData];
    if (image) {
      // By default, the image data isn't decompressed until set on a UIImageView, on the main
      // thread. This can result in poor scrolling performance. To fix this, we force decompression
      // in the background before assignment to a UIImageView.
      UIGraphicsBeginImageContext(CGSizeMake(1, 1));
      [image drawAtPoint:CGPointZero];
      UIGraphicsEndImageContext();

      GADNativeAdImage *nativeAdImage = [[GADNativeAdImage alloc] initWithImage:image];
      NSString *imagekey = [self returnImageKey:imageURL.absoluteString];
      GADMAdapterMoPubMutableDictionarySetObjectForKey(_imagesDictionary, imagekey, nativeAdImage);
    }
  }

  if (_imagesDictionary[kAdIconImageKey] && _imagesDictionary[kAdMainImageKey]) {
    _mediatedAd = [[GADMAdapterMopubUnifiedNativeAd alloc]
        initWithMoPubNativeAd:_nativeAd
                  mappedImage:_imagesDictionary[kAdMainImageKey]
                   mappedIcon:_imagesDictionary[kAdIconImageKey]
          nativeAdViewOptions:_nativeAdViewAdOptions
                networkExtras:strongConnector.networkExtras];
    [strongConnector adapter:self didReceiveMediatedUnifiedNativeAd:_mediatedAd];
    return;
  }

  MPLogDebug(@"Re-downloading as cache miss on %@", imageURLs);

  GADMAdapterMoPub __weak *weakSelf = self;
  [_imageDownloadQueue
      addDownloadImageURLs:imageURLs
           completionBlock:^(NSArray *errors) {
             GADMAdapterMoPub *strongSelf = weakSelf;
             if (!strongSelf) {
               MPLogDebug(@"MPNativeAd deallocated before loadImageForURL:intoImageView: download "
                          @"completion block was called");
               NSError *adapterError = [NSError errorWithDomain:kGADMAdapterMoPubErrorDomain
                                                           code:kGADErrorInternalError
                                                       userInfo:nil];
               [strongConnector adapter:strongSelf didFailAd:adapterError];
               return;
             }

             if (errors.count > 0) {
               MPLogDebug(@"Failed to download images. Giving up for now.");
               NSError *adapterError = [NSError errorWithDomain:kGADMAdapterMoPubErrorDomain
                                                           code:kGADErrorNetworkError
                                                       userInfo:nil];
               [strongConnector adapter:strongSelf didFailAd:adapterError];
               return;
             }

             id<GADMAdNetworkConnector> strongConnector = strongSelf->_connector;
             for (NSURL *imageURL in imageURLs) {
               UIImage *image =
                   [UIImage imageWithData:[[MPNativeCache sharedCache]
                                              retrieveDataForKey:imageURL.absoluteString]];

               GADNativeAdImage *nativeAdImage = [[GADNativeAdImage alloc] initWithImage:image];
               NSString *imagekey = [strongSelf returnImageKey:imageURL.absoluteString];
               GADMAdapterMoPubMutableDictionarySetObjectForKey(strongSelf->_imagesDictionary,
                                                                imagekey, nativeAdImage);
             }

             if (strongSelf->_imagesDictionary[kAdIconImageKey] &&
                 strongSelf->_imagesDictionary[kAdMainImageKey]) {
               strongSelf->_mediatedAd = [[GADMAdapterMopubUnifiedNativeAd alloc]
                   initWithMoPubNativeAd:strongSelf->_nativeAd
                             mappedImage:strongSelf->_imagesDictionary[kAdMainImageKey]
                              mappedIcon:strongSelf->_imagesDictionary[kAdIconImageKey]
                     nativeAdViewOptions:strongSelf->_nativeAdViewAdOptions
                           networkExtras:strongConnector.networkExtras];
               [strongConnector adapter:strongSelf
                   didReceiveMediatedUnifiedNativeAd:strongSelf->_mediatedAd];
             }
           }];
}

#pragma mark MPNativeAdDelegate Methods

- (UIViewController *)viewControllerForPresentingModalView {
  return [_connector viewControllerForPresentingModalView];
}

- (void)willPresentModalForNativeAd:(MPNativeAd *)nativeAd {
  [GADMediatedUnifiedNativeAdNotificationSource mediatedNativeAdWillPresentScreen:_mediatedAd];
}

- (void)didDismissModalForNativeAd:(MPNativeAd *)nativeAd {
  [GADMediatedUnifiedNativeAdNotificationSource mediatedNativeAdWillDismissScreen:_mediatedAd];
  [GADMediatedUnifiedNativeAdNotificationSource mediatedNativeAdDidDismissScreen:_mediatedAd];
}

- (void)willLeaveApplicationFromNativeAd:(MPNativeAd *)nativeAd {
  [GADMediatedUnifiedNativeAdNotificationSource mediatedNativeAdWillLeaveApplication:_mediatedAd];
}

@end
