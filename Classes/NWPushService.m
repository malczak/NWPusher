//
//  NWPushService.m
//  NWPusher
//
//  Created by Mateusz Malczak on 20/05/15.
//  Copyright (c) 2015 noodlewerk. All rights reserved.
//

#import "NWPushService.h"
#import "NWNotification.h"

#define dispatchOnMain(_block, ...) \
if( _block ) \
{ \
    dispatch_async(dispatch_get_main_queue(), ^{ \
        _block(__VA_ARGS__); \
    }); \
}


@interface NWPushService ()

@property (nonatomic, strong) NSString *payload;

@property (nonatomic, strong) NSDate *expiry;

@property (nonatomic, assign) NSUInteger priority;

@property (nonatomic, strong) NSEnumerator *tokenEnumerator;

@property (nonatomic, strong) NSArray *tokens;

@property (nonatomic, assign) dispatch_group_t sendQueueGroup;

@end

@implementation NWPushService

-(instancetype)init
{
    self = [super init];
    if(self)
    {
        self.sendQueueGroup = dispatch_group_create();
    }
    return self;
}

- (void) pushWithTokens:(NSArray*) tokens payload:(NSString*) payload expireDate:(NSDate*) expiry priority:(NSUInteger) priority
{
    NSAssert(nil != self.hub, @"Hub is required");
    
    NSAssert(nil != self.queue, @"Missing hub queue");

    self.tokens = [tokens copy];
    self.tokenEnumerator = self.tokens.objectEnumerator;
    
    self.payload = payload;
    self.expiry = [expiry copy];
    self.priority = priority;
    
    __weak typeof(self) weakSelf = self;
    dispatchOnMain(weakSelf.beginBlock);
    
    [self pushNotification];
}

- (void) pushNotification
{
    NSString *token = [self.tokenEnumerator nextObject];
    if(token)
    {
        __weak typeof(self) weakSelf = self;

        dispatch_group_async(self.sendQueueGroup, self.queue, [self sendNotificationBlock:token]);

        dispatch_group_notify(self.sendQueueGroup, self.queue, ^(){
            if(weakSelf.delay > 0)
            {
                dispatch_time_t delayTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(weakSelf.delay * NSEC_PER_MSEC));
                dispatch_after(delayTime, weakSelf.queue, ^(void) {
                    __strong typeof(self) strongSelf = weakSelf;
                    if(strongSelf)
                    {
                        [weakSelf pushNotification];
                    }
                });
            } else {
                [weakSelf pushNotification];
            }
        });
        

    } else {
        [self complete];
    }
}

- (void(^)()) sendNotificationBlock:(NSString*) token
{
    __weak typeof(self) weakSelf = self;
    return ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if(strongSelf)
        {
            NWNotification *notification = [[NWNotification alloc] initWithPayload:strongSelf.payload
                                                                             token:nil
                                                                        identifier:0
                                                                        expiration:strongSelf.expiry
                                                                          priority:strongSelf.priority];
            NSError *error = nil;
        
            dispatchOnMain(weakSelf.notificationWillSend,token);
            
            BOOL pushed = [strongSelf.hub pushNotification:notification
                                             autoReconnect:YES
                                                     error:&error];
            
            if (pushed)
            {
                dispatch_group_enter(weakSelf.sendQueueGroup);
                
                dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC));
                dispatch_after(popTime, strongSelf.queue, ^(void)
                               {
                                   NSError *error = nil;
                                   NWNotification *failed = nil;
                                   BOOL read = [strongSelf.hub readFailed:&failed
                                                            autoReconnect:YES
                                                                    error:&error];
                                   if (read)
                                   {
                                       if (!failed)
                                       {
                                           dispatchOnMain(weakSelf.notificationSendComplete,token);
                                       }
                                   }
                                   
                                   [_hub trimIdentifiers];
                                   
                                   dispatch_group_leave(strongSelf.sendQueueGroup);
                               });
            }
            
            
            if(nil != error)
            {
                dispatchOnMain(weakSelf.notificationSendError,token, error);
            }
        }
    };
}

- (void)complete
{
    __weak typeof(self) weakSelf = self;
    dispatchOnMain(weakSelf.completionBlock);
}

-(void)dealloc
{
    self.beginBlock = nil;
    self.sendQueueGroup = nil;
    self.tokens = nil;
    self.completionBlock = nil;
    self.notificationWillSend = nil;
    self.notificationSendComplete = nil;
    self.notificationSendError = nil;
    self.queue = nil;
}

@end
