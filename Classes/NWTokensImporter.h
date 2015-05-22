//
//  NWTokensImporter.h
//  NWPusher
//
//  Created by Mateusz Malczak on 20/05/15.
//  Copyright (c) 2015 noodlewerk. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NWTokensImporter : NSObject <NSStreamDelegate>

-(instancetype) init;

-(NSArray*) availableTokens;

-(BOOL) isWorking;

-(void) addTokensFile:(NSURL*) url;

-(void) parseTokensAsyncWithBlock:(void(^)(NSString *file, NSString *token, NSError* error)) block completion:(void(^)(NSArray *tokens)) completionBlock;

-(void) parseTokensWithBlock:(void(^)(NSString *file, NSString *token, NSError* error)) block;

@end
