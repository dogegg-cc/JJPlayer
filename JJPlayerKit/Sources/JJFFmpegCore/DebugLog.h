//
//  Header.h
//  JJPlayerKit
//
//  Created by 我勒个去去 on 2026/5/21.
//

#ifndef DebugLog_h
#define DebugLog_h

#ifdef DEBUG
#define DLog(fmt, ...) NSLog((@"[DLog] %s Line %d | " fmt), __FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
#define DLog(...)
#endif

#endif
