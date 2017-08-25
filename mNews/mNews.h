/****************************************************************************
 *                                                                           *
 *  Copyright (C) 2014-2015 iBuildApp, Inc. ( http://ibuildapp.com )         *
 *                                                                           *
 *  This file is part of iBuildApp.                                          *
 *                                                                           *
 *  This Source Code Form is subject to the terms of the iBuildApp License.  *
 *  You can obtain one at http://ibuildapp.com/license/                      *
 *                                                                           *
 ****************************************************************************/

#import <UIKit/UIKit.h>
#import "mWebVC.h"
#import "urlloader.h"
#import "EGORefreshTableHeaderView.h"

@class Reachability;

// Main module class for widget RSS / News. Module entry point.
@interface mNewsViewController : UITableViewController<NSXMLParserDelegate,
                                                      UIScrollViewDelegate,
                                                      EGORefreshTableHeaderDelegate,
                                                      IURLLoaderDelegate>

// Widget type
@property (nonatomic, copy) NSString *widgetType;

// Use 24-hour time format
@property (nonatomic, assign) BOOL normalFormatDate;

// Add link to ibuildapp.com to sharing messages
@property (nonatomic, assign) BOOL showLink;

// Allow sharing via Email
@property (nonatomic, assign) BOOL shareEMail;

// Allow sharing via SMS
@property (nonatomic, assign) BOOL shareSMS;

// Allow adding notifications
@property (nonatomic, assign) BOOL addNotifications;

// Allow adding events
@property (nonatomic, assign) BOOL addEvents;

// Set widget parameters
// @param params dictionary with parameters
- (void)setParams:(NSMutableDictionary *)params;

// Get widget title for statistics
// @return widget title
- (NSString*)getWidgetTitle;

@end


