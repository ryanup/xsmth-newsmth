//
//  SMPostViewControllerV2.m
//  newsmth
//
//  Created by Maxwin on 14-8-30.
//  Copyright (c) 2014年 nju. All rights reserved.
//

/**
 * use xsmth://_?[parameters] to proxy native method
 *
 */

#import "SMPostViewControllerV2.h"
#import "SMBoardViewController.h"
#import "PBWebViewController.h"
#import "XImageView.h"
#import "XImageViewCache.h"
#import "SMMainViewController.h"

#import "SMPostActivityItemProvider.h"
#import "SMWeiXinSessionActivity.h"
#import "SMWeiXinTimelineActivity.h"
#import "SMMailToActivity.h"
#import "SMViewLinkActivity.h"
#import "SMReplyActivity.h"
#import "SMForwardActivity.h"
#import "SMSingleAuthorActivity.h"

#import "SMMailComposeViewController.h"
#import "SMWritePostViewController.h"
#import "SMIPadSplitViewController.h"
#import "SMImageViewerViewController.h"

#import "Reachability.h"

#import <WKVerticalScrollBar/WKVerticalScrollBar.h>
#import <ActionSheetPicker-3.0/ActionSheetPicker.h>

//#define DEBUG_HOST @"10.128.100.175"
#define DEBUG_HOST @"192.168.3.161"


@interface SMPostViewControllerV2 () <UIWebViewDelegate, UIScrollViewDelegate, SMWebLoaderOperationDelegate>
@property (strong, nonatomic) UIWebView *webView;
@property (strong, nonatomic) UIRefreshControl *refreshControl;
@property (strong, nonatomic) NSMutableDictionary *imageLoaders;

@property (strong, nonatomic) NSMutableArray *posts;
@property (assign, nonatomic) NSInteger currentPage;
@property (assign, nonatomic) NSInteger totalPage;
@property (strong, nonatomic) NSMutableDictionary *data;


@property (strong, nonatomic) SMPost *postForAction;    // 准备回复的主题
@property (strong, nonatomic) SMWebLoaderOperation *forwardOp;

@property (assign, nonatomic) CGFloat maxScrollY;
@property (assign, nonatomic) CGFloat lastScrollY;
@property (assign, nonatomic) BOOL hideTop;

#pragma mark bottom bar
@property (strong, nonatomic) IBOutlet UIView *viewForButtomBar;
@property (weak, nonatomic) IBOutlet UIButton *buttonForBack;
@property (weak, nonatomic) IBOutlet UIButton *buttonForPageSelector;
@property (weak, nonatomic) IBOutlet UIButton *buttonForGoTop;

@end

@implementation SMPostViewControllerV2

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.posts = [NSMutableArray new];
    self.data = [NSMutableDictionary new];
    self.maxScrollY = 0;
    self.lastScrollY = 0;
    
    NSString *title = self.post.title;
    if (self.author.length > 0) {
        title = [NSString stringWithFormat:@"%@ - 同作者 %@", title, self.author];
    }
    self.title = title;
    
    // add bottom bar
    [[NSBundle mainBundle] loadNibNamed:@"SMPostViewBottomBar" owner:self options:nil];
    CGRect frame = self.viewForButtomBar.frame;
    frame.origin.y = self.view.frame.size.height - frame.size.height;
    self.viewForButtomBar.frame = frame;
    self.viewForButtomBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin
    | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.viewForButtomBar];
    
    self.imageLoaders = [NSMutableDictionary new];
    [self setupWebView];
    
    frame = self.webView.bounds;
    /*
    frame.origin.y = SM_TOP_INSET;
    frame.size.height -= SM_TOP_INSET;
     */
    WKVerticalScrollBar *bar = [[WKVerticalScrollBar alloc] initWithFrame:frame];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:bar];
    [bar setScrollView:self.webView.scrollView];
    
    NSMutableArray *items = [NSMutableArray new];
    if (!_fromBoard) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                      target:self
                                                      action:@selector(onRightBarButtonClick)];
        [items addObject:item];
    }
    if ([SMUtils systemVersion] < 6) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(onRefreshControlValueChanged:)];
        [items addObject:item];
    }
    if (items.count > 0) {
        self.navigationItem.rightBarButtonItems = items;
    }
    
    // setup swipe gesture
    UISwipeGestureRecognizer *gesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(onSwipeGesture:)];
    gesture.direction = UISwipeGestureRecognizerDirectionRight;
    [self.view addGestureRecognizer:gesture];
    
    [self setupTheme];
    
}

- (void)onSwipeGesture:(UIGestureRecognizer *)gesture
{
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)hideNavigation:(BOOL)animated
{
    self.hideTop = YES;
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [self.navigationController setNavigationBarHidden:animated];
    [[UIApplication sharedApplication] setStatusBarHidden:YES];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (void)showNavigation:(BOOL)animated
{
    self.hideTop = NO;
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [[UIApplication sharedApplication] setStatusBarHidden:NO];
    [self setNeedsStatusBarAppearanceUpdate];
}

- (BOOL)prefersStatusBarHidden 
{
    return self.hideTop;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self hideNavigation:YES];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self showNavigation:NO];
}

- (void)onRightBarButtonClick
{
    SMBoardViewController *vc = [[SMBoardViewController alloc] init];
    vc.board = self.post.board;
    
    if ([SMUtils isPad]) {
        [[SMMainViewController instance] setRootViewController:vc];
    } else {
        [self.navigationController pushViewController:vc animated:YES];
    }
}


- (void)setupTheme
{
    [super setupTheme];
    if (!self.viewForButtomBar) {
        return ;
    }
    self.viewForButtomBar.backgroundColor = [SMTheme colorForBackground];
    NSArray *buttons = @[self.buttonForBack, self.buttonForGoTop];
    for (UIButton *button in buttons) {
        UIImage *image = [button imageForState:UIControlStateNormal];
        if ([image respondsToSelector:@selector(imageWithRenderingMode:)]) {
            image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        [button setImage:image forState:UIControlStateNormal];
    }
}

- (void)onThemeChangedNotification:(NSNotification *)n
{
    [super onThemeChangedNotification:n];
    [self sendThemeChangedMessage];
}

- (void)setupWebView
{
    CGRect frame = self.view.bounds;
    frame.size.height -= self.viewForButtomBar.frame.size.height;
    self.webView = [[UIWebView alloc] initWithFrame:frame];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.dataDetectorTypes = UIDataDetectorTypeLink;
    self.webView.scalesPageToFit = YES;
    [self.view addSubview:self.webView];
    
    self.webView.delegate = self;
    self.webView.scrollView.delegate = self;
    
    // remove webview background color
    self.webView.backgroundColor = [UIColor clearColor];
    self.webView.opaque = NO;
    if (![SMUtils systemVersion] < 7) {
        UIWebView *webView = self.webView;
        for (UIView *view in [[webView subviews].firstObject subviews]) {
            if ([view isKindOfClass:[UIImageView class]]) view.hidden = YES;
        }
    }
    
    
    UIScrollView *scrollView = self.webView.scrollView;
    /*
    UIEdgeInsets insets = scrollView.contentInset;
    insets.bottom += self.viewForButtomBar.frame.size.height;
    scrollView.contentInset = scrollView.scrollIndicatorInsets = insets;
     */
    scrollView.decelerationRate = UIScrollViewDecelerationRateNormal;

    // add refresh control
    if ([SMUtils systemVersion] > 5) {
        self.refreshControl = [[UIRefreshControl alloc] init];
        [scrollView addSubview:self.refreshControl];
        [self.refreshControl addTarget:self action:@selector(onRefreshControlValueChanged:) forControlEvents:UIControlEventValueChanged];
    }
    // debug
//    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost/xsmth/"]];
//    NSURL *url = [NSURL URLWithString:@"http://" DEBUG_HOST @"/xsmth/index.html"];
//    NSString *str = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];

    NSString *documentPath = [SMUtils documentPath];
    NSString *postPagePath = [NSString stringWithFormat:@"%@/post/index.html", documentPath];
    NSString *html = [NSString stringWithContentsOfURL:[NSURL fileURLWithPath:postPagePath] encoding:NSUTF8StringEncoding error:0];

    html = [html stringByReplacingOccurrencesOfString:@"{__cachedjsfile__}" withString:[self cachedJSFilename]];
    html = [html stringByReplacingOccurrencesOfString:@"{__t__}" withString:[NSString stringWithFormat:@"%@", @([NSDate timeIntervalSinceReferenceDate])]];
    
    BOOL autoLoadImage = [[Reachability reachabilityForInternetConnection] isReachableViaWiFi] || [SMConfig enableMobileAutoLoadImage];
    
    NSDictionary *config = @{
                             @"autoload": @(autoLoadImage),
                             @"showQMD": @([SMConfig enableShowQMD]),
                             @"tapPaging": @([SMConfig enableTapPaing])
                             };
    html = [html stringByReplacingOccurrencesOfString:@"{__config__}" withString:[SMUtils json2string:config]];
    
    [SMUtils writeData:[html dataUsingEncoding:NSUTF8StringEncoding] toDocumentFolder:@"/post/index2.html"];
    postPagePath = [NSString stringWithFormat:@"%@/post/index2.html", documentPath];
    
//    NSString *baseUrl = [NSString stringWithFormat:@"%@/post/", documentPath];
//    [self.webView loadHTMLString:html baseURL:[NSURL fileURLWithPath:baseUrl]];
    
    NSURL *url = [NSURL fileURLWithPath:postPagePath];
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];

//    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://" DEBUG_HOST @"/xsmth/"]];
//    [self.webView loadRequest:req];
    
}

- (NSString *)cachedJSFilename
{
    return [NSString stringWithFormat:@"%d_%@", self.post.gid, self.author ?: @""];
}

- (void)onRefreshControlValueChanged:(UIRefreshControl *)refreshControl
{
    // remove file
    [self.posts removeAllObjects];
    NSString *file = [NSString stringWithFormat:@"/posts/%@.js", [self cachedJSFilename]];
    [SMUtils writeData:[NSData data] toDocumentFolder:file];
    [self.webView stringByEvaluatingJavaScriptFromString:@"window.location.reload()"];
    [self performSelector:@selector(endRefresh) withObject:nil afterDelay:0.1];
}


- (void)beginRefresh
{
    if ([SMUtils systemVersion] > 5) {
        [self.refreshControl beginRefreshing];
    }
}

- (void)endRefresh
{
    if ([SMUtils systemVersion] > 5) {
        [self.refreshControl endRefreshing];
    }
}

- (void)savePostInfo
{
    // write to js file
//    NSMutableDictionary *info = [NSMutableDictionary new];
//    [info setObject:@(self.currentPage) forKey:@"currentPage"];
//    [info setObject:@(self.totalPage) forKey:@"totalPage"];
//    [info setObject:@(self.maxScrollY) forKey:@"maxScrollY"];
//    NSMutableArray *posts = [NSMutableArray new];
//    [self.posts enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
//        SMPost *post = obj;
//        NSDictionary *json = [post encode];
//        if (json == nil) {
//            
//        } else {
//            [posts addObject:json];
//        }
//    }];
//    [info setObject:posts forKey:@"posts"];
//    
//    NSString *json = [SMUtils json2string:info];
//    NSString *result = [NSString stringWithFormat:@"var info = %@", json];
//    NSString *file = [NSString stringWithFormat:@"/posts/%@.js", [self cachedJSFilename]];
//    [SMUtils writeData:[result dataUsingEncoding:NSUTF8StringEncoding] toDocumentFolder:file];
   
    self.data[@"maxScrollY"] = @(self.maxScrollY);
    NSString *json = [SMUtils json2string:self.data];
    NSString *result = [NSString stringWithFormat:@"var info = %@", json];
    NSString *file = [NSString stringWithFormat:@"/posts/%@.js", [self cachedJSFilename]];
    [SMUtils writeData:[result dataUsingEncoding:NSUTF8StringEncoding] toDocumentFolder:file];
//    XLog_d(@"data: %@", [SMUtils json2string:self.data]);
}

- (void)dealloc
{
    [self savePostInfo];
    XLog_d(@"%s", __PRETTY_FUNCTION__);
    [self.navigationController setNavigationBarHidden:NO];
}

#pragma mark - UIWebViewDelegate
- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    NSURL *url = request.URL;
    
    if ([url.absoluteString hasPrefix:@"xsmth://_"]) {
        NSDictionary *query = [self parseQuery:url.query];
        [self handleJSAPI:query];
        return NO;
    }
    
    if ([url.scheme isEqualToString:@"file"]) {
        return YES;
    }
    
    if ([url.absoluteString isEqualToString:@"about:blank"]) {
        return YES;
    }
    
    XLog_d(@"load: %@", url);
    
    if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
        PBWebViewController *vc = [[PBWebViewController alloc] init];
        vc.URL = url;
        [self.navigationController pushViewController:vc animated:YES];
        return NO;
    }
    
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:nil cancelButtonTitle:@"取消" destructiveButtonTitle:nil otherButtonTitles:@"打开", nil];
    [sheet.rac_buttonClickedSignal subscribeNext:^(id x) {
        NSInteger buttonIndex = [x integerValue];
        XLog_d(@"%@", @(buttonIndex));
    }];
    [sheet showInView:self.view];
    return NO;
}

- (void)webViewDidFinishLoad:(UIWebView *)webView
{
    [self sendThemeChangedMessage];
}

#pragma mark - UIScrollViewDelegate
- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [self sendScrollToBottomEvent:scrollView];
    
//    XLog_d(@"%@", @(scrollView.contentOffset.y));
    self.maxScrollY = MAX(self.maxScrollY, scrollView.contentOffset.y);
    
    if (scrollView.contentOffset.y >= self.lastScrollY) {
        [self hideNavigation:YES];
    } else {
        [self showNavigation:YES];
    }
    self.lastScrollY = scrollView.contentOffset.y;
}

- (void)sendScrollToBottomEvent:(UIScrollView *)scrollView
{
    if (scrollView.contentOffset.y + scrollView.frame.size.height == scrollView.contentSize.height) {
        [self.webView stringByEvaluatingJavaScriptFromString:@"window.SMApp.scrollToBottom()"];
    }
}

#pragma mark - Native method for webview

- (void)sendThemeChangedMessage
{
    NSString *js = [NSString stringWithFormat:@"window.onThemeChanged(%@)", [SMUtils json2string:[self makeupThemeCSS]]];
//    [self.webView performSelector:@selector(stringByEvaluatingJavaScriptFromString:) withObject:js afterDelay:0];
    [self.webView stringByEvaluatingJavaScriptFromString:js];
}

- (void)handleJSAPI:(NSDictionary *)query
{
    NSString *method = query[@"method"];
    NSDictionary *parameters = [SMUtils string2json:query[@"parameters"]];
    
    if ([method isEqualToString:@"log"]) {
        [self apiLog:parameters];
    }
    
    if ([method isEqualToString:@"toast"]) {
        [self apiToast:parameters];
    }
    
    if ([method isEqualToString:@"ajax"]) {
        [self apiAjax:parameters];
    }
    
    if ([method isEqualToString:@"getPostInfo"]) {
        [self apiGetPostInfo:parameters];
    }
    
    if ([method isEqualToString:@"scrollTo"]) {
        [self apiScrollTo:parameters];
    }
    
    if ([method isEqualToString:@"getImageInfo"]) {
        [self apiGetImageInfo:parameters];
    }
    
    if ([method isEqualToString:@"tapImage"]) {
        [self apiTapImage:parameters];
    }
    
    if ([method isEqualToString:@"tapAction"]) {
        [self apiTapAction:parameters];
    }
    
    if ([method isEqualToString:@"reply"]) {
        [self apiReply:parameters];
    }
    
    if ([method isEqualToString:@"savePostsInfo"]) {
        [self apiSavePostsInfo:parameters];
    }
   
    if ([method isEqualToString:@"savePage"]) {
        [self apiSavePageWithPosts:parameters];
    }
    
    if ([method isEqualToString:@"setCurrentPage"]) {
        [self apiSetCurrentPage:parameters];
    }
}

- (void)sendMessage2WebViewWithCallbackID:(NSString *)callbackID value:(id)value
{
    NSString *str = [SMUtils json2string:value];
    NSString *js = [NSString stringWithFormat:@"window.SMApp.callback(%@, %@)", callbackID, str];
    
    [self.webView performSelector:@selector(stringByEvaluatingJavaScriptFromString:) withObject:js];
//    [self.webView stringByEvaluatingJavaScriptFromString:js];
}

- (void)apiLog:(NSDictionary *)parameters
{
    XLog_d(@"weblog: %@", parameters[@"log"]);
}

- (void)apiToast:(NSDictionary *)parameters
{
    [self toast:parameters[@"message"]];
}

- (void)apiAjax:(NSDictionary *)parameters
{
    SMHttpRequest *req;
    NSString *url = parameters[@"url"];
    XLog_d(@"load url: %@", url);
    req = [[SMHttpRequest alloc] initWithURL:[NSURL URLWithString:url]];
    
    if ([url hasPrefix:@"http://www.newsmth.net/nForum/"]) {
        [req addRequestHeader:@"X-Requested-With" value:@"XMLHttpRequest"];
    }
    
    @weakify(req);
    @weakify(self);
    [req setCompletionBlock:^{
        @strongify(req);
        @strongify(self);
        NSString *responseString = req.responseString;
        XLog_d(@"resp length: %@", @(responseString.length));
        if (responseString == nil) {
//            XLog_d(@"%@", req.responseData);
            XLog_e(@"get response string error. parse from data");
            responseString = [SMUtils gb2312Data2String:req.responseData];
        }
        [self sendMessage2WebViewWithCallbackID:parameters[@"callbackID"] value:@{@"response": responseString ?: @""}];
    }];
    
    [req setFailedBlock:^{
        @strongify(req);
        @strongify(self);
        XLog_e(@"req error: %@", req.error);
        [self sendMessage2WebViewWithCallbackID:parameters[@"callbackID"] value:@{@"error": req.error.localizedDescription ?: @"加载失败"}];
    }];
    
    [req startAsynchronous];
}

- (void)apiGetPostInfo:(NSDictionary *)parameters
{
    [self sendMessage2WebViewWithCallbackID:parameters[@"callbackID"] value:@{
                                                                              @"post": self.post.encode,
                                                                              @"author": self.author ?: @""
                                                                              }];
}

- (void)apiScrollTo:(NSDictionary *)parameters
{
    UIScrollView *scrollView = self.webView.scrollView;
    CGFloat pos = [parameters[@"pos"] floatValue] / 2.0f;
    pos = MAX(pos, 0);
    pos = MIN(pos, scrollView.contentSize.height - scrollView.frame.size.height + scrollView.contentInset.top);
    pos -= scrollView.contentInset.top;
    [scrollView setContentOffset:CGPointMake(0, pos) animated:YES];
}

- (void)apiGetImageInfo:(NSDictionary *)parameters
{
    NSString *imageUrl = parameters[@"url"];
    
    XImageView *imageView = [[XImageView alloc] init];
    imageView.autoLoad = [parameters[@"autoload"] boolValue];
    @weakify(self);
    imageView.getSizeBlock = ^(long long size) {
        @strongify(self);
        XLog_d(@"url:%@, %@", imageUrl, @(size));
        [self sendMessage2WebViewWithCallbackID:parameters[@"callbackID"] value:@{@"size": @(size)}];
    };
    
    imageView.didLoadBlock = ^() {
        @strongify(self);
        NSString *path = [[XImageViewCache sharedInstance] pathForUrl:imageUrl];
        XLog_d(@"url: %@ success, %@", imageUrl, path);
        [self sendMessage2WebViewWithCallbackID:parameters[@"callbackID"] value:@{@"success": path}];
    };
    imageView.didFailBlock = ^() {
        @strongify(self);
        [self sendMessage2WebViewWithCallbackID:parameters[@"callbackID"] value:@{@"fail": @"download fail"}];
    };
    
    __block CGFloat latestProgress = -1.0f;
    imageView.updateProgressBlock = ^(CGFloat progress) {
        @strongify(self);
        XLog_d(@"progress: %@", @(progress));
        if (progress - latestProgress > 0.05) {
            [self sendMessage2WebViewWithCallbackID:parameters[@"callbackID"] value:@{@"progress": @(progress)}];
            latestProgress = progress;
            XLog_d(@"update progres %@", @(progress));
        }
    };
    
    imageView.url = imageUrl;
    [self.imageLoaders setObject:imageView forKey:imageUrl];
}

- (void)apiSavePostsInfo:(NSDictionary *)parameters
{
    NSArray *posts = parameters[@"posts"];
    [self mergePosts:posts];
    self.currentPage = [parameters[@"currentPage"] integerValue];
    self.totalPage = [parameters[@"totalPage"] integerValue];
    XLog_d(@"save post: %@, %@, %@", @(posts.count), @(self.currentPage), @(self.totalPage));
}

- (void)apiSavePageWithPosts:(NSDictionary *)parameters
{
    [self.data addEntriesFromDictionary:parameters];
}

- (void)apiSetCurrentPage:(NSDictionary *)parameters
{
    NSInteger currentPage = [parameters[@"page"] integerValue];
    NSInteger totalPage = [parameters[@"total"] integerValue];
    self.currentPage = currentPage;
    self.totalPage = totalPage;
    [self updateButtonForPageSelector];
}

- (void)updateButtonForPageSelector
{
    NSString *title = [NSString stringWithFormat:@"%@/%@", @(self.currentPage), @(self.totalPage)];
    [self.buttonForPageSelector setTitle:title forState:UIControlStateNormal];
}

- (void)apiTapImage:(NSDictionary *)parameters
{
    NSString *url = parameters[@"url"];
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:nil cancelButtonTitle:@"取消" destructiveButtonTitle:nil otherButtonTitles:@"保存图片", @"查看大图", nil];
    @weakify(sheet);
    [sheet.rac_buttonClickedSignal subscribeNext:^(id x) {
        @strongify(sheet);
        NSInteger buttonIndex = [x integerValue];
        if (buttonIndex == sheet.cancelButtonIndex) {
            return  ;
        }
        
        NSString *title = [sheet buttonTitleAtIndex:buttonIndex];
        if ([title isEqualToString:@"保存图片"]) {
            UIImage *image = [[XImageViewCache sharedInstance] getImage:url];
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
        }
        
        if ([title isEqualToString:@"查看大图"]) {
            UIImage *image = [[XImageViewCache sharedInstance] getImage:url];
            SMImageViewerViewController *vc = [SMImageViewerViewController new];
            vc.image = image;
            [self.navigationController pushViewController:vc animated:YES];
        }
    }];
    [sheet showInView:self.view];
}

- (void)apiTapAction:(NSDictionary *)parameters
{
    NSInteger pid = [parameters[@"pid"] integerValue];
    SMPost *post = [self postByID:pid];
    post = [[SMPost alloc] initWithJSON:post.encode];   // make a copy
    post.content = [SMUtils trimHtmlTag:post.content];
    post.board = self.post.board;
    self.postForAction = post;
    if (post == nil) {
        [self toast:@"错误，请刷新页面后重试"];
        return ;
    }
    
    if ([SMUtils systemVersion] < 7) {
        [self tapActionForIOS6];
    } else {
        [self tapActionForIOS7];
    }
}

- (void)apiReply:(NSDictionary *)parameters
{
    NSInteger pid = [parameters[@"pid"] integerValue];
    SMPost *post = [self postByID:pid];
    post = [[SMPost alloc] initWithJSON:post.encode];   // make a copy
    post.content = [SMUtils trimHtmlTag:post.content];
    post.board = self.post.board;
    self.postForAction = post;
    if (post == nil) {
        [self toast:@"错误，请刷新页面后重试"];
        return ;
    }
    [self doReplyPost];
}

- (void)tapActionForIOS6
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil delegate:nil cancelButtonTitle:@"取消" destructiveButtonTitle:nil otherButtonTitles:@"回复", @"同作者", @"发信给作者", @"转寄", nil];
    @weakify(sheet);
    [sheet.rac_buttonClickedSignal subscribeNext:^(id x) {
        @strongify(sheet);
        NSString *title = [sheet buttonTitleAtIndex:[x integerValue]];
        if ([title isEqualToString:@"回复"]) {
            [self doReplyPost];
        }
        if ([title isEqualToString:@"同作者"]) {
            [self doSingleAuthor];
        }
        if ([title isEqualToString:@"发信给作者"]) {
            [self performSelector:@selector(mailtoWithPost) withObject:nil afterDelay:1];
        }
        if ([title isEqualToString:@"转寄"]) {
            [self doForwardPost];
        }
    }];
    [sheet showInView:self.view];
}

- (void)tapActionForIOS7
{
    SMPost *post = self.postForAction;
    SMPostActivityItemProvider *provider = [[SMPostActivityItemProvider alloc] initWithPlaceholderItem:post];
    SMWeiXinSessionActivity *wxSessionActivity = [[SMWeiXinSessionActivity alloc] init];
    SMWeiXinTimelineActivity *wxTimelineActivity = [[SMWeiXinTimelineActivity alloc] init];
    
    SMReplyActivity *replyActivity = [SMReplyActivity new];
    SMMailToActivity *mailtoActivity = [SMMailToActivity new];
    SMForwardActivity *forwordActivity = [SMForwardActivity new];
    SMSingleAuthorActivity *singleAuthorActivity = [SMSingleAuthorActivity new];
    
    NSMutableArray *activites = [[NSMutableArray alloc] initWithArray:@[wxSessionActivity, wxTimelineActivity, replyActivity, singleAuthorActivity, mailtoActivity, forwordActivity]];
    
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[provider] applicationActivities:activites];
    if (&UIActivityTypeAirDrop != NULL) {
        avc.excludedActivityTypes = @[UIActivityTypeAirDrop, UIActivityTypeMessage, UIActivityTypeCopyToPasteboard];
    } else {
        avc.excludedActivityTypes = @[UIActivityTypeMessage, UIActivityTypeCopyToPasteboard];
    }
    @weakify(self);
    @weakify(avc);
    avc.completionHandler = ^(NSString *activityType, BOOL completed) {
        @strongify(self);
        @strongify(avc);
        
        if ([activityType isEqualToString:SMActivityReplyActivity]) {
            [self doReplyPost];
        }
        
        if ([activityType isEqualToString:SMActivityTypeMailToAuthor]) {
            if ([SMUtils systemVersion] < 7) {  // fixme: ios6 animation cause crash
                [self performSelector:@selector(mailtoWithPost) withObject:post afterDelay:1];
            } else {
                [self mailtoWithPost];
            }
        }
        
        if ([activityType isEqualToString:SMActivityForwardActivity]) {
            [self doForwardPost];
        }
        
        if ([activityType isEqualToString:SMActivitySingleAuthorActivity]) {
            [self doSingleAuthor];
        }
        
        [SMUtils trackEventWithCategory:@"postgroup" action:@"more_action" label:activityType];
        avc.completionHandler = nil;
    };
   
    if ([SMUtils isPad]) {
        UIPopoverController *popover = [[UIPopoverController alloc] initWithContentViewController:avc];
        
        CGRect frame = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height, 0, 0);
        [popover presentPopoverFromRect:frame inView:self.view permittedArrowDirections:0 animated:YES];
//        [[SMIPadSplitViewController instance] presentViewController:avc animated:YES completion:NULL];
    } else {
        [self presentViewController:avc animated:YES completion:nil];
    }
}

- (void)doSingleAuthor
{
    SMPostViewControllerV2 *vc = [SMPostViewControllerV2 new];
    vc.post = self.post;
    vc.author = self.postForAction.author;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)doReplyPost
{
    if (![SMAccountManager instance].isLogin) {
        [self performSelectorAfterLogin:@selector(doReplyPost)];
        return ;
    }
    SMWritePostViewController *writeViewController = [[SMWritePostViewController alloc] init];
    writeViewController.post = self.postForAction;
    writeViewController.postTitle = self.post.title;
    writeViewController.title = [NSString stringWithFormat:@"回复-%@", self.post.title];
    P2PNavigationController *nvc = [[P2PNavigationController alloc] initWithRootViewController:writeViewController];
    if ([SMUtils isPad]) {
        [[SMIPadSplitViewController instance] presentViewController:nvc animated:YES completion:NULL];
    } else {
        [self presentViewController:nvc animated:YES completion:NULL];
    }
}

- (void)mailtoWithPost
{
    if (![SMAccountManager instance].isLogin) {
        [self performSelectorAfterLogin:@selector(mailtoWithPost)];  // todo
        return ;
    }
    
    SMPost *post = self.postForAction;
    SMMailComposeViewController *vc = [[SMMailComposeViewController alloc] init];
    SMMailItem *mail = [SMMailItem new];
    mail.title = post.title;
    mail.content = post.content;
    mail.author = post.author;
    vc.mail = mail;
    
    P2PNavigationController *nvc = [[P2PNavigationController alloc] initWithRootViewController:vc];
    [self.view.window.rootViewController presentViewController:nvc animated:YES completion:NULL];
}

- (void)doForwardPost
{
    [self performSelectorAfterLogin:@selector(forwardAfterLogin)];
}

- (void)forwardAfterLogin
{
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"转寄"
                                                        message:@"请输入转寄到的id或email"
                                                       delegate:nil
                                              cancelButtonTitle:@"取消"
                                              otherButtonTitles:@"转寄", nil];
    alertView.alertViewStyle = UIAlertViewStylePlainTextInput;
    [alertView textFieldAtIndex:0].text = [SMAccountManager instance].name;
    @weakify(alertView);
    [alertView.rac_buttonClickedSignal subscribeNext:^(id x) {
        @strongify(alertView);
        NSInteger buttonIndex = [x integerValue];
        if (buttonIndex != alertView.cancelButtonIndex) {
            NSString *text = [alertView textFieldAtIndex:0].text;
            if (text.length != 0) {
                _forwardOp = [[SMWebLoaderOperation alloc] init];
                
                NSString *formUrl = @"http://www.newsmth.net/bbsfwd.php?do";
                SMHttpRequest *request = [[SMHttpRequest alloc] initWithURL:[NSURL URLWithString:formUrl]];
                
                NSString *postBody = [NSString stringWithFormat:@"board=%@&id=%d&target=%@&noansi=1", self.post.board.name, self.postForAction.pid, [SMUtils encodeurl:text]];
                [request setRequestMethod:@"POST"];
                [request addRequestHeader:@"Content-type" value:@"application/x-www-form-urlencoded"];
                [request setPostBody:[[postBody dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]];
                
                _forwardOp.delegate = self;
                [_forwardOp loadRequest:request withParser:@"bbsfwd"];
            }
        }
    }];
    [alertView show];
}


#pragma mark - method
- (SMPost *)postByID:(NSInteger)pid
{
    __block SMPost *ret = nil;
   [self.data enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([obj isKindOfClass:[NSArray class]]) {
            NSArray *posts = obj;
            for (NSDictionary *post in posts) {
                if ([post[@"pid"] integerValue] == pid) {
                    ret = [[SMPost alloc] initWithJSON:post];
                    *stop = YES;
                    break;
                }
            }
        }
    }];
    return ret;
}

- (void)mergePosts:(NSArray *)posts
{
    NSInteger lastPid = 0;
    SMPost *post = self.posts.lastObject;
    if (post) {
        lastPid = post.pid;
    }
    @weakify(self);
    [posts enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        @strongify(self);
        SMPost *post = [[SMPost alloc] initWithJSON:obj];
        if (post.pid > lastPid) {
            [self.posts addObject:post];
        }
    }];
}

- (NSDictionary *)parseQuery:(NSString *)query
{
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithCapacity:0];
    
    NSArray *pairs = [query componentsSeparatedByString:@"&"];
    for (NSString *pair in pairs) {
        NSArray *elements = [pair componentsSeparatedByString:@"="];
		
		if ([elements count] <= 1) {
			continue;
		}
		
        NSString *key = [[elements objectAtIndex:0] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *val = [[elements objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        
        [dict setObject:val forKey:key];
    }
    
    return dict;
}

- (NSDictionary *)makeupThemeCSS
{
    UIFont *font = [SMConfig postFont];
    
    NSString *fontSize = [NSString stringWithFormat:@"%dpx", (int)(font.pointSize * 2)];
    NSString *fontFamily = font.fontName;
    NSString *lineHeight = [NSString stringWithFormat:@"%dpx", (int)(font.lineHeight * 1.2 * 2)];
    NSString *backgroundColor = [self color2hex:[SMTheme colorForBackground]];
    NSString *textColor = [self color2hex:[SMTheme colorForPrimary]];
    NSString *tintColor = [self color2hex:[SMTheme colorForTintColor]];
    NSString *quoteColor = [self color2hex:[SMTheme colorForQuote]];
    
    return @{@"fontSize": fontSize,
             @"fontFamily": fontFamily,
             @"lineHeight": lineHeight,
             @"backgroundColor": backgroundColor,
             @"textColor": textColor,
             @"tintColor": tintColor,
             @"quoteColor": quoteColor
             };
}

- (NSString *)color2hex:(UIColor *)color
{
    CGFloat rf, gf, bf, af;
    [color getRed:&rf green:&gf blue: &bf alpha: &af];
    
    int r = (int)(255.0 * rf);
    int g = (int)(255.0 * gf);
    int b = (int)(255.0 * bf);
    
    return [NSString stringWithFormat:@"#%02x%02x%02x",r,g,b];
}

#pragma mark - WebloaderDelegate
- (void)webLoaderOperationFinished:(SMWebLoaderOperation *)opt
{
    if (opt == self.forwardOp) {
        SMWriteResult *res = _forwardOp.data;
        if (res.success) {
            [self toast:@"转寄成功"];
        }
    }
}

- (void)webLoaderOperationFail:(SMWebLoaderOperation *)opt error:(SMMessage *)error
{
    if (opt == self.forwardOp) {
        [self toast:error.message];
    }
}

#pragma mark - bottom bar
- (IBAction)onBackButtonClick:(id)sender
{
    [self.navigationController popViewControllerAnimated:YES];
}

- (IBAction)onPageSelectorButtonClick:(id)sender
{
    NSMutableArray *pages = [NSMutableArray new];
    for (int i = 0; i < self.totalPage; ++i) {
        [pages addObject:[NSString stringWithFormat:@"%@", @(i + 1)]];
    }

    [ActionSheetStringPicker showPickerWithTitle:@"页面跳转"
                                            rows:pages
                                initialSelection:self.currentPage - 1
                                       doneBlock:^(ActionSheetStringPicker *picker, NSInteger selectedIndex, id selectedValue) {
                                           self.currentPage = selectedIndex + 1;
                                           NSString *js = [NSString stringWithFormat:@"SMApp.loadPage(%@)", @(self.currentPage)];
                                           [self.webView stringByEvaluatingJavaScriptFromString:js];
                                           [self updateButtonForPageSelector];
                                       }
                                     cancelBlock:^(ActionSheetStringPicker *picker) {
                                     }
                                          origin:sender];
}

- (IBAction)onScrollTopButtonClick:(id)sender
{
    [self.webView.scrollView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:YES];
}

@end
