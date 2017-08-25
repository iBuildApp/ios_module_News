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
#import <SDWebImage/SDImageCache.h>
#import <SDWebImage/SDWebImagePrefetcher.h>
#import "functionLibrary.h"
#import "reachability.h"
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

#import "mNewsCell.h"
#import "mNewsDetailsVC.h"
#import <CommonCrypto/CommonDigest.h>
#import "iphColorskinModel.h"
#import "iphNavBarCustomization.h"

#define kImageViewTag 555
#define kPlaceholderImage @"photo_placeholder_small"

// Javascript to resize images in webView
#define kImagesWidthsAdjustingFrame @"<html>\n\
<head>\n\
<script type=\"text/javascript\">\n\
function adjustImagesWidths(){\n\
var maxWidth = %f;\n\
var images=document.images;\n\
for (var i = 0; i < images.length; i++) {\n\
var image = images[i];\n\
var width = image.width;\n\
var height = image.height;\n\
if(width > maxWidth){\n\
image.width = maxWidth;\n\
image.height = (maxWidth * height)/width;\n\
}\n\
};\n\
}\n\
</script>\n\
</head>\n\
<body onload=\"adjustImagesWidths();\">\n\
%@\n\
</body>\n\
</html>"

@interface mNewsViewController()

// RSS URL string
@property(nonatomic,strong) NSString *RSSPath;
// Background imageView
@property(nonatomic,strong) UIImageView *backImgView;
// Text color
@property (nonatomic, strong) UIColor *txtColor;
//vTitle color
@property (nonatomic, strong) UIColor *titleColor;
// Background color
@property (nonatomic, strong) UIColor *backgroundColor;
// Date label color
@property (nonatomic, strong) UIColor *dateColor;
// Array with parsed rss data
@property(nonatomic,strong) NSMutableArray *arr;
// EGORefreshTableHeaderView
@property (nonatomic, strong) EGORefreshTableHeaderView *refreshHeaderView;
// Reloading status
@property (nonatomic, assign) BOOL reloading;
//First loading indicator
@property (nonatomic, assign) BOOL bFirstLoading;
// Download indicator
@property (nonatomic, strong) TDownloadIndicator *downloadIndicator;
// Buffer for current element
@property (nonatomic, strong) NSMutableString *currentElement;

@property (nonatomic, copy) NSString *isLight;

@property (nonatomic, strong) Reachability    *hostReachable;
@property (nonatomic, assign) BOOL mediaRSS; // YES if we parse media rss
@property (nonatomic, assign) BOOL RSSFeed; // YES if datasource is RSS feed

@property (nonatomic, strong) iphColorskinModel *colorSkin;

@property (nonatomic, strong) NSMutableArray *tableData;
@property (nonatomic, assign) BOOL canUpdateTable;
@property (nonatomic, assign) int finished;

@property (nonatomic, strong) NSTimer *updateTableTimer;

@end

@implementation mNewsViewController

@synthesize colorSkin = _colorSkin;
@synthesize tableData = _tableData;
@synthesize updateTableTimer;

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

  NSMutableArray *contentArray = [[NSMutableArray alloc] init];
  
  NSString *szTitle = @"";
  TBXMLElement *titleElement = [TBXML childElementNamed:@"title" parentElement:&element];
  if ( titleElement )
    szTitle = [TBXML textForElement:titleElement];
  
  NSMutableDictionary *contentDict = [[NSMutableDictionary alloc] init];
  contentDict[@"title"] = (szTitle ? szTitle : @"");
  
    // processing tag <colorskin>
  TBXMLElement *colorskinElement = [TBXML childElementNamed:@"colorskin" parentElement:&element];
  if (colorskinElement)
  {
    TBXMLElement *colorElement = colorskinElement->firstChild;
    while( colorElement )
    {
      NSString *colorElementContent = [TBXML textForElement:colorElement];
      
      if ( colorElementContent.length )
        [contentDict setValue:colorElementContent forKey:[TBXML elementName:colorElement].lowercaseString];
      
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
    if ( szRssURL.length )
      [contentArray addObject:@{[TBXML elementName:urlElement]: szRssURL}];
  }
  else
  {
      // if tag <url> missing then seek for tag <news>
    TBXMLElement *newsElement = [TBXML childElementNamed:@"news" parentElement:&element];
    while( newsElement )
    {
        // find tags: title, indextext, date, url, description
      NSMutableDictionary *objDictionary = [[NSMutableDictionary alloc] init];

      static NSDictionary<NSString *, NSString *> *tagToKeyMapping;
      if (!tagToKeyMapping)
      {
        tagToKeyMapping = @{
          @"title"       : @"title",
          @"description" : @"description",
          @"date"        : @"date",
          @"indextext"   : @"description_text",
          @"url"         : @"url"
        };
      }

      for (TBXMLElement *tagElement = newsElement->firstChild;
           tagElement; tagElement = tagElement->nextSibling)
      {
        NSString *tag = [TBXML elementName:tagElement].lowercaseString;
        NSString *key = tagToKeyMapping[tag];
        NSString *tagContent = [TBXML textForElement:tagElement];
        if (key && tagContent.length)
          objDictionary[key] = tagContent;
      }
      
      if ( objDictionary.count )
        [contentArray addObject:objDictionary];
      
      newsElement = [TBXML nextSiblingNamed:@"news" searchFromElement:newsElement];
    }
  }
  
  params_[@"data"] = contentArray;
}

- (void)setDefaults:(NSArray *)base
{
  self.arr = [NSMutableArray array];
  for( NSObject *obj in base )
    [self.arr addObject:[obj mutableCopy]];
}

- (void)setParams:(NSMutableDictionary *)params
{
  if (params != nil)
  {
    NSArray *data = params[@"data"];
    NSDictionary *contentDict = data[0];
    
    (self.navigationItem).title = contentDict[@"title"];
    
    
      //      1 - background
      //      2 - month
      //      3 - text header
      //      4 - text
      //      5 - date
    
      // set colors
    
    //---
    // set values for ColorskinModel
    _colorSkin = [[iphColorskinModel alloc] init];
    

    NSString *colorskinValue = contentDict[@"islight"];
    if(colorskinValue && colorskinValue.length)
      _colorSkin.isLight = colorskinValue.boolValue;
    
    NSString *color1Value = contentDict[@"color1"];
    if(color1Value && color1Value.length)
      _colorSkin.color1 = [color1Value asColor];
    
    if([color1Value.uppercaseString  isEqualToString:@"#FFFFFF"])
      _colorSkin.color1IsWhite = YES;
    
    if([[color1Value uppercaseString]  isEqualToString:@"#000000"])
      _colorSkin.color1IsBlack = YES;
    
    NSString *color2Value = contentDict[@"color2"];
    if(color2Value && [color2Value length])
      _colorSkin.color2 = [color2Value asColor];
    
    NSString *color3Value = contentDict[@"color3"];
    if(color3Value && color3Value.length)
      _colorSkin.color3 = [color3Value asColor];
    
    NSString *color4Value = contentDict[@"color4"];
    if(color4Value && color4Value.length)
      _colorSkin.color4 = [color4Value asColor];
    
    NSString *color5Value = contentDict[@"color5"];
    if(color5Value && color5Value.length)
      _colorSkin.color5 = [color5Value asColor];
    //---
    
    if (contentDict[@"color1"])
      self.backgroundColor = [contentDict[@"color1"] asColor];
    
    if (contentDict[@"color3"])
      self.titleColor = [contentDict[@"color3"] asColor];
    
    if (contentDict[@"color4"])
      self.txtColor = [contentDict[@"color4"] asColor];
    
    if (contentDict[@"isLight"])
      self.isLight = contentDict[@"isLight"];
    
    self.dateColor = self.txtColor;
    
    
      // if there is no color scheme in configuration - define colors by old algorithm
    if (self.backgroundColor)
      self.backImgView  = [contentDict[@"color1"] asImageView:nil];
    else
      self.backImgView = [params[@"backImg"] asImageView:nil];
    
    if (!self.txtColor)
      self.txtColor     = [params[@"textColor"] asColor];
    
    
      // if colors wasn't defined - set default colors:
    
    if (!self.titleColor)
      self.titleColor = [UIColor blackColor];
    
    if (!self.txtColor)
      self.txtColor = [UIColor grayColor];
    
    if (!self.dateColor)
      self.dateColor = [UIColor grayColor];
    
    
    
    _showLink         = [params[@"showLink"]         isEqual:@"1"];
    _normalFormatDate = [params[@"normalFormatDate"] isEqual:@"1"];
    _shareEMail       = [params[@"shareEMail"]       isEqual:@"1"];
    _shareSMS         = [params[@"shareSMS"]         isEqual:@"1"];
    _addNotifications = [params[@"addNotifications"] isEqual:@"1"];
    _addEvents        = [params[@"addEvents"]        isEqual:@"1"];
    
    
    NSString *widgetTypeStr = [params[@"widgetType"] lowercaseString];
    
    if ( widgetTypeStr != nil && ( [widgetTypeStr isEqualToString:@"news"] ||
                                  [widgetTypeStr isEqualToString:@"rss"] ) )
    {
      NSRange range;
      range.location=1;
      range.length=data.count-1;
      [self setDefaults:[data objectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:range]]];
    }
    else
      [self setDefaults:data];
  }
}

- (NSString*)getWidgetTitle
{
  if (_widgetType && [_widgetType isEqualToString:@"RSS"])
    return @"RSS";
  else
    return @"News";
}

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
	self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  if ( self )
  {
    _showLink         = NO;
    _normalFormatDate = YES;
    _shareEMail       = NO;
    _shareSMS         = NO;
    _addNotifications = NO;
    _addEvents        = NO;
    
    self.mediaRSS    = NO;
    self.RSSFeed     = NO;
    self.bFirstLoading = YES;
    self.reloading = NO;
  }
	return self;
}

- (void)dealloc
{
  
  
  [self.downloadIndicator removeFromSuperview];
  
  
  
  if ((self.updateTableTimer).valid)
  {
    [self.updateTableTimer invalidate];
  }
  
}

#pragma mark - View Lifecycle
- (void)viewDidLoad
{
  [iphNavBarCustomization setNavBarSettingsWhenViewDidLoadWithController:self];
  
	if ( !(self.arr).count )
    return;
  
    // show loading indicator on first loading
  self.bFirstLoading = YES;
  
	NSString * path = (self.arr)[0][@"rss"];
  self.mediaRSS = NO;
  self.RSSFeed  = NO;

  self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
	
    //for use on mode @rss widget"
	if ( !path && !(self.arr)[0][@"description"])
    path = (self.arr)[0][@"url"];
	if ( path.length )
	{
    [self.arr removeAllObjects];
    self.RSSPath = path;
    NSLog(@"self.RSSPath = %@", self.RSSPath );
    _RSSFeed = YES;
    
    self.refreshHeaderView = [[EGORefreshTableHeaderView alloc] initWithFrame:CGRectMake( 0.0f,
                                                                                          0.0f - self.tableView.bounds.size.height,
                                                                                          self.view.frame.size.width,
                                                                                          self.tableView.bounds.size.height)];
    self.refreshHeaderView.delegate = self;
    [self.tableView addSubview:self.refreshHeaderView];
    
      //  refresh the last update date
    [self.refreshHeaderView refreshLastUpdatedDate];
    
    self.tableView.separatorColor = [UIColor clearColor];
    
      // load data by rss link
    [self reloadTableViewDataSource];
	}
  
	if ( self.backImgView )
	{
    self.backImgView.autoresizesSubviews = YES;
    self.backImgView.autoresizingMask    = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backImgView.frame = self.tableView.bounds;
		(self.tableView).backgroundView = self.backImgView;
	}
  self.view.backgroundColor = _colorSkin.color1;

  if ([self.tableView respondsToSelector:@selector(setSeparatorInset:)])
    (self.tableView).separatorInset = UIEdgeInsetsZero;
  
  if ([self.tableView respondsToSelector:@selector(setLayoutMargins:)])
    (self.tableView).layoutMargins = UIEdgeInsetsZero;
  
  [self generateTableData];

  
  [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  [iphNavBarCustomization customizeNavBarWithController:self colorskinModel:_colorSkin];
}

- (void)viewWillDisappear:(BOOL)animated
{
  [iphNavBarCustomization restoreNavBarWithController:self colorskinModel:_colorSkin];
  
  [super viewWillDisappear:animated];
}

#pragma mark Table delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  return _tableData.count;//[self.arr count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
  CGFloat cellWidth = tableView.frame.size.width;
  
  NSMutableDictionary *dict = _tableData[indexPath.row];
  
  UIImage *newsImage = nil;

  NSString *URLString = dict[@"headerImageUrl"];
  if (URLString)
    newsImage = [[SDImageCache sharedImageCache] imageFromKey:URLString];
    
  NSString *titleText = dict[@"titleText"];
  NSString *dateText = dict[@"dateText"];
  
  
  
  BOOL lastCell = (indexPath.row == _tableData.count - 1)? YES : NO;
  
  CGFloat result = [mNewsCell heightForCellWithNewsImage:newsImage title:titleText date:dateText cellWidth:cellWidth hasImage:(newsImage != nil) lastCell:lastCell];
  
  return result;
}

- (void) updateTable {

  if(_canUpdateTable == YES)
  {
    _canUpdateTable = NO;
    
    [UIView animateWithDuration:0 animations:^{
      [self.tableView reloadData];
    } completion:^(BOOL finished) {
      
      _canUpdateTable = YES;
    }];
  }
}

- (BOOL) tableHasUnloadedImages {

  for (NSDictionary *dict in _tableData)
  {
    NSString *URLString = dict[@"headerImageUrl"];
    if (URLString && ![[SDImageCache sharedImageCache] imageFromKey:URLString fromDisk:NO])
      return YES;
  }
  
  return NO;
}

- (void) generateTableData {
  
  _canUpdateTable = NO;
  
  long int count = (self.arr).count;
  
  if(_tableData)
  {
    _tableData = nil;
  }
  
  _tableData = [[NSMutableArray alloc] init];
  NSMutableArray<NSURL *> *URLsToPrefetch = [NSMutableArray new];
  
  for(int i = 0; i < count; i++)
  {
    NSString *titleText = [[functionLibrary stringByReplaceEntitiesInString:(self.arr)[i][@"title"]] htmlToTextFast];
    
    NSDate *dateDate = [functionLibrary dateFromInternetDateTimeString:(self.arr)[i][@"date"]];

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [self setupDateFormatterForcingGMTAndHourFormat:dateFormatter];
    NSString *date_s = [dateFormatter stringFromDate:dateDate];
    NSString *date_str = (self.arr)[i][@"date_text"];
    NSString *dispDate = [NSString string];
    if (date_str) dispDate =[date_str stringByReplacingOccurrencesOfString:@"+0000" withString:@""];
    if (date_s) dispDate = [date_s stringByReplacingOccurrencesOfString:@"+0000" withString:@""];
    
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
                                  @"([0-9][0-9]?:[0-9][0-9])(:[0-9][0-9])" options:0 error:nil];
    
    NSMutableString* mutDate = [[NSMutableString alloc] init];
    [mutDate setString: dispDate];
    [regex replaceMatchesInString:mutDate options:0 range:NSMakeRange(0, mutDate.length) withTemplate:@"$1"];
    (self.arr)[i][@"disp_date"] = mutDate;
    
    
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    
    dict[@"titleText"] = titleText;
    dict[@"dateText"] = mutDate;
    //---
    NSString *youtubeDescription = (self.arr)[i][@"mediaDescription"];
    if(youtubeDescription && youtubeDescription.length)
      dict[@"youtubeDescription"] = youtubeDescription;
    //---
    [_tableData addObject:dict];
    
    NSMutableDictionary *rssElement = (self.arr)[i];
    NSURL* url = [self getCorrectImgUrlFromRssElement:rssElement];
    
    if(url && [url.absoluteString rangeOfString:@"http://www.youtu"].location != NSNotFound)
    {
      url = nil;
      [self setImgSrc:nil forRssItem:rssElement];
    }
    
    if(url)
    {
      dict[@"headerImageUrl"] = url.absoluteString;
      [URLsToPrefetch addObject:url];
    }
  }
  
  [[SDWebImagePrefetcher sharedImagePrefetcher] prefetchURLs:URLsToPrefetch];
  
  if(self.updateTableTimer)
  {
    if ((self.updateTableTimer).valid)
    {
      [self.updateTableTimer invalidate];
      self.updateTableTimer = nil;
    }
  }
  
  self.updateTableTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                         target:self
                                                       selector:@selector(checkTableUpdates)
                                                       userInfo:nil
                                                        repeats:YES];

  _canUpdateTable = YES;
}

-(void)checkTableUpdates {
  
  [self updateTable];
  
  BOOL hasUnloaded = [self tableHasUnloadedImages];
  if(hasUnloaded == NO)
  {
    if(self.updateTableTimer)
    {
      if ((self.updateTableTimer).valid)
      {
        [self.updateTableTimer invalidate];
        self.updateTableTimer = nil;
      }
    }
  }
}



- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  
  mNewsCell *cell = (mNewsCell *)[tableView dequeueReusableCellWithIdentifier:@"Cell"];
  
  if (cell == nil)
  {
    cell = [[mNewsCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
  }
  
  NSMutableDictionary *dict = _tableData[indexPath.row];
  
  //----
  
  NSMutableDictionary *rssElement = (self.arr)[indexPath.row];
  NSURL* url = [self getCorrectImgUrlFromRssElement:rssElement];
  
  if(url && [url.absoluteString rangeOfString:@"http://www.youtu"].location != NSNotFound)
  {
    url = nil;
    [self setImgSrc:nil forRssItem:rssElement];
  }
  //-----

  NSString *URLString = dict[@"headerImageUrl"];
  cell.newsImage = (URLString ? [[SDImageCache sharedImageCache] imageFromKey:URLString] : nil);
  cell.hasImage = (cell.newsImage != nil);
  cell.titleText = dict[@"titleText"];
  cell.dateText = dict[@"dateText"];
  cell.titleColor = [UIColor blackColor];
  cell.dateColor = [[UIColor blackColor] colorWithAlphaComponent:0.5f];
  
  BOOL lastCell = (indexPath.row == _tableData.count - 1)? YES : NO;
  
  cell.lastCell = lastCell;
  
  return cell;
}

- (void) setupDateFormatterForcingGMTAndHourFormat:(NSDateFormatter *) dateFormatter
{

  [dateFormatter setDateFormat:NSBundleLocalizedString(@"localizedDateFormat",@"MM/dd/yyyy HH:mm a")];
}

  // Override to support row selection in the table view.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{

	NSDictionary *arrElement = (self.arr)[indexPath.row];
	
	NSString *link         = arrElement[@"link"];
  NSString *mediaType    = arrElement[@"mediaType"];
  NSString *mediaURL     = arrElement[@"mediaURL"];
  NSString *mediaPlayer  = arrElement[@"mediaPlayer"];
  NSString *enclosureURL = arrElement[@"enclosureURL"];
  NSString *readMoreURL  = nil;
  
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

  mNewsDetailsVC *detailsVC = [[mNewsDetailsVC alloc] init];
  detailsVC.colorSkin = _colorSkin;
  NSString *detailsContent = nil;
  NSString *mailSharingContent = nil;

  NSString *dateString = arrElement[@"disp_date"];
  
  dateString = [dateString stringByReplacingOccurrencesOfString:@"+0000" withString:@""];
  if ( !dateString )
    dateString = @"";
  
  NSDictionary *dict = _tableData[indexPath.row];
  
  detailsVC.titleText = arrElement[@"title"];
  detailsVC.dateText = dateString;

  NSString *URLString = dict[@"headerImageUrl"];
  detailsVC.headerImage = (URLString ? [[SDImageCache sharedImageCache] imageFromKey:URLString] : nil);
  detailsVC.showLink = self.showLink;
  
  detailsVC.shareEMail = _shareEMail;
  detailsVC.shareSMS = _shareSMS;
  detailsVC.youtubeVideo = NO;
  
  NSString *backgroundHex = [self hexStringFromColor:_colorSkin.color1];
  NSString *textColorHex = [self hexStringFromColor:_colorSkin.color4];
   NSString *anchorColorHex = [self hexStringFromColor:_colorSkin.color5];// 3399ff


  NSString *szDescription = arrElement[@"description"];
	if (link)
	{
    NSString *date = arrElement[@"disp_date"];
    
    if ( !date )
      date = @"";
    
     detailsVC.smsSharingText = [NSString stringWithFormat:@"%@ %@\n %@\n %@", NSBundleLocalizedString(@"mRSS_sharingMessage", @"I just read excellent news!"),
                    arrElement[@"title"],
                    (szDescription ? [szDescription htmlToTextFast] : @""),
                    link];
    
    NSRange pos = [link rangeOfString:@"youtu"];
    if ( pos.location != NSNotFound )
    {
      NSString *description = arrElement[@"description"] != nil ?arrElement[@"description"]: @"";
      
      mailSharingContent = [NSString stringWithFormat:@"<style>a { text-decoration: none; color:#3399FF;}</style><span style='font-family:Helvetica; font-size:16px; font-weight:bold;'>%@</span><br><span style='font-family:Helvetica; font-size:12px;  color:#555555;' >%@</span><br><br>%@<br><br><embed id=\"yt\" src=\"%@\" type=\"application/x-shockwave-flash\"</embed>",arrElement[@"title"],[date stringByReplacingOccurrencesOfString:@"+0000" withString:@""],arrElement[@"description"],link];
      
      /*
      detailsContent = [NSString stringWithFormat:@"<style>body {background: #%@; font-family:Helvetica; font-size:15px; color:#%@;  margin-left: 15px;margin-right: 15px;} a { text-decoration: none; color:#%@;}</style>%@<br/><embed id=\"yt\" src=\"%@\" type=\"application/x-shockwave-flash\"</embed>", backgroundHex, textColorHex, anchorColorHex, description,link];*/
      
      detailsContent = [NSString stringWithFormat:@"<style>body {background: #%@; font-family:Helvetica; font-size:15px; color:#%@;  margin-left: 15px;margin-right: 15px;} a { text-decoration: none; color:#%@;}</style>%@<br/>", backgroundHex, textColorHex, anchorColorHex, description];
      
      detailsVC.youtubeVideo = YES;
      detailsVC.youtubeLink = link;
      
      detailsVC.headerImage = nil;
    }
    else
    {
      NSString *scheme;
      NSURL *url = [NSURL URLWithString:self.RSSPath];
      if (url)
        scheme = url.scheme;
      else
        scheme = @"http";
      
      NSString *description = arrElement[@"description"];
      
        // processing image urls without scheme:
      description = [description stringByReplacingOccurrencesOfString:@"img src=\"//" withString:[NSString stringWithFormat:@"img src=\"%@://", scheme]];
        // processing relative links:
      description = [description stringByReplacingOccurrencesOfString:@"src=\"/" withString:[NSString stringWithFormat:@"src=\"%@://%@/", scheme, url.host]];
      
      
      description = [functionLibrary stringByReplaceEntitiesInString:description];
      
      NSMutableString *mailSharingHtmlCode = [NSMutableString stringWithFormat:@"<div style=\"overflow:hidden;\"><style>a { text-decoration: none; color:#3399FF;}</style><span style='font-family:Helvetica; font-size:16px; font-weight:bold;'>%@</span><br /><span style='font-family:Helvetica; font-size:12px;  color:#555555;' >%@</span><br><br>%@<br><br></div>",arrElement[@"title"],[date stringByReplacingOccurrencesOfString:@"+0000" withString:@""], description];
        float wid = self.view.frame.size.width - 20.0f;
        NSMutableString *htmlCode = [NSMutableString stringWithFormat:@"<style>body {background: #%@; font-family:Helvetica; font-size:15px; color:#%@; margin-left: 15px; margin-right: 15px;}</style><div style=\"overflow:hidden; width: %dpx;\"><style>a { text-decoration: none; color:#%@;}</style>%@</div>", backgroundHex, textColorHex, (int)wid, anchorColorHex, description];
      
        // if url is correct and content is available, then add link for read more...
      
      if (readMoreURL)
      {
        [htmlCode appendString:@"<br/>"];
      
        [htmlCode appendString:[self getHtmlForLink:link withTag:NSBundleLocalizedString(@"mRSS_playMediaLink", @"Play media")]];
        
        [htmlCode appendString:[self getHtmlForLink:readMoreURL withTag:NSBundleLocalizedString(@"mRSS_readMoreLink", @"Read more...")]];
        
        
        [mailSharingHtmlCode appendString:[self getHtmlForLink:link withTag:NSBundleLocalizedString(@"mRSS_playMediaLink", @"Play media")]];
        
        [mailSharingHtmlCode appendString:[self getHtmlForLink:readMoreURL withTag:NSBundleLocalizedString(@"mRSS_readMoreLink", @"Read more...")]];
      }
      else
      {
        
        [htmlCode appendString:@"<br/>"];

        [htmlCode appendString:[self getHtmlForLink:link withTag:NSBundleLocalizedString(@"mRSS_readMoreLink", @"Read more...")]];
        
        [mailSharingHtmlCode appendString:[self getHtmlForLink:link withTag:NSBundleLocalizedString(@"mRSS_readMoreLink", @"Read more...")]];
      }
      
      //Empirically detected that the width of webView is about 300 pts
      CGFloat maxImageWidth = self.view.frame.size.width - 20.0f;
      //In some cases, images from third-party rss'es were too wide to fit the description page
      //let us use some JS to adjust the width
      NSString *webVCContent = [NSString stringWithFormat:kImagesWidthsAdjustingFrame, maxImageWidth, htmlCode];
      
      detailsContent = webVCContent;
      
      mailSharingContent = [NSString stringWithFormat:kImagesWidthsAdjustingFrame, maxImageWidth, mailSharingHtmlCode];
    }
  }
  else
  {
    NSString *descriptionText = szDescription ? szDescription : @"";
    
      // creating html code for manually entered news:
    detailsVC.smsSharingText = [NSString stringWithFormat:@"%@ %@\n %@", NSBundleLocalizedString(@"mRSS_sharingMessage", @"I just read excellent news!"),
                    arrElement[@"title"],
                    descriptionText];
    
    NSString *date=arrElement[@"disp_date"];
		if ( !date )
      date=@"";
    
    NSString *mailSharingImageURL = arrElement[@"url"];
    NSString *mailSharingImageElement = mailSharingImageURL.length ?
    [NSString stringWithFormat:@"<img src=\"%@\" height=\"150\" border=\"0\" align=\"left\" style=\"margin-right:5px;\"/>", mailSharingImageURL] : @"";
    
     NSString *mailSharingHtmlCode = [NSString stringWithFormat:@"<style>a { text-decoration: none; color:#3399FF;}</style><span style='font-family:Helvetica; font-size:16px; font-weight:bold;'>%@</span><br /><span style='font-family:Helvetica; font-size:12px;  color:#555555;' >%@</span><br /><br />%@%@", arrElement[@"title"], [date stringByReplacingOccurrencesOfString:@"+0000" withString:@""], mailSharingImageElement, descriptionText];
    
    mailSharingContent = mailSharingHtmlCode;
    
    
    NSString *htmlCode = [NSString stringWithFormat:@"<style>body {background: #%@; font-family:Helvetica; font-size:15px; color:#%@; margin-left: 15px;margin-right: 15px;} a { text-decoration: none; color:#%@;}</style>%@", backgroundHex, textColorHex, anchorColorHex, descriptionText];
    
    
		detailsContent = htmlCode;
  }
  
    // adding share button (if it need)
  if ( _shareEMail || _shareSMS )
  {
    detailsVC.mailSharingText = [[NSString stringWithFormat:@"<span style='font-family:Helvetica; font-size:14px;'>%@</span><br /><br />", NSBundleLocalizedString(@"mRSS_sharingMessage", @"I just read excellent news!")] stringByAppendingString:mailSharingContent];
  }

  detailsContent = [self removeHeaderImageFromContent:detailsContent imageUrl:dict[@"headerImageUrl"]];
  
  
  BOOL showUsualDescription = YES;
  if(link)
  {
    NSRange pos = [link rangeOfString:@"youtu"];
    if ( pos.location != NSNotFound )
    {
      NSString *youtubeDescription = dict[@"youtubeDescription"];
      
      detailsVC.content = [NSString stringWithFormat:@"<style>body {background: #%@; font-family:Helvetica; font-size:15px; color:#%@; margin-left: 15px;margin-right: 15px;} a { text-decoration: none; color:#%@;}</style>%@", backgroundHex, textColorHex, anchorColorHex, youtubeDescription];
      
      showUsualDescription = NO;
    }

  }
  
  if(showUsualDescription == YES)
  {
    detailsVC.content = detailsContent;
  }
  
  NSArray *links = [self getLinksFromContent:detailsContent];
  detailsVC.contentLinks = links;
  
  detailsVC.navBarTitle = self.navigationItem.title;
  
  [self.navigationController pushViewController:detailsVC animated:YES];
}

- (NSString *) removeHeaderImageFromContent:(NSString *)content imageUrl:(NSString *)imageUrl {
  
  NSString *resultContent = [NSString stringWithString:content];//[content copy];

  
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<img[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
  //NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<img [^>]*src=[\"|']([^\"|']+)" options:NSRegularExpressionCaseInsensitive error:nil];
  
   NSArray *arrayOfAllMatches = [regex matchesInString:content options:0 range:NSMakeRange(0, content.length)];
  
  for(NSTextCheckingResult *result in arrayOfAllMatches)
  {
    NSRange capture = [result rangeAtIndex:0];
    NSString *currentUrlString = [content substringWithRange:capture];
    
    NSRange range = [currentUrlString rangeOfString: imageUrl];
    BOOL found = (range.location != NSNotFound);
    
      if(found)
      {
        NSString *matchText = [resultContent substringWithRange:result.range];
        resultContent = [resultContent stringByReplacingOccurrencesOfString:matchText
                                             withString:@""];
      }
  }
  return resultContent;
}

- (NSArray *) getLinksFromContent:(NSString *)content {
  
  NSMutableArray *links = [NSMutableArray array];
  
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<a[^>]+href=\"(.*?)\"[^>]*>.*?</a>" options:NSRegularExpressionCaseInsensitive error:nil];
  NSArray *arrayOfAllMatches = [regex matchesInString:content options:0 range:NSMakeRange(0, content.length)];
  
  if(arrayOfAllMatches && arrayOfAllMatches.count)
  {
    for (NSTextCheckingResult *result in arrayOfAllMatches)
    {
      if(result.numberOfRanges == 2)
      {
        NSRange capture = [result rangeAtIndex:1];
        NSString *urlString = [content substringWithRange:capture];
        
        [links addObject:urlString];
      }
    }
  }
  
  return links;
}

- (NSString *)hexStringFromColor:(UIColor *)color
{
  const CGFloat *components = CGColorGetComponents(color.CGColor);
  
  CGFloat r = components[0];
  CGFloat g = components[1];
  CGFloat b = components[2];
  
  return [NSString stringWithFormat:@"%02lX%02lX%02lX",
          lroundf(r * 255),
          lroundf(g * 255),
          lroundf(b * 255)];
}

#pragma mark - Parsing

- (void)parseXMLWithData:(NSData *)data
{
	[self.arr removeAllObjects];
    //you must then convert the path to a proper NSURL or it won't work
  NSXMLParser *rssParser = [[NSXMLParser alloc] initWithData:data];
	
    // Set self as the delegate of the parser so that it will receive the parser delegate methods callbacks.
  rssParser.delegate = self;
	
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
	self.currentElement = [elementName mutableCopy];
	if ([elementName isEqualToString:@"item"] || [elementName isEqualToString:@"entry"])
  {
		[self.arr addObject:[NSMutableDictionary dictionary]];
	}
	else if ([elementName isEqualToString:@"link"])
	{
		NSMutableString *link=[attributeDict[@"href"] mutableCopy];
		if (link&&
       !((self.arr).lastObject[@"link"]&&attributeDict[@"rel"]&&[attributeDict[@"rel"] isEqualToString:@"image"])) //to avoid situations where link replaces with next image link
      (self.arr).lastObject[@"link"] = link;
    
    if (attributeDict[@"rel"]&&[attributeDict[@"rel"] isEqualToString:@"image"])
      (self.arr).lastObject[@"url"] = link;
    
	}
  else if ([elementName isEqualToString:@"img"])
	{
    if (attributeDict)
    {
      NSString *imgLnk=attributeDict[@"src"];
      if (imgLnk) (self.arr).lastObject[@"url"] = imgLnk;
    }
	}
  else if ([elementName isEqualToString:@"media:content"])
	{
    if (attributeDict)
    {
      NSString *mediaType=attributeDict[@"medium"];
      if (mediaType) (self.arr).lastObject[@"mediaType"] = mediaType;
      
      NSString *mediaLnk=attributeDict[@"url"];
      if (mediaLnk) (self.arr).lastObject[@"mediaURL"] = mediaLnk;
    }
  }
  else if ([elementName isEqualToString:@"media:thumbnail"])
	{
    if (attributeDict)
    {
      NSString *imgLnk=attributeDict[@"url"];
      if (imgLnk) (self.arr).lastObject[@"mediaThumbnail"] = imgLnk;
    }
  }
  else if ([elementName isEqualToString:@"media:description"])
  {
    NSMutableString *mediaDescription = [NSMutableString stringWithString:@""];
    (self.arr).lastObject[@"mediaDescription"] = mediaDescription;

  }
  else if ([elementName isEqualToString:@"media:player"])
	{
    if (attributeDict)
    {
      NSString *imgLnk=attributeDict[@"url"];
      if (imgLnk) (self.arr).lastObject[@"mediaPlayer"] = imgLnk;
    }
	}
  else if ([elementName isEqualToString:@"enclosure"])
	{
    if (attributeDict)
    {
      NSString *mediaType=attributeDict[@"type"];
      if (mediaType) (self.arr).lastObject[@"mediaType"] = mediaType;
      
      NSString *mediaLnk=attributeDict[@"url"];
      if (mediaLnk) (self.arr).lastObject[@"enclosureURL"] = mediaLnk;
    }
	}
  else if ([elementName isEqualToString:@"rss"])
	{
    if (attributeDict)
    {
      NSString *mediaNamespaces=attributeDict[@"xmlns:media"];
      if (mediaNamespaces) _mediaRSS = true;
    }
	}
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName{
  
  if ([elementName isEqualToString:@"item"] || [elementName isEqualToString:@"entry"])
  {
    NSString *title=(self.arr).lastObject[@"title"];
    if (title)
    {
      (self.arr).lastObject[@"title"] = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSString *url=[mNewsViewController getAttribFromText:(self.arr).lastObject[@"description"] WithAttr:@"src="];
    if (url)
      (self.arr).lastObject[@"url"] = url;
  }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string{
  
  // save the characters for the current item...
  if ([self.currentElement isEqualToString:@"media:description"])
  {
    
    NSMutableString *descr= (self.arr).lastObject[@"mediaDescription"];
    if (descr)
    {
      [descr appendString:string];
      (self.arr).lastObject[@"mediaDescription"] = descr;
    }
    else (self.arr).lastObject[@"mediaDescription"] = [string mutableCopy];
    
  }
  else if ([self.currentElement isEqualToString:@"title"])
  {
    NSMutableString *title=(self.arr).lastObject[@"title"];
    if (title)
    {
      [title appendString:string];
      (self.arr).lastObject[@"title"] = title;
    }
    else (self.arr).lastObject[@"title"] = [string mutableCopy];
    
  } else if ([self.currentElement isEqualToString:@"content"])
  {
    NSMutableString *description=(self.arr).lastObject[@"description"];
    if (description)
    {
      [description appendString:string];
      (self.arr).lastObject[@"description"] = description;
    }
    else
      (self.arr).lastObject[@"description"] = [string mutableCopy];}
  
  else if ([self.currentElement isEqualToString:@"content:encoded"])
  {
    NSMutableString *description=(self.arr).lastObject[@"content_encoded"];
    if (description)
    {
      [description appendString:string];
      (self.arr).lastObject[@"content_encoded"] = description;
    }
    else
      (self.arr).lastObject[@"content_encoded"] = [string mutableCopy];
    
    (self.arr).lastObject[@"description"] = (self.arr).lastObject[@"content_encoded"];
  }
  else if ([self.currentElement isEqualToString:@"description"])
  {
    if ((self.arr).lastObject[@"description"])
    {
      NSMutableString *tmpString = [[NSMutableString alloc] initWithString:string];
      NSMutableString *tmpDescription = [[NSMutableString alloc] initWithString:(self.arr).lastObject[@"description"]];
      [tmpDescription appendString:tmpString];
      
      NSRange tmpRange;
      tmpRange.location = 0;
      tmpRange.length = tmpString.length;
      [tmpDescription replaceOccurrencesOfString:@"&nbsp;" withString:@"" options:NSCaseInsensitiveSearch range:tmpRange];
      
      (self.arr).lastObject[@"description"] = tmpDescription;
      
      tmpDescription = nil;
      
      tmpString = nil;
    }
    else
      (self.arr).lastObject[@"description"] = [string mutableCopy];
  }
  
  else if ([self.currentElement isEqualToString:@"summary"])
  {
    NSMutableString *description=(self.arr).lastObject[@"description"];
    if (description)
    {
      [description appendString:string];
      (self.arr).lastObject[@"description"] = description;
    }
    else
      (self.arr).lastObject[@"description"] = [string mutableCopy];
  }
  else if ([self.currentElement isEqualToString:@"link"])
  {
    NSMutableString *link=(self.arr).lastObject[@"link"];
    if (link)
    {
      [link appendString:string];
      (self.arr).lastObject[@"link"] = link;
    }
    else
      (self.arr).lastObject[@"link"] = [string mutableCopy];
    
  } else if ([self.currentElement isEqualToString:@"pubDate"]||
             [self.currentElement isEqualToString:@"dc:date"]||
             [self.currentElement isEqualToString:@"updated"])
  {
    NSMutableString *date=(self.arr).lastObject[@"date"];
    if (date)
    {
      [date appendString:string];
      (self.arr).lastObject[@"date"] = date;
    }
    else
      (self.arr).lastObject[@"date"] = [string mutableCopy];
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
  if (_mediaRSS)
  {
    url_str=[item[@"mediaThumbnail"] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    url_str=[url_str stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
  }
  

  NSString *link = item[@"link"];
  if(link && [link rangeOfString:@"http://www.youtu"].location != NSNotFound)
  {
    url_str=[item[@"mediaThumbnail"] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    
    url_str=[url_str stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
  }
  else
  {
    if (!(_mediaRSS) || (url_str==nil))
    {
      // Bug from web: for manually entered news (without images) image url is hostname (http://ibuildapp.com/, e.t.c).
      // Get round it!
      
      NSString *hostname = appIBuildAppHostName();
      NSString *item_url = item[@"url"];
      
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
    
    if ([item[@"mediaType"] isEqualToString:@"image"] && item[@"mediaURL"])
      url_str = item[@"mediaURL"];
    
    if ((item[@"content_encoded"]) && ([_RSSPath rangeOfString:@"feeds.feedburner.com"].location != NSNotFound)) {
      
      NSString *stringRegex = @"<img [^>]*src=[\"|']([^\"|']+)";
      
      NSString *description = item[@"content_encoded"];
      
      NSError *error = NULL;
      NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:stringRegex
                                                                             options:NSRegularExpressionCaseInsensitive
                                                                               error:&error];
      NSArray *matches = [regex matchesInString:description options:NSRegularExpressionCaseInsensitive range:NSMakeRange(0, description.length)];
      
      if (matches.count)
        url_str = [description substringWithRange:[matches[0] rangeAtIndex:1]];
      
    }
    
    //---
    if(url_str == nil)
    {
      url_str=[item[@"enclosureURL"] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
      
      url_str=[url_str stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    }
    //---
  }

  
	if (url_str)
  {
    
    NSURL *url;
    (_RSSPath.length) ? (url = [NSURL URLWithString:_RSSPath]) : (url = [NSURL URLWithString:url_str]);
    
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

-(void)setImgSrc:(NSString*)imgSrc forRssItem:(NSMutableDictionary*)item
{
  if(imgSrc == nil)
  {
    imgSrc = @"";
  }
  
  NSString *url_str=nil;
    if (_mediaRSS)
    {
      item[@"mediaThumbnail"] = imgSrc;
    }
    if (!(_mediaRSS) || (url_str==nil))
    {
        [item setValue:imgSrc forKey:@"url"];
    }
    
    if ([item[@"mediaType"] isEqualToString:@"image"] && item[@"mediaURL"])
        item[@"mediaURL"] = imgSrc;
    
    if ((item[@"content_encoded"]) && ([_RSSPath rangeOfString:@"feeds.feedburner.com"].location != NSNotFound)) {
        item[@"content_encoded"] = imgSrc;
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
    
		NSRange space=[text rangeOfString:separator options:NSCaseInsensitiveSearch range:NSMakeRange(pos.location+pos.length+1, text.length-pos.location-pos.length-1)];
		if (space.location==NSNotFound) space.location=text.length;
		content.length=space.location-pos.location-attrib.length;
		res=[[text substringWithRange:content] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\'\""]];
	}
	return res;
}

#pragma mark -

- (void)reverseRSS
{
  NSMutableArray* reversedArr = [NSMutableArray arrayWithCapacity:(self.arr).count];
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

  [self generateTableData];
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
    return [NSString stringWithFormat:@"<a href=\"%@\">%@</a><br><br>", link, tag];
  else
    return @"";
}

- (void)fillTextDescription
{
  for (int i=0; i<(self.arr).count; i++) {
    
    NSString *st = [(self.arr)[i][@"description"] htmlToTextFast];
    
    (self.arr)[i][@"description_text"] = st?st:@"";
    
    NSString *date_str=(self.arr)[i][@"date"];
    if (date_str)
    {
      NSDate *date = [functionLibrary dateFromInternetDateTimeString:[date_str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
      if (date)
      {
        NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init];
        [self setupDateFormatterForcingGMTAndHourFormat:dateFormat];
        
        (self.arr)[i][@"date_text"] = [dateFormat stringFromDate:date];
      }
    }
  }
}

#pragma mark Data Source Loading IURLLoaderDelegate

- (void)didFinishLoading:(NSData *)data_
           withURLloader:(TURLLoader *)urlLoader
{
  [self.downloadIndicator removeFromSuperview];
  self.downloadIndicator = nil;
  self.bFirstLoading = NO;                      /// reset first-load flag
  [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
  
  [self parseXMLWithData:data_];
  
  [self generateTableData];

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
  UIAlertView *message = [[UIAlertView alloc] initWithTitle:NSBundleLocalizedString(@"mRSS_errorLoadingRSSTitle", @"Error") //@"Error sending sms"
                                                     message:NSBundleLocalizedString(@"mRSS_errorLoadingRSSMessage", @"Cannot load RSS feed") //@"Error sending sms"
                                                    delegate:nil
                                           cancelButtonTitle:NSBundleLocalizedString(@"mRSS_errorLoadingRSSOkButtonTitle", @"OK") //@"OK"
                                           otherButtonTitles:nil];
  [message show];

  self.reloading = NO;
  [self doneLoadingTableViewData];
}

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
    self.downloadIndicator = [[TDownloadIndicator alloc] initWithFrame:self.view.bounds];
    [self.downloadIndicator createViewsWithBackgroundColor:_colorSkin.color1];//createViews];
    
    self.downloadIndicator.autoresizesSubviews = YES;
    self.downloadIndicator.autoresizingMask    = UIViewAutoresizingFlexibleWidth |
    UIViewAutoresizingFlexibleHeight;
    [self.downloadIndicator setHidden:NO];
    [self.downloadIndicator startLockViewAnimating:YES];
    [self.view addSubview:self.downloadIndicator];
  }
  [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
  
    // start async loading
  TURLLoader *loader = [[TURLLoader alloc] initWithURL:self.RSSPath
                                            cachePolicy:NSURLRequestReloadIgnoringCacheData
                                        timeoutInterval:30.f];
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
    //  model should call this when its done loading
	self.reloading = NO;
    // unlock UI
  [self.tableView setUserInteractionEnabled:YES];
	[self.refreshHeaderView egoRefreshScrollViewDataSourceDidFinishedLoading:self.tableView];
}

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

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
  return UIInterfaceOrientationMaskPortrait |
  UIInterfaceOrientationMaskPortraitUpsideDown;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
  return UIInterfaceOrientationPortrait;
}

@end
