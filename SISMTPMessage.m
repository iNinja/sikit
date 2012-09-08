//
//  SISMTPMessage.m
//  SIKit
//
//  Created by Matias Pequeno on 10/5/10.
//  Copyright 2010 Silicon Illusions, Inc. All rights reserved.
//

#import "SISMTPMessage.h"
#import "NSData+Base64.h"
#import "SIFoundationExtension.h"
#import "SIUtil.h"

NSString *kSISMTPPartContentDispositionKey = @"kSISMTPPartContentDispositionKey";
NSString *kSISMTPPartContentTypeKey = @"kSISMTPPartContentTypeKey";
NSString *kSISMTPPartMessageKey = @"kSISMTPPartMessageKey";
NSString *kSISMTPPartContentTransferEncodingKey = @"kSISMTPPartContentTransferEncodingKey";

#define SHORT_LIVENESS_TIMEOUT 20.0
#define LONG_LIVENESS_TIMEOUT 60.0

@interface SISMTPMessage ()

@property(nonatomic, retain) NSMutableString *inputString;
@property(nonatomic, retain) NSTimer *connectTimer;
@property(nonatomic, retain) NSTimer *watchdogTimer;

- (void)parseBuffer;
- (BOOL)sendParts;
- (void)cleanUpStreams;
- (void)startShortWatchdog;
- (void)stopWatchdog;
- (NSString *)formatAnAddress:(NSString *)address;
- (NSString *)formatAddresses:(NSString *)addresses;

@end

@implementation SISMTPMessage

@synthesize login, pass, relayHost, relayPorts, subject, fromEmail, toEmail, \
			parts, requiresAuth, inputString, wantsSecure, delegate, \
			connectTimer, connectTimeout, watchdogTimer, validateSSLChain;
@synthesize ccEmail;
@synthesize bccEmail;

- (id)init
{
    static NSArray *defaultPorts = nil;
    
    if (!defaultPorts)
    {
        defaultPorts = [[NSArray alloc] initWithObjects:[NSNumber numberWithShort:25], [NSNumber numberWithShort:465], [NSNumber numberWithShort:587], nil];
    }
    
    if (self = [super init])
    {
        // Setup the default ports
        self.relayPorts = defaultPorts;
        
        // setup a default timeout (8 seconds)
        connectTimeout = 8.0; 
        
        // by default, validate the SSL chain
        validateSSLChain = YES;
    }
    
    return self;
}

- (void)dealloc
{
    self.login = nil;
    self.pass = nil;
    self.relayHost = nil;
    self.relayPorts = nil;
    self.subject = nil;
    self.fromEmail = nil;
    self.toEmail = nil;
	self.ccEmail = nil;
	self.bccEmail = nil;
    self.parts = nil;
    self.inputString = nil;
    
    [inputStream release];
    inputStream = nil;
    
    [outputStream release];
    outputStream = nil;
    
    [self.connectTimer invalidate];
    self.connectTimer = nil;
    
    [self stopWatchdog];
    
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    SISMTPMessage *smtpMessageCopy = [[[self class] allocWithZone:zone] init];
    smtpMessageCopy.delegate = self.delegate;
    smtpMessageCopy.fromEmail = self.fromEmail;
    smtpMessageCopy.login = self.login;
    smtpMessageCopy.parts = [[self.parts copy] autorelease];
    smtpMessageCopy.pass = self.pass;
    smtpMessageCopy.relayHost = self.relayHost;
    smtpMessageCopy.requiresAuth = self.requiresAuth;
    smtpMessageCopy.subject = self.subject;
    smtpMessageCopy.toEmail = self.toEmail;
    smtpMessageCopy.wantsSecure = self.wantsSecure;
    smtpMessageCopy.validateSSLChain = self.validateSSLChain;
    smtpMessageCopy.ccEmail = self.ccEmail;
    smtpMessageCopy.bccEmail = self.bccEmail;
    
    return smtpMessageCopy;
}

- (void)startShortWatchdog
{
    NSLog(@"*** starting short watchdog ***");
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:SHORT_LIVENESS_TIMEOUT target:self selector:@selector(connectionWatchdog:) userInfo:nil repeats:NO];
}

- (void)startLongWatchdog
{
    NSLog(@"*** starting long watchdog ***");
    self.watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:LONG_LIVENESS_TIMEOUT target:self selector:@selector(connectionWatchdog:) userInfo:nil repeats:NO];
}

- (void)stopWatchdog
{
    NSLog(@"*** stopping watchdog ***");
    [self.watchdogTimer invalidate];
    self.watchdogTimer = nil;
}

- (BOOL)send
{
    NSAssert(sendState == kSISMTPIdle, @"Message has already been sent!");
    
    if (requiresAuth)
    {
        NSAssert(login, @"auth requires login");
        NSAssert(pass, @"auth requires pass");
    }
    
    NSAssert(relayHost, @"send requires relayHost");
    NSAssert(subject, @"send requires subject");
    NSAssert(fromEmail, @"send requires fromEmail");
    NSAssert(toEmail, @"send requires toEmail");
    NSAssert(parts, @"send requires parts");
    
    if (![relayPorts count])
    {
        [delegate messageFailed:self 
                          error:[NSError errorWithDomain:@"SISMTPMessageError" 
                                                    code:kSISMTPErrorConnectionFailed 
                                                userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Unable to connect to the server.", @"server connection fail error description"),NSLocalizedDescriptionKey,
                                                          NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]]];
        
        return NO;
    }
    
    // Grab the next relay port
    short relayPort = [[relayPorts objectAtIndex:0] shortValue];
    
    // Pop this off the head of the queue.
    self.relayPorts = ([relayPorts count] > 1) ? [relayPorts subarrayWithRange:NSMakeRange(1, [relayPorts count] - 1)] : [NSArray array];
    
    NSLog(@"C: Attempting to connect to server at: %@:%d", relayHost, relayPort);
    
    self.connectTimer = [NSTimer scheduledTimerWithTimeInterval:connectTimeout
                                                         target:self
                                                       selector:@selector(connectionConnectedCheck:)
                                                       userInfo:nil 
                                                        repeats:NO];
    
    [NSStream getStreamsToHostNamed:relayHost port:relayPort inputStream:&inputStream outputStream:&outputStream];
    if ((inputStream != nil) && (outputStream != nil))
    {
        sendState = kSISMTPConnecting;
        isSecure = NO;
        
        [inputStream retain];
        [outputStream retain];
        
        [inputStream setDelegate:self];
        [outputStream setDelegate:self];
        
        [inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop]
                               forMode:NSRunLoopCommonModes];
        [outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop]
                                forMode:NSRunLoopCommonModes];
        [inputStream open];
        [outputStream open];
        
        self.inputString = [NSMutableString string];
        
        
        
        return YES;
    }
    else
    {
        [self.connectTimer invalidate];
        self.connectTimer = nil;
        
        [delegate messageFailed:self 
                          error:[NSError errorWithDomain:@"SISMTPMessageError" 
                                                    code:kSISMTPErrorConnectionFailed 
                                                userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Unable to connect to the server.", @"server connection fail error description"),NSLocalizedDescriptionKey,
                                                          NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]]];
        
        return NO;
    }
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode 
{
    switch(eventCode) 
    {
        case NSStreamEventHasBytesAvailable:
        {
            uint8_t buf[1024];
            memset(buf, 0, sizeof(uint8_t) * 1024);
            unsigned int len = 0;
            len = [(NSInputStream *)stream read:buf maxLength:1024];
            if(len) 
            {
                NSString *tmpStr = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
                [inputString appendString:tmpStr];
                [tmpStr release];
                
                [self parseBuffer];
            }
            break;
        }
        case NSStreamEventEndEncountered:
        {
            [self stopWatchdog];
            [stream close];
            [stream removeFromRunLoop:[NSRunLoop currentRunLoop]
                              forMode:NSDefaultRunLoopMode];
            [stream release];
            stream = nil; // stream is ivar, so reinit it
            
            if (sendState != kSISMTPMessageSent)
            {
                [delegate messageFailed:self 
                                  error:[NSError errorWithDomain:@"SISMTPMessageError" 
                                                            code:kSISMTPErrorConnectionInterrupted 
                                                        userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"The connection to the server was interrupted.", @"server connection interrupted error description"),NSLocalizedDescriptionKey,
                                                                  NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]]];
				
            }
            
            break;
        }
        default:
            break;
    }
}


- (NSString *)formatAnAddress:(NSString *)address {
	NSString		*formattedAddress;
	NSCharacterSet	*whitespaceCharSet = [NSCharacterSet whitespaceCharacterSet];
	
	if (([address rangeOfString:@"<"].location == NSNotFound) && ([address rangeOfString:@">"].location == NSNotFound)) {
		formattedAddress = [NSString stringWithFormat:@"RCPT TO:<%@>\r\n", [address stringByTrimmingCharactersInSet:whitespaceCharSet]];									
	}
	else {
		formattedAddress = [NSString stringWithFormat:@"RCPT TO:%@\r\n", [address stringByTrimmingCharactersInSet:whitespaceCharSet]];																		
	}
	
	return(formattedAddress);
}

- (NSString *)formatAddresses:(NSString *)addresses {
	NSCharacterSet	*splitSet = [NSCharacterSet characterSetWithCharactersInString:@";,"];
	NSMutableString	*multipleRcptTo = [NSMutableString string];
	
	if ((addresses != nil) && (![addresses isEqualToString:@""])) {
		if( [addresses rangeOfString:@";"].location != NSNotFound || [addresses rangeOfString:@","].location != NSNotFound ) {
			NSArray *addressParts = [addresses componentsSeparatedByCharactersInSet:splitSet];
			
			for( NSString *address in addressParts ) {
				[multipleRcptTo appendString:[self formatAnAddress:address]];
			}
		}
		else {
			[multipleRcptTo appendString:[self formatAnAddress:addresses]];
		}		
	}
	
	return(multipleRcptTo);
}


- (void)parseBuffer
{
    // Pull out the next line
    NSScanner *scanner = [NSScanner scannerWithString:inputString];
    NSString *tmpLine = nil;
    
    NSError *error = nil;
    BOOL encounteredError = NO;
    BOOL messageSent = NO;
    
    while (![scanner isAtEnd])
    {
        BOOL foundLine = [scanner scanUpToCharactersFromSet:[NSCharacterSet newlineCharacterSet]
                                                 intoString:&tmpLine];
        if (foundLine)
        {
            [self stopWatchdog];
            
            NSLog(@"S: %@", tmpLine);
            switch (sendState)
            {
                case kSISMTPConnecting:
                {
                    if ([tmpLine hasPrefix:@"220 "])
                    {
                        
                        sendState = kSISMTPWaitingEHLOReply;
                        
                        NSString *ehlo = [NSString stringWithFormat:@"EHLO %@\r\n", @"localhost"];
                        NSLog(@"C: %@", ehlo);
                        if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[ehlo UTF8String], [ehlo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
                case kSISMTPWaitingEHLOReply:
                {
                    // Test auth login options
                    if ([tmpLine hasPrefix:@"250-AUTH"])
                    {
                        NSRange testRange;
                        testRange = [tmpLine rangeOfString:@"CRAM-MD5"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthCRAMMD5 = YES;
                        }
                        
                        testRange = [tmpLine rangeOfString:@"PLAIN"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthPLAIN = YES;
                        }
                        
                        testRange = [tmpLine rangeOfString:@"LOGIN"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthLOGIN = YES;
                        }
                        
                        testRange = [tmpLine rangeOfString:@"DIGEST-MD5"];
                        if (testRange.location != NSNotFound)
                        {
                            serverAuthDIGESTMD5 = YES;
                        }
                    }
                    else if ([tmpLine hasPrefix:@"250-8BITMIME"])
                    {
                        server8bitMessages = YES;
                    }
                    else if ([tmpLine hasPrefix:@"250-STARTTLS"] && !isSecure && wantsSecure)
                    {
                        // if we're not already using TLS, start it up
                        sendState = kSISMTPWaitingTLSReply;
                        
                        NSString *startTLS = @"STARTTLS\r\n";
                        NSLog(@"C: %@", startTLS);
                        if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[startTLS UTF8String], [startTLS lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"250 "])
                    {
                        if (self.requiresAuth)
                        {
                            // Start up auth
                            if (serverAuthPLAIN)
                            {
                                sendState = kSISMTPWaitingAuthSuccess;
                                NSString *loginString = [NSString stringWithFormat:@"\000%@\000%@", login, pass];
                                NSString *authString = [NSString stringWithFormat:@"AUTH PLAIN %@\r\n", [[loginString dataUsingEncoding:NSUTF8StringEncoding] base64EncodedString]];
                                NSLog(@"C: %@", authString);
                                if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                                {
                                    error =  [outputStream streamError];
                                    encounteredError = YES;
                                }
                                else
                                {
                                    [self startShortWatchdog];
                                }
                            }
                            else if (serverAuthLOGIN)
                            {
                                sendState = kSISMTPWaitingLOGINUsernameReply;
                                NSString *authString = @"AUTH LOGIN\r\n";
                                NSLog(@"C: %@", authString);
                                if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                                {
                                    error =  [outputStream streamError];
                                    encounteredError = YES;
                                }
                                else
                                {
                                    [self startShortWatchdog];
                                }
                            }
                            else
                            {
                                error = [NSError errorWithDomain:@"SISMTPMessageError" 
                                                            code:kSISMTPErrorUnsupportedLogin
                                                        userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Unsupported login mechanism.", @"server unsupported login fail error description"),NSLocalizedDescriptionKey,
                                                                  NSLocalizedString(@"Your server's security setup is not supported, please contact your system administrator or use a supported email account like MobileMe.", @"server security fail error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
								
                                encounteredError = YES;
                            }
							
                        }
                        else
                        {
                            // Start up send from
                            sendState = kSISMTPWaitingFromReply;
                            
                            NSString *mailFrom = [NSString stringWithFormat:@"MAIL FROM:<%@>\r\n", fromEmail];
                            NSLog(@"C: %@", mailFrom);
                            if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[mailFrom UTF8String], [mailFrom lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                            {
                                error =  [outputStream streamError];
                                encounteredError = YES;
                            }
                            else
                            {
                                [self startShortWatchdog];
                            }
                        }
                    }
                    break;
                }
                    
                case kSISMTPWaitingTLSReply:
                {
                    if ([tmpLine hasPrefix:@"220 "])
                    {
                        
                        // Attempt to use TLSv1
                        CFMutableDictionaryRef sslOptions = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                        
                        CFDictionarySetValue(sslOptions, kCFStreamSSLLevel, kCFStreamSocketSecurityLevelTLSv1);
                        
                        if (!self.validateSSLChain)
                        {
                            // Don't validate SSL certs. This is terrible, please complain loudly to your BOFH.
                            NSLog(@"WARNING: Will not validate SSL chain!!!");
                            
                            CFDictionarySetValue(sslOptions, kCFStreamSSLValidatesCertificateChain, kCFBooleanFalse);
                            CFDictionarySetValue(sslOptions, kCFStreamSSLAllowsExpiredCertificates, kCFBooleanTrue);
                            CFDictionarySetValue(sslOptions, kCFStreamSSLAllowsExpiredRoots, kCFBooleanTrue);
                            CFDictionarySetValue(sslOptions, kCFStreamSSLAllowsAnyRoot, kCFBooleanTrue);
                        }
                        
                        NSLog(@"Beginning TLSv1...");
                        
                        CFReadStreamSetProperty((CFReadStreamRef)inputStream, kCFStreamPropertySSLSettings, sslOptions);
                        CFWriteStreamSetProperty((CFWriteStreamRef)outputStream, kCFStreamPropertySSLSettings, sslOptions);
                        
                        CFRelease(sslOptions);
                        
                        // restart the connection
                        sendState = kSISMTPWaitingEHLOReply;
                        isSecure = YES;
                        
                        NSString *ehlo = [NSString stringWithFormat:@"EHLO %@\r\n", @"localhost"];
                        NSLog(@"C: %@", ehlo);
                        
                        if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[ehlo UTF8String], [ehlo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                        
                        /*
						 else
						 {
						 error = [NSError errorWithDomain:@"SISMTPMessageError" 
						 code:kSISMTPErrorTLSFail
						 userInfo:[NSDictionary dictionaryWithObject:@"Unable to start TLS" 
						 forKey:NSLocalizedDescriptionKey]];
						 encounteredError = YES;
						 }
						 */
                    }
                }
					
                case kSISMTPWaitingLOGINUsernameReply:
                {
                    if ([tmpLine hasPrefix:@"334 VXNlcm5hbWU6"])
                    {
                        sendState = kSISMTPWaitingLOGINPasswordReply;
                        
                        NSString *authString = [NSString stringWithFormat:@"%@\r\n", [[login dataUsingEncoding:NSUTF8StringEncoding] base64EncodedString]];
                        NSLog(@"C: %@", authString);
                        if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
                    
                case kSISMTPWaitingLOGINPasswordReply:
                {
                    if ([tmpLine hasPrefix:@"334 UGFzc3dvcmQ6"])
                    {
                        sendState = kSISMTPWaitingAuthSuccess;
                        
                        NSString *authString = [NSString stringWithFormat:@"%@\r\n", [[pass dataUsingEncoding:NSUTF8StringEncoding] base64EncodedString]];
                        NSLog(@"C: %@", authString);
                        if( SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[authString UTF8String], [authString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0 )
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
					
                case kSISMTPWaitingAuthSuccess:
                {
                    if ([tmpLine hasPrefix:@"235 "])
                    {
                        sendState = kSISMTPWaitingFromReply;
                        
                        NSString *mailFrom = server8bitMessages ? [NSString stringWithFormat:@"MAIL FROM:<%@> BODY=8BITMIME\r\n", fromEmail] : [NSString stringWithFormat:@"MAIL FROM:<%@>\r\n", fromEmail];
                        NSLog(@"C: %@", mailFrom);
                        if (SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[mailFrom cStringUsingEncoding:NSASCIIStringEncoding], [mailFrom lengthOfBytesUsingEncoding:NSASCIIStringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"535 "])
                    {
                        error =[NSError errorWithDomain:@"SISMTPMessageError" 
                                                   code:kSISMTPErrorInvalidUserPass 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Invalid username or password.", @"server login fail error description"),NSLocalizedDescriptionKey,
                                                         NSLocalizedString(@"Go to Email Preferences in the application and re-enter your username and password.", @"server login error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                    break;
                }
					
                case kSISMTPWaitingFromReply:
                {
					// toc 2009-02-18 begin changes per mdesaro issue 18 - http://code.google.com/p/skpsmtpmessage/issues/detail?id=18
					// toc 2009-02-18 begin changes to support cc & bcc
					
                    if ([tmpLine hasPrefix:@"250 "]) {
                        sendState = kSISMTPWaitingToReply;
                        
						NSMutableString	*multipleRcptTo = [NSMutableString string];
						[multipleRcptTo appendString:[self formatAddresses:toEmail]];
						[multipleRcptTo appendString:[self formatAddresses:ccEmail]];
						[multipleRcptTo appendString:[self formatAddresses:bccEmail]];
						
                        NSLog(@"C: %@", multipleRcptTo);
                        if (SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[multipleRcptTo UTF8String], [multipleRcptTo lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    break;
                }
                case kSISMTPWaitingToReply:
                {
                    if ([tmpLine hasPrefix:@"250 "])
                    {
                        sendState = kSISMTPWaitingForEnterMail;
                        
                        NSString *dataString = @"DATA\r\n";
                        NSLog(@"C: %@", dataString);
                        if (SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[dataString UTF8String], [dataString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"530 "])
                    {
                        error =[NSError errorWithDomain:@"SISMTPMessageError" 
                                                   code:kSISMTPErrorNoRelay 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Relay rejected.", @"server relay fail error description"),NSLocalizedDescriptionKey,
														 NSLocalizedString(@"Your server probably requires a username and password.", @"server relay fail error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                    else if ([tmpLine hasPrefix:@"550 "])
                    {
                        error =[NSError errorWithDomain:@"SISMTPMessageError" 
                                                   code:kSISMTPErrorInvalidMessage 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"To address rejected.", @"server to address fail error description"),NSLocalizedDescriptionKey,
                                                         NSLocalizedString(@"Please re-enter the To: address.", @"server to address fail error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                    break;
                }
                case kSISMTPWaitingForEnterMail:
                {
                    if ([tmpLine hasPrefix:@"354 "])
                    {
                        sendState = kSISMTPWaitingSendSuccess;
                        
                        if (![self sendParts])
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                    }
                    break;
                }
                case kSISMTPWaitingSendSuccess:
                {
                    if ([tmpLine hasPrefix:@"250 "])
                    {
                        sendState = kSISMTPWaitingQuitReply;
                        
                        NSString *quitString = @"QUIT\r\n";
                        NSLog(@"C: %@", quitString);
                        if (SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[quitString UTF8String], [quitString lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
                        {
                            error =  [outputStream streamError];
                            encounteredError = YES;
                        }
                        else
                        {
                            [self startShortWatchdog];
                        }
                    }
                    else if ([tmpLine hasPrefix:@"550 "])
                    {
                        error =[NSError errorWithDomain:@"SISMTPMessageError" 
                                                   code:kSISMTPErrorInvalidMessage 
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Failed to logout.", @"server logout fail error description"),NSLocalizedDescriptionKey,
                                                         NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
                        encounteredError = YES;
                    }
                }
                case kSISMTPWaitingQuitReply:
                {
                    if ([tmpLine hasPrefix:@"221 "])
                    {
                        sendState = kSISMTPMessageSent;
                        
                        messageSent = YES;
                    }
                }
            }
            
        }
        else
        {
            break;
        }
    }
    self.inputString = [[[inputString substringFromIndex:[scanner scanLocation]] mutableCopy] autorelease];
    
    if (messageSent)
    {
        [self cleanUpStreams];
        
        [delegate messageSent:self];
    }
    else if (encounteredError)
    {
        [self cleanUpStreams];
        
        [delegate messageFailed:self error:error];
    }
}

- (BOOL)sendParts
{
    NSMutableString *message = [[NSMutableString alloc] init];
    static NSString *separatorString = @"--SISMTPMessage--Separator--Delimiter\r\n";
    
	CFUUIDRef	uuidRef   = CFUUIDCreate(kCFAllocatorDefault);
	NSString	*uuid     = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
	CFRelease(uuidRef);
    
    NSDate *now = [[NSDate alloc] init];
	NSDateFormatter	*dateFormatter = [[NSDateFormatter alloc] init];
	
	[dateFormatter setDateFormat:@"EEE, dd MMM yyyy HH:mm:ss Z"];
	
	[message appendFormat:@"Date: %@\r\n", [dateFormatter stringFromDate:now]];
	[message appendFormat:@"Message-id: <%@@%@>\r\n", [(NSString *)uuid stringByReplacingOccurrencesOfString:@"-" withString:@""], self.relayHost];
	
    [now release];
    [dateFormatter release];
    [uuid release];
    
    [message appendFormat:@"From:%@\r\n", fromEmail];
	
    
	if ((self.toEmail != nil) && (![self.toEmail isEqualToString:@""])) 
    {
		[message appendFormat:@"To:%@\r\n", self.toEmail];		
	}
	
	if ((self.ccEmail != nil) && (![self.ccEmail isEqualToString:@""])) 
    {
		[message appendFormat:@"Cc:%@\r\n", self.ccEmail];		
	}
    
    [message appendString:@"Content-Type: multipart/mixed; boundary=SISMTPMessage--Separator--Delimiter\r\n"];
    [message appendString:@"Mime-Version: 1.0 (SISMTPMessage 1.0)\r\n"];
    [message appendFormat:@"Subject:%@\r\n\r\n",subject];
    [message appendString:separatorString];
    
    NSData *messageData = [message dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
    [message release];
    
    //NSLog(@"C: %s", [messageData bytes], [messageData length]);
    if (SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[messageData bytes], [messageData length]) < 0)
    {
        return NO;
    }
    
    message = [[NSMutableString alloc] init];
    
    for (NSDictionary *part in parts)
    {
        if ([part objectForKey:kSISMTPPartContentDispositionKey])
        {
            [message appendFormat:@"Content-Disposition: %@\r\n", [part objectForKey:kSISMTPPartContentDispositionKey]];
        }
        [message appendFormat:@"Content-Type: %@\r\n", [part objectForKey:kSISMTPPartContentTypeKey]];
        [message appendFormat:@"Content-Transfer-Encoding: %@\r\n\r\n", [part objectForKey:kSISMTPPartContentTransferEncodingKey]];
        [message appendString:[part objectForKey:kSISMTPPartMessageKey]];
        [message appendString:@"\r\n"];
        [message appendString:separatorString];
    }
    
    [message appendString:@"\r\n.\r\n"];
    
    NSLog(@"C: %@", message);
    if (SIWriteStreamWriteFully((CFWriteStreamRef)outputStream, (const uint8_t *)[message UTF8String], [message lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) < 0)
    {
        [message release];
        return NO;
    }
    [self startLongWatchdog];
    [message release];
    return YES;
}

- (void)connectionConnectedCheck:(NSTimer *)aTimer
{
    if (sendState == kSISMTPConnecting)
    {
        [inputStream close];
        [inputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                               forMode:NSDefaultRunLoopMode];
        [inputStream release];
        inputStream = nil;
        
        [outputStream close];
        [outputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                                forMode:NSDefaultRunLoopMode];
        [outputStream release];
        outputStream = nil;
        
        // Try the next port - if we don't have another one to try, this will fail
        sendState = kSISMTPIdle;
        [self send];
    }
    
    self.connectTimer = nil;
}

- (void)connectionWatchdog:(NSTimer *)aTimer
{
    [self cleanUpStreams];
    
    // No hard error if we're wating on a reply
    if (sendState != kSISMTPWaitingQuitReply)
    {
        NSError *error = [NSError errorWithDomain:@"SISMTPMessageError" 
                                             code:kSKPSMPTErrorConnectionTimeout 
                                         userInfo:[NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Timeout sending message.", @"server timeout fail error description"),NSLocalizedDescriptionKey,
                                                   NSLocalizedString(@"Try sending your message again later.", @"server generic error recovery"),NSLocalizedRecoverySuggestionErrorKey,nil]];
        [delegate messageFailed:self error:error];
    }
    else
    {
        [delegate messageSent:self];
    }
}

- (void)cleanUpStreams
{
    [inputStream close];
    [inputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                           forMode:NSDefaultRunLoopMode];
    [inputStream release];
    inputStream = nil;
    
    [outputStream close];
    [outputStream removeFromRunLoop:[NSRunLoop currentRunLoop]
                            forMode:NSDefaultRunLoopMode];
    [outputStream release];
    outputStream = nil;
}

@end