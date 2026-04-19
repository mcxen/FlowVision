#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"netdcy.FlowVision";

/// The "OutlineViewBgColor" asset catalog color resource.
static NSString * const ACColorNameOutlineViewBgColor AC_SWIFT_PRIVATE = @"OutlineViewBgColor";

/// The "AliasBadge" asset catalog image resource.
static NSString * const ACImageNameAliasBadge AC_SWIFT_PRIVATE = @"AliasBadge";

#undef AC_SWIFT_PRIVATE
