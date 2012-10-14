/*
 * Author: Andreas Linde <mail@andreaslinde.de>
 *
 * Copyright (c) 2012 HockeyApp, Bit Stadium GmbH.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */


#import "HockeySDK.h"
#import "HockeySDKPrivate.h"

#import "BITFeedbackManager.h"
#import "BITFeedbackManagerPrivate.h"
#import "BITHockeyBaseManagerPrivate.h"

#import "BITHockeyManagerPrivate.h"

#import "BITHockeyHelper.h"


#define kBITFeedbackUserDataAsked   @"HockeyFeedbackUserDataAsked"
#define kBITFeedbackDateOfLastCheck	@"HockeyFeedbackDateOfLastCheck"
#define kBITFeedbackMessages        @"HockeyFeedbackMessages"
#define kBITFeedbackToken           @"HockeyFeedbackToken"
#define kBITFeedbackName            @"HockeyFeedbackName"
#define kBITFeedbackEmail           @"HockeyFeedbackEmail"
#define kBITFeedbackLastMessageID   @"HockeyFeedbackLastMessageID"


@implementation BITFeedbackManager {
  NSFileManager  *_fileManager;
  NSString       *_feedbackDir;
  NSString       *_settingsFile;
  
  BOOL _incomingMessagesAlertShowing;
  BOOL _didSetupDidBecomeActiveNotifications;
  BOOL _networkRequestInProgress;
}

#pragma mark - Initialization

- (id)init {
  if ((self = [super init])) {
    _currentFeedbackListViewController = nil;
    _currentFeedbackComposeViewController = nil;
    _didAskUserData = NO;
    
    _requireUserName = BITFeedbackUserDataElementRequired;
    _requireUserEmail = BITFeedbackUserDataElementRequired;
    _showAlertOnIncomingMessages = YES;
    
    _disableFeedbackManager = NO;
    _didSetupDidBecomeActiveNotifications = NO;
    _networkRequestInProgress = NO;
    _incomingMessagesAlertShowing = NO;
    _lastCheck = nil;
    _token = nil;
    
    self.feedbackList = [NSMutableArray array];

    _fileManager = [[NSFileManager alloc] init];

    // temporary directory for crashes grabbed from PLCrashReporter
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    _feedbackDir = [[[paths objectAtIndex:0] stringByAppendingPathComponent:BITHOCKEY_IDENTIFIER] retain];
    
    if (![_fileManager fileExistsAtPath:_feedbackDir]) {
      NSDictionary *attributes = [NSDictionary dictionaryWithObject: [NSNumber numberWithUnsignedLong: 0755] forKey: NSFilePosixPermissions];
      NSError *theError = NULL;
      
      [_fileManager createDirectoryAtPath:_feedbackDir withIntermediateDirectories: YES attributes: attributes error: &theError];
    }
    
    _settingsFile = [[_feedbackDir stringByAppendingPathComponent:BITHOCKEY_FEEDBACK_SETTINGS] retain];
    
    
    _userName = nil;
    _userEmail = nil;
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:BITHockeyNetworkDidBecomeReachableNotification object:nil];
  
  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];

  [_currentFeedbackListViewController release], _currentFeedbackListViewController = nil;
  [_currentFeedbackComposeViewController release], _currentFeedbackComposeViewController = nil;
  
  [_lastCheck release], _lastCheck = nil;
  [_token release], _token = nil;
  [_feedbackList release], _feedbackList = nil;
  
  [_userName release], _userName = nil;
  [_userEmail release], _userEmail = nil;
  
  [_fileManager release], _fileManager = nil;
  [_feedbackDir release], _feedbackDir = nil;
  [_settingsFile release], _settingsFile = nil;
  
  [super dealloc];
}


- (void)didBecomeActiveActions {
  if (![self isFeedbackManagerDisabled]) {
    [self updateAppDefinedUserData];
    [self updateMessagesList];
  }
}

- (void)setupDidBecomeActiveNotifications {
  if (!_didSetupDidBecomeActiveNotifications) {
    NSNotificationCenter *dnc = [NSNotificationCenter defaultCenter];
    [dnc addObserver:self selector:@selector(didBecomeActiveActions) name:UIApplicationDidBecomeActiveNotification object:nil];
    [dnc addObserver:self selector:@selector(didBecomeActiveActions) name:BITHockeyNetworkDidBecomeReachableNotification object:nil];
    _didSetupDidBecomeActiveNotifications = YES;
  }
}

- (void)cleanupDidBecomeActiveNotifications {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:BITHockeyNetworkDidBecomeReachableNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

#pragma mark - Private methods

- (NSString *)uuidString {
  CFUUIDRef theToken = CFUUIDCreate(NULL);
  CFStringRef stringUUID = CFUUIDCreateString(NULL, theToken);
  CFRelease(theToken);
  
  return [(NSString *)stringUUID autorelease];
}

- (NSString *)uuidAsLowerCaseAndShortened {
  return [[[self uuidString] lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

#pragma mark - Feedback Modal UI

- (BITFeedbackListViewController *)feedbackListViewController:(BOOL)modal {
  return [[[BITFeedbackListViewController alloc] initWithModalStyle:modal] autorelease];
}

- (void)showFeedbackListView {
  if (_currentFeedbackListViewController) {
    BITHockeyLog(@"INFO: update view already visible, aborting");
    return;
  }
  
  [self showView:[self feedbackListViewController:YES]];
}


#pragma mark - Manager Control

- (void)startManager {
  if ([_feedbackList count] == 0) {
    [self loadMessages];
  } else {
    [self updateAppDefinedUserData];
  }
  [self updateMessagesList];

  [self setupDidBecomeActiveNotifications];
}

- (void)updateMessagesList {
  if (_networkRequestInProgress) return;
  
  NSArray *pendingMessages = [self messagesWithStatus:BITFeedbackMessageStatusSendPending];
  if ([pendingMessages count] > 0) {
    [self submitPendingMessages];
  } else {
    [self fetchMessageUpdates];
  }
}

- (void)updateMessagesListIfRequired {
  double now = [[NSDate date] timeIntervalSince1970];
  if ((now - [_lastCheck timeIntervalSince1970] > 30)) {
    [self updateMessagesList];
  }
}

- (void)updateAppDefinedUserData {
  if ([BITHockeyManager sharedHockeyManager].delegate &&
      [[BITHockeyManager sharedHockeyManager].delegate respondsToSelector:@selector(userNameForHockeyManager:componentManager:)]) {
    self.userName = [[BITHockeyManager sharedHockeyManager].delegate
                     userNameForHockeyManager:[BITHockeyManager sharedHockeyManager]
                     componentManager:self];
    self.requireUserName = BITFeedbackUserDataElementDontShow;
    self.requireUserEmail = BITFeedbackUserDataElementDontShow;
  }
  if ([BITHockeyManager sharedHockeyManager].delegate &&
      [[BITHockeyManager sharedHockeyManager].delegate respondsToSelector:@selector(userEmailForHockeyManager:componentManager:)]) {
    self.userEmail = [[BITHockeyManager sharedHockeyManager].delegate
                      userEmailForHockeyManager:[BITHockeyManager sharedHockeyManager]
                      componentManager:self];
    self.requireUserName = BITFeedbackUserDataElementDontShow;
    self.requireUserEmail = BITFeedbackUserDataElementDontShow;
  }
}

#pragma mark - Local Storage

- (void)loadMessages {
  BOOL userNameViaDelegate = NO;
  BOOL userEmailViaDelegate = NO;
  
  if ([BITHockeyManager sharedHockeyManager].delegate &&
      [[BITHockeyManager sharedHockeyManager].delegate respondsToSelector:@selector(userNameForHockeyManager:componentManager:)]) {
    userNameViaDelegate = YES;
    self.userName = [[BITHockeyManager sharedHockeyManager].delegate
                     userNameForHockeyManager:[BITHockeyManager sharedHockeyManager]
                     componentManager:self];
    self.requireUserName = BITFeedbackUserDataElementDontShow;
    self.requireUserEmail = BITFeedbackUserDataElementDontShow;
  }
  if ([BITHockeyManager sharedHockeyManager].delegate &&
      [[BITHockeyManager sharedHockeyManager].delegate respondsToSelector:@selector(userEmailForHockeyManager:componentManager:)]) {
    userEmailViaDelegate = YES;
    self.userEmail = [[BITHockeyManager sharedHockeyManager].delegate
                     userEmailForHockeyManager:[BITHockeyManager sharedHockeyManager]
                     componentManager:self];
    self.requireUserName = BITFeedbackUserDataElementDontShow;
    self.requireUserEmail = BITFeedbackUserDataElementDontShow;
  }
  
  if (![_fileManager fileExistsAtPath:_settingsFile])
    return;

  NSData *codedData = [[[NSData alloc] initWithContentsOfFile:_settingsFile] autorelease];
  if (codedData == nil) return;
  
  NSKeyedUnarchiver *unarchiver = nil;
  
  @try {
    unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:codedData];
  }
  @catch (NSException *exception) {
    return;
  }

  if (!userNameViaDelegate) {
    if ([unarchiver containsValueForKey:kBITFeedbackName])
      self.userName = [unarchiver decodeObjectForKey:kBITFeedbackName];
  }

  if (!userEmailViaDelegate) {
    if ([unarchiver containsValueForKey:kBITFeedbackEmail])
      self.userEmail = [unarchiver decodeObjectForKey:kBITFeedbackEmail];
  }
  
  if ([unarchiver containsValueForKey:kBITFeedbackUserDataAsked])
    _didAskUserData = YES;
  
  if ([unarchiver containsValueForKey:kBITFeedbackToken])
    self.token = [unarchiver decodeObjectForKey:kBITFeedbackToken];
  
  if ([unarchiver containsValueForKey:kBITFeedbackDateOfLastCheck])
    self.lastCheck = [unarchiver decodeObjectForKey:kBITFeedbackDateOfLastCheck];
  
  if ([unarchiver containsValueForKey:kBITFeedbackMessages]) {
    [self.feedbackList setArray:[unarchiver decodeObjectForKey:kBITFeedbackMessages]];
    
    [self sortFeedbackList];
    
    // inform the UI to update its data in case the list is already showing
    [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
  }

  [unarchiver finishDecoding];
  [unarchiver release];

  if (!self.lastCheck) {
    self.lastCheck = [NSDate distantPast];
  }
}


- (void)saveMessages {
  [self sortFeedbackList];
  
  NSMutableData *data = [[NSMutableData alloc] init];
  NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];

  if (_didAskUserData)
    [archiver encodeObject:[NSNumber numberWithBool:YES] forKey:kBITFeedbackUserDataAsked];
  
  if (self.token)
    [archiver encodeObject:self.token forKey:kBITFeedbackToken];
  
  if (self.userName)
    [archiver encodeObject:self.userName forKey:kBITFeedbackName];
  
  if (self.userEmail)
    [archiver encodeObject:self.userEmail forKey:kBITFeedbackEmail];
  
  if (self.lastCheck)
    [archiver encodeObject:self.lastCheck forKey:kBITFeedbackDateOfLastCheck];
  
  [archiver encodeObject:self.feedbackList forKey:kBITFeedbackMessages];
  
  [archiver finishEncoding];
  [data writeToFile:_settingsFile atomically:YES];
  [archiver release];
  [data release];
}


- (void)updateDidAskUserData {
  if (!_didAskUserData) {
    _didAskUserData = YES;
    
    [self saveMessages];
  }
}

#pragma mark - Messages

- (void)sortFeedbackList {
  [_feedbackList sortUsingComparator:^(BITFeedbackMessage *obj1, BITFeedbackMessage *obj2) {
    NSDate *date1 = [obj1 date];
    NSDate *date2 = [obj2 date];
    
    // not send, in conflict and send in progress messages on top, sorted by date
    // read and unread on bottom, sorted by date
    // archived on the very bottom
    
    if ([obj1 status] >= BITFeedbackMessageStatusSendInProgress && [obj2 status] < BITFeedbackMessageStatusSendInProgress) {
      return NSOrderedAscending;
    } else if ([obj1 status] < BITFeedbackMessageStatusSendInProgress && [obj2 status] >= BITFeedbackMessageStatusSendInProgress) {
      return NSOrderedDescending;
    } else if ([obj1 status] == BITFeedbackMessageStatusArchived && [obj2 status] < BITFeedbackMessageStatusArchived) {
      return NSOrderedDescending;
    } else if ([obj1 status] < BITFeedbackMessageStatusArchived && [obj2 status] == BITFeedbackMessageStatusArchived) {
      return NSOrderedAscending;
    } else {
      return (NSInteger)[date2 compare:date1];
    }
  }];
}

- (NSUInteger)numberOfMessages {
  return [_feedbackList count];
}

- (BITFeedbackMessage *)messageAtIndex:(NSUInteger)index {
  if ([_feedbackList count] > index) {
    return [_feedbackList objectAtIndex:index];
  }
  
  return nil;
}

- (BITFeedbackMessage *)messageWithID:(NSNumber *)messageID {
  __block BITFeedbackMessage *message = nil;
  
  [_feedbackList enumerateObjectsUsingBlock:^(BITFeedbackMessage *objMessage, NSUInteger messagesIdx, BOOL *stop) {
    if ([[objMessage id] isEqualToNumber:messageID]) {
      message = objMessage;
      *stop = YES;
    }
  }];
  
  return message;
}

- (NSArray *)messagesWithStatus:(BITFeedbackMessageStatus)status {
  NSMutableArray *resultMessages = [[NSMutableArray alloc] initWithCapacity:[_feedbackList count]];
  
  [_feedbackList enumerateObjectsUsingBlock:^(BITFeedbackMessage *objMessage, NSUInteger messagesIdx, BOOL *stop) {
    if ([objMessage status] == status) {
      [resultMessages addObject: objMessage];
    }
  }];
  
  return [NSArray arrayWithArray:resultMessages];;
}

- (BITFeedbackMessage *)lastMessageHavingID {
  __block BITFeedbackMessage *message = nil;
  
  [_feedbackList enumerateObjectsUsingBlock:^(BITFeedbackMessage *objMessage, NSUInteger messagesIdx, BOOL *stop) {
    if ([[objMessage id] integerValue] != 0) {
      message = objMessage;
      *stop = YES;
    }
  }];
  
  return message;
}

- (void)markSendInProgressMessagesAsPending {
  // make sure message that may have not been send successfully, get back into the right state to be send again
  [_feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger messagesIdx, BOOL *stop) {
    if ([(BITFeedbackMessage *)objMessage status] == BITFeedbackMessageStatusSendInProgress)
      [(BITFeedbackMessage *)objMessage setStatus:BITFeedbackMessageStatusSendPending];
  }];
}

- (void)markSendInProgressMessagesAsInConflict {
  // make sure message that may have not been send successfully, get back into the right state to be send again
  [_feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger messagesIdx, BOOL *stop) {
    if ([(BITFeedbackMessage *)objMessage status] == BITFeedbackMessageStatusSendInProgress)
      [(BITFeedbackMessage *)objMessage setStatus:BITFeedbackMessageStatusInConflict];
  }];
}


#pragma mark - User

- (BOOL)askManualUserDataAvailable {
  if (self.requireUserName == BITFeedbackUserDataElementDontShow &&
      self.requireUserEmail == BITFeedbackUserDataElementDontShow)
    return NO;
  
  return YES;
}

- (BOOL)requireManualUserDataMissing {
  if (self.requireUserName == BITFeedbackUserDataElementRequired && !self.userName)
    return YES;
  
  if (self.requireUserEmail == BITFeedbackUserDataElementRequired && !self.userEmail)
    return YES;
  
  return NO;
}

- (BOOL)isManualUserDataAvailable {
  if ((self.requireUserName != BITFeedbackUserDataElementDontShow && self.userName) ||
      (self.requireUserEmail != BITFeedbackUserDataElementDontShow && self.userEmail))
    return YES;
  
  return NO;
}


#pragma mark - Networking

- (void)updateMessageListFromResponse:(NSDictionary *)jsonDictionary {
  if (!jsonDictionary) {
    // nil is used when the server returns 404, so we need to mark all existing threads as archives and delete the discussion token

    NSArray *messagesSendInProgress = [self messagesWithStatus:BITFeedbackMessageStatusSendInProgress];
    NSInteger pendingMessagesCount = [messagesSendInProgress count] + [[self messagesWithStatus:BITFeedbackMessageStatusSendPending] count];

    [self markSendInProgressMessagesAsPending];
    
    [_feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger messagesIdx, BOOL *stop) {
      if ([(BITFeedbackMessage *)objMessage status] != BITFeedbackMessageStatusSendPending)
        [(BITFeedbackMessage *)objMessage setStatus:BITFeedbackMessageStatusArchived];
    }];

    if ([self token]) {
      self.token = nil;
    }
    
    NSInteger pendingMessagesCountAfterProcessing = [[self messagesWithStatus:BITFeedbackMessageStatusSendPending] count];

    [self saveMessages];
    
    // check if this request was successful and we have more messages pending and continue if positive
    if (pendingMessagesCount > pendingMessagesCountAfterProcessing && pendingMessagesCountAfterProcessing > 0) {
      [self performSelector:@selector(submitPendingMessages) withObject:nil afterDelay:0.1];
    }
    
    return;
  }
  
  NSDictionary *feedback = [jsonDictionary objectForKey:@"feedback"];
  NSString *token = [jsonDictionary objectForKey:@"token"];
  NSDictionary *feedbackObject = [jsonDictionary objectForKey:@"feedback"];
  if (feedback && token && feedbackObject) {
    // update the thread token, which is not available until the 1st message was successfully sent
    self.token = token;
    
    self.lastCheck = [NSDate date];
    
    // add all new messages
    NSArray *feedMessages = [feedbackObject objectForKey:@"messages"];
    
    // get the message that was currently sent if available
    NSArray *messagesSendInProgress = [self messagesWithStatus:BITFeedbackMessageStatusSendInProgress];
    
    NSInteger pendingMessagesCount = [messagesSendInProgress count] + [[self messagesWithStatus:BITFeedbackMessageStatusSendPending] count];
    
    __block BOOL newResponseMessage = NO;
    __block NSMutableSet *returnedMessageIDs = [[[NSMutableSet alloc] init] autorelease];
    
    [feedMessages enumerateObjectsUsingBlock:^(id objMessage, NSUInteger messagesIdx, BOOL *stop) {
      NSNumber *messageID = [(NSDictionary *)objMessage objectForKey:@"id"];
      [returnedMessageIDs addObject:messageID];
      
      BITFeedbackMessage *thisMessage = [self messageWithID:messageID];
      if (!thisMessage) {
        // check if this is a message that was sent right now
        __block BITFeedbackMessage *matchingSendInProgressOrInConflictMessage = nil;
        
        // TODO: match messages in state conflict
        
        [messagesSendInProgress enumerateObjectsUsingBlock:^(id objSendInProgressMessage, NSUInteger messagesSendInProgressIdx, BOOL *stop) {
          if ([[(NSDictionary *)objMessage objectForKey:@"token"] isEqualToString:[(BITFeedbackMessage *)objSendInProgressMessage token]]) {
            matchingSendInProgressOrInConflictMessage = objSendInProgressMessage;
            *stop = YES;
          }
        }];
        
        if (matchingSendInProgressOrInConflictMessage) {
          matchingSendInProgressOrInConflictMessage.date = [self parseRFC3339Date:[(NSDictionary *)objMessage objectForKey:@"created_at"]];
          matchingSendInProgressOrInConflictMessage.id = messageID;
          matchingSendInProgressOrInConflictMessage.status = BITFeedbackMessageStatusRead;
        } else {
          BITFeedbackMessage *message = [[[BITFeedbackMessage alloc] init] autorelease];
          message.text = [(NSDictionary *)objMessage objectForKey:@"text"];
          message.name = [(NSDictionary *)objMessage objectForKey:@"name"];
          message.email = [(NSDictionary *)objMessage objectForKey:@"email"];
          
          message.date = [self parseRFC3339Date:[(NSDictionary *)objMessage objectForKey:@"created_at"]];
          message.id = [(NSDictionary *)objMessage objectForKey:@"id"];
          message.status = BITFeedbackMessageStatusUnread;
          
          [_feedbackList addObject:message];
          
          newResponseMessage = YES;
        }
      } else {
        // we should never get any messages back that are already stored locally,
        // since we add the last_message_id to the request
      }
    }];
    
    [self markSendInProgressMessagesAsPending];
    
    // we got a new incoming message, trigger user notification system
    if (newResponseMessage) {
      if (self.showAlertOnIncomingMessages && !self.currentFeedbackListViewController && !self.currentFeedbackComposeViewController) {
        UIAlertView *alertView = [[[UIAlertView alloc] initWithTitle:BITHockeyLocalizedString(@"HockeyFeedbackNewMessageTitle")
                                                             message:BITHockeyLocalizedString(@"HockeyFeedbackNewMessageText")
                                                            delegate:self
                                                   cancelButtonTitle:BITHockeyLocalizedString(@"HockeyFeedbackIgnore")
                                                   otherButtonTitles:BITHockeyLocalizedString(@"HockeyFeedbackShow"), nil
                                   ] autorelease];
        [alertView setTag:0];
        [alertView show];
        _incomingMessagesAlertShowing = YES;
      }
    }
    
    NSInteger pendingMessagesCountAfterProcessing = [[self messagesWithStatus:BITFeedbackMessageStatusSendPending] count];

    // check if this request was successful and we have more messages pending and continue if positive
    if (pendingMessagesCount > pendingMessagesCountAfterProcessing && pendingMessagesCountAfterProcessing > 0) {
      [self performSelector:@selector(submitPendingMessages) withObject:nil afterDelay:0.1];
    }
    
  } else {
    [self markSendInProgressMessagesAsPending];
  }
  
  [self saveMessages];

  return;
}

- (void)sendNetworkRequestWithHTTPMethod:(NSString *)httpMethod withMessage:(BITFeedbackMessage *)message completionHandler:(void (^)(NSError *err))completionHandler {
  NSString *boundary = @"----FOO";
  
  _networkRequestInProgress = YES;
  // inform the UI to update its data in case the list is already showing
  [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingStarted object:nil];

  NSString *tokenParameter = @"";
  if ([self token]) {
    tokenParameter = [NSString stringWithFormat:@"/%@", [self token]];
  }
  NSMutableString *parameter = [NSMutableString stringWithFormat:@"api/2/apps/%@/feedback%@", [self encodedAppIdentifier], tokenParameter];
  
  NSString *lastMessageID = @"";
  BITFeedbackMessage *lastMessageHavingID = [self lastMessageHavingID];
  if (lastMessageHavingID) {
    lastMessageID = [NSString stringWithFormat:@"&last_message_id=%i", [[lastMessageHavingID id] integerValue]];
  }
  
  [parameter appendFormat:@"?format=json&bundle_version=%@&sdk=%@&sdk_version=%@%@",
   bit_URLEncodedString([[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]),
   BITHOCKEY_NAME,
   BITHOCKEY_VERSION,
   lastMessageID
   ];
  
  // build request & send
  NSString *url = [NSString stringWithFormat:@"%@%@", self.serverURL, parameter];
  BITHockeyLog(@"INFO: sending api request to %@", url);
  
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:1 timeoutInterval:10.0];
  [request setHTTPMethod:httpMethod];
  [request setValue:@"Hockey/iOS" forHTTPHeaderField:@"User-Agent"];
  [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
  
  if (message) {
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
    [request setValue:contentType forHTTPHeaderField:@"Content-type"];
    
    NSMutableData *postBody = [NSMutableData data];
    
    [postBody appendData:[self appendPostValue:@"Apple" forKey:@"oem"]];
    [postBody appendData:[self appendPostValue:[[UIDevice currentDevice] systemVersion] forKey:@"os_version"]];
    [postBody appendData:[self appendPostValue:[self getDevicePlatform] forKey:@"model"]];
    [postBody appendData:[self appendPostValue:[[[NSBundle mainBundle] preferredLocalizations] objectAtIndex:0] forKey:@"lang"]];
    [postBody appendData:[self appendPostValue:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] forKey:@"bundle_version"]];
    [postBody appendData:[self appendPostValue:[message text] forKey:@"text"]];
    [postBody appendData:[self appendPostValue:[message token] forKey:@"message_token"]];
    
    if (self.userName) {
      [postBody appendData:[self appendPostValue:self.userName forKey:@"name"]];
    }
    if (self.userEmail) {
      [postBody appendData:[self appendPostValue:self.userEmail forKey:@"email"]];
    }
    
    [postBody appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    [request setHTTPBody:postBody];
  }
  
  [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *responseData, NSError *err) {
    _networkRequestInProgress = NO;
    
    if (err) {
      [self reportError:err];
      [self markSendInProgressMessagesAsPending];
      completionHandler(err);
    } else {
      NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
      if (statusCode == 404) {
        // thread has been deleted, we archive it
        [self updateMessageListFromResponse:nil];
      } else if (statusCode == 409) {
        // we submitted a message that is already on the server, mark it as being in conflict and resolve it with another fetch
        
        if (!self.token) {
          // set the token to the first message token, since this is identical
          __block NSString *token = nil;

          [_feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger messagesIdx, BOOL *stop) {
            if ([(BITFeedbackMessage *)objMessage status] == BITFeedbackMessageStatusSendInProgress) {
              token = [(BITFeedbackMessage *)objMessage token];
              *stop = YES;
            }
          }];

          if (token) {
            self.token = token;
          }
        }
        
        [self markSendInProgressMessagesAsInConflict];
        [self saveMessages];
        [self performSelector:@selector(fetchMessageUpdates) withObject:nil afterDelay:0.2];
      } else if ([responseData length]) {
        NSString *responseString = [[[NSString alloc] initWithBytes:[responseData bytes] length:[responseData length] encoding: NSUTF8StringEncoding] autorelease];
        BITHockeyLog(@"INFO: Received API response: %@", responseString);
        
        NSError *error = NULL;
        
        NSDictionary *feedDict = (NSDictionary *)bit_parseJSON(responseString, &error);
        
        // server returned empty response?
        if (error) {
          [self reportError:error];
        } else if (![feedDict count]) {
          [self reportError:[NSError errorWithDomain:kBITFeedbackErrorDomain
                                                code:BITFeedbackAPIServerReturnedEmptyResponse
                                            userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Server returned empty response.", NSLocalizedDescriptionKey, nil]]];
        } else {
          BITHockeyLog(@"INFO: Received API response: %@", responseString);
          NSString *status = [feedDict objectForKey:@"status"];
          if ([status compare:@"success"] != NSOrderedSame) {
            [self reportError:[NSError errorWithDomain:kBITFeedbackErrorDomain
                                                  code:BITFeedbackAPIServerReturnedInvalidStatus
                                              userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Server returned invalid status.", NSLocalizedDescriptionKey, nil]]];
          } else {
            [self updateMessageListFromResponse:feedDict];
          }
        }
      }
      
      [self markSendInProgressMessagesAsPending];
      completionHandler(err);
    }
  }];
}

- (void)fetchMessageUpdates {
  if ([_feedbackList count] == 0) {
    // inform the UI to update its data in case the list is already showing
    [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
    
    return;
  }
  
  [self sendNetworkRequestWithHTTPMethod:@"GET"
                             withMessage:nil
                       completionHandler:^(NSError *err){
                         // inform the UI to update its data in case the list is already showing
                         [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
                       }];
}

- (void)submitPendingMessages {
  if (_networkRequestInProgress) {
    [self performSelector:@selector(submitPendingMessages) withObject:nil afterDelay:2.0f];
    return;
  }
  
  // app defined user data may have changed, update it
  [self updateAppDefinedUserData];
  
  NSArray *pendingMessages = [self messagesWithStatus:BITFeedbackMessageStatusSendPending];

  if ([pendingMessages count] > 0) {
    // we send one message at a time
    BITFeedbackMessage *messageToSend = [pendingMessages objectAtIndex:0];
    
    [messageToSend setStatus:BITFeedbackMessageStatusSendInProgress];
    if (self.userName)
      [messageToSend setName:self.userName];
    if (self.userEmail)
      [messageToSend setEmail:self.userEmail];
    
    NSString *httpMethod = @"POST";
    if ([self token]) {
      httpMethod = @"PUT";
    }
    
    [self sendNetworkRequestWithHTTPMethod:httpMethod
                               withMessage:messageToSend
                         completionHandler:^(NSError *err){
                           if (err) {
                             [self markSendInProgressMessagesAsPending];
                             
                             [self saveMessages];
                           }
                           
                           // inform the UI to update its data in case the list is already showing
                           [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
                         }];
  }
}

- (void)submitMessageWithText:(NSString *)text {
  BITFeedbackMessage *message = [[[BITFeedbackMessage alloc] init] autorelease];
  message.text = text;
  [message setStatus:BITFeedbackMessageStatusSendPending];
  [message setToken:[self uuidAsLowerCaseAndShortened]];  
  [message setUserMessage:YES];
  
  [_feedbackList addObject:message];
  
  [self submitPendingMessages];
}


#pragma mark - UIAlertViewDelegate

// invoke the selected action from the actionsheet for a location element
- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
  
  _incomingMessagesAlertShowing = NO;
  if (buttonIndex == [alertView firstOtherButtonIndex]) {
    // Show button has been clicked
    [self showFeedbackListView];
  }
}

@end
