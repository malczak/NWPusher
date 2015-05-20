//
//  NWPushService.h
//  NWPusher
//
//  Created by Mateusz Malczak on 20/05/15.
//  Copyright (c) 2015 noodlewerk. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "NWHub.h"

@interface NWPushService : NSObject

@property (nonatomic, weak) NWHub *hub;

@property (nonatomic, assign) dispatch_queue_t queue;

@property (nonatomic, assign) NSUInteger delay;

@property (nonatomic, copy) void (^notificationWillSend)(NSString *token);

@property (nonatomic, copy) void (^notificationSendComplete)(NSString *token);

@property (nonatomic, copy) void (^notificationSendError)(NSString *token, NSError *error);

@property (nonatomic, copy) void (^beginBlock)();

@property (nonatomic, copy) void (^completionBlock)();

- (void) pushWithTokens:(NSArray*) tokens payload:(NSString*) payload expireDate:(NSDate*) expiry priority:(NSUInteger) priority;

@end
