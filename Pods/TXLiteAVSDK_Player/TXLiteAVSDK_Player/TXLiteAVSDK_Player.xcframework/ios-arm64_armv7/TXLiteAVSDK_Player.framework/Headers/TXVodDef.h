//  Copyright © 2023 Tencent. All rights reserved.

#import <Foundation/Foundation.h>
#import "TXLiteAVSymbolExport.h"

/**
 * Subtitle callback data
 */
LITEAV_EXPORT @interface TXVodSubtitleData : NSObject

/// Subtitle content
@property(nonatomic, copy) NSString *subtitleData;

/// Subtitle duration, in milliseconds
@property(nonatomic, assign) int64_t durationMs;

/// Subtitle start time, which is the position of the video, in milliseconds
@property(nonatomic, assign) int64_t startPositionMs;

/// TrackIndex of the current subtitle track
@property(nonatomic, assign) int64_t trackIndex;

@end
