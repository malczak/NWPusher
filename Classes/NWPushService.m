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

@property (nonatomic, assign) NSUInteger sendCount;

@property (nonatomic, assign) NSUInteger failedCount;

@property (nonatomic, assign) NSUInteger totalCount;

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
    
    self.totalCount = [tokens count];
    self.sendCount = 0;
    self.failedCount = 0;
    
    __weak typeof(self) weakSelf = self;
    dispatchOnMain(weakSelf.beginBlock);
    
    [self pushNotification];
}

- (NSUInteger) sendCount
{
    return _sendCount;
}

- (NSUInteger) failedCount
{
    return _failedCount;
}

- (NSUInteger) totalCount
{
    return _totalCount;
}

- (NSUInteger) intProgress
{
    return round(((double)(self.sendCount + self.failedCount) / (double)self.totalCount) * 100.0);
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
                                                                             token:token
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
                                   if (read && !failed)
                                   {
                                       weakSelf.sendCount += 1;
                                       dispatchOnMain(weakSelf.notificationSendComplete,token);
                                   } else {
                                        [weakSelf pushFailed:token withError:error];
                                   }
                                   
                                   [_hub trimIdentifiers];
                                   
                                   dispatch_group_leave(strongSelf.sendQueueGroup);
                               });
            } else {
                [weakSelf pushFailed:token withError:error];
            }
                        
        }
    };
}

- (void)pushFailed:(NSString*) token withError:(NSError*) error
{
    self.failedCount += 1;
    dispatchOnMain(self.notificationSendError, token, error);
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
