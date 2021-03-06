//
//  NWTokensImporter.m
//  NWPusher
//
//  Created by Mateusz Malczak on 20/05/15.
//  Copyright (c) 2015 noodlewerk. All rights reserved.
//

#import "NWTokensImporter.h"

@interface NWTokensImporter ()

@property (nonatomic, assign) BOOL working;

@property (nonatomic, strong) NSMutableArray *tokenFiles;

@property (nonatomic, strong) NSString *filePath;

@property (nonatomic, strong) NSInputStream *inputStream;

@property (nonatomic, assign) dispatch_queue_t queue;

@property (nonatomic, strong) NSMutableArray *tokens;

@property (nonatomic, copy) void (^parseBlock)(NSString *file, NSString *token, NSError *error);

@property (nonatomic, copy) void (^completionBlock)(NSArray *tokens);

@end
@implementation NWTokensImporter

-(instancetype) init
{
    self = [super init];
    if(self)
    {
        self.working = NO;
        self.tokens = @[].mutableCopy;
        self.tokenFiles = @[].mutableCopy;
        self.filePath = nil;
        self.inputStream = nil;
    }
    return self;
}

-(NSArray*) availableTokens
{
    __block NSArray *result = nil;
    @synchronized(self)
    {
        result = self.tokens;
    }
    return result;
}

-(BOOL) isWorking
{
    return self.working;
}

-(void)addTokensFile:(NSURL *)url
{
    if(self.working)
    {
        return;
    }
    
    if(![self.tokenFiles containsObject:url])
    {
        [self.tokenFiles addObject:url];
    }
}

-(void) parseTokensAsyncWithBlock:(void(^)(NSString *file, NSString *token, NSError* error)) block completion:(void(^)(NSArray *tokens)) completionBlock
{
    if(self.working)
    {
        return;
    }
    
    self.parseBlock = block;
    self.completionBlock = completionBlock;

    [self parseTokensAsync:YES];
}

-(void) parseTokensWithBlock:(void(^)(NSString *file, NSString *token, NSError* error)) block
{
    if(self.working)
    {
        return;
    }

    self.parseBlock = block;
    self.completionBlock = nil;
    
    [self parseTokensAsync:NO];
}

-(void) parseTokensAsync:(BOOL) async
{
    if(async)
    {
        [self popFileAndParseAsync];
    } else {
        [self parseAllFilesWithBlock];
    }
}

-(BOOL) createStream
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *url = nil;
    
    do
    {
        if(![self.tokenFiles count])
        {
            return NO;
        }
        
        url =[self.tokenFiles firstObject];
        [self.tokenFiles removeObject:url];
    } while( ![fileManager fileExistsAtPath:[url path]] );
    
    self.filePath = [[url filePathURL] path];
    self.inputStream = [NSInputStream inputStreamWithFileAtPath:self.filePath];
    self.inputStream.delegate = self;
    
    return YES;
}

-(void) popFileAndParseAsync
{
    if([self createStream])
    {
        self.working = YES;

        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        
        __weak typeof(self) weakSelf = self;
        dispatch_async(queue, ^(){
            [weakSelf readStreamWithBlock:weakSelf.parseBlock];
            [weakSelf popFileAndParseAsync];
        });
    } else {
        [self tokenParseCompleted];
    }
}

-(void) parseAllFilesWithBlock
{
    while ([self createStream])
    {
        self.working = YES;
        [self readStreamWithBlock:self.parseBlock];
    }
    [self tokenParseCompleted];
}

-(void) readStreamWithBlock:(void(^)(NSString *file, NSString *token, NSError *error)) block
{
    NSInputStream *ins = self.inputStream;
    if(!ins)
    {
        return;
    }
    
    void (^getToken)(NSData*) = ^(NSData *data){
        if([data length])
        {
            NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if(![line hasPrefix:@"//"])
            {
                NSString *token = line;

                // @todo validate tokens ?!
                
                if(block)
                {
                    block(self.filePath, token, nil);
                };
                
                @synchronized(self)
                {
                    if(![self.tokens containsObject:token])
                    {
                        [self.tokens addObject:line];
                    }
                }
            }
        }
    };
    
    [ins open];
    NSMutableData *lineData = [NSMutableData data];
    uint8_t oneByte;
    while ([ins hasBytesAvailable])
    {
        // read line
        NSUInteger actuallyRead = [ins read: &oneByte maxLength: 1];
        if (actuallyRead == 1)
        {
            if(oneByte == '\n')
            {
                getToken(lineData);
                lineData.length = 0;
            }
            
            [lineData appendBytes:&oneByte length: 1];
        }
    };
    [ins close];
    
    getToken(lineData);
    
    self.working = NO;
}

-(void) tokenParseCompleted
{
    if(self.completionBlock)
    {
        self.completionBlock(self.availableTokens);
    }
}

-(void)dealloc
{
    if(self.inputStream)
    {
        [self.inputStream close];
    }
    self.tokens = nil;
    self.completionBlock = nil;
    self.parseBlock = nil;
}
@end
