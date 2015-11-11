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

#import "mNews.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <SDWebImage/UIImageView+WebCache.h>

#import "functionLibrary.h"
#import "Reachability.h"
#import "functionLibrary.h"
#import "downloadindicator.h"
#import "downloadmanager.h"
#import "NSURL+RootDomain.h"
#import "appconfig.h"
#import "TBXML.h"
#import "NSString+colorizer.h"
#import "NSString+html.h"
#import "NSString+truncation.h"
#import "UIColor+HSL.h"
#import "NSString+size.h"
#import "GTMNSString+HTML.h"

#define kImageViewTag 555
#define kPlaceholderImage @"photo_placeholder_small"
#define kImagesWidthsAdjustingFrame @"<html>\n\
<head>\n\
<script type=\"text/javascript\">\n\
function adjustImagesWidths(){\n\
    var maxWidth = %f;\n\
    var images=document.images;\n\
    for (var i = 0; i < images.length; i++) {\n\
        var image = images[i];\n\
        var width = image.width;\n\
        if(width > maxWidth){\n\
            image.width = maxWidth;\n\
            image.height *= maxWidth/width;\n\
        }\n\
    };\n\
}\n\
</script>\n\
</head>\n\
<body onload=\"adjustImagesWidths();\">\n\
%@\n\
</body>\n\
</html>"

#define GCDBackgroundThread dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)

@interface mNewsViewController()
{
  NSAutoreleasePool *pool;
}

/**
 *  RSS URL string
 */
@property(nonatomic,strong) NSString       *RSSPath;

/**
 *  Background imageView
 */
@property(nonatomic,retain) UIImageView    *backImgView;

/**
 *  Text color
 */
@property (nonatomic, strong) UIColor       *txtColor;

/**
 *  Title color
 */
@property (nonatomic, strong) UIColor       *titleColor;

/**
 *  Background color
 */
@property (nonatomic, strong) UIColor       *backgroundColor;

/**
 *  Date label color
 */
@property (nonatomic, strong) UIColor       *dateColor;

/**
 *  Array with parsed rss data
 */
@property(nonatomic,strong) NSMutableArray *arr;


/**
 *  EGORefreshTableHeaderView
 */
@property (nonatomic, strong) EGORefreshTableHeaderView *refreshHeaderView;

/**
 *  Reloading status
 */
@property (nonatomic, assign) BOOL                       reloading;

/**
 *  First loading indicator
 */
@property (nonatomic, assign) BOOL                       bFirstLoading;

/**
 *  Download indicator
 */
@property (nonatomic, strong) TDownloadIndicator        *downloadIndicator;

/**
 *  Buffer for current element
 */
@property (nonatomic, strong) NSMutableString *currentElement;

/**
 *  Text for share
 */
@property (nonatomic, copy  ) NSString        *smsText;

/**
 *  Decorated text for share
 */
@property (nonatomic, copy  ) NSString        *szShareHTML;

@property (nonatomic, strong) Reachability    *hostReachable;

/**
 *  YES if we parse media rss
 */
@property (nonatomic, assign) BOOL             mediaRSS;

/**
 *  YES if datasource is RSS feed
 */
@property (nonatomic, assign) BOOL             RSSFeed;

@end

@implementation mNewsViewController
@synthesize normalFormatDate,
backImgView = _backImgView,
downloadIndicator = _downloadIndicator,
currentElement = _currentElement,
smsText = _smsText,
szShareHTML = _szShareHTML,
hostReachable = _hostReachable,
arr = _arr,
mediaRSS,
RSSFeed,
txtColor,
titleColor,
backgroundColor,
dateColor,
showLink,
shareEMail,
shareSMS,
addNotifications,
addEvents,
widgetType,
RSSPath,
bFirstLoading,
refreshHeaderView,
reloading;

#pragma mark - XML <data> parser

/**
 *  Special parser for processing original xml file
 *
 *  @param xmlElement_ XML node
 *  @param params_     Dictionary with module parameters
 */
+ (void)parseXML:(NSValue *)xmlElement_
     withParams:(NSMutableDictionary *)params_
{
  TBXMLElement element;
  [xmlElement_ getValue:&element];

  NSMutableArray *contentArray = [[[NSMutableArray alloc] init] autorelease];
  
  NSString *szTitle = @"";
  TBXMLElement *titleElement = [TBXML childElementNamed:@"title" parentElement:&element];
  if ( titleElement )
    szTitle = [TBXML textForElement:titleElement];
  
  NSMutableDictionary *contentDict = [[[NSMutableDictionary alloc] init] autorelease];
  [contentDict setObject:(szTitle ? szTitle : @"") forKey:@"title"];
  
    // processing tag <colorskin>
  TBXMLElement *colorskinElement = [TBXML childElementNamed:@"colorskin" parentElement:&element];
  if (colorskinElement)
  {
    TBXMLElement *colorElement = colorskinElement->firstChild;
    while( colorElement )
    {
      NSString *colorElementContent = [TBXML textForElement:colorElement];
      
      if ( [colorElementContent length] )
        [contentDict setValue:colorElementContent forKey:[[TBXML elementName:colorElement] lowercaseString]];
      
      colorElement = colorElement->nextSibling;
    }
  }
  
  
    // 1. adding a zero element to array
  [contentArray addObject:contentDict];
  
    // 2. search for tag <url> or <rss>
  TBXMLElement *urlElement = [TBXML childElementNamed:@"url" parentElement:&element];
  TBXMLElement *rssElement = [TBXML childElementNamed:@"rss" parentElement:&element];
  if ( !urlElement && rssElement )
    urlElement = rssElement;
  if ( urlElement )
  {
    NSString *szRssURL = [TBXML textForElement:urlElement];
      // for compatibility with previous versions we'll add url to 1st (0) element
    if ( [szRssURL length] )
      [contentArray addObject:[NSDictionary dictionaryWithObject:szRssURL
                                                          forKey:[TBXML elementName:urlElement]]];
  }
  else
  {
      // if tag <url> missing then seek for tag <news>
    TBXMLElement *newsElement = [TBXML childElementNamed:@"news" parentElement:&element];
    while( newsElement )
    {
        // find tags: title, indextext, date, url, description
      NSMutableDictionary *objDictionary = [[NSMutableDictionary alloc] init];
      
        // define accessory structure
      typedef struct tagTTagsForDictionary
      {
        const NSString *tagName;
        const NSString *keyName;
      }TTagsForDictionary;

      const TTagsForDictionary parsedTags[] = { { @"title"      , @"title"            },
        { @"description", @"description"      },
        { @"date"       , @"date"             },
        { @"indextext"  , @"description_text" },
        { @"url"        , @"url"              } };
      TBXMLElement *tagElement = newsElement->firstChild;
      while( tagElement )
      {
        NSString *szTag = [[TBXML elementName:tagElement] lowercaseString];

        for ( int i = 0; i < sizeof(parsedTags) / sizeof(parsedTags[0]); ++i )
        {
          if ( [szTag isEqual:parsedTags[i].tagName] )
          {
            NSString *tagContent = [TBXML textForElement:tagElement];
            if ( [tagContent length] )
              [objDictionary setObject:tagContent forKey:parsedTags[i].keyName];
            break;
          }
        }
        tagElement = tagElement->nextSibling;
      }
      
      if ( [objDictionary count] )
        [contentArray addObject:objDictionary];
      [objDictionary release];
      
      newsElement = [TBXML nextSiblingNamed:@"news" searchFromElement:newsElement];
    }
  }
  [params_ setObject:contentArray forKey:@"data"];
}

- (void)setDefaults:(NSArray *)base
{
  self.arr = [NSMutableArray array];
  for( NSObject *obj in base )
    [self.arr addObject:[[obj mutableCopy] autorelease]];
}

- (void)setParams:(NSMutableDictionary *)params
{
  if (params != nil)
  {
    NSArray *data = [params objectForKey:@"data"];
    NSDictionary *contentDict = [data objectAtIndex:0];
    
    [self.navigationItem setTitle:[contentDict objectForKey:@"title"]];
    
    
      //      1 - background
      //      2 - month
      //      3 - text header
      //      4 - text
      //      5 - date
    
      // set colors
    
    if ([contentDict objectForKey:@"color1"])
      self.backgroundColor = [[contentDict objectForKey:@"color1"] asColor];
    
    if ([contentDict objectForKey:@"color3"])
      self.titleColor = [[contentDict objectForKey:@"color3"] asColor];
    
    if ([contentDict objectForKey:@"color4"])
      self.txtColor = [[contentDict objectForKey:@"color4"] asColor];
    
    self.dateColor = self.txtColor;
    
    
      // if there is no color scheme in configuration - define colors by old algorithm
    if (self.backgroundColor)
      self.backImgView  = [[contentDict objectForKey:@"color1"] asImageView:nil];
    else
      self.backImgView = [[params objectForKey:@"backImg"] asImageView:nil];
    
    if (!self.txtColor)
      self.txtColor     = [[params objectForKey:@"textColor"] asColor];
    
    
      // if colors wasn't defined - set default colors:
    
    if (!self.titleColor)
      self.titleColor = [UIColor blackColor];
    
    if (!self.txtColor)
      self.txtColor = [UIColor grayColor];
    
    if (!self.dateColor)
      self.dateColor = [UIColor grayColor];
    
    
    
    showLink         = [[params objectForKey:@"showLink"]         isEqual:@"1"];
    normalFormatDate = [[params objectForKey:@"normalFormatDate"] isEqual:@"1"];
    shareEMail       = [[params objectForKey:@"shareEMail"]       isEqual:@"1"];
    shareSMS         = [[params objectForKey:@"shareSMS"]         isEqual:@"1"];
    addNotifications = [[params objectForKey:@"addNotifications"] isEqual:@"1"];
    addEvents        = [[params objectForKey:@"addEvents"]        isEqual:@"1"];
    
    
    NSString *widgetTypeStr = [[params objectForKey:@"widgetType"] lowercaseString];
    
    if ( widgetTypeStr != nil && ( [widgetTypeStr isEqualToString:@"news"] ||
                                  [widgetTypeStr isEqualToString:@"rss"] ) )
    {
      NSRange range;
      range.location=1;
      range.length=[data count]-1;
      [self setDefaults:[data objectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:range]]];
    }
    else
      [self setDefaults:data];
  }
}


- (NSString*)getWidgetTitle
{
  if (widgetType && [widgetType isEqualToString:@"RSS"])
    return @"RSS";
  else
    return @"News";
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
	self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  if ( self )
  {
    showLink         = NO;
    normalFormatDate = YES;
    shareEMail       = NO;
    shareSMS         = NO;
    addNotifications = NO;
    addEvents        = NO;
    
    _currentElement  = nil;
    _smsText         = nil;
    _szShareHTML     = nil;
    _hostReachable   = nil;
    _arr             = nil;
    
    self.mediaRSS    = NO;
    self.RSSFeed     = NO;
    
    txtColor         = nil;
    titleColor       = nil;
    backgroundColor  = nil;
    dateColor        = nil;
    RSSPath          = nil;
    _backImgView     = nil;
    _downloadIndicator = nil;
    self.bFirstLoading = YES;
    self.reloading = NO;
    self.refreshHeaderView = nil;
  }
	return self;
}

- (void)dealloc
{
  self.currentElement  = nil;
  self.smsText         = nil;
  self.szShareHTML     = nil;
  
  self.hostReachable   = nil;
  
  [self.downloadIndicator removeFromSuperview];
  self.downloadIndicator = nil;
	self.backImgView  = nil;
	self.txtColor     = nil;
  self.titleColor       = nil;
  self.backgroundColor  = nil;
  self.dateColor        = nil;
  
  self.RSSPath      = nil;
	self.arr          = nil;
  self.refreshHeaderView = nil;
  [super dealloc];
}

#pragma mark - View Lifecycle
- (void)viewDidLoad
{
  self.navigationController.navigationBar.translucent = NO;
  [self.navigationController setNavigationBarHidden:NO animated:YES];
  [self.navigationItem setHidesBackButton:NO animated:YES];
  [[self.tabBarController tabBar] setHidden:NO];
  
	if ( ![self.arr count] )
    return;
  
    // show loading indicator on first loading
  self.bFirstLoading = YES;
  
	NSString * path = [[[self.arr objectAtIndex:0] objectForKey:@"rss"] retain];
  self.mediaRSS = NO;
  self.RSSFeed  = NO;

  self.tableView.separatorColor = [UIColor grayColor];
	
    //for use on mode @rss widget"
	if ( !path && ![[self.arr objectAtIndex:0] objectForKey:@"description"])
    path = [[[self.arr objectAtIndex:0] objectForKey:@"url"] retain];
	if ( [path length] )
	{
    [self.arr removeAllObjects];
    self.RSSPath = path;
    NSLog(@"self.RSSPath = %@", self.RSSPath );
    RSSFeed = YES;
    
    self.refreshHeaderView = [[[EGORefreshTableHeaderView alloc] initWithFrame:CGRectMake( 0.0f,
                                                                                          0.0f - self.tableView.bounds.size.height,
                                                                                          self.view.frame.size.width,
                                                                                          self.tableView.bounds.size.height)] autorelease];
    self.refreshHeaderView.delegate = self;
    [self.tableView addSubview:self.refreshHeaderView];
    
      //  refresh the last update date
    [self.refreshHeaderView refreshLastUpdatedDate];
    
    self.tableView.separatorColor = [UIColor clearColor];
    
      // load data by rss link
    [self reloadTableViewDataSource];
	}
	self.smsText     = nil;
  self.szShareHTML = nil;
  
  
	if ( self.backImgView )
	{
    self.backImgView.autoresizesSubviews = YES;
    self.backImgView.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backImgView.frame = self.tableView.bounds;
		[self.tableView setBackgroundView:self.backImgView];
	}
#ifdef __IPHONE_7_0
  
  if ([self.tableView respondsToSelector:@selector(setSeparatorInset:)])
    [self.tableView setSeparatorInset:UIEdgeInsetsZero];
  
  if ([self.tableView respondsToSelector:@selector(setLayoutMargins:)])
    [self.tableView setLayoutMargins:UIEdgeInsetsZero];
  
#endif
  [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
    // forcibly rotate interface to portrait orientation:
  if ( UIInterfaceOrientationIsLandscape( [[UIApplication sharedApplication] statusBarOrientation] ) )
  {
    [[UIDevice currentDevice] performSelector:NSSelectorFromString(@"setOrientation:")
                                   withObject:(id)UIInterfaceOrientationPortrait];
  }
	[self.tableView reloadData];
}

#pragma mark -
#pragma mark Table delegate
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return [self.arr count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
  NSURL* url = [self getCorrectImgUrlFromRssElement:[self.arr objectAtIndex:indexPath.row]];
	
	CGSize titleSize = [[[self.arr objectAtIndex:indexPath.row] objectForKey:@"title"]
                      sizeForFont:[UIFont boldSystemFontOfSize:15]
                      limitSize:url?CGSizeMake(220, 40):CGSizeMake(280, 40)
                      nslineBreakMode:NSLineBreakByTruncatingTail];
	
  NSString *descr=[[self.arr objectAtIndex:indexPath.row] objectForKey:@"description_text"];
	if ( !descr )
    descr = @"";
  
	CGSize descrSize = [descr
                      sizeForFont:[UIFont systemFontOfSize:13]
                      limitSize:url?CGSizeMake(220, 40):CGSizeMake(290, 40)
                      nslineBreakMode:NSLineBreakByTruncatingTail];
  
	CGFloat res = descrSize.height + titleSize.height +10;
  
	if (url && res<75)
    res=75;
  
	NSString *date=[[self.arr objectAtIndex:indexPath.row] objectForKey:@"date"];
	
	if ( date )
    res+=30;
  
	return res;
}

-(void)updateCellWithEmptyImage:(UITableViewCell *)cell{
  UILabel *lblTitle = (UILabel *)[cell viewWithTag:1];
  UILabel *lblDescr = (UILabel *)[cell viewWithTag:4];
  UILabel *lblTempDate = (UILabel *)[cell viewWithTag:2];
    lblTitle.frame = CGRectUnion(lblTitle.frame, CGRectOffset(lblTitle.frame, 7 - lblTitle.frame.origin.x, 0.0f));
    lblDescr.frame = CGRectUnion(lblDescr.frame, CGRectOffset(lblDescr.frame, 7 - lblDescr.frame.origin.x, 0.0f));
  
    CGFloat dateOffsetY = cell.frame.size.height - lblTempDate.frame.origin.y - 35.0f;
    lblTempDate.frame = CGRectOffset(lblTempDate.frame, 0.0f, dateOffsetY);
}

/**
 * Method for sophisticated image setting for news entry.
 * In case of failure we try to send request with unescaped url string, 
 * because we've encountered a bug with facebook feed which had url-encoded img srcs
 */
-(void)setImageViewOnCell:(UITableViewCell*)cell
                  withURL:(NSURL*)url
           fromRssElement:(NSMutableDictionary *)rssElement
{
  UIImageView *imageView = (UIImageView*)[cell.contentView viewWithTag:kImageViewTag];
  
  SDWebImageSuccessBlock successBlock = ^(UIImage *image, BOOL cached)
  {
    if ( CGSizeEqualToSize( image.size, CGSizeZero ) ||
        CGSizeEqualToSize( image.size, CGSizeMake( 1.f, 1.f )))
    {
      [imageView setHidden:YES];
      [self setImgSrc:nil forRssItem:rssElement];
      [self performSelectorOnMainThread:@selector(updateCellWithEmptyImage:) withObject:cell waitUntilDone:NO];
    } else {
      imageView.contentMode = UIViewContentModeScaleAspectFill;
      [imageView setHidden:NO];
    }
  };
  
  SDWebImageFailureBlock failureBlockWithImageViewHiding = ^(NSError *error)
  {
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    [imageView setHidden:YES];
    [self setImgSrc:nil forRssItem:rssElement];
    [self performSelectorOnMainThread:@selector(updateCellWithEmptyImage:) withObject:cell waitUntilDone:NO];
  };
  
  SDWebImageFailureBlock failureBlockWithUnescapedURLRetry = ^(NSError *error)
  {
    NSString *URLString = [url absoluteString];
    NSString *escapedURLString = [URLString gtm_stringByUnescapingFromHTML];
    
    if([URLString caseInsensitiveCompare:escapedURLString] != NSOrderedSame){
      NSURL *unescapedURL = [NSURL URLWithString:escapedURLString];
      //could not set it after actual download succeeds, so it's not guaranteed to have the coorect URL after all
      //nonetheless, if we've got here, we did not have correct URL anyway
      [self setImgSrc:escapedURLString forRssItem:rssElement];
  
        [self setImageView:imageView
                   withURL:unescapedURL
                   success:successBlock
                   failure:failureBlockWithImageViewHiding];
      
    } else {
      failureBlockWithImageViewHiding(nil);
    }
  };
  
  [self setImageView:imageView
             withURL:url
             success:successBlock
             failure:failureBlockWithUnescapedURLRetry];
}

-(void)setImageView:(UIImageView *)imageView
            withURL:(NSURL*)url
            success:(SDWebImageSuccessBlock)success
            failure:(SDWebImageFailureBlock)failure
{
  [imageView setImageWithURL:url
            placeholderImage:[UIImage imageNamed:kPlaceholderImage]
                     options:SDWebImageRetryFailed
                   andResize:CGSizeMake( 64.f, 64.f )
             withContentMode:UIViewContentModeScaleAspectFit
                     success:success
                     failure:failure
   ];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
  
  if (cell == nil) {
		cell = [self getCellContentView:@"Cell"];
  }
	CGRect frame;
  
  UIImageView *imageView = (UIImageView*)[cell.contentView viewWithTag:kImageViewTag];
  NSMutableDictionary *rssElement = [self.arr objectAtIndex:indexPath.row];
  NSURL* url = [self getCorrectImgUrlFromRssElement:rssElement];
  
  if(url && [url.absoluteString rangeOfString:@"http://www.youtu"].location != NSNotFound){
    url = nil;
    [self setImgSrc:nil forRssItem:rssElement];
    [self performSelectorOnMainThread:@selector(updateCellWithEmptyImage:) withObject:cell waitUntilDone:NO];
  }
  
  if ( url )
  {
    [self setImageViewOnCell:cell
                     withURL:url
              fromRssElement:rssElement];
  }
  else
  {
    [imageView setHidden:YES];
  }
  
	UILabel *lblTitle =  (UILabel *)[cell viewWithTag:1];
	if (url)
    lblTitle.frame = CGRectMake(75, 8, 220, 40);
	else
    lblTitle.frame = CGRectMake(7, 8, cell.frame.size.width-30, 40);
  
	lblTitle.text = [[functionLibrary stringByReplaceEntitiesInString:[[self.arr objectAtIndex:indexPath.row] objectForKey:@"title"]] htmlToTextFast];
  
  
	CGSize titleSize = [lblTitle.text
                      sizeForFont:lblTitle.font
                      limitSize:lblTitle.frame.size
                      nslineBreakMode:lblTitle.lineBreakMode];
	frame = lblTitle.frame;
	frame.size.height=titleSize.height;
	lblTitle.frame=frame;

  NSString *descr=[[self.arr objectAtIndex:indexPath.row] objectForKey:@"description_text"];
	if ( !descr )
    descr = @"";
	UILabel *lblDescr = (UILabel *)[cell viewWithTag:4];
  
	if (url)
    lblDescr.frame = CGRectMake(75, titleSize.height+5, 220, 40);
	else
    lblDescr.frame = CGRectMake(7, titleSize.height+5, cell.frame.size.width-30, 40);
  
  NSString *desc = [[[functionLibrary stringByReplaceEntitiesInString:descr] htmlToNewLinePreservingTextFast] truncate];
  [lblDescr setText: [desc stringByReplaceCharacterSet:[NSCharacterSet newlineCharacterSet] withString:@" "]];
  
  CGSize descrSize = [lblDescr.text
                      sizeForFont:lblDescr.font
                      limitSize:lblDescr.frame.size
                      nslineBreakMode:lblDescr.lineBreakMode];
  
	frame=lblDescr.frame;
	frame.size.height=descrSize.height;
	lblDescr.frame=frame;
  
	UILabel *lblTempDate =  (UILabel *)[cell viewWithTag:2];
  
	lblTempDate.frame = CGRectMake(7, [self tableView:tableView heightForRowAtIndexPath:indexPath]-35, cell.frame.size.width-30, 40);
  
  NSDate *dateDate = [functionLibrary dateFromInternetDateTimeString:[[self.arr objectAtIndex:indexPath.row] objectForKey:@"date"]];
  
  NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
  [self setupDateFormatterForcingGMTAndHourFormat:dateFormatter];
  
  NSString *date_s = [dateFormatter stringFromDate:dateDate];
  
  
  [dateFormatter release];
  
  NSString *date_str = [[self.arr objectAtIndex:indexPath.row] objectForKey:@"date_text"];
  
  NSString *dispDate = [NSString string];
  if (date_str) dispDate =[date_str stringByReplacingOccurrencesOfString:@"+0000" withString:@""];

  if (date_s) dispDate = [date_s stringByReplacingOccurrencesOfString:@"+0000" withString:@""];

  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
                                @"([0-9][0-9]?:[0-9][0-9])(:[0-9][0-9])" options:0 error:nil];
  
  NSMutableString* mutDate = [[NSMutableString alloc] init];
  [mutDate setString: dispDate];
  
  [regex replaceMatchesInString:mutDate options:0 range:NSMakeRange(0, [mutDate length]) withTemplate:@"$1"];
  
  lblTempDate.text = mutDate;
  [[self.arr objectAtIndex:indexPath.row] setObject:mutDate forKey:@"disp_date"];
  
  UIImageView *indicatorImageView = [[[UIImageView alloc] initWithFrame: (CGRect){300, 29, 9, 14}] autorelease];
  if ([self.backgroundColor isLight])
    indicatorImageView.image = [UIImage imageNamed: resourceFromBundle(@"mNews_detail")];
  else
    indicatorImageView.image = [UIImage imageNamed: resourceFromBundle(@"mNews_detail_light")];
  cell.accessoryView = indicatorImageView;
  return cell;
}

- (void) setupDateFormatterForcingGMTAndHourFormat:(NSDateFormatter *) dateFormatter
{
  if (self.normalFormatDate)
  {
    static NSString *twentyFourHoursFormat = @"EEE, d MMMM yyyy HH:mm";
    [dateFormatter setDateFormat:twentyFourHoursFormat];
  }
  else
  {
    static NSString *twelveHoursFormat = @"EEE, d MMMM yyyy h:mm a";
    [dateFormatter setDateFormat:twelveHoursFormat];
  }
  
  static NSString *gmtName = @"GMT";
  
  [dateFormatter setTimeZone:[NSTimeZone timeZoneWithName:gmtName]];
}

- (UITableViewCell *) getCellContentView:(NSString *)cellIdentifier
{
	CGRect CellFrame = CGRectMake(0, 0, 320, 90);
	
  UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier] autorelease];
  
  if ([cell respondsToSelector:@selector(setLayoutMargins:)])
  {
    [cell setPreservesSuperviewLayoutMargins:NO];
    [cell setLayoutMargins:UIEdgeInsetsZero];
  }
  
  cell.backgroundColor = [UIColor clearColor];
  
	if ( !self.backImgView )
  {
    UIImageView *backImage = [[UIImageView alloc] initWithFrame:CellFrame];
    backImage.image = [UIImage imageNamed:resourceFromBundle(@"mNews_bcgrd.png")];
    [cell setBackgroundView:backImage];
    [backImage release];
  }
	
	UILabel *lblTemp = [[UILabel alloc] init];
	lblTemp.tag = 1;
	lblTemp.textColor = self.titleColor;
	lblTemp.numberOfLines = 2;
	lblTemp.font = [UIFont boldSystemFontOfSize:15];
	lblTemp.backgroundColor = [UIColor clearColor];
	[cell.contentView addSubview:lblTemp];
	[lblTemp release];
	
	lblTemp = [[UILabel alloc] init];
	lblTemp.tag = 2;
	lblTemp.frame = CGRectMake(75, 24, 220, 50);
	lblTemp.textColor = self.dateColor;
	lblTemp.font = [UIFont systemFontOfSize:11];
	lblTemp.backgroundColor = [UIColor clearColor];
	[cell.contentView addSubview:lblTemp];
	[lblTemp release];
	
	UILabel *descr = [[UILabel alloc] init];
	descr.tag = 4;
	descr.textColor = self.txtColor;
	descr.font = [UIFont systemFontOfSize:13];
	descr.backgroundColor = [UIColor clearColor];
	descr.numberOfLines = 2;
	[cell.contentView addSubview:descr];
	[descr release];
	
	UIImageView *img = [[UIImageView alloc] initWithFrame:CGRectMake(8, 8, 60, 60)];
  [img setContentMode:UIViewContentModeScaleAspectFill];
  [img setClipsToBounds:YES];
	[img.layer setBorderColor: [[UIColor lightGrayColor] CGColor]];
	[img.layer setBorderWidth: 1.0];
	img.tag = kImageViewTag;
	[cell.contentView addSubview:img];
	[img setHidden:true];
	[img release];
  
  UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:
                                      UIActivityIndicatorViewStyleGray];
  spinner.frame = CGRectMake(30, 30, 15, 15);
  spinner.backgroundColor = [UIColor whiteColor];
  spinner.tag = 556;
  [cell.contentView addSubview:spinner];
  [spinner setHidden:true];
  [spinner release];
	
	return cell;
}

  // Override to support row selection in the table view.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSDictionary *arrElement = [self.arr objectAtIndex:indexPath.row];
	
	NSString *link         = [arrElement objectForKey:@"link"];
  NSString *mediaType    = [arrElement objectForKey:@"mediaType"];
  NSString *mediaURL     = [arrElement objectForKey:@"mediaURL"];
  NSString *mediaPlayer  = [arrElement objectForKey:@"mediaPlayer"];
  NSString *enclosureURL = [arrElement objectForKey:@"enclosureURL"];
  NSString *readMoreURL  = nil;
  
  self.smsText     = nil;
  self.szShareHTML = nil;
  
  if (mediaPlayer)
    link = mediaPlayer;
  if (mediaURL&&([mediaType isEqualToString:@"video"]
                 ||[mediaType isEqualToString:@"audio"]))
    link = mediaURL;
  
  if (enclosureURL)
  {
    NSRange posVid=[mediaType rangeOfString:@"video"];
    NSRange posAud=[mediaType rangeOfString:@"audio"];
    if (posVid.location!=NSNotFound||posAud.location!=NSNotFound) {
      readMoreURL = link;
      link = enclosureURL;
    }
  }
  
  mWebVCViewController *webVC = [[[mWebVCViewController alloc] init] autorelease];
  NSString *szDescription = [arrElement objectForKey:@"description"];
	if (link)
	{
    NSString *date = [arrElement objectForKey:@"disp_date"];
    
    if ( !date )
      date = @"";
    
    self.smsText = [NSString stringWithFormat:@"%@ %@\n %@\n %@", NSBundleLocalizedString(@"mRSS_sharingMessage", @"I just read excellent news!"),
                    [arrElement objectForKey:@"title"],
                    (szDescription ? [szDescription htmlToTextFast] : @""),
                    link];
    
    NSRange pos = [link rangeOfString:@"youtu"];
    if ( pos.location != NSNotFound )
    {
      webVC.content = [NSString stringWithFormat:@"<style>a { text-decoration: none; color:#3399FF;}</style><span style='font-family:Helvetica; font-size:16px; font-weight:bold;'>%@</span><br><span style='font-family:Helvetica; font-size:12px;  color:#555555;' >%@</span><br><br>%@<br><br><embed id=\"yt\" src=\"%@\" type=\"application/x-shockwave-flash\"</embed>",[arrElement objectForKey:@"title"],[date stringByReplacingOccurrencesOfString:@"+0000" withString:@""],[arrElement objectForKey:@"description"],link];
    }
    else
    {
      NSString *scheme;
      NSURL *url = [NSURL URLWithString:self.RSSPath];
      if (url)
        scheme = url.scheme;
      else
        scheme = @"http";
      
      NSString *description = [arrElement objectForKey:@"description"];
      
        // processing image urls without scheme:
      description = [description stringByReplacingOccurrencesOfString:@"img src=\"//" withString:[NSString stringWithFormat:@"img src=\"%@://", scheme]];
        // processing relative links:
      description = [description stringByReplacingOccurrencesOfString:@"src=\"/" withString:[NSString stringWithFormat:@"src=\"%@://%@/", scheme, url.host]];
      
      
      description = [functionLibrary stringByReplaceEntitiesInString:description];
      
    
      NSMutableString *htmlCode = [NSMutableString stringWithFormat:@"<div style=\"overflow:hidden;\"><style>a { text-decoration: none; color:#3399FF;}</style><span style='font-family:Helvetica; font-size:16px; font-weight:bold;'>%@</span><br /><span style='font-family:Helvetica; font-size:12px;  color:#555555;' >%@</span><br><br>%@<br><br></div>",[arrElement objectForKey:@"title"],[date stringByReplacingOccurrencesOfString:@"+0000" withString:@""], description];
      
        // if url is correct and content is available, then add link for read more...
      
      if (readMoreURL)
      {
        [htmlCode appendString:[self getHtmlForLink:link withTag:NSBundleLocalizedString(@"mRSS_playMediaLink", @"Play media")]];
        
        [htmlCode appendString:[self getHtmlForLink:readMoreURL withTag:NSBundleLocalizedString(@"mRSS_readMoreLink", @"Read more...")]];
      }
      else
        [htmlCode appendString:[self getHtmlForLink:link withTag:NSBundleLocalizedString(@"mRSS_readMoreLink", @"Read more...")]];
      
      //Empirically detected that the width of webView is about 300 pts
      CGFloat maxImageWidth = self.view.frame.size.width - 20.0f;
      //In some cases, images from third-party rss'es were too wide to fit the description page
      //let us use some JS to adjust the width
      NSString *webVCContent = [NSString stringWithFormat:kImagesWidthsAdjustingFrame, maxImageWidth, htmlCode];
      
      webVC.content = webVCContent;
    }
  }
  else
  {
      // creating html code for manually entered news:
    self.smsText = [NSString stringWithFormat:@"%@ %@\n %@", NSBundleLocalizedString(@"mRSS_sharingMessage", @"I just read excellent news!"),
                    [arrElement objectForKey:@"title"],
                    (szDescription ? [szDescription htmlToNewLinePreservingTextFast] : @"")];
    
    NSString *date=[arrElement objectForKey:@"disp_date"];
		if ( !date )
      date=@"";
    
    NSString *description_text = szDescription ? [szDescription htmlToNewLinePreservingTextFast] : @"";
    if(description_text.length){
      description_text = [description_text stringByReplacingOccurrencesOfString:@"\n" withString:@"<br>"];
    }
    NSString *imageURL = [arrElement objectForKey:@"url"];
    NSString *imageElement = [imageURL length] ?
    [NSString stringWithFormat:@"<img src=\"%@\" height=\"150\" border=\"0\" align=\"left\" style=\"margin-right:5px;\"/>", imageURL] :
    @"";
    
    NSString *htmlCode = [NSString stringWithFormat:@"<style>a { text-decoration: none; color:#3399FF;}</style><span style='font-family:Helvetica; font-size:16px; font-weight:bold;'>%@</span><br /><span style='font-family:Helvetica; font-size:12px;  color:#555555;' >%@</span><br /><br />%@%@", [arrElement objectForKey:@"title"], [date stringByReplacingOccurrencesOfString:@"+0000" withString:@""], imageElement, description_text];
    
    
		webVC.content = htmlCode;
  }
  
    // adding share button (if it need)
  if ( shareEMail || shareSMS )
  {
    self.szShareHTML = [[NSString stringWithFormat:@"<span style='font-family:Helvetica; font-size:14px;'>%@</span><br /><br />", NSBundleLocalizedString(@"mRSS_sharingMessage", @"I just read excellent news!")] stringByAppendingString:webVC.content];
    
    UIBarButtonItem *anotherButton = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                    target:self
                                                                                    action:@selector(showAction)] autorelease];
    webVC.navigationItem.rightBarButtonItem = anotherButton;
    webVC.showTBarOnNextStep = YES;
    webVC.withoutTBar        = YES;
  }
  webVC.showTabBar                = NO;
  webVC.scalesPageToFitOnNextStep = YES;
  [webVC setInputTitle: self.navigationItem.title];
  [self.navigationController pushViewController:webVC animated:YES];
}



#pragma mark -
#pragma mark Actions

-(void)showAction
{
	UIActionSheet *actionSheet = [[UIActionSheet alloc] initWithTitle:nil
                                                           delegate:self
                                                  cancelButtonTitle:nil
                                             destructiveButtonTitle:nil
                                                  otherButtonTitles:nil];
  if ( shareEMail )
    [actionSheet addButtonWithTitle:NSBundleLocalizedString(@"mRSS_shareEmail", @"Share via EMail")];
  if ( shareSMS )
    [actionSheet addButtonWithTitle:NSBundleLocalizedString(@"mRSS_shareSMS", @"Share via SMS")];
  actionSheet.destructiveButtonIndex = [actionSheet addButtonWithTitle:NSBundleLocalizedString(@"mRSS_shareCancel", @"Cancel")];
	actionSheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
	if ( actionSheet.numberOfButtons > 1 )
    [actionSheet showInView:[self.navigationController view]];
	[actionSheet release];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
	NSString *title=[actionSheet buttonTitleAtIndex:buttonIndex];
	if ([title isEqualToString:NSBundleLocalizedString(@"mRSS_shareEmail", @"Share via EMail")])
	{
    [self performSelector:@selector(callMailComposer) withObject:nil afterDelay:0.5f];
	}
	else if ([title isEqualToString:NSBundleLocalizedString(@"mRSS_shareSMS", @"Share via SMS")])
	{
    [self performSelector:@selector(callSMSComposer) withObject:nil afterDelay:0.5f];
	}
}


- (void)callMailComposer
{
  [functionLibrary callMailComposerWithRecipients:nil
                                       andSubject:NSBundleLocalizedString(@"mRSS_sharingEmailSubject", @"Excellent news")
                                          andBody:self.szShareHTML
                                           asHTML:YES
                                   withAttachment:nil
                                         mimeType:nil
                                         fileName:nil
                                   fromController:self
                                         showLink:showLink];
}

- (void)callSMSComposer
{
  [functionLibrary callSMSComposerWithRecipients:nil
                                         andBody:self.smsText
                                  fromController:self];
}


- (void)messageComposeViewController:(MFMessageComposeViewController *)controller
                 didFinishWithResult:(MessageComposeResult)composeResult
{
  if ( composeResult == MessageComposeResultFailed )
  {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"general_sendingSMSFailedAlertTitle", @"Error sending sms") //@"Error sending sms"
                                                    message:NSLocalizedString(@"general_sendingSMSFailedAlertMessage", @"Error sending sms") //@"Error sending sms"
                                                   delegate:nil
                                          cancelButtonTitle:NSLocalizedString(@"general_sendingSMSFailedAlertOkButtonTitle", @"OK") //@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
  }
  [self dismissModalViewControllerAnimated:YES];
}

- (void)mailComposeController:(MFMailComposeViewController *)controller
          didFinishWithResult:(MFMailComposeResult)composeResult
                        error:(NSError *)error
{
  if ( composeResult == MFMailComposeResultFailed )
  {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"general_sendingEmailFailedAlertTitle", @"Error sending email") //@"Error sending sms"
                                                    message:NSLocalizedString(@"general_sendingEmailFailedAlertMessage", @"Error sending email") //@"Error sending sms"
                                                   delegate:nil
                                          cancelButtonTitle:NSLocalizedString(@"general_sendingEmailFailedAlertOkButtonTitle", @"OK") //@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
  }
  [self dismissModalViewControllerAnimated:YES];
}


#pragma mark - Parsing
- (void)parseXMLWithData:(NSData *)data
{
	[self.arr removeAllObjects];
    //you must then convert the path to a proper NSURL or it won't work
  NSXMLParser *rssParser = [[[NSXMLParser alloc] initWithData:data] autorelease];
	
    // Set self as the delegate of the parser so that it will receive the parser delegate methods callbacks.
  [rssParser setDelegate:self];
	
    // Depending on the XML document you're parsing, you may want to enable these features of NSXMLParser.
  [rssParser setShouldProcessNamespaces:NO];
  [rssParser setShouldReportNamespacePrefixes:NO];
  [rssParser setShouldResolveExternalEntities:NO];
  if ([rssParser parse])
  {
    NSLog(@"... Start parsing ...");
  }
  else
  {
    NSLog(@"Parsing Error: %@", rssParser.parserError);
  }
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qName
    attributes:(NSDictionary *)attributeDict
{
  if (!pool)
    pool = [[NSAutoreleasePool alloc] init];
	self.currentElement = [[elementName mutableCopy] autorelease];
	if ([elementName isEqualToString:@"item"] || [elementName isEqualToString:@"entry"])
  {
		[self.arr addObject:[NSMutableDictionary dictionary]];
	}
	else if ([elementName isEqualToString:@"link"])
	{
		NSMutableString *link=[[[attributeDict objectForKey:@"href"] mutableCopy] autorelease];
		if (link&&
       !([[self.arr lastObject] objectForKey:@"link"]&&[attributeDict objectForKey:@"rel"]&&[[attributeDict objectForKey:@"rel"] isEqualToString:@"image"])) //to avoid situations where link replaces with next image link
      [[self.arr lastObject] setObject:link forKey:@"link"];
    
    if ([attributeDict objectForKey:@"rel"]&&[[attributeDict objectForKey:@"rel"] isEqualToString:@"image"])
      [[self.arr lastObject] setObject:link forKey:@"url"];
    
	}
  else if ([elementName isEqualToString:@"img"])
	{
    if (attributeDict)
    {
      NSString *imgLnk=[attributeDict objectForKey:@"src"];
      if (imgLnk) [[self.arr lastObject] setObject:imgLnk forKey:@"url"];
    }
	}
  else if ([elementName isEqualToString:@"media:content"])
	{
    if (attributeDict)
    {
      NSString *mediaType=[attributeDict objectForKey:@"medium"];
      if (mediaType) [[self.arr lastObject] setObject:mediaType forKey:@"mediaType"];
      
      NSString *mediaLnk=[attributeDict objectForKey:@"url"];
      if (mediaLnk) [[self.arr lastObject] setObject:mediaLnk forKey:@"mediaURL"];
    }
	}
  else if ([elementName isEqualToString:@"media:thumbnail"])
	{
    if (attributeDict)
    {
      NSString *imgLnk=[attributeDict objectForKey:@"url"];
      if (imgLnk) [[self.arr lastObject] setObject:imgLnk forKey:@"mediaThumbnail"];
    }
	}
  else if ([elementName isEqualToString:@"media:player"])
	{
    if (attributeDict)
    {
      NSString *imgLnk=[attributeDict objectForKey:@"url"];
      if (imgLnk) [[self.arr lastObject] setObject:imgLnk forKey:@"mediaPlayer"];
    }
	}
  else if ([elementName isEqualToString:@"enclosure"])
	{
    if (attributeDict)
    {
      NSString *mediaType=[attributeDict objectForKey:@"type"];
      if (mediaType) [[self.arr lastObject] setObject:mediaType forKey:@"mediaType"];
      
      NSString *mediaLnk=[attributeDict objectForKey:@"url"];
      if (mediaLnk) [[self.arr lastObject] setObject:mediaLnk forKey:@"enclosureURL"];
    }
	}
  else if ([elementName isEqualToString:@"rss"])
	{
    if (attributeDict)
    {
      NSString *mediaNamespaces=[attributeDict objectForKey:@"xmlns:media"];
      if (mediaNamespaces) mediaRSS = true;
    }
	}
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName{
	if ([elementName isEqualToString:@"item"] || [elementName isEqualToString:@"entry"])
	{
		NSString *title=[[self.arr lastObject] objectForKey:@"title"];
		if (title)
		{
			[[self.arr lastObject] setObject:[title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] forKey:@"title"];
		}
    NSString *content = [[self.arr lastObject] objectForKey:@"content"];
    
    if (content)
    {
      NSString *url=[mNewsViewController getAttribFromText:content WithAttr:@"src="];
      if (url)
        [[self.arr lastObject] setObject:url forKey:@"url"];
    }
	}
  if (pool)
  {
    [pool drain];
    pool=nil;
  }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string{
    // save the characters for the current item...
    if ([self.currentElement isEqualToString:@"title"])
    {
      NSMutableString *title=[[self.arr lastObject] objectForKey:@"title"];
      if (title)
      {
        [title appendString:string];
        [[self.arr lastObject] setObject:title forKey:@"title"];
      }
      else [[self.arr lastObject] setObject:[[string mutableCopy] autorelease] forKey:@"title"];
      
    } else if ([self.currentElement isEqualToString:@"content"])
    {
      NSMutableString *description=[[self.arr lastObject] objectForKey:@"description"];
      if (description)
      {
        [description appendString:string];
        [[self.arr lastObject] setObject:description forKey:@"description"];
      }
      else
        [[self.arr lastObject] setObject:[[string mutableCopy] autorelease] forKey:@"description"];
    }
    else if ([self.currentElement isEqualToString:@"content:encoded"])
    {
      NSMutableString *description=[[self.arr lastObject] objectForKey:@"content_encoded"];
      if (description)
      {
        [description appendString:string];
        [[self.arr lastObject] setObject:description forKey:@"content_encoded"];
      }
      else
        [[self.arr lastObject] setObject:[[string mutableCopy] autorelease] forKey:@"content_encoded"];
      
      [[self.arr lastObject] setObject:[[self.arr lastObject] objectForKey:@"content_encoded"] forKey:@"description"];
    }
    else if ([self.currentElement isEqualToString:@"description"])
    {
      if ([[self.arr lastObject] objectForKey:@"description"])
      {
        NSMutableString *tmpString = [[NSMutableString alloc] initWithString:string];
        NSMutableString *tmpDescription = [[NSMutableString alloc] initWithString:[[self.arr lastObject] objectForKey:@"description"]];
        [tmpDescription appendString:tmpString];
       
        NSRange tmpRange;
        tmpRange.location = 0;
        tmpRange.length = tmpString.length;
        [tmpDescription replaceOccurrencesOfString:@"&nbsp;" withString:@"" options:NSCaseInsensitiveSearch range:tmpRange];
        [[self.arr lastObject] setObject:tmpDescription forKey:@"description"];
        
        [tmpDescription release];
        tmpDescription = nil;
        
        [tmpString release];
        tmpString = nil;
      }
      else
        [[self.arr lastObject] setObject:[[string mutableCopy] autorelease] forKey:@"description"];
    }
    
    else if ([self.currentElement isEqualToString:@"summary"])
    {
      NSMutableString *description=[[self.arr lastObject] objectForKey:@"description"];
      if (description)
      {
        [description appendString:string];
        [[self.arr lastObject] setObject:description forKey:@"description"];
      }
      else
        [[self.arr lastObject] setObject:[[string mutableCopy] autorelease] forKey:@"description"];
    }
    else if ([self.currentElement isEqualToString:@"link"])
    {
      NSMutableString *link=[[self.arr lastObject] objectForKey:@"link"];
      if (link)
      {
        [link appendString:string];
        [[self.arr lastObject] setObject:link forKey:@"link"];
      }
      else
        [[self.arr lastObject] setObject:[[string mutableCopy] autorelease] forKey:@"link"];
      
    } else if ([self.currentElement isEqualToString:@"pubDate"]||
               [self.currentElement isEqualToString:@"dc:date"]||
               [self.currentElement isEqualToString:@"updated"])
    {
      NSMutableString *date=[[self.arr lastObject] objectForKey:@"date"];
      if (date)
      {
        [date appendString:string];
        [[self.arr lastObject] setObject:date forKey:@"date"];
      }
      else
        [[self.arr lastObject] setObject:[[string mutableCopy] autorelease] forKey:@"date"];
    }
}

- (void)parser:(NSXMLParser *)parser validationErrorOccurred:(NSError *)parseError
{
  [parser abortParsing];
}
- (void)parserDidEndDocument:(NSXMLParser *)parser
{
  [self fillTextDescription];
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError
{
  [parser abortParsing];
}

- (NSURL*) getCorrectImgUrlFromRssElement:(NSDictionary*)item {
  
  NSString *url_str=nil;
  if (mediaRSS)
  {
    url_str=[[item objectForKey:@"mediaThumbnail"] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    url_str=[url_str stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
  }
  if (!(mediaRSS) || (url_str==nil))
  {
      // Bug from web: for manually entered news (without images) image url is hostname (http://ibuildapp.com/, e.t.c).
      // Get round it!
    
    NSString *hostname = appIBuildAppHostName();
    NSString *item_url = [item objectForKey:@"url"];
    
    NSString *url = [NSString stringWithFormat:@"http://%@/", hostname];
    
    if (![url isEqualToString:item_url])
    {
      url_str=[item_url stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
      url_str=[url_str stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    }
    else
    {
        // remove wrong value!
      [item setValue:nil forKey:@"url"];
    }
  }
  
  if ([[item objectForKey:@"mediaType"] isEqualToString:@"image"] && [item objectForKey:@"mediaURL"])
    url_str = [item objectForKey:@"mediaURL"];
  
  if (([item objectForKey:@"content_encoded"]) && ([RSSPath rangeOfString:@"feeds.feedburner.com"].location != NSNotFound)) {
    
    NSString *stringRegex = @"<img [^>]*src=[\"|']([^\"|']+)";
    
    NSString *description = [item objectForKey:@"content_encoded"];
    
    NSError *error = NULL;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:stringRegex
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];
    NSArray *matches = [regex matchesInString:description options:NSRegularExpressionCaseInsensitive range:NSMakeRange(0, description.length)];
    
    if (matches.count)
      url_str = [description substringWithRange:[[matches objectAtIndex:0] rangeAtIndex:1]];

  }
  
	if (url_str)
  {
    
    NSURL *url;
    (RSSPath.length) ? (url = [NSURL URLWithString:RSSPath]) : (url = [NSURL URLWithString:url_str]);
    
    NSString *scheme = url.scheme;
    
    if ([url_str hasPrefix:@"//"]) {
        // no scheme:
      url_str = [NSString stringWithFormat:@"%@:%@", scheme, url_str];
    }
    else if ([url_str hasPrefix:@"/"])
    {
        // processing relative path:
      url_str = [NSString stringWithFormat:@"%@://%@%@", scheme, url.host, url_str];
    }
    
    NSString *correctImgUrlStr = url_str;
    
    return [NSURL URLWithString:correctImgUrlStr];
  }
  else
  {
    // Can not get image URL...
    return nil;
  }
}

-(void)setImgSrc:(NSString*)imgSrc forRssItem:(NSMutableDictionary*)item {
    NSString *url_str=nil;
    if (mediaRSS)
    {
      [item setObject:imgSrc forKey:@"mediaThumbnail"];
    }
    if (!(mediaRSS) || (url_str==nil))
    {
        [item setValue:imgSrc forKey:@"url"];
    }
    
    if ([[item objectForKey:@"mediaType"] isEqualToString:@"image"] && [item objectForKey:@"mediaURL"])
        [item setObject:imgSrc forKey:@"mediaURL"];
    
    if (([item objectForKey:@"content_encoded"]) && ([RSSPath rangeOfString:@"feeds.feedburner.com"].location != NSNotFound)) {
        [item setObject:imgSrc forKey:@"content_encoded"];
    }
}

+ (NSString*)getAttribFromText:(NSString*)text WithAttr:(NSString*)attrib

{
	NSString *res=nil;
	NSRange pos=[text rangeOfString:attrib];
	if (pos.location!=NSNotFound)
	{
    NSRange separator_pos;
    separator_pos.location = pos.location+pos.length;
    separator_pos.length = 1;
    NSString *separator = [text substringWithRange:separator_pos];
    
    if (![separator isEqualToString:@"\""]&&![separator isEqualToString:@"\'"])
    {
      separator = @" ";
    }
    
		NSRange content;
		content.location=pos.location+pos.length;
    
		NSRange space=[text rangeOfString:separator options:NSCaseInsensitiveSearch range:NSMakeRange(pos.location+pos.length+1, [text length]-pos.location-pos.length-1)];
		if (space.location==NSNotFound) space.location=[text length];
		content.length=space.location-pos.location-[attrib length];
		res=[[text substringWithRange:content] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\'\""]];
	}
	return res;
}

#pragma mark -

- (void)reverseRSS
{
  NSMutableArray* reversedArr = [NSMutableArray arrayWithCapacity:[self.arr count]];
  NSEnumerator*   reverseEnumerator = [self.arr reverseObjectEnumerator];
  for (NSMutableDictionary *object in reverseEnumerator)
  {
    [reversedArr addObject:object];
  }
  
  [self.arr removeAllObjects];
  
  for (NSMutableDictionary *object in reversedArr)
  {
    [self.arr addObject:object];
  }
  
  [self.tableView reloadData];
}

- (NSString *)getCorrectURLString:(NSString *)urlString
{
  NSString *retVal = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  retVal = [retVal stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]];
  retVal = [retVal stringByReplacingOccurrencesOfString:@" " withString:@"%20"];
  return retVal;
}

- (NSString *) getHtmlForLink:(NSString*)link withTag:(NSString*)tag
{
  link = [self getCorrectURLString:link];
  
  self.hostReachable = [Reachability reachabilityWithHostName:[functionLibrary hostNameFromString:link]];
  
  NetworkStatus hostStatus = [self.hostReachable currentReachabilityStatus];
  
  if (hostStatus != NotReachable)
    return [NSString stringWithFormat:@"<a href=%@>%@</a><br><br>", link, tag];
  else
    return @"";
}

- (void)fillTextDescription
{
  for (int i=0; i<[self.arr count]; i++) {
    
    NSString *st = [[[self.arr objectAtIndex:i] objectForKey:@"description"] htmlToTextFast];
    
    [[self.arr objectAtIndex:i] setObject:st?st:@"" forKey:@"description_text"];
    
    NSString *date_str=[[self.arr objectAtIndex:i] objectForKey:@"date"];
    if (date_str)
    {
      NSDate *date = [functionLibrary dateFromInternetDateTimeString:[date_str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
      if (date)
      {
        NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init];
        [self setupDateFormatterForcingGMTAndHourFormat:dateFormat];
        
        [[self.arr objectAtIndex:i] setObject:[dateFormat stringFromDate:date] forKey:@"date_text"];
        [dateFormat release];
      }
    }
  }
}

#pragma mark -
#pragma mark Data Source Loading IURLLoaderDelegate
- (void)didFinishLoading:(NSData *)data_
           withURLloader:(TURLLoader *)urlLoader
{
  [self.downloadIndicator removeFromSuperview];
  self.downloadIndicator = nil;
  self.bFirstLoading = NO;                      /// reset first-load flag
  [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];

  [self parseXMLWithData:data_];
  [self.tableView reloadData];
  [self doneLoadingTableViewData];
}

- (void)loaderConnection:(NSURLConnection *)connection
        didFailWithError:(NSError *)error
            andURLloader:(TURLLoader *)urlLoader
{
  [self.downloadIndicator removeFromSuperview];
  self.downloadIndicator = nil;
  self.bFirstLoading = NO;                      // reset flag bFirstLoading
  [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
  UIAlertView *message = [[[UIAlertView alloc] initWithTitle:NSBundleLocalizedString(@"mRSS_errorLoadingRSSTitle", @"Error") //@"Error sending sms"
                                                     message:NSBundleLocalizedString(@"mRSS_errorLoadingRSSMessage", @"Cannot load RSS feed") //@"Error sending sms"
                                                    delegate:nil
                                           cancelButtonTitle:NSBundleLocalizedString(@"mRSS_errorLoadingRSSOkButtonTitle", @"OK") //@"OK"
                                           otherButtonTitles:nil] autorelease];
  [message show];

  self.reloading = NO;
  [self doneLoadingTableViewData];
}


#pragma mark -
#pragma mark Data Source Loading / Reloading Methods

- (void)reloadTableViewDataSource
{
	self.reloading = YES;
    // lock user interface while reloading
  [self.tableView setUserInteractionEnabled:NO];
  
    // show loading indicator
  if ( self.bFirstLoading )
  {
    [self.downloadIndicator removeFromSuperview];
    self.downloadIndicator = [[[TDownloadIndicator alloc] initWithFrame:self.view.bounds] autorelease];
    [self.downloadIndicator createViews];
    
    self.downloadIndicator.autoresizesSubviews = YES;
    self.downloadIndicator.autoresizingMask    = UIViewAutoresizingFlexibleWidth |
    UIViewAutoresizingFlexibleHeight;
    [self.downloadIndicator setHidden:NO];
    [self.downloadIndicator startLockViewAnimating:YES];
    [self.view addSubview:self.downloadIndicator];
  }
  [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
  
    // start async loading
  TURLLoader *loader = [[[TURLLoader alloc] initWithURL:self.RSSPath
                                            cachePolicy:NSURLRequestReloadIgnoringCacheData
                                        timeoutInterval:30.f] autorelease];
  TURLLoader *pOldLoader = [[TDownloadManager instance] appendTarget:loader];
  if ( pOldLoader != loader )
  {
    [pOldLoader addDelegate:self];
    [pOldLoader addDelegate:self.downloadIndicator];
  }else{
    [loader addDelegate:self.downloadIndicator];
    [loader addDelegate:self];
  }
  [[TDownloadManager instance] runAll];
}

- (void)doneLoadingTableViewData
{
  self.tableView.separatorColor = [UIColor grayColor];
    //  model should call this when its done loading
	self.reloading = NO;
    // unlock UI
  [self.tableView setUserInteractionEnabled:YES];
	[self.refreshHeaderView egoRefreshScrollViewDataSourceDidFinishedLoading:self.tableView];
}


#pragma mark -
#pragma mark UIScrollViewDelegate Methods

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
	[self.refreshHeaderView egoRefreshScrollViewDidScroll:scrollView];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                  willDecelerate:(BOOL)decelerate
{
	[self.refreshHeaderView egoRefreshScrollViewDidEndDragging:scrollView];
}


#pragma mark - EGORefreshTableHeaderDelegate Methods
- (void)egoRefreshTableHeaderDidTriggerRefresh:(EGORefreshTableHeaderView*)view
{
	[self reloadTableViewDataSource];
}
- (BOOL)egoRefreshTableHeaderDataSourceIsLoading:(EGORefreshTableHeaderView*)view
{
	return self.reloading; // should return if data source model is reloading
}
- (NSDate*)egoRefreshTableHeaderDataSourceLastUpdated:(EGORefreshTableHeaderView*)view
{
	return [NSDate date]; // should return date data source was last changed
}


#pragma mark - Autorotate handlers
-(BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation
{
  return UIInterfaceOrientationIsPortrait( toInterfaceOrientation );
}

-(BOOL)shouldAutorotate
{
  return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
  return UIInterfaceOrientationMaskPortrait |
  UIInterfaceOrientationMaskPortraitUpsideDown;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
  return UIInterfaceOrientationPortrait;
}

@end
