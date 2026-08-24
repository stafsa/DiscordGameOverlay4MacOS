#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>
#import <stdlib.h>

#if __has_feature(objc_arc)
    #define DO_SUPER_DEALLOC()
    #define DO_WEAK __weak
#else
    #define DO_SUPER_DEALLOC() [super dealloc]
    #define DO_WEAK __unsafe_unretained
#endif

#pragma mark - Config

static NSString * const DO_CLIENT_ID     = @"<insert yours here ig>";
static NSString * const DO_CLIENT_SECRET = @"<insert yours here ig>";
static NSString * const DO_REDIRECT_URI  = @"https://localhost";
static NSString * const DO_LOG_FILE      = @"/tmp/overlayplusipc.log";
static NSString * const DO_PROFILE_AUTH_FILE = @"/tmp/discord_profile_authorization";

static void DOLog(NSString *fmt, ...) {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (msg.length == 0) return;

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:DO_LOG_FILE];
    if (!h) {
        [data writeToFile:DO_LOG_FILE atomically:YES];
        return;
    }

    @try {
        [h seekToEndOfFile];
        [h writeData:data];
    } @catch (__unused NSException *e) {
        [data writeToFile:DO_LOG_FILE atomically:YES];
    }
    @try { [h closeFile]; } @catch (__unused NSException *e) {}
}

static NSString *DOEnvString(const char *name) {
    if (!name) return nil;
    const char *value = getenv(name);
    if (!value || value[0] == '\0') return nil;
    return [NSString stringWithUTF8String:value];
}

static NSString *DOTrimmedSecretString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 ? trimmed : nil;
}

static NSString *DOProfileAuthorizationFromFile(void) {
    NSString *s = [NSString stringWithContentsOfFile:DO_PROFILE_AUTH_FILE
                                           encoding:NSUTF8StringEncoding
                                              error:nil];
    return DOTrimmedSecretString(s);
}

static NSString *DOProfileAuthorizationHeader(void) {
    NSString *env = DOTrimmedSecretString(DOEnvString("DISCORD_PROFILE_AUTHORIZATION"));
    if (env.length > 0) return env;
    return DOProfileAuthorizationFromFile();
}

#pragma mark - Models

@interface DOUser : NSObject <NSCopying>
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *avatarHash;
@property (nonatomic, copy) NSString *primaryGuildId;
@property (nonatomic, copy) NSString *primaryGuildTag;
@property (nonatomic, copy) NSString *primaryGuildBadgeHash;
@property (nonatomic, assign) BOOL speaking;
@property (nonatomic, assign) BOOL mute;
@property (nonatomic, assign) BOOL deaf;
@property (nonatomic, strong) NSImage *avatarImage;
@property (nonatomic, strong) NSImage *primaryGuildBadgeImage;
@end

@implementation DOUser
- (id)copyWithZone:(NSZone *)zone {
    DOUser *u = [[[self class] allocWithZone:zone] init];
    u.userId = self.userId;
    u.name = self.name;
    u.avatarHash = self.avatarHash;
    u.primaryGuildId = self.primaryGuildId;
    u.primaryGuildTag = self.primaryGuildTag;
    u.primaryGuildBadgeHash = self.primaryGuildBadgeHash;
    u.speaking = self.speaking;
    u.mute = self.mute;
    u.deaf = self.deaf;
    u.avatarImage = self.avatarImage;
    u.primaryGuildBadgeImage = self.primaryGuildBadgeImage;
    return u;
}
@end

@interface DONotification : NSObject <NSCopying>
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) NSTimeInterval createdAt;
@property (nonatomic, assign) NSTimeInterval ttl;
@end

@implementation DONotification
- (id)copyWithZone:(NSZone *)zone {
    DONotification *n = [[[self class] allocWithZone:zone] init];
    n.text = self.text;
    n.createdAt = self.createdAt;
    n.ttl = self.ttl;
    return n;
}
@end

#pragma mark - Chat Models

@interface DOChatGuild : NSObject <NSCopying>
@property (nonatomic, copy) NSString *guildId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *iconHash;
@property (nonatomic, assign) BOOL folder;
@property (nonatomic, copy) NSString *folderId;
@property (nonatomic, strong) NSArray<NSString *> *folderGuildIds;
@property (nonatomic, strong) NSColor *folderColor;
@end

@implementation DOChatGuild
- (id)copyWithZone:(NSZone *)zone {
    DOChatGuild *g = [[[self class] allocWithZone:zone] init];
    g.guildId = self.guildId;
    g.name = self.name;
    g.iconHash = self.iconHash;
    g.folder = self.folder;
    g.folderId = self.folderId;
    g.folderGuildIds = self.folderGuildIds;
    g.folderColor = self.folderColor;
    return g;
}
@end

@interface DOChatChannel : NSObject <NSCopying>
@property (nonatomic, copy) NSString *channelId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *guildId;
@property (nonatomic, assign) NSInteger type;
@end

@implementation DOChatChannel
- (id)copyWithZone:(NSZone *)zone {
    DOChatChannel *c = [[[self class] allocWithZone:zone] init];
    c.channelId = self.channelId;
    c.name = self.name;
    c.guildId = self.guildId;
    c.type = self.type;
    return c;
}
@end

@interface DOChatMessage : NSObject <NSCopying>
@property (nonatomic, copy) NSString *messageId;
@property (nonatomic, copy) NSString *authorId;
@property (nonatomic, copy) NSString *authorName;
@property (nonatomic, copy) NSString *authorAvatarHash;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, assign) NSTimeInterval createdAt;
@end

@implementation DOChatMessage
- (id)copyWithZone:(NSZone *)zone {
    DOChatMessage *m = [[[self class] allocWithZone:zone] init];
    m.messageId = self.messageId;
    m.authorId = self.authorId;
    m.authorName = self.authorName;
    m.authorAvatarHash = self.authorAvatarHash;
    m.content = self.content;
    m.createdAt = self.createdAt;
    return m;
}
@end

#pragma mark - Shared State

@interface DOSharedState : NSObject
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, strong) NSArray<DOUser *> *users;
@property (nonatomic, strong) NSMutableArray<DONotification *> *notifications;
@property (nonatomic, assign) BOOL selfMute;
@property (nonatomic, assign) BOOL selfDeaf;
@property (nonatomic, strong) NSArray<DOChatGuild *> *guilds;
@property (nonatomic, strong) NSArray<DOChatChannel *> *channels;
@property (nonatomic, strong) NSMutableArray<DOChatMessage *> *messages;
@property (nonatomic, copy) NSString *selectedGuildId;
@property (nonatomic, copy) NSString *selectedChannelId;
+ (instancetype)shared;
- (NSArray<DOUser *> *)usersSnapshot;
- (NSArray<DONotification *> *)notificationsSnapshot;
- (NSArray<DOChatGuild *> *)guildsSnapshot;
- (NSArray<DOChatChannel *> *)channelsSnapshot;
- (NSArray<DOChatMessage *> *)messagesSnapshot;
@end

@implementation DOSharedState

+ (instancetype)shared {
    static DOSharedState *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [DOSharedState new];
        s.channelName = @"Voice";
        s.users = @[];
        s.notifications = [NSMutableArray array];
        s.selfMute = NO;
        s.selfDeaf = NO;
        s.guilds = @[];
        s.channels = @[];
        s.messages = [NSMutableArray array];
        s.selectedGuildId = @"";
        s.selectedChannelId = @"";
    });
    return s;
}

- (NSArray<DOUser *> *)usersSnapshot {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:self.users.count];
    for (DOUser *u in self.users) [out addObject:[u copy]];
    return out;
}

- (NSArray<DONotification *> *)notificationsSnapshot {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:self.notifications.count];
    for (DONotification *n in self.notifications) [out addObject:[n copy]];
    return out;
}

- (NSArray<DOChatGuild *> *)guildsSnapshot {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:self.guilds.count];
    for (DOChatGuild *g in self.guilds) [out addObject:[g copy]];
    return out;
}

- (NSArray<DOChatChannel *> *)channelsSnapshot {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:self.channels.count];
    for (DOChatChannel *c in self.channels) [out addObject:[c copy]];
    return out;
}

- (NSArray<DOChatMessage *> *)messagesSnapshot {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:self.messages.count];
    for (DOChatMessage *m in self.messages) [out addObject:[m copy]];
    return out;
}

@end

#pragma mark - Helpers

static BOOL DOIsBoolLike(id value) {
    return [value respondsToSelector:@selector(boolValue)];
}

static NSString *DOAvatarURLString(NSString *userId, NSString *avatarHash) {
    if (userId.length == 0 || avatarHash.length == 0) return nil;
    return [NSString stringWithFormat:@"https://cdn.discordapp.com/avatars/%@/%@.png",
            userId, avatarHash];
}

static NSString *DOGuildIconURLString(NSString *guildId, NSString *iconHash) {
    if (guildId.length == 0 || iconHash.length == 0) return nil;
    return [NSString stringWithFormat:@"https://cdn.discordapp.com/icons/%@/%@.png?size=64",
            guildId, iconHash];
}

static NSString *DOGuildTagBadgeURLString(NSString *guildId, NSString *badgeHash) {
    if (guildId.length == 0 || badgeHash.length == 0) return nil;
    return [NSString stringWithFormat:@"https://cdn.discordapp.com/guild-tag-badges/%@/%@.png?size=32",
            guildId, badgeHash];
}

static NSImage *DOFetchImageSync(NSString *urlString, NSString *label) {
    if (urlString.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        DOLog(@"image fetch invalid url label=%@ url=%@", label ?: @"image", urlString);
        return nil;
    }

    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:8.0];
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSURLResponse *response = nil;
    __block NSError *error = nil;
    __block NSData *data = nil;

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
                                                               completionHandler:^(NSData *taskData, NSURLResponse *taskResponse, NSError *taskError) {
        data = taskData;
        response = taskResponse;
        error = taskError;
        dispatch_semaphore_signal(sema);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.5 * NSEC_PER_SEC)));
    if (waitResult != 0) {
        [task cancel];
        DOLog(@"image fetch timeout label=%@ url=%@", label ?: @"image", urlString);
        return nil;
    }

    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
        ? [(NSHTTPURLResponse *)response statusCode] : 0;

    if (error || data.length == 0 || (status >= 400 && status <= 599)) {
        DOLog(@"image fetch failed label=%@ status=%ld bytes=%lu error=%@ url=%@",
              label ?: @"image",
              (long)status,
              (unsigned long)data.length,
              error.localizedDescription ?: @"",
              urlString);
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithData:data];
    if (!image) {
        DOLog(@"image decode failed label=%@ status=%ld bytes=%lu url=%@",
              label ?: @"image",
              (long)status,
              (unsigned long)data.length,
              urlString);
    }
    return image;
}

static NSString *DOGenerateNonce(void) {
    return [NSString stringWithFormat:@"nonce_%f_%u", CFAbsoluteTimeGetCurrent(), arc4random()];
}

static NSData *DORPCPacket(NSInteger op, NSDictionary *payload) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (!json || error) {
        NSLog(@"[ipc] failed to serialize payload: %@", error);
        return nil;
    }

    int32_t header[2];
    header[0] = (int32_t)op;
    header[1] = (int32_t)json.length;

    NSMutableData *buf = [NSMutableData dataWithBytes:header length:8];
    [buf appendData:json];
    return buf;
}

#pragma mark - Discord IPC Manager

@interface DODiscordIPCManager : NSObject
@property (nonatomic, assign) int socketFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t cmdQueue;
@property (nonatomic, assign) BOOL didAuthorize;
@property (nonatomic, assign) BOOL didAuthenticate;
@property (nonatomic, assign) BOOL didSubscribeNotifications;
@property (nonatomic, assign) BOOL didSubscribeVoiceSettings;
@property (nonatomic, assign) BOOL didSubscribeVoiceChannelSelection;
@property (nonatomic, assign) BOOL didLoadTextGuilds;
@property (nonatomic, assign) BOOL didSubscribeTextChannelEvents;
@property (nonatomic, copy) NSString *accessToken;
@property (nonatomic, copy) NSString *currentUserId;
@property (nonatomic, copy) NSString *subscribedChannelId;
@property (nonatomic, copy) NSString *subscribedTextChannelId;
@property (nonatomic, strong) NSMutableDictionary *currentChannel;
@property (nonatomic, strong) NSMutableDictionary *currentTextChannel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *guildIconHashes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *primaryGuildsByUserId;
@property (nonatomic, strong) NSMutableSet<NSString *> *loadingPrimaryGuildUserIds;
@property (nonatomic, assign) NSUInteger lastLoggedPrimaryGuildPayloadCount;
@property (nonatomic, assign) NSUInteger lastLoggedPrimaryGuildVisibleCount;
@property (nonatomic, assign) BOOL currentMute;
@property (nonatomic, assign) BOOL currentDeaf;
+ (instancetype)shared;
- (void)start;
- (void)toggleMute;
- (void)toggleDeafen;
- (void)disconnectVoice;
- (void)handleMoreOptions;
// Text chat (Discord RPC)
- (void)selectTextGuildId:(NSString *)guildId;
- (void)selectTextChannelId:(NSString *)channelId;
- (void)joinVoiceChannelId:(NSString *)channelId;
- (void)refreshGuildIconsFromREST;
- (void)refreshGuildFoldersFromREST;
- (void)fetchPrimaryGuildForUserIdIfNeeded:(NSString *)userId;
@end

@implementation DODiscordIPCManager

+ (instancetype)shared {
    static DODiscordIPCManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        m = [DODiscordIPCManager new];
        m.socketFD = -1;
        m.queue = dispatch_queue_create("discord.overlay.ipc.io", DISPATCH_QUEUE_SERIAL);
        m.cmdQueue = dispatch_queue_create("discord.overlay.ipc.cmd", DISPATCH_QUEUE_SERIAL);
        m.currentChannel = [NSMutableDictionary dictionary];
        m.currentMute = NO;
        m.currentDeaf = NO;
        m.didLoadTextGuilds = NO;
        m.didSubscribeTextChannelEvents = NO;
        m.subscribedTextChannelId = nil;
        m.currentTextChannel = [NSMutableDictionary dictionary];
        m.guildIconHashes = [NSMutableDictionary dictionary];
        m.primaryGuildsByUserId = [NSMutableDictionary dictionary];
        m.loadingPrimaryGuildUserIds = [NSMutableSet set];
    });
    return m;
}

- (void)resetSessionState {
    self.didAuthorize = NO;
    self.didAuthenticate = NO;
    self.didSubscribeNotifications = NO;
    self.didSubscribeVoiceSettings = NO;
    self.didSubscribeVoiceChannelSelection = NO;
    self.didLoadTextGuilds = NO;
    self.didSubscribeTextChannelEvents = NO;
    self.accessToken = nil;
    self.currentUserId = nil;
    self.subscribedChannelId = nil;
    self.subscribedTextChannelId = nil;
    self.currentChannel = [NSMutableDictionary dictionary];
    self.currentTextChannel = [NSMutableDictionary dictionary];
    [self.guildIconHashes removeAllObjects];
    [self.primaryGuildsByUserId removeAllObjects];
    [self.loadingPrimaryGuildUserIds removeAllObjects];
    self.currentMute = NO;
    self.currentDeaf = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        DOSharedState *s = [DOSharedState shared];
        s.channelName = @"Voice";
        s.users = @[];
        s.selfMute = NO;
        s.selfDeaf = NO;
        s.guilds = @[];
        s.channels = @[];
        s.messages = [NSMutableArray array];
        s.selectedGuildId = @"";
        s.selectedChannelId = @"";
    });
}

- (NSString *)findSocketPath {
    NSArray<NSString *> *bases = @[@"/tmp", NSTemporaryDirectory()];
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *base in bases) {
        if (base.length == 0) continue;
        for (int i = 0; i < 10; i++) {
            NSString *p = [base stringByAppendingPathComponent:[NSString stringWithFormat:@"discord-ipc-%d", i]];
            if ([fm fileExistsAtPath:p]) {
                DOLog(@"IPC socket found at %@", p);
                return p;
            }
        }
    }
    DOLog(@"IPC socket not found. bases=%@", bases);
    return nil;
}

- (BOOL)connectSocket {
    NSString *path = [self findSocketPath];
    if (path.length == 0) {
        NSLog(@"[ipc] Discord IPC not found");
        DOLog(@"connectSocket: Discord IPC not found");
        return NO;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[ipc] socket() failed: %d", errno);
        DOLog(@"connectSocket: socket() failed errno=%d", errno);
        return NO;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.UTF8String, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSLog(@"[ipc] connect() failed: %d", errno);
        DOLog(@"connectSocket: connect() failed errno=%d path=%@", errno, path);
        close(fd);
        return NO;
    }

    self.socketFD = fd;
    NSLog(@"[ipc] connected: %@", path);
    DOLog(@"connectSocket: connected %@", path);
    return YES;
}

- (BOOL)writeData:(NSData *)data {
    if (!data) return NO;
    int fd;
    @synchronized (self) { fd = self.socketFD; }
    if (fd < 0) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger total = data.length;
    NSUInteger sent = 0;

    while (sent < total) {
        ssize_t n = write(fd, bytes + sent, total - sent);
        if (n <= 0) return NO;
        sent += (NSUInteger)n;
    }
    return YES;
}

- (BOOL)sendCommand:(NSString *)cmd args:(NSDictionary *)args evt:(NSString *)evt {
    if (self.socketFD < 0) return NO;

    NSMutableDictionary *payload = [@{
        @"cmd": cmd ?: @"",
        @"nonce": DOGenerateNonce()
    } mutableCopy];

    if (args) payload[@"args"] = args;
    if (evt.length > 0) payload[@"evt"] = evt;

    NSData *packet = DORPCPacket(1, payload);
    BOOL ok = [self writeData:packet];
    if (!ok) DOLog(@"sendCommand failed cmd=%@", cmd);
    return ok;
}

- (BOOL)sendHandshake {
    NSDictionary *handshake = @{
        @"v": @1,
        @"client_id": DO_CLIENT_ID
    };
    return [self writeData:DORPCPacket(0, handshake)];
}

- (NSData *)readExact:(NSUInteger)length {
    int fd;
    @synchronized (self) { fd = self.socketFD; }
    if (fd < 0) return nil;

    NSMutableData *d = [NSMutableData dataWithLength:length];
    uint8_t *ptr = d.mutableBytes;
    NSUInteger received = 0;

    while (received < length) {
        ssize_t n = read(fd, ptr + received, length - received);
        if (n <= 0) return nil;
        received += (NSUInteger)n;
    }
    return d;
}

- (NSString *)urlEncodedString:(NSString *)s {
    NSCharacterSet *allowed = [NSCharacterSet URLQueryAllowedCharacterSet];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

- (NSString *)exchangeTokenSync:(NSString *)code {
    if (code.length == 0) return nil;

    NSString *body = [NSString stringWithFormat:@"grant_type=authorization_code&code=%@&redirect_uri=%@",
                      [self urlEncodedString:code],
                      [self urlEncodedString:DO_REDIRECT_URI]];

    NSURL *url = [NSURL URLWithString:@"https://discord.com/api/oauth2/token"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSString *basic = [[[NSString stringWithFormat:@"%@:%@", DO_CLIENT_ID, DO_CLIENT_SECRET]
                        dataUsingEncoding:NSUTF8StringEncoding]
                       base64EncodedStringWithOptions:0];

    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Basic %@", basic] forHTTPHeaderField:@"Authorization"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *accessToken = nil;

    NSURLSessionDataTask *task =
    [[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data.length > 0) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                accessToken = [json[@"access_token"] isKindOfClass:[NSString class]] ? json[@"access_token"] : nil;
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return accessToken;
}

- (void)authorize {
    dispatch_async(self.cmdQueue, ^{
        if (self.didAuthorize || self.socketFD < 0) return;
        self.didAuthorize = YES;

        [self sendCommand:@"AUTHORIZE"
                     args:@{
                        @"client_id": DO_CLIENT_ID,
                        @"scopes": @[@"rpc",
                                      @"identify",
                                      @"guilds",
                                      @"rpc.voice.read",
                                      @"rpc.voice.write",
                                      @"rpc.notifications.read",
                                      @"messages.read"]
                     }
                      evt:nil];
    });
}

- (void)authenticate:(NSString *)accessToken {
    if (accessToken.length == 0) return;
    dispatch_async(self.cmdQueue, ^{
        [self sendCommand:@"AUTHENTICATE"
                     args:@{ @"access_token": accessToken }
                      evt:nil];
    });
}

- (void)getSelectedVoiceChannel {
    dispatch_async(self.cmdQueue, ^{
        if (!self.didAuthenticate) return;
        [self sendCommand:@"GET_SELECTED_VOICE_CHANNEL" args:nil evt:nil];
    });
}

- (void)getVoiceSettings {
    dispatch_async(self.cmdQueue, ^{
        if (!self.didAuthenticate) return;
        [self sendCommand:@"GET_VOICE_SETTINGS" args:nil evt:nil];
    });
}

- (void)setVoiceSettingsModifier:(NSDictionary *)modifier {
    dispatch_async(self.cmdQueue, ^{
        if (!self.didAuthenticate) return;
        BOOL ok = [self sendCommand:@"SET_VOICE_SETTINGS" args:modifier evt:nil];
        DOLog(@"SET_VOICE_SETTINGS sent=%d modifier=%@", ok, modifier);
        // Discord doesn't always emit VOICE_SETTINGS_UPDATE reliably in every host process;
        // force-refresh to keep currentMute/currentDeaf in sync for toggles.
        [self sendCommand:@"GET_VOICE_SETTINGS" args:nil evt:nil];
    });
}

- (void)subscribeVoiceSettingsEvents {
    if (!self.didAuthenticate || self.didSubscribeVoiceSettings) return;
    self.didSubscribeVoiceSettings = YES;
    [self sendCommand:@"SUBSCRIBE" args:@{} evt:@"VOICE_SETTINGS_UPDATE"];
}

- (void)subscribeNotificationEvents {
    if (!self.didAuthenticate || self.didSubscribeNotifications) return;
    self.didSubscribeNotifications = YES;
    [self sendCommand:@"SUBSCRIBE" args:@{} evt:@"NOTIFICATION_CREATE"];
}

- (void)subscribeVoiceChannelSelectionEvents {
    if (!self.didAuthenticate || self.didSubscribeVoiceChannelSelection) return;
    self.didSubscribeVoiceChannelSelection = YES;
    [self sendCommand:@"SUBSCRIBE" args:@{} evt:@"VOICE_CHANNEL_SELECT"];
}

- (void)subscribeVoiceChannelEvents:(NSString *)channelId {
    if (!self.didAuthenticate || channelId.length == 0) return;
    if ([self.subscribedChannelId isEqualToString:channelId]) return;

    [self unsubscribeVoiceChannelEvents:self.subscribedChannelId];
    self.subscribedChannelId = channelId;

    NSDictionary *args = @{ @"channel_id": channelId };
    [self sendCommand:@"SUBSCRIBE" args:args evt:@"VOICE_STATE_CREATE"];
    [self sendCommand:@"SUBSCRIBE" args:args evt:@"VOICE_STATE_UPDATE"];
    [self sendCommand:@"SUBSCRIBE" args:args evt:@"VOICE_STATE_DELETE"];
    [self sendCommand:@"SUBSCRIBE" args:args evt:@"SPEAKING_START"];
    [self sendCommand:@"SUBSCRIBE" args:args evt:@"SPEAKING_STOP"];
}

- (void)unsubscribeVoiceChannelEvents:(NSString *)channelId {
    if (!self.didAuthenticate || channelId.length == 0) return;
    NSDictionary *args = @{ @"channel_id": channelId };
    [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"VOICE_STATE_CREATE"];
    [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"VOICE_STATE_UPDATE"];
    [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"VOICE_STATE_DELETE"];
    [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"SPEAKING_START"];
    [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"SPEAKING_STOP"];
}

- (NSDictionary *)primaryGuildFromVoiceStateEntry:(NSDictionary *)vs source:(NSString **)source {
    NSDictionary *user = [vs[@"user"] isKindOfClass:[NSDictionary class]] ? vs[@"user"] : @{};
    NSDictionary *member = [vs[@"member"] isKindOfClass:[NSDictionary class]] ? vs[@"member"] : @{};
    NSDictionary *memberUser = [member[@"user"] isKindOfClass:[NSDictionary class]] ? member[@"user"] : @{};

    NSDictionary *candidates[] = {
        [user[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? user[@"primary_guild"] : nil,
        [user[@"clan"] isKindOfClass:[NSDictionary class]] ? user[@"clan"] : nil,
        [vs[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? vs[@"primary_guild"] : nil,
        [vs[@"clan"] isKindOfClass:[NSDictionary class]] ? vs[@"clan"] : nil,
        [memberUser[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? memberUser[@"primary_guild"] : nil,
        [memberUser[@"clan"] isKindOfClass:[NSDictionary class]] ? memberUser[@"clan"] : nil,
    };
    NSString *sources[] = {
        @"user.primary_guild",
        @"user.clan",
        @"primary_guild",
        @"clan",
        @"member.user.primary_guild",
        @"member.user.clan",
    };

    for (NSUInteger i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        NSDictionary *candidate = candidates[i];
        if (![candidate isKindOfClass:[NSDictionary class]]) continue;
        if (source) *source = sources[i];
        return candidate;
    }

    if (source) *source = @"none";
    return @{};
}

- (NSDictionary *)normalizedPrimaryGuildFromDictionary:(NSDictionary *)primaryGuild {
    if (![primaryGuild isKindOfClass:[NSDictionary class]]) return @{};

    NSString *guildId = [primaryGuild[@"identity_guild_id"] isKindOfClass:[NSString class]]
        ? primaryGuild[@"identity_guild_id"]
        : ([primaryGuild[@"guild_id"] isKindOfClass:[NSString class]] ? primaryGuild[@"guild_id"] : nil);
    NSString *tag = [primaryGuild[@"tag"] isKindOfClass:[NSString class]] ? primaryGuild[@"tag"] : nil;
    NSString *badge = [primaryGuild[@"badge"] isKindOfClass:[NSString class]] ? primaryGuild[@"badge"] : nil;
    id enabled = DOIsBoolLike(primaryGuild[@"identity_enabled"]) ? @([primaryGuild[@"identity_enabled"] boolValue]) : [NSNull null];

    if (guildId.length == 0 && tag.length == 0 && badge.length == 0) return @{};

    return @{
        @"identity_guild_id": guildId ?: (id)[NSNull null],
        @"identity_enabled": enabled,
        @"tag": tag ?: (id)[NSNull null],
        @"badge": badge ?: (id)[NSNull null]
    };
}

- (void)mergePrimaryGuild:(NSDictionary *)primaryGuild forUserId:(NSString *)userId {
    if (userId.length == 0 || primaryGuild.count == 0) return;
    if (![self.currentChannel[@"voice_states"] isKindOfClass:[NSMutableArray class]]) return;

    NSMutableArray *arr = self.currentChannel[@"voice_states"];
    for (NSMutableDictionary *entry in arr) {
        NSMutableDictionary *user = [entry[@"user"] isKindOfClass:[NSMutableDictionary class]]
            ? entry[@"user"]
            : ([entry[@"user"] isKindOfClass:[NSDictionary class]] ? [entry[@"user"] mutableCopy] : nil);
        if (![user[@"id"] isEqualToString:userId]) continue;
        user[@"primary_guild"] = [primaryGuild mutableCopy];
        entry[@"user"] = user;
        DOLog(@"voice primary_guild merged user=%@ primary=%@", userId, primaryGuild);
        break;
    }
}

- (NSMutableDictionary *)normalizedVoiceStateEntryFrom:(NSDictionary *)vs {
    NSDictionary *user = [vs[@"user"] isKindOfClass:[NSDictionary class]] ? vs[@"user"] : @{};
    NSDictionary *voiceState = [vs[@"voice_state"] isKindOfClass:[NSDictionary class]] ? vs[@"voice_state"] : @{};
    NSString *primaryGuildSource = nil;
    NSDictionary *primaryGuild = [self primaryGuildFromVoiceStateEntry:vs source:&primaryGuildSource];
    NSString *userId = [user[@"id"] isKindOfClass:[NSString class]] ? user[@"id"] : @"";

    static NSMutableSet<NSString *> *loggedPrimaryGuildUsers = nil;
    static dispatch_once_t loggedPrimaryGuildOnceToken;
    dispatch_once(&loggedPrimaryGuildOnceToken, ^{
        loggedPrimaryGuildUsers = [NSMutableSet set];
    });
    if (userId.length > 0 && ![loggedPrimaryGuildUsers containsObject:userId]) {
        [loggedPrimaryGuildUsers addObject:userId];
        NSArray *userKeys = [[user allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSArray *vsKeys = [[vs allKeys] sortedArrayUsingSelector:@selector(compare:)];
        DOLog(@"voice raw user primary_guild user=%@ source=%@ hasPrimary=%d userKeys=%@ vsKeys=%@ primary=%@",
              userId,
              primaryGuildSource ?: @"none",
              primaryGuild.count > 0 ? 1 : 0,
              [userKeys componentsJoinedByString:@","],
              [vsKeys componentsJoinedByString:@","],
              primaryGuild);
    }

    return [@{
        @"user": [@{
            @"id": [user[@"id"] isKindOfClass:[NSString class]] ? user[@"id"] : @"",
            @"username": [user[@"username"] isKindOfClass:[NSString class]] ? user[@"username"] : @"Unknown",
            @"global_name": [user[@"global_name"] isKindOfClass:[NSString class]] ? user[@"global_name"] : [NSNull null],
            @"avatar": [user[@"avatar"] isKindOfClass:[NSString class]] ? user[@"avatar"] : [NSNull null],
            @"primary_guild": [[self normalizedPrimaryGuildFromDictionary:primaryGuild] mutableCopy]
        } mutableCopy],
        @"voice_state": [@{
            @"mute": @([voiceState[@"mute"] respondsToSelector:@selector(boolValue)] ? [voiceState[@"mute"] boolValue] : NO),
            @"deaf": @([voiceState[@"deaf"] respondsToSelector:@selector(boolValue)] ? [voiceState[@"deaf"] boolValue] : NO),
            @"self_mute": @([voiceState[@"self_mute"] respondsToSelector:@selector(boolValue)] ? [voiceState[@"self_mute"] boolValue] : NO),
            @"self_deaf": @([voiceState[@"self_deaf"] respondsToSelector:@selector(boolValue)] ? [voiceState[@"self_deaf"] boolValue] : NO),
            @"suppress": @([voiceState[@"suppress"] respondsToSelector:@selector(boolValue)] ? [voiceState[@"suppress"] boolValue] : NO)
        } mutableCopy],
        @"speaking": @([vs[@"speaking"] respondsToSelector:@selector(boolValue)] ? [vs[@"speaking"] boolValue] : NO)
    } mutableCopy];
}

- (NSMutableDictionary *)normalizedChannelFrom:(NSDictionary *)channel {
    if (![channel isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableArray *voiceStates = [NSMutableArray array];
    NSArray *raw = [channel[@"voice_states"] isKindOfClass:[NSArray class]] ? channel[@"voice_states"] : @[];
    for (id item in raw) {
        if ([item isKindOfClass:[NSDictionary class]]) {
            [voiceStates addObject:[self normalizedVoiceStateEntryFrom:item]];
        }
    }

    return [@{
        @"id": [channel[@"id"] isKindOfClass:[NSString class]] ? channel[@"id"] : [NSNull null],
        @"guild_id": [channel[@"guild_id"] isKindOfClass:[NSString class]] ? channel[@"guild_id"] : [NSNull null],
        @"name": [channel[@"name"] isKindOfClass:[NSString class]] ? channel[@"name"] : @"Voice",
        @"voice_states": voiceStates
    } mutableCopy];
}

- (void)upsertVoiceState:(NSDictionary *)entry {
    if (![self.currentChannel[@"voice_states"] isKindOfClass:[NSMutableArray class]]) return;
    NSMutableDictionary *normalized = [self normalizedVoiceStateEntryFrom:entry];
    NSString *userId = normalized[@"user"][@"id"];
    if (userId.length == 0) return;

    NSMutableArray *arr = self.currentChannel[@"voice_states"];
    NSInteger idx = NSNotFound;
    for (NSInteger i = 0; i < arr.count; i++) {
        NSDictionary *e = arr[i];
        if ([e[@"user"][@"id"] isEqualToString:userId]) { idx = i; break; }
    }

    if (idx != NSNotFound) {
        NSMutableDictionary *prev = [arr[idx] mutableCopy];
        if ([prev[@"speaking"] respondsToSelector:@selector(boolValue)] &&
            ![entry[@"speaking"] respondsToSelector:@selector(boolValue)]) {
            normalized[@"speaking"] = prev[@"speaking"];
        }
        arr[idx] = normalized;
    } else {
        [arr addObject:normalized];
    }
}

- (void)removeVoiceState:(NSDictionary *)entry {
    if (![self.currentChannel[@"voice_states"] isKindOfClass:[NSMutableArray class]]) return;
    NSString *userId = [entry[@"user"] isKindOfClass:[NSDictionary class]] && [entry[@"user"][@"id"] isKindOfClass:[NSString class]]
        ? entry[@"user"][@"id"] : nil;
    if (userId.length == 0) return;

    NSMutableArray *arr = self.currentChannel[@"voice_states"];
    NSIndexSet *dead = [arr indexesOfObjectsPassingTest:^BOOL(NSDictionary *obj, NSUInteger idx, BOOL *stop) {
        return [obj[@"user"][@"id"] isEqualToString:userId];
    }];
    if (dead.count > 0) [arr removeObjectsAtIndexes:dead];
}

- (void)setSpeaking:(NSString *)userId speaking:(BOOL)speaking {
    if (![self.currentChannel[@"voice_states"] isKindOfClass:[NSMutableArray class]] || userId.length == 0) return;
    NSMutableArray *arr = self.currentChannel[@"voice_states"];
    for (NSMutableDictionary *e in arr) {
        if ([e[@"user"][@"id"] isEqualToString:userId]) {
            e[@"speaking"] = @(speaking);
            break;
        }
    }
}

- (NSArray<NSDictionary *> *)sortedVoiceStates:(NSArray<NSDictionary *> *)states {
    return [states sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL aSpeaking = [a[@"speaking"] boolValue];
        BOOL bSpeaking = [b[@"speaking"] boolValue];
        if (aSpeaking != bSpeaking) return aSpeaking ? NSOrderedAscending : NSOrderedDescending;

        NSDictionary *avs = a[@"voice_state"] ?: @{};
        NSDictionary *bvs = b[@"voice_state"] ?: @{};
        BOOL aMuted = [avs[@"self_mute"] boolValue] || [avs[@"mute"] boolValue];
        BOOL bMuted = [bvs[@"self_mute"] boolValue] || [bvs[@"mute"] boolValue];
        if (aMuted != bMuted) return aMuted ? NSOrderedDescending : NSOrderedAscending;

        NSString *an = [[a[@"user"][@"global_name"] isKindOfClass:[NSString class]] ? a[@"user"][@"global_name"] :
                        [a[@"user"][@"username"] isKindOfClass:[NSString class]] ? a[@"user"][@"username"] : @"" lowercaseString];
        NSString *bn = [[b[@"user"][@"global_name"] isKindOfClass:[NSString class]] ? b[@"user"][@"global_name"] :
                        [b[@"user"][@"username"] isKindOfClass:[NSString class]] ? b[@"user"][@"username"] : @"" lowercaseString];
        return [an compare:bn options:NSCaseInsensitiveSearch];
    }];
}

- (void)publishSharedState {
    NSDictionary *channel = self.currentChannel;
    NSArray *states = [channel[@"voice_states"] isKindOfClass:[NSArray class]] ? [self sortedVoiceStates:channel[@"voice_states"]] : @[];
    NSUInteger primaryGuildPayloadCount = 0;
    NSUInteger primaryGuildVisibleCount = 0;
    NSMutableArray<DOUser *> *users = [NSMutableArray array];
    for (NSDictionary *vs in states) {
        NSDictionary *user = [vs[@"user"] isKindOfClass:[NSDictionary class]] ? vs[@"user"] : @{};
        NSDictionary *voiceState = [vs[@"voice_state"] isKindOfClass:[NSDictionary class]] ? vs[@"voice_state"] : @{};
        NSDictionary *primaryGuild = [user[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? user[@"primary_guild"] : @{};
        NSString *uid = [user[@"id"] isKindOfClass:[NSString class]] ? user[@"id"] : @"";
        if (uid.length == 0) continue;
        NSDictionary *cachedPrimaryGuild = self.primaryGuildsByUserId[uid];
        if ((![primaryGuild isKindOfClass:[NSDictionary class]] || primaryGuild.count == 0) &&
            [cachedPrimaryGuild isKindOfClass:[NSDictionary class]] &&
            cachedPrimaryGuild.count > 0) {
            primaryGuild = cachedPrimaryGuild;
        }

        BOOL isSelf = self.currentUserId.length > 0 && [uid isEqualToString:self.currentUserId];

        DOUser *u = [DOUser new];
        u.userId = uid;
        u.name = [user[@"global_name"] isKindOfClass:[NSString class]] && [user[@"global_name"] length] > 0
            ? user[@"global_name"]
            : ([user[@"username"] isKindOfClass:[NSString class]] ? user[@"username"] : @"Unknown");
        u.avatarHash = [user[@"avatar"] isKindOfClass:[NSString class]] ? user[@"avatar"] : nil;
        BOOL primaryGuildEnabled = DOIsBoolLike(primaryGuild[@"identity_enabled"]) ? [primaryGuild[@"identity_enabled"] boolValue] : YES;
        NSString *primaryGuildId = [primaryGuild[@"identity_guild_id"] isKindOfClass:[NSString class]] ? primaryGuild[@"identity_guild_id"] : nil;
        NSString *primaryGuildTag = [primaryGuild[@"tag"] isKindOfClass:[NSString class]] ? primaryGuild[@"tag"] : nil;
        NSString *primaryGuildBadge = [primaryGuild[@"badge"] isKindOfClass:[NSString class]] ? primaryGuild[@"badge"] : nil;
        if (primaryGuildId.length > 0 || primaryGuildTag.length > 0 || primaryGuildBadge.length > 0) primaryGuildPayloadCount++;
        if (primaryGuildEnabled && primaryGuildTag.length > 0) {
            u.primaryGuildId = primaryGuildId;
            u.primaryGuildTag = primaryGuildTag;
            u.primaryGuildBadgeHash = primaryGuildBadge;
            primaryGuildVisibleCount++;
        } else {
            [self fetchPrimaryGuildForUserIdIfNeeded:uid];
        }
        u.speaking = [vs[@"speaking"] respondsToSelector:@selector(boolValue)] ? [vs[@"speaking"] boolValue] : NO;
        u.mute = isSelf ? ([voiceState[@"self_mute"] boolValue] || self.currentMute)
                        : ([voiceState[@"self_mute"] boolValue] || [voiceState[@"mute"] boolValue]);
        u.deaf = isSelf ? ([voiceState[@"self_deaf"] boolValue] || self.currentDeaf)
                        : ([voiceState[@"self_deaf"] boolValue] || [voiceState[@"deaf"] boolValue]);
        [users addObject:u];
    }

    NSString *channelName = [channel[@"name"] isKindOfClass:[NSString class]] ? channel[@"name"] : @"Voice";
    BOOL selfMute = self.currentMute;
    BOOL selfDeaf = self.currentDeaf;
    if (states.count > 0 &&
        (primaryGuildPayloadCount != self.lastLoggedPrimaryGuildPayloadCount ||
         primaryGuildVisibleCount != self.lastLoggedPrimaryGuildVisibleCount)) {
        self.lastLoggedPrimaryGuildPayloadCount = primaryGuildPayloadCount;
        self.lastLoggedPrimaryGuildVisibleCount = primaryGuildVisibleCount;
        DOLog(@"voice primary_guild payloads=%lu visibleTags=%lu users=%lu",
              (unsigned long)primaryGuildPayloadCount,
              (unsigned long)primaryGuildVisibleCount,
              (unsigned long)states.count);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        DOSharedState *s = [DOSharedState shared];
        s.channelName = channelName ?: @"Voice";
        s.users = users;
        s.selfMute = selfMute;
        s.selfDeaf = selfDeaf;
    });
}

- (void)addNotificationFromRPC:(NSDictionary *)data {
    NSString *title = [data[@"title"] isKindOfClass:[NSString class]] ? data[@"title"] : @"";
    NSString *body  = [data[@"body"]  isKindOfClass:[NSString class]] ? data[@"body"]  : @"";

    NSString *text = nil;
    if (title.length && body.length) text = [NSString stringWithFormat:@"%@: %@", title, body];
    else text = title.length ? title : body;

    if (text.length == 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        DONotification *n = [DONotification new];
        n.text = text;
        n.ttl = 6.0;
        n.createdAt = [NSDate date].timeIntervalSince1970;

        DOSharedState *s = [DOSharedState shared];
        [s.notifications insertObject:n atIndex:0];
        if (s.notifications.count > 30) {
            [s.notifications removeObjectsInRange:NSMakeRange(30, s.notifications.count - 30)];
        }
    });
}

- (void)processMessage:(NSDictionary *)msg {
    NSString *evt = [msg[@"evt"] isKindOfClass:[NSString class]] ? msg[@"evt"] : nil;
    NSString *cmd = [msg[@"cmd"] isKindOfClass:[NSString class]] ? msg[@"cmd"] : nil;

    if ([evt isEqualToString:@"READY"]) {
        NSDictionary *data = [msg[@"data"] isKindOfClass:[NSDictionary class]] ? msg[@"data"] : @{};
        NSDictionary *user = [data[@"user"] isKindOfClass:[NSDictionary class]] ? data[@"user"] : @{};
        self.currentUserId = [user[@"id"] isKindOfClass:[NSString class]] ? user[@"id"] : nil;
        DOLog(@"IPC READY. currentUserId=%@", self.currentUserId);
        // OAuth required for voice scopes (4006 otherwise).
        self.didAuthenticate = NO;
        self.didAuthorize = NO;
        [self authorize];
        return;
    }

    if ([evt isEqualToString:@"ERROR"]) {
        NSLog(@"[ipc] RPC ERROR: %@", msg[@"data"]);
        DOLog(@"IPC ERROR evt data=%@", msg[@"data"]);
        // 4006: Not authenticated or invalid scope → retry authorize.
        NSNumber *code = [msg[@"data"][@"code"] respondsToSelector:@selector(integerValue)] ? msg[@"data"][@"code"] : nil;
        if (code.integerValue == 4006) {
            self.didAuthenticate = NO;
            self.didAuthorize = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), self.cmdQueue, ^{
                [self authorize];
            });
        }
        return;
    }

    if ([cmd isEqualToString:@"AUTHORIZE"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSString *code = [msg[@"data"][@"code"] isKindOfClass:[NSString class]] ? msg[@"data"][@"code"] : nil;
        DOLog(@"AUTHORIZE response codeLen=%lu", (unsigned long)code.length);
        if (code.length > 0) {
            NSString *accessToken = [self exchangeTokenSync:code];
            DOLog(@"token exchange: %s", (accessToken.length > 0 ? "ok" : "failed"));
            if (accessToken.length > 0) {
                self.accessToken = accessToken;
                [self authenticate:accessToken];
            }
        }
        return;
    }

    if ([cmd isEqualToString:@"AUTHENTICATE"] && evt == nil) {
        self.didAuthenticate = YES;
        DOLog(@"AUTHENTICATE ok");
        [self subscribeVoiceSettingsEvents];
        [self subscribeNotificationEvents];
        [self subscribeVoiceChannelSelectionEvents];
        [self getVoiceSettings];
        [self getSelectedVoiceChannel];
        [self bootstrapTextChatIfNeeded];
        [self refreshGuildIconsFromREST];
        [self refreshGuildFoldersFromREST];
        return;
    }

    if ([evt isEqualToString:@"NOTIFICATION_CREATE"]) {
        [self addNotificationFromRPC:[msg[@"data"] isKindOfClass:[NSDictionary class]] ? msg[@"data"] : @{}];
        return;
    }

    if ([cmd isEqualToString:@"GET_VOICE_SETTINGS"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        self.currentMute = [msg[@"data"][@"mute"] respondsToSelector:@selector(boolValue)] ? [msg[@"data"][@"mute"] boolValue] : NO;
        self.currentDeaf = [msg[@"data"][@"deaf"] respondsToSelector:@selector(boolValue)] ? [msg[@"data"][@"deaf"] boolValue] : NO;
        DOLog(@"VOICE_SETTINGS mute=%d deaf=%d", self.currentMute, self.currentDeaf);
        [self publishSharedState];
        return;
    }

    if ([evt isEqualToString:@"VOICE_SETTINGS_UPDATE"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        self.currentMute = [msg[@"data"][@"mute"] respondsToSelector:@selector(boolValue)] ? [msg[@"data"][@"mute"] boolValue] : NO;
        self.currentDeaf = [msg[@"data"][@"deaf"] respondsToSelector:@selector(boolValue)] ? [msg[@"data"][@"deaf"] boolValue] : NO;
        [self publishSharedState];
        return;
    }

    if ([cmd isEqualToString:@"GET_SELECTED_VOICE_CHANNEL"]) {
        NSDictionary *data = [msg[@"data"] isKindOfClass:[NSDictionary class]] ? msg[@"data"] : nil;
        self.currentChannel = [self normalizedChannelFrom:data] ?: [NSMutableDictionary dictionary];
        NSString *channelId = [self.currentChannel[@"id"] isKindOfClass:[NSString class]] ? self.currentChannel[@"id"] : nil;
        DOLog(@"SELECTED_VOICE_CHANNEL id=%@ name=%@", channelId, self.currentChannel[@"name"]);

        if (channelId.length > 0) {
            [self subscribeVoiceChannelEvents:channelId];
        } else if (self.subscribedChannelId.length > 0) {
            [self unsubscribeVoiceChannelEvents:self.subscribedChannelId];
            self.subscribedChannelId = nil;
        }

        [self publishSharedState];
        return;
    }

    if ([cmd isEqualToString:@"GET_GUILDS"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSArray *guildArr = [msg[@"data"][@"guilds"] isKindOfClass:[NSArray class]] ? msg[@"data"][@"guilds"] : @[];
        NSMutableArray<DOChatGuild *> *guilds = [NSMutableArray array];
        NSUInteger guildIconCount = 0;
        for (id g in guildArr) {
            NSDictionary *gd = [g isKindOfClass:[NSDictionary class]] ? g : @{};
            NSString *gid = [gd[@"id"] isKindOfClass:[NSString class]] ? gd[@"id"] : @"";
            NSString *name = [gd[@"name"] isKindOfClass:[NSString class]] ? gd[@"name"] : @"";
            NSString *icon = [gd[@"icon"] isKindOfClass:[NSString class]] ? gd[@"icon"] : nil;
            if (gid.length == 0) continue;
            DOChatGuild *gg = [DOChatGuild new];
            gg.guildId = gid;
            gg.name = (name.length > 0 ? name : gid);
            gg.iconHash = icon;
            if (icon.length > 0) {
                self.guildIconHashes[gid] = icon;
                guildIconCount++;
            } else {
                [self.guildIconHashes removeObjectForKey:gid];
            }
            [guilds addObject:gg];
        }
        DOLog(@"GET_GUILDS parsed guilds=%lu icons=%lu", (unsigned long)guilds.count, (unsigned long)guildIconCount);

        NSString *firstGuildId = guilds.count > 0 ? guilds.firstObject.guildId : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            s.guilds = guilds;
            s.selectedGuildId = firstGuildId ?: @"";
            // Clear dependent panes.
            s.channels = @[];
            [s.messages removeAllObjects];
        });

        [self publishSharedState];
        [self refreshGuildIconsFromREST];
        [self refreshGuildFoldersFromREST];
        if (firstGuildId.length > 0) [self selectTextGuildId:firstGuildId];
        return;
    }

    if ([cmd isEqualToString:@"GET_CHANNELS"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSArray *chArr = [msg[@"data"][@"channels"] isKindOfClass:[NSArray class]] ? msg[@"data"][@"channels"] : @[];
        NSMutableArray<DOChatChannel *> *channels = [NSMutableArray array];
        for (id c in chArr) {
            NSDictionary *cd = [c isKindOfClass:[NSDictionary class]] ? c : @{};
            NSString *cid = [cd[@"id"] isKindOfClass:[NSString class]] ? cd[@"id"] : @"";
            NSString *name = [cd[@"name"] isKindOfClass:[NSString class]] ? cd[@"name"] : @"";
            NSString *guildId = [cd[@"guild_id"] isKindOfClass:[NSString class]] ? cd[@"guild_id"] : (self.currentChannel[@"guild_id"] ?: @"");
            NSInteger type = [cd[@"type"] respondsToSelector:@selector(integerValue)] ? [cd[@"type"] integerValue] : -1;
            if (cid.length == 0) continue;
            // type 0 = guild text (doc). We'll still allow others if present.
            DOChatChannel *cc = [DOChatChannel new];
            cc.channelId = cid;
            cc.name = (name.length > 0 ? name : cid);
            cc.guildId = guildId ?: @"";
            cc.type = type;
            [channels addObject:cc];
        }

        NSString *firstChannelId = @"";
        for (DOChatChannel *cc in channels) {
            if (cc.type == 0) {
                firstChannelId = cc.channelId ?: @"";
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            s.channels = channels;
            s.selectedChannelId = firstChannelId ?: @"";
            [s.messages removeAllObjects];
        });

        if (firstChannelId.length > 0) [self selectTextChannelId:firstChannelId];
        return;
    }

    if ([cmd isEqualToString:@"SELECT_TEXT_CHANNEL"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *data = msg[@"data"];
        NSString *channelId = [data[@"id"] isKindOfClass:[NSString class]] ? data[@"id"] : nil;
        if (channelId.length == 0) return;

        NSArray *messagesArr = [data[@"messages"] isKindOfClass:[NSArray class]] ? data[@"messages"] : @[];
        NSMutableArray<DOChatMessage *> *messages = [NSMutableArray array];
        for (id m in messagesArr) {
            NSDictionary *md = [m isKindOfClass:[NSDictionary class]] ? m : @{};
            NSString *mid = [md[@"id"] isKindOfClass:[NSString class]] ? md[@"id"] : @"";
            NSString *content = [md[@"content"] isKindOfClass:[NSString class]] ? md[@"content"] : @"";
            NSString *authorName = @"";
            NSString *authorId = @"";
            NSString *authorAvatarHash = nil;
            NSDictionary *author = [md[@"author"] isKindOfClass:[NSDictionary class]] ? md[@"author"] : nil;
            if (author) {
                authorId = [author[@"id"] isKindOfClass:[NSString class]] ? author[@"id"] : @"";
                authorAvatarHash = [author[@"avatar"] isKindOfClass:[NSString class]] ? author[@"avatar"] : nil;
                authorName = [author[@"global_name"] isKindOfClass:[NSString class]] && [author[@"global_name"] length] > 0
                    ? author[@"global_name"]
                    : ([author[@"username"] isKindOfClass:[NSString class]] ? author[@"username"] : @"");
            }
            if (mid.length == 0) continue;
            DOChatMessage *cm = [DOChatMessage new];
            cm.messageId = mid;
            cm.authorId = authorId ?: @"";
            cm.authorAvatarHash = authorAvatarHash;
            cm.authorName = (authorName.length > 0 ? authorName : @"Unknown");
            cm.content = content ?: @"";
            cm.createdAt = 0;
            NSString *ts = [md[@"timestamp"] isKindOfClass:[NSString class]] ? md[@"timestamp"] : nil;
            // Timestamp string parsing isn't required for rendering; leave as 0.
            (void)ts;
            [messages addObject:cm];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            s.selectedChannelId = channelId;
            // No reliable guild_id in the GET_CHANNELS sample; keep current selection for sidebar.
            [s.messages removeAllObjects];
            [s.messages addObjectsFromArray:messages];
        });

        NSDictionary *args = @{ @"channel_id": channelId };
        [self sendCommand:@"SUBSCRIBE" args:args evt:@"MESSAGE_CREATE"];
        [self sendCommand:@"SUBSCRIBE" args:args evt:@"MESSAGE_UPDATE"];
        [self sendCommand:@"SUBSCRIBE" args:args evt:@"MESSAGE_DELETE"];
        self.didSubscribeTextChannelEvents = YES;
        return;
    }

    if ([evt isEqualToString:@"MESSAGE_CREATE"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *data = msg[@"data"];
        NSString *eventChannelId = [data[@"channel_id"] isKindOfClass:[NSString class]] ? data[@"channel_id"] : nil;
        if (eventChannelId.length > 0 &&
            self.subscribedTextChannelId.length > 0 &&
            ![eventChannelId isEqualToString:self.subscribedTextChannelId]) {
            return;
        }
        NSDictionary *message = [data[@"message"] isKindOfClass:[NSDictionary class]] ? data[@"message"] : nil;
        if (!message) return;

        NSString *mid = [message[@"id"] isKindOfClass:[NSString class]] ? message[@"id"] : @"";
        if (mid.length == 0) return;

        NSString *content = [message[@"content"] isKindOfClass:[NSString class]] ? message[@"content"] : @"";
        NSString *authorName = @"Unknown";
        NSString *authorId = @"";
        NSString *authorAvatarHash = nil;
        NSDictionary *author = [message[@"author"] isKindOfClass:[NSDictionary class]] ? message[@"author"] : nil;
        if (author) {
            authorId = [author[@"id"] isKindOfClass:[NSString class]] ? author[@"id"] : @"";
            authorAvatarHash = [author[@"avatar"] isKindOfClass:[NSString class]] ? author[@"avatar"] : nil;
            authorName = ([author[@"global_name"] isKindOfClass:[NSString class]] && [author[@"global_name"] length] > 0)
                ? author[@"global_name"]
                : ([author[@"username"] isKindOfClass:[NSString class]] ? author[@"username"] : @"Unknown");
        }

        DOChatMessage *m = [DOChatMessage new];
        m.messageId = mid;
        m.authorId = authorId ?: @"";
        m.authorAvatarHash = authorAvatarHash;
        m.authorName = authorName;
        m.content = content ?: @"";
        m.createdAt = 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            // Avoid duplicates by message id.
            for (DOChatMessage *existing in s.messages) {
                if ([existing.messageId isEqualToString:mid]) return;
            }
            [s.messages addObject:m];
            if (s.messages.count > 200) {
                [s.messages removeObjectsInRange:NSMakeRange(0, s.messages.count - 200)];
            }
        });
        return;
    }

    if ([evt isEqualToString:@"MESSAGE_UPDATE"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *data = msg[@"data"];
        NSString *eventChannelId = [data[@"channel_id"] isKindOfClass:[NSString class]] ? data[@"channel_id"] : nil;
        if (eventChannelId.length > 0 &&
            self.subscribedTextChannelId.length > 0 &&
            ![eventChannelId isEqualToString:self.subscribedTextChannelId]) {
            return;
        }
        NSDictionary *message = [data[@"message"] isKindOfClass:[NSDictionary class]] ? data[@"message"] : nil;
        if (!message) return;

        NSString *mid = [message[@"id"] isKindOfClass:[NSString class]] ? message[@"id"] : @"";
        if (mid.length == 0) return;

        NSString *content = [message[@"content"] isKindOfClass:[NSString class]] ? message[@"content"] : @"";

        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            for (DOChatMessage *existing in s.messages) {
                if ([existing.messageId isEqualToString:mid]) {
                    existing.content = content ?: @"";
                    break;
                }
            }
        });
        return;
    }

    if ([evt isEqualToString:@"MESSAGE_DELETE"] && [msg[@"data"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary *data = msg[@"data"];
        NSString *eventChannelId = [data[@"channel_id"] isKindOfClass:[NSString class]] ? data[@"channel_id"] : nil;
        if (eventChannelId.length > 0 &&
            self.subscribedTextChannelId.length > 0 &&
            ![eventChannelId isEqualToString:self.subscribedTextChannelId]) {
            return;
        }
        NSString *mid = [data[@"id"] isKindOfClass:[NSString class]] ? data[@"id"] : @"";
        if (mid.length == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            NSIndexSet *dead = [s.messages indexesOfObjectsPassingTest:^BOOL(DOChatMessage *obj, NSUInteger idx, BOOL *stop) {
                return [obj.messageId isEqualToString:mid];
            }];
            if (dead.count > 0) [s.messages removeObjectsAtIndexes:dead];
        });
        return;
    }

    if ([evt isEqualToString:@"VOICE_CHANNEL_SELECT"]) {
        [self getSelectedVoiceChannel];
        return;
    }

    if ([evt isEqualToString:@"VOICE_STATE_CREATE"]) {
        [self upsertVoiceState:[msg[@"data"] isKindOfClass:[NSDictionary class]] ? msg[@"data"] : @{}];
        [self publishSharedState];
        return;
    }

    if ([evt isEqualToString:@"VOICE_STATE_UPDATE"]) {
        [self upsertVoiceState:[msg[@"data"] isKindOfClass:[NSDictionary class]] ? msg[@"data"] : @{}];
        [self publishSharedState];
        return;
    }

    if ([evt isEqualToString:@"VOICE_STATE_DELETE"]) {
        [self removeVoiceState:[msg[@"data"] isKindOfClass:[NSDictionary class]] ? msg[@"data"] : @{}];
        [self publishSharedState];
        return;
    }

    if ([evt isEqualToString:@"SPEAKING_START"]) {
        NSString *uid = [msg[@"data"][@"user_id"] isKindOfClass:[NSString class]] ? msg[@"data"][@"user_id"] : nil;
        [self setSpeaking:uid speaking:YES];
        [self publishSharedState];
        return;
    }

    if ([evt isEqualToString:@"SPEAKING_STOP"]) {
        NSString *uid = [msg[@"data"][@"user_id"] isKindOfClass:[NSString class]] ? msg[@"data"][@"user_id"] : nil;
        [self setSpeaking:uid speaking:NO];
        [self publishSharedState];
        return;
    }
}

- (void)readLoop {
    while (1) {
        NSData *header = [self readExact:8];
        if (!header || header.length != 8) break;

        const int32_t *h = (const int32_t *)header.bytes;
        int32_t op = h[0];
        int32_t len = h[1];
        if (len <= 0 || len > 10 * 1024 * 1024) break;

        NSData *payload = [self readExact:(NSUInteger)len];
        if (!payload || payload.length != (NSUInteger)len) break;

        if (op != 1) continue;

        id json = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]]) {
            [self processMessage:json];
        }
    }

    if (self.socketFD >= 0) {
        int fd;
        @synchronized (self) {
            fd = self.socketFD;
            self.socketFD = -1;
        }
        if (fd >= 0) close(fd);
    }

    [self resetSessionState];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), self.queue, ^{
        [self start];
    });
}

- (void)start {
    dispatch_async(self.queue, ^{
        [self resetSessionState];
        if (![self connectSocket]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), self.queue, ^{
                [self start];
            });
            return;
        }

        if (![self sendHandshake]) {
            int fd;
            @synchronized (self) {
                fd = self.socketFD;
                self.socketFD = -1;
            }
            if (fd >= 0) close(fd);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), self.queue, ^{
                [self start];
            });
            return;
        }

        [self readLoop];
    });
}

- (void)toggleMute {
    dispatch_async(self.cmdQueue, ^{
        if (self.socketFD < 0) return;
        DOLog(@"callbar: toggleMute pressed (cur=%d)", self.currentMute);
        id v = self.currentMute ? @NO : @YES; // ensure JSON boolean (true/false), not 0/1
        [self setVoiceSettingsModifier:@{ @"mute": v }];
    });
}

- (void)toggleDeafen {
    dispatch_async(self.cmdQueue, ^{
        if (self.socketFD < 0) return;
        DOLog(@"callbar: toggleDeafen pressed (cur=%d)", self.currentDeaf);
        id v = self.currentDeaf ? @NO : @YES; // ensure JSON boolean (true/false), not 0/1
        [self setVoiceSettingsModifier:@{ @"deaf": v }];
    });
}

- (void)disconnectVoice {
    dispatch_async(self.cmdQueue, ^{
        if (self.socketFD < 0) return;
        BOOL ok = [self sendCommand:@"SELECT_VOICE_CHANNEL" args:@{ @"channel_id": [NSNull null] } evt:nil];
        DOLog(@"SELECT_VOICE_CHANNEL(null) sent=%d", ok);
    });
}

- (void)handleMoreOptions {
    NSLog(@"[ipc] more_options pressed");
}

- (void)bootstrapTextChatIfNeeded {
    dispatch_async(self.cmdQueue, ^{
        if (self.didLoadTextGuilds) return;
        self.didLoadTextGuilds = YES;
        [self sendCommand:@"GET_GUILDS" args:nil evt:nil];
    });
}

- (void)refreshGuildIconsFromREST {
    NSString *token = self.accessToken ?: @"";
    if (token.length == 0) {
        DOLog(@"REST guild icon refresh skipped: no access token");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://discord.com/api/users/@me/guilds"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:10.0];
    req.HTTPMethod = @"GET";
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || data.length == 0 || status < 200 || status >= 300) {
            DOLog(@"REST guild icon refresh failed status=%ld bytes=%lu error=%@",
                  (long)status,
                  (unsigned long)data.length,
                  error.localizedDescription ?: @"");
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSArray class]]) {
            DOLog(@"REST guild icon refresh invalid json status=%ld bytes=%lu",
                  (long)status,
                  (unsigned long)data.length);
            return;
        }

        NSMutableDictionary<NSString *, NSString *> *iconsByGuildId = [NSMutableDictionary dictionary];
        for (id item in (NSArray *)json) {
            NSDictionary *g = [item isKindOfClass:[NSDictionary class]] ? item : nil;
            NSString *gid = [g[@"id"] isKindOfClass:[NSString class]] ? g[@"id"] : nil;
            NSString *icon = [g[@"icon"] isKindOfClass:[NSString class]] ? g[@"icon"] : nil;
            if (gid.length > 0 && icon.length > 0) iconsByGuildId[gid] = icon;
        }

        DOLog(@"REST guild icon refresh guilds=%lu icons=%lu",
              (unsigned long)[(NSArray *)json count],
              (unsigned long)iconsByGuildId.count);

        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            NSMutableArray<DOChatGuild *> *merged = [NSMutableArray arrayWithCapacity:s.guilds.count];
            for (DOChatGuild *old in s.guilds ?: @[]) {
                DOChatGuild *copy = [old copy];
                NSString *icon = iconsByGuildId[copy.guildId ?: @""];
                if (icon.length > 0) copy.iconHash = icon;
                [merged addObject:copy];
            }
            if (merged.count > 0) s.guilds = merged;
        });
    }];
    [task resume];
}

- (NSColor *)chatFolderColorFromValue:(id)value {
    if (![value respondsToSelector:@selector(integerValue)]) {
        return [NSColor colorWithCalibratedWhite:0.20 alpha:1.0];
    }
    NSInteger rgb = [value integerValue];
    if (rgb <= 0) return [NSColor colorWithCalibratedWhite:0.20 alpha:1.0];
    CGFloat r = ((rgb >> 16) & 0xff) / 255.0;
    CGFloat g = ((rgb >> 8) & 0xff) / 255.0;
    CGFloat b = (rgb & 0xff) / 255.0;
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
}

- (NSArray<DOChatGuild *> *)guildSidebarItemsByApplyingFolders:(NSArray *)folders
                                                       guilds:(NSArray<DOChatGuild *> *)guilds {
    if (![folders isKindOfClass:[NSArray class]] || folders.count == 0) return guilds ?: @[];

    NSMutableDictionary<NSString *, DOChatGuild *> *guildById = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *originalOrder = [NSMutableArray array];
    for (DOChatGuild *g in guilds ?: @[]) {
        if (g.folder || g.guildId.length == 0) continue;
        guildById[g.guildId] = g;
        [originalOrder addObject:g.guildId];
    }

    NSMutableSet<NSString *> *usedGuildIds = [NSMutableSet set];
    NSMutableArray<DOChatGuild *> *items = [NSMutableArray array];
    NSUInteger unnamedFolderIndex = 1;

    for (id item in folders) {
        NSDictionary *fd = [item isKindOfClass:[NSDictionary class]] ? item : nil;
        NSArray *guildIds = [fd[@"guild_ids"] isKindOfClass:[NSArray class]] ? fd[@"guild_ids"] : @[];
        NSMutableArray<NSString *> *validGuildIds = [NSMutableArray array];
        for (id gidObj in guildIds) {
            NSString *gid = [gidObj isKindOfClass:[NSString class]] ? gidObj : nil;
            if (gid.length == 0 || !guildById[gid]) continue;
            [validGuildIds addObject:gid];
        }
        if (validGuildIds.count == 0) continue;

        NSString *folderId = [fd[@"id"] isKindOfClass:[NSString class]] ? fd[@"id"] : @"";
        NSString *name = [fd[@"name"] isKindOfClass:[NSString class]] ? fd[@"name"] : @"";
        BOOL hasFolderContainer = (folderId.length > 0 || name.length > 0 || validGuildIds.count > 1);

        if (hasFolderContainer) {
            DOChatGuild *folder = [DOChatGuild new];
            folder.folder = YES;
            folder.folderId = folderId.length > 0 ? folderId : [NSString stringWithFormat:@"folder-%lu", (unsigned long)unnamedFolderIndex++];
            folder.name = name.length > 0 ? name : @"Folder";
            folder.folderGuildIds = validGuildIds;
            folder.folderColor = [self chatFolderColorFromValue:fd[@"color"]];
            [items addObject:folder];
        }

        for (NSString *gid in validGuildIds) {
            DOChatGuild *g = guildById[gid];
            if (!g) continue;
            [items addObject:g];
            [usedGuildIds addObject:gid];
        }
    }

    for (NSString *gid in originalOrder) {
        if ([usedGuildIds containsObject:gid]) continue;
        DOChatGuild *g = guildById[gid];
        if (g) [items addObject:g];
    }

    return items.count > 0 ? items : (guilds ?: @[]);
}

- (void)refreshGuildFoldersFromREST {
    NSString *authorization = DOProfileAuthorizationHeader();
    if (authorization.length == 0) {
        DOLog(@"REST guild folders skipped: no profile authorization");
        return;
    }

    NSURL *url = [NSURL URLWithString:@"https://discord.com/api/v9/users/@me/settings"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:10.0];
    req.HTTPMethod = @"GET";
    [req setValue:authorization forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;
        if (error || data.length == 0 || status < 200 || status >= 300) {
            NSString *body = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (body.length > 180) body = [[body substringToIndex:180] stringByAppendingString:@"..."];
            DOLog(@"REST guild folders failed status=%ld bytes=%lu error=%@ body=%@",
                  (long)status,
                  (unsigned long)data.length,
                  error.localizedDescription ?: @"",
                  body ?: @"");
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *settings = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        NSArray *folders = [settings[@"guild_folders"] isKindOfClass:[NSArray class]] ? settings[@"guild_folders"] : nil;
        if (!folders) {
            DOLog(@"REST guild folders missing guild_folders status=%ld bytes=%lu",
                  (long)status,
                  (unsigned long)data.length);
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            NSArray<DOChatGuild *> *merged = [self guildSidebarItemsByApplyingFolders:folders guilds:s.guilds ?: @[]];
            s.guilds = merged;
            DOLog(@"REST guild folders folders=%lu sidebarItems=%lu",
                  (unsigned long)folders.count,
                  (unsigned long)merged.count);
        });
    }];
    [task resume];
}

- (void)fetchPrimaryGuildForUserIdIfNeeded:(NSString *)userId {
    if (userId.length == 0) return;
    if (self.primaryGuildsByUserId[userId]) return;
    if ([self.loadingPrimaryGuildUserIds containsObject:userId]) return;

    NSString *token = self.accessToken ?: @"";
    if (token.length == 0) return;

    [self.loadingPrimaryGuildUserIds addObject:userId];

    BOOL isCurrentUser = self.currentUserId.length > 0 && [userId isEqualToString:self.currentUserId];
    NSString *urlString = isCurrentUser
        ? @"https://discord.com/api/users/@me"
        : [NSString stringWithFormat:@"https://discord.com/api/v9/users/%@/profile", userId];
    NSString *profileAuthorizationEnv = !isCurrentUser ? DOTrimmedSecretString(DOEnvString("DISCORD_PROFILE_AUTHORIZATION")) : nil;
    NSString *profileAuthorizationFile = (!isCurrentUser && profileAuthorizationEnv.length == 0) ? DOProfileAuthorizationFromFile() : nil;
    NSString *profileAuthorizationValue = profileAuthorizationEnv.length > 0 ? profileAuthorizationEnv : profileAuthorizationFile;
    NSString *authorization = profileAuthorizationValue.length > 0
        ? profileAuthorizationValue
        : [NSString stringWithFormat:@"Bearer %@", token];
    NSString *authSource = profileAuthorizationEnv.length > 0 ? @"env" : (profileAuthorizationFile.length > 0 ? @"file" : @"oauth");
    DOLog(@"REST user primary_guild fetch user=%@ current=%d endpoint=%@ auth=%@",
          userId,
          isCurrentUser ? 1 : 0,
          isCurrentUser ? @"@me" : @"profile",
          authSource);
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:10.0];
    req.HTTPMethod = @"GET";
    [req setValue:authorization forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
                                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? [(NSHTTPURLResponse *)response statusCode] : 0;

        if (error || data.length == 0 || status < 200 || status >= 300) {
            NSString *body = data.length > 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (body.length > 180) body = [[body substringToIndex:180] stringByAppendingString:@"..."];
            DOLog(@"REST user primary_guild failed user=%@ current=%d endpoint=%@ auth=%@ status=%ld bytes=%lu error=%@ body=%@",
                  userId,
                  isCurrentUser ? 1 : 0,
                  isCurrentUser ? @"@me" : @"profile",
                  authSource,
                  (long)status,
                  (unsigned long)data.length,
                  error.localizedDescription ?: @"",
                  body ?: @"");
            dispatch_async(self.cmdQueue, ^{
                [self.loadingPrimaryGuildUserIds removeObject:userId];
                if (status != 429) self.primaryGuildsByUserId[userId] = @{};
            });
            return;
        }

        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *root = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        NSDictionary *profileUser = [root[@"user"] isKindOfClass:[NSDictionary class]] ? root[@"user"] : nil;
        NSDictionary *userProfile = [root[@"user_profile"] isKindOfClass:[NSDictionary class]] ? root[@"user_profile"] : nil;
        NSString *primarySource =
            [root[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? @"root.primary_guild" :
            [profileUser[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? @"user.primary_guild" :
            [userProfile[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? @"user_profile.primary_guild" :
            @"none";
        NSDictionary *primaryGuildRaw =
            [root[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? root[@"primary_guild"] :
            [profileUser[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? profileUser[@"primary_guild"] :
            [userProfile[@"primary_guild"] isKindOfClass:[NSDictionary class]] ? userProfile[@"primary_guild"] :
            nil;
        NSDictionary *primaryGuild = primaryGuildRaw ? [self normalizedPrimaryGuildFromDictionary:primaryGuildRaw] : @{};
        NSArray *keys = root ? [[root allKeys] sortedArrayUsingSelector:@selector(compare:)] : @[];
        NSArray *userKeys = profileUser ? [[profileUser allKeys] sortedArrayUsingSelector:@selector(compare:)] : @[];
        NSArray *profileKeys = userProfile ? [[userProfile allKeys] sortedArrayUsingSelector:@selector(compare:)] : @[];

        DOLog(@"REST user primary_guild user=%@ current=%d endpoint=%@ auth=%@ status=%ld source=%@ keys=%@ userKeys=%@ profileKeys=%@ primary=%@",
              userId,
              isCurrentUser ? 1 : 0,
              isCurrentUser ? @"@me" : @"profile",
              authSource,
              (long)status,
              primarySource,
              [keys componentsJoinedByString:@","],
              [userKeys componentsJoinedByString:@","],
              [profileKeys componentsJoinedByString:@","],
              primaryGuild);

        dispatch_async(self.cmdQueue, ^{
            [self.loadingPrimaryGuildUserIds removeObject:userId];
            self.primaryGuildsByUserId[userId] = primaryGuild ?: @{};
            if (primaryGuild.count > 0) {
                [self mergePrimaryGuild:primaryGuild forUserId:userId];
                [self publishSharedState];
            }
        });
    }];
    [task resume];
}

- (void)selectTextGuildId:(NSString *)guildId {
    if (guildId.length == 0) return;
    dispatch_async(self.cmdQueue, ^{
        if (!self.didAuthenticate) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            s.selectedGuildId = guildId ?: @"";
            s.channels = @[];
            s.selectedChannelId = @"";
            [s.messages removeAllObjects];
        });
        [self sendCommand:@"GET_CHANNELS" args:@{ @"guild_id": guildId } evt:nil];
    });
}

- (void)selectTextChannelId:(NSString *)channelId {
    if (channelId.length == 0) return;
    dispatch_async(self.cmdQueue, ^{
        if (!self.didAuthenticate) return;

        if (self.subscribedTextChannelId.length > 0 &&
            ![self.subscribedTextChannelId isEqualToString:channelId]) {
            NSDictionary *args = @{ @"channel_id": self.subscribedTextChannelId };
            [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"MESSAGE_CREATE"];
            [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"MESSAGE_UPDATE"];
            [self sendCommand:@"UNSUBSCRIBE" args:args evt:@"MESSAGE_DELETE"];
        }

        self.subscribedTextChannelId = channelId;
        self.didSubscribeTextChannelEvents = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            s.selectedChannelId = channelId ?: @"";
            [s.messages removeAllObjects];
        });
        [self sendCommand:@"SELECT_TEXT_CHANNEL" args:@{ @"channel_id": channelId } evt:nil];
    });
}

- (void)joinVoiceChannelId:(NSString *)channelId {
    if (channelId.length == 0) return;
    dispatch_async(self.cmdQueue, ^{
        if (!self.didAuthenticate) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DOSharedState *s = [DOSharedState shared];
            s.selectedChannelId = channelId ?: @"";
            [s.messages removeAllObjects];
        });
        BOOL ok = [self sendCommand:@"SELECT_VOICE_CHANNEL" args:@{ @"channel_id": channelId } evt:nil];
        DOLog(@"SELECT_VOICE_CHANNEL(%@) sent=%d", channelId, ok);
    });
}

@end

#pragma mark - Voice View

@interface DOVoiceView : NSView
@property (nonatomic, strong) NSArray<DOUser *> *users;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, assign) BOOL editMode;
@property (nonatomic, assign) BOOL showOutsideEditMode;
@property (nonatomic, copy) void (^toggleVisibilityHandler)(void);
@property (nonatomic, assign) NSWindow *hostWindow;
@property (nonatomic, assign) NSPoint dragStartScreen;
@property (nonatomic, assign) NSPoint dragWindowOrigin;
@property (nonatomic, assign) CGFloat animationPhase;
@property (nonatomic, assign) BOOL isDragging;
@end

@implementation DOVoiceView

- (BOOL)isFlipped { return YES; }
- (CGFloat)panelWidth { return self.bounds.size.width; }
- (CGFloat)rowHeight { return 56.0; }
- (CGFloat)headerHeight { return 36.0; }

- (CGFloat)panelHeight {
    CGFloat top = 10.0;
    CGFloat bottom = 12.0;
    return MAX(96.0, top + [self headerHeight] + (self.users.count * [self rowHeight]) + bottom);
}

- (NSRect)panelRect {
    return NSMakeRect(0, 0, [self panelWidth], [self panelHeight]);
}

- (NSRect)eyeRect {
    if (!self.editMode) return NSZeroRect;
    return NSMakeRect(self.bounds.size.width - 34.0 - 10.0, 10.0, 34.0, 34.0);
}

- (void)drawPanelBackground:(NSRect)rect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:18.0 yRadius:18.0];
    [[NSColor colorWithCalibratedWhite:0.05 alpha:0.76] setFill];
    [path fill];

    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.12] setStroke];
    [path setLineWidth:1.0];
    [path stroke];
}

- (void)drawEyeIconInRect:(NSRect)rect slashed:(BOOL)slashed {
    NSColor *c = [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];
    [c setStroke];
    [c setFill];
    CGFloat w = rect.size.width, h = rect.size.height;
    NSPoint o = rect.origin;

    NSBezierPath *eye = [NSBezierPath bezierPath];
    [eye moveToPoint:NSMakePoint(o.x + w * 0.14, o.y + h * 0.55)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.74)
        controlPoint1:NSMakePoint(o.x + w * 0.26, o.y + h * 0.78)
        controlPoint2:NSMakePoint(o.x + w * 0.40, o.y + h * 0.86)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.86, o.y + h * 0.55)
        controlPoint1:NSMakePoint(o.x + w * 0.60, o.y + h * 0.86)
        controlPoint2:NSMakePoint(o.x + w * 0.74, o.y + h * 0.78)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.36)
        controlPoint1:NSMakePoint(o.x + w * 0.74, o.y + h * 0.32)
        controlPoint2:NSMakePoint(o.x + w * 0.60, o.y + h * 0.24)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.14, o.y + h * 0.55)
        controlPoint1:NSMakePoint(o.x + w * 0.40, o.y + h * 0.24)
        controlPoint2:NSMakePoint(o.x + w * 0.26, o.y + h * 0.32)];
    [eye closePath];
    [eye setLineWidth:1.9];
    [eye stroke];

    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(o.x + w * 0.44, o.y + h * 0.48, w * 0.12, h * 0.12)] fill];

    if (slashed) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.33 blue:0.33 alpha:1.0] setStroke];
        NSBezierPath *slash = [NSBezierPath bezierPath];
        [slash moveToPoint:NSMakePoint(o.x + w * 0.18, o.y + h * 0.25)];
        [slash lineToPoint:NSMakePoint(o.x + w * 0.88, o.y + h * 0.84)];
        [slash setLineWidth:2.2];
        [slash stroke];
    }
}

- (void)drawMutedMicIconAtPoint:(NSPoint)origin size:(CGFloat)size {
    [[NSColor colorWithCalibratedWhite:0.82 alpha:1.0] setStroke];

    NSBezierPath *micBody = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(origin.x + size * 0.28,
                                                                               origin.y + size * 0.20,
                                                                               size * 0.32,
                                                                               size * 0.42)
                                                            xRadius:size * 0.16
                                                            yRadius:size * 0.16];
    [micBody setLineWidth:1.8];
    [micBody stroke];

    NSBezierPath *stem = [NSBezierPath bezierPath];
    [stem moveToPoint:NSMakePoint(origin.x + size * 0.44, origin.y + size * 0.62)];
    [stem lineToPoint:NSMakePoint(origin.x + size * 0.44, origin.y + size * 0.82)];
    [stem setLineWidth:1.8];
    [stem stroke];

    NSBezierPath *base = [NSBezierPath bezierPath];
    [base moveToPoint:NSMakePoint(origin.x + size * 0.28, origin.y + size * 0.82)];
    [base lineToPoint:NSMakePoint(origin.x + size * 0.60, origin.y + size * 0.82)];
    [base setLineWidth:1.8];
    [base stroke];

    [[NSColor colorWithCalibratedRed:1.0 green:0.33 blue:0.33 alpha:1.0] setStroke];
    NSBezierPath *slash = [NSBezierPath bezierPath];
    [slash moveToPoint:NSMakePoint(origin.x + size * 0.18, origin.y + size * 0.16)];
    [slash lineToPoint:NSMakePoint(origin.x + size * 0.74, origin.y + size * 0.90)];
    [slash setLineWidth:2.2];
    [slash stroke];
}

- (void)drawDeafenIconAtPoint:(NSPoint)origin size:(CGFloat)size {
    [[NSColor colorWithCalibratedWhite:0.90 alpha:1.0] setStroke];

    NSBezierPath *left = [NSBezierPath bezierPath];
    [left moveToPoint:NSMakePoint(origin.x + size * 0.24, origin.y + size * 0.58)];
    [left curveToPoint:NSMakePoint(origin.x + size * 0.24, origin.y + size * 0.40)
         controlPoint1:NSMakePoint(origin.x + size * 0.14, origin.y + size * 0.54)
         controlPoint2:NSMakePoint(origin.x + size * 0.14, origin.y + size * 0.44)];
    [left setLineWidth:2.1];
    [left stroke];

    NSBezierPath *right = [NSBezierPath bezierPath];
    [right moveToPoint:NSMakePoint(origin.x + size * 0.76, origin.y + size * 0.58)];
    [right curveToPoint:NSMakePoint(origin.x + size * 0.76, origin.y + size * 0.40)
          controlPoint1:NSMakePoint(origin.x + size * 0.86, origin.y + size * 0.54)
          controlPoint2:NSMakePoint(origin.x + size * 0.86, origin.y + size * 0.44)];
    [right setLineWidth:2.1];
    [right stroke];

    NSBezierPath *band = [NSBezierPath bezierPath];
    [band moveToPoint:NSMakePoint(origin.x + size * 0.28, origin.y + size * 0.34)];
    [band curveToPoint:NSMakePoint(origin.x + size * 0.72, origin.y + size * 0.34)
         controlPoint1:NSMakePoint(origin.x + size * 0.40, origin.y + size * 0.22)
         controlPoint2:NSMakePoint(origin.x + size * 0.60, origin.y + size * 0.22)];
    [band setLineWidth:2.1];
    [band stroke];

    [[NSColor colorWithCalibratedRed:1.0 green:0.33 blue:0.33 alpha:1.0] setStroke];
    NSBezierPath *slash = [NSBezierPath bezierPath];
    [slash moveToPoint:NSMakePoint(origin.x + size * 0.16, origin.y + size * 0.18)];
    [slash lineToPoint:NSMakePoint(origin.x + size * 0.86, origin.y + size * 0.88)];
    [slash setLineWidth:2.8];
    [slash stroke];
}

- (void)drawAvatarForUser:(DOUser *)user inRect:(NSRect)rect {
    CGFloat pulse = 0.0;
    if (user.speaking) pulse = 2.0 + (sinf(self.animationPhase) + 1.0f) * 1.5f;

    if (user.speaking) {
        NSRect glowRect = NSInsetRect(rect, -8.0 - pulse, -8.0 - pulse);
        NSBezierPath *glowPath = [NSBezierPath bezierPathWithOvalInRect:glowRect];
        [[NSColor colorWithCalibratedRed:0.25 green:1.0 blue:0.52 alpha:0.16] setFill];
        [glowPath fill];

        NSRect ringRect = NSInsetRect(rect, -4.0 - pulse * 0.35, -4.0 - pulse * 0.35);
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:ringRect];
        [[NSColor colorWithCalibratedRed:0.22 green:0.95 blue:0.50 alpha:1.0] setStroke];
        [ring setLineWidth:3.0];
        [ring stroke];
    }

    NSBezierPath *clip = [NSBezierPath bezierPathWithOvalInRect:rect];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];

    if (user.avatarImage) {
        [user.avatarImage drawInRect:rect
                            fromRect:NSZeroRect
                           operation:NSCompositingOperationSourceOver
                            fraction:1.0
                      respectFlipped:YES
                               hints:nil];
    } else {
        NSColor *fill = [NSColor colorWithCalibratedRed:0.22 green:0.25 blue:0.32 alpha:1.0];
        [fill setFill];
        [[NSBezierPath bezierPathWithOvalInRect:rect] fill];

        NSString *name = user.name.length > 0 ? user.name : @"?";
        NSString *initial = [[name substringToIndex:1] uppercaseString];

        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:16.0],
            NSForegroundColorAttributeName: NSColor.whiteColor
        };

        NSSize s = [initial sizeWithAttributes:attrs];
        NSPoint p = NSMakePoint(NSMidX(rect) - (s.width / 2.0),
                                NSMidY(rect) - (s.height / 2.0) - 1.0);
        [initial drawAtPoint:p withAttributes:attrs];
    }

    [NSGraphicsContext restoreGraphicsState];

    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.32] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithOvalInRect:rect];
    [border setLineWidth:1.0];
    [border stroke];
}

- (void)logPrimaryGuildTagDrawOnceForUser:(DOUser *)user
                                   reason:(NSString *)reason
                                  originX:(CGFloat)originX
                                     maxX:(CGFloat)maxX
                                    pillW:(CGFloat)pillW {
    static NSMutableSet<NSString *> *logged = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logged = [NSMutableSet set];
    });

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@",
                     user.userId ?: @"",
                     user.primaryGuildTag ?: @"",
                     user.primaryGuildBadgeHash ?: @"",
                     reason ?: @""];
    if ([logged containsObject:key]) return;
    [logged addObject:key];

    DOLog(@"voice tag draw %@ user=%@ name=%@ tag=%@ guild=%@ badgeHash=%@ badgeImage=%d originX=%.1f maxX=%.1f pillW=%.1f",
          reason ?: @"",
          user.userId ?: @"",
          user.name ?: @"",
          user.primaryGuildTag ?: @"",
          user.primaryGuildId ?: @"",
          user.primaryGuildBadgeHash ?: @"",
          user.primaryGuildBadgeImage ? 1 : 0,
          originX,
          maxX,
          pillW);
}

- (NSRect)drawPrimaryGuildTagForUser:(DOUser *)user atPoint:(NSPoint)origin maxX:(CGFloat)maxX {
    NSString *tag = user.primaryGuildTag ?: @"";
    if (tag.length == 0) {
        [self logPrimaryGuildTagDrawOnceForUser:user reason:@"missing-tag" originX:origin.x maxX:maxX pillW:0.0];
        return NSZeroRect;
    }

    NSDictionary *tagAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.0 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.92 alpha:1.0]
    };
    NSSize tagSize = [tag sizeWithAttributes:tagAttrs];
    CGFloat badgeSize = user.primaryGuildBadgeImage ? 14.0 : 0.0;
    CGFloat gap = badgeSize > 0.0 ? 4.0 : 0.0;
    CGFloat padX = 6.0;
    CGFloat pillW = padX * 2.0 + badgeSize + gap + ceil(tagSize.width);
    CGFloat pillH = 20.0;
    if (origin.x + pillW > maxX) {
        [self logPrimaryGuildTagDrawOnceForUser:user reason:@"clipped" originX:origin.x maxX:maxX pillW:pillW];
        return NSZeroRect;
    }

    [self logPrimaryGuildTagDrawOnceForUser:user reason:@"drawn" originX:origin.x maxX:maxX pillW:pillW];

    NSRect pill = NSMakeRect(origin.x, origin.y, pillW, pillH);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:7.0 yRadius:7.0];
    [[NSColor colorWithCalibratedWhite:0.14 alpha:0.78] setFill];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] setStroke];
    [bg setLineWidth:1.0];
    [bg stroke];

    CGFloat contentX = pill.origin.x + padX;
    if (user.primaryGuildBadgeImage) {
        NSRect badgeRect = NSMakeRect(contentX, NSMidY(pill) - badgeSize / 2.0, badgeSize, badgeSize);
        NSBezierPath *clip = [NSBezierPath bezierPathWithOvalInRect:badgeRect];
        [NSGraphicsContext saveGraphicsState];
        [clip addClip];
        [user.primaryGuildBadgeImage drawInRect:badgeRect
                                       fromRect:NSZeroRect
                                      operation:NSCompositingOperationSourceOver
                                       fraction:1.0
                                 respectFlipped:YES
                                          hints:nil];
        [NSGraphicsContext restoreGraphicsState];
        contentX = NSMaxX(badgeRect) + gap;
    }

    [tag drawAtPoint:NSMakePoint(contentX, NSMidY(pill) - tagSize.height / 2.0)
      withAttributes:tagAttrs];
    return pill;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect panel = [self panelRect];
    if (self.editMode) [self drawPanelBackground:panel];
    if (self.editMode) {
        NSRect eyeR = [self eyeRect];
        NSBezierPath *eyeBg = [NSBezierPath bezierPathWithOvalInRect:eyeR];
        [[NSColor colorWithCalibratedWhite:0.10 alpha:0.90] setFill];
        [eyeBg fill];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] setStroke];
        [eyeBg setLineWidth:1.0];
        [eyeBg stroke];
        [self drawEyeIconInRect:NSInsetRect(eyeR, 7.0, 7.0) slashed:(!self.showOutsideEditMode)];
    }

    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:14.0],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };

    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.5],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.97 alpha:1.0]
    };

    NSDictionary *subAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11.5],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.72 alpha:1.0]
    };

    CGFloat x = 14.0;
    CGFloat y = 12.0;
    BOOL compact = !self.editMode;

    if (!compact) {
        NSString *title = self.channelName.length > 0 ? self.channelName : @"Voice";
        [title drawAtPoint:NSMakePoint(x, y) withAttributes:titleAttrs];
        y += [self headerHeight];
    } else {
        y += 12.0;
    }

    for (DOUser *user in self.users) {
        NSString *name = user.name.length > 0 ? user.name : @"Unknown";

        NSRect avatarRect = NSMakeRect(x, y + 2.0, 38.0, 38.0);
        [self drawAvatarForUser:user inRect:avatarRect];

        CGFloat textX = NSMaxX(avatarRect) + 12.0;
        NSPoint namePoint = NSMakePoint(textX, y + 3.0);
        NSSize nameSize = [name sizeWithAttributes:nameAttrs];
        CGFloat pillPadX = 10.0;
        CGFloat pillPadY = 4.0;
        NSRect namePill = NSInsetRect((NSRect){ namePoint, nameSize }, -pillPadX, -pillPadY);
        namePill.origin.y += 1.0;
        namePill.size.height = MAX(namePill.size.height, 22.0);
        namePill.origin.y = y + 1.0;

        NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:namePill xRadius:10.0 yRadius:10.0];
        [[NSColor colorWithCalibratedWhite:0.10 alpha:0.55] setFill];
        [pillPath fill];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.08] setStroke];
        [pillPath setLineWidth:1.0];
        [pillPath stroke];

        [name drawAtPoint:NSMakePoint(namePill.origin.x + pillPadX, namePoint.y) withAttributes:nameAttrs];

        if (!compact) {
            NSString *status = user.speaking ? @"Speaking" : @"Connected";
            [status drawAtPoint:NSMakePoint(textX, y + 22.0) withAttributes:subAttrs];
        }

        CGFloat iconSize = 16.0;
        CGFloat safeRightOriginX = panel.size.width - 28.0; // eski sağ konum
        CGFloat nameEndX = NSMaxX(namePill);
        if (user.primaryGuildTag.length > 0) {
            NSRect tagRect = [self drawPrimaryGuildTagForUser:user
                                                      atPoint:NSMakePoint(nameEndX + 7.0, y + 2.0)
                                                         maxX:safeRightOriginX];
            if (!NSIsEmptyRect(tagRect)) nameEndX = NSMaxX(tagRect);
        } else {
            [self logPrimaryGuildTagDrawOnceForUser:user
                                             reason:@"missing-tag"
                                            originX:nameEndX + 7.0
                                               maxX:safeRightOriginX
                                              pillW:0.0];
        }
        CGFloat iconY = y + 11.0;

        if (user.deaf && user.mute) {
            // İki ikon yan yana: önce mute (sol), sonra deafen (sağ).
            CGFloat desiredMuteOriginX = nameEndX + 8.0;
            CGFloat desiredDeafenOriginX = desiredMuteOriginX + 18.0;

            if (desiredDeafenOriginX <= safeRightOriginX) {
                [self drawMutedMicIconAtPoint:NSMakePoint(desiredMuteOriginX, iconY) size:iconSize];
                [self drawDeafenIconAtPoint:NSMakePoint(desiredDeafenOriginX, iconY) size:iconSize];
            } else {
                // Taşarsa eski sağa sabitle.
                [self drawMutedMicIconAtPoint:NSMakePoint(safeRightOriginX - 18.0, iconY) size:iconSize];
                [self drawDeafenIconAtPoint:NSMakePoint(safeRightOriginX, iconY) size:iconSize];
            }
        } else if (user.deaf) {
            CGFloat desiredDeafenOriginX = nameEndX + 8.0;
            CGFloat x = (desiredDeafenOriginX <= safeRightOriginX) ? desiredDeafenOriginX : safeRightOriginX;
            [self drawDeafenIconAtPoint:NSMakePoint(x, iconY) size:iconSize];
        } else if (user.mute) {
            CGFloat desiredMuteOriginX = nameEndX + 8.0;
            CGFloat x = (desiredMuteOriginX <= safeRightOriginX) ? desiredMuteOriginX : safeRightOriginX;
            [self drawMutedMicIconAtPoint:NSMakePoint(x, iconY) size:iconSize];
        }

        y += [self rowHeight];
    }

    BOOL anySpeaking = NO;
    for (DOUser *u in self.users) if (u.speaking) { anySpeaking = YES; break; }

    if (anySpeaking && !self.isDragging) {
        self.animationPhase += 0.14;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 / 30.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self setNeedsDisplay:YES];
        });
    }
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.editMode || !self.hostWindow) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, [self eyeRect])) {
        if (self.toggleVisibilityHandler) self.toggleVisibilityHandler();
        return;
    }
    self.isDragging = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.editMode || !self.hostWindow) return;
    NSPoint newOrigin = self.hostWindow.frame.origin;
    newOrigin.x += event.deltaX;
    newOrigin.y -= event.deltaY;
    [self.hostWindow setFrameOrigin:newOrigin];
}

- (void)mouseUp:(NSEvent *)event {
    if (!self.editMode || !self.hostWindow) return;
    self.isDragging = NO;
    [self setNeedsDisplay:YES];
}

@end

#pragma mark - Call Bar

@interface DOCallBarView : NSView
@property (nonatomic, assign) BOOL editMode;
@property (nonatomic, assign) BOOL showOutsideEditMode;
@property (nonatomic, copy) void (^toggleVisibilityHandler)(void);
@property (nonatomic, assign) CFTimeInterval bounceStartTime;
@property (nonatomic, assign) NSInteger bounceButtonIndex;
@property (nonatomic, assign) BOOL isDragging;
@end

@implementation DOCallBarView

- (BOOL)isFlipped { return YES; }

- (NSRect)pillRectForButtonRects:(NSArray<NSValue *> *)rects {
    if (rects.count < 4) return NSZeroRect;
    NSRect first = rects.firstObject.rectValue;
    NSRect last = rects.lastObject.rectValue;
    return NSInsetRect(NSUnionRect(first, last), -16.0, -10.0);
}

- (NSRect)eyeRectForPillRect:(NSRect)pill {
    if (!self.editMode || NSIsEmptyRect(pill)) return NSZeroRect;
    CGFloat d = 34.0;
    return NSMakeRect(NSMaxX(pill) + 10.0, NSMidY(pill) - d / 2.0, d, d);
}

- (NSArray<NSValue *> *)buttonRects {
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    CGFloat d = 44.0, gap = 14.0;
    CGFloat total = d * 4 + gap * 3;
    CGFloat startX = (self.bounds.size.width - total) / 2.0;
    CGFloat y = (self.bounds.size.height - d) / 2.0;

    for (NSInteger i = 0; i < 4; i++) {
        [rects addObject:[NSValue valueWithRect:NSMakeRect(startX + i * (d + gap), y, d, d)]];
    }
    return rects;
}

- (void)drawCircleButtonInRect:(NSRect)rect fill:(NSColor *)fill stroke:(NSColor *)stroke {
    NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:rect];
    [fill setFill];
    [p fill];
    [stroke setStroke];
    [p setLineWidth:1.0];
    [p stroke];
}

- (void)startBounceForButtonIndex:(NSInteger)index {
    self.bounceButtonIndex = index;
    self.bounceStartTime = CFAbsoluteTimeGetCurrent();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self setNeedsDisplay:YES]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self setNeedsDisplay:YES]; });
}

- (CGFloat)bounceScaleForButtonIndex:(NSInteger)index {
    if (index != self.bounceButtonIndex) return 1.0;
    CFTimeInterval t = CFAbsoluteTimeGetCurrent() - self.bounceStartTime;
    if (t < 0 || t > 0.28) return 1.0;
    CGFloat a = exp(-t * 9.0);
    CGFloat s = sin(t * 28.0);
    return 1.0 + (0.12 * a * s);
}

- (void)drawMicIconInRect:(NSRect)rect color:(NSColor *)color {
    [color setStroke];
    [color setFill];
    CGFloat w = rect.size.width, h = rect.size.height;
    NSPoint o = rect.origin;

    NSRect body = NSMakeRect(o.x + w * 0.40, o.y + h * 0.30, w * 0.20, h * 0.32);
    [[NSBezierPath bezierPathWithRoundedRect:body xRadius:w * 0.10 yRadius:w * 0.10] fill];

    NSBezierPath *stem = [NSBezierPath bezierPath];
    [stem moveToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.62)];
    [stem lineToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.73)];
    [stem setLineWidth:2.0];
    [stem stroke];

    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc moveToPoint:NSMakePoint(o.x + w * 0.34, o.y + h * 0.58)];
    [arc curveToPoint:NSMakePoint(o.x + w * 0.66, o.y + h * 0.58)
        controlPoint1:NSMakePoint(o.x + w * 0.36, o.y + h * 0.74)
        controlPoint2:NSMakePoint(o.x + w * 0.64, o.y + h * 0.74)];
    [arc setLineWidth:2.0];
    [arc stroke];
}

- (void)drawDeafenIconInRect:(NSRect)rect color:(NSColor *)color {
    [color setStroke];
    CGFloat w = rect.size.width, h = rect.size.height;
    NSPoint o = rect.origin;

    NSBezierPath *left = [NSBezierPath bezierPath];
    [left moveToPoint:NSMakePoint(o.x + w * 0.30, o.y + h * 0.60)];
    [left curveToPoint:NSMakePoint(o.x + w * 0.30, o.y + h * 0.42)
         controlPoint1:NSMakePoint(o.x + w * 0.18, o.y + h * 0.56)
         controlPoint2:NSMakePoint(o.x + w * 0.18, o.y + h * 0.46)];
    [left setLineWidth:2.0];
    [left stroke];

    NSBezierPath *right = [NSBezierPath bezierPath];
    [right moveToPoint:NSMakePoint(o.x + w * 0.70, o.y + h * 0.60)];
    [right curveToPoint:NSMakePoint(o.x + w * 0.70, o.y + h * 0.42)
          controlPoint1:NSMakePoint(o.x + w * 0.82, o.y + h * 0.56)
          controlPoint2:NSMakePoint(o.x + w * 0.82, o.y + h * 0.46)];
    [right setLineWidth:2.0];
    [right stroke];

    NSBezierPath *band = [NSBezierPath bezierPath];
    [band moveToPoint:NSMakePoint(o.x + w * 0.33, o.y + h * 0.36)];
    [band curveToPoint:NSMakePoint(o.x + w * 0.67, o.y + h * 0.36)
         controlPoint1:NSMakePoint(o.x + w * 0.44, o.y + h * 0.22)
         controlPoint2:NSMakePoint(o.x + w * 0.56, o.y + h * 0.22)];
    [band setLineWidth:2.0];
    [band stroke];
}

- (void)drawMoreIconInRect:(NSRect)rect color:(NSColor *)color {
    [color setFill];
    CGFloat w = rect.size.width, h = rect.size.height;
    NSPoint o = rect.origin;
    CGFloat r = w * 0.06, cy = o.y + h * 0.52;
    NSArray<NSNumber *> *xs = @[@(o.x + w * 0.36), @(o.x + w * 0.50), @(o.x + w * 0.64)];
    for (NSNumber *nx in xs) {
        CGFloat cx = nx.doubleValue;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r, cy - r, r * 2.0, r * 2.0)] fill];
    }
}

- (void)drawDisconnectIconInRect:(NSRect)rect color:(NSColor *)color {
    [color setStroke];
    CGFloat w = rect.size.width, h = rect.size.height;
    NSPoint o = rect.origin;

    NSBezierPath *phone = [NSBezierPath bezierPath];
    [phone moveToPoint:NSMakePoint(o.x + w * 0.30, o.y + h * 0.58)];
    [phone curveToPoint:NSMakePoint(o.x + w * 0.70, o.y + h * 0.58)
          controlPoint1:NSMakePoint(o.x + w * 0.38, o.y + h * 0.44)
          controlPoint2:NSMakePoint(o.x + w * 0.62, o.y + h * 0.44)];
    [phone setLineWidth:2.4];
    [phone stroke];

    NSBezierPath *hookL = [NSBezierPath bezierPath];
    [hookL moveToPoint:NSMakePoint(o.x + w * 0.28, o.y + h * 0.58)];
    [hookL lineToPoint:NSMakePoint(o.x + w * 0.22, o.y + h * 0.50)];
    [hookL setLineWidth:2.4];
    [hookL stroke];

    NSBezierPath *hookR = [NSBezierPath bezierPath];
    [hookR moveToPoint:NSMakePoint(o.x + w * 0.72, o.y + h * 0.58)];
    [hookR lineToPoint:NSMakePoint(o.x + w * 0.78, o.y + h * 0.50)];
    [hookR setLineWidth:2.4];
    [hookR stroke];
}

- (void)drawEyeIconInRect:(NSRect)rect color:(NSColor *)color slashed:(BOOL)slashed {
    [color setStroke];
    [color setFill];
    CGFloat w = rect.size.width, h = rect.size.height;
    NSPoint o = rect.origin;

    NSBezierPath *eye = [NSBezierPath bezierPath];
    [eye moveToPoint:NSMakePoint(o.x + w * 0.14, o.y + h * 0.55)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.74)
        controlPoint1:NSMakePoint(o.x + w * 0.26, o.y + h * 0.78)
        controlPoint2:NSMakePoint(o.x + w * 0.40, o.y + h * 0.86)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.86, o.y + h * 0.55)
        controlPoint1:NSMakePoint(o.x + w * 0.60, o.y + h * 0.86)
        controlPoint2:NSMakePoint(o.x + w * 0.74, o.y + h * 0.78)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.36)
        controlPoint1:NSMakePoint(o.x + w * 0.74, o.y + h * 0.32)
        controlPoint2:NSMakePoint(o.x + w * 0.60, o.y + h * 0.24)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.14, o.y + h * 0.55)
        controlPoint1:NSMakePoint(o.x + w * 0.40, o.y + h * 0.24)
        controlPoint2:NSMakePoint(o.x + w * 0.26, o.y + h * 0.32)];
    [eye closePath];
    [eye setLineWidth:1.9];
    [eye stroke];

    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(o.x + w * 0.44, o.y + h * 0.48, w * 0.12, h * 0.12)] fill];

    if (slashed) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.33 blue:0.33 alpha:1.0] setStroke];
        NSBezierPath *slash = [NSBezierPath bezierPath];
        [slash moveToPoint:NSMakePoint(o.x + w * 0.18, o.y + h * 0.25)];
        [slash lineToPoint:NSMakePoint(o.x + w * 0.88, o.y + h * 0.84)];
        [slash setLineWidth:2.2];
        [slash stroke];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSArray<NSValue *> *rects = [self buttonRects];
    if (rects.count < 4) return;

    NSRect pill = [self pillRectForButtonRects:rects];
    NSRect eyeRect = [self eyeRectForPillRect:pill];

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:22.0 yRadius:22.0];
    [[NSColor colorWithCalibratedWhite:0.06 alpha:0.88] setFill];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] setStroke];
    [bg setLineWidth:1.0];
    [bg stroke];

    NSColor *buttonFill = [NSColor colorWithCalibratedWhite:0.12 alpha:0.95];
    NSColor *buttonStroke = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08];
    NSColor *brand = [NSColor colorWithCalibratedRed:0.35 green:0.42 blue:0.95 alpha:1.0];
    NSColor *danger = [NSColor colorWithCalibratedRed:0.95 green:0.28 blue:0.34 alpha:1.0];
    NSColor *muted = [NSColor colorWithCalibratedWhite:0.78 alpha:1.0];

    for (NSInteger i = 0; i < 4; i++) {
        NSRect r = rects[i].rectValue;
        CGFloat scale = [self bounceScaleForButtonIndex:i];
        if (fabs(scale - 1.0) > 0.001) {
            [NSGraphicsContext saveGraphicsState];
            NSAffineTransform *tx = [NSAffineTransform transform];
            [tx translateXBy:NSMidX(r) yBy:NSMidY(r)];
            [tx scaleBy:scale];
            [tx translateXBy:-NSMidX(r) yBy:-NSMidY(r)];
            [tx concat];
        }

        if (i == 0) {
            [self drawCircleButtonInRect:r fill:buttonFill stroke:buttonStroke];
            [self drawMicIconInRect:NSInsetRect(r, 10.0, 10.0) color:brand];
        } else if (i == 1) {
            [self drawCircleButtonInRect:r fill:buttonFill stroke:buttonStroke];
            [self drawDeafenIconInRect:NSInsetRect(r, 10.0, 10.0) color:brand];
        } else if (i == 2) {
            [self drawCircleButtonInRect:r fill:buttonFill stroke:buttonStroke];
            [self drawMoreIconInRect:NSInsetRect(r, 10.0, 10.0) color:muted];
        } else if (i == 3) {
            NSColor *endFill = [NSColor colorWithCalibratedRed:0.22 green:0.08 blue:0.09 alpha:0.95];
            [self drawCircleButtonInRect:r fill:endFill stroke:[NSColor colorWithCalibratedWhite:1.0 alpha:0.06]];
            [self drawDisconnectIconInRect:NSInsetRect(r, 10.0, 10.0) color:danger];
        }

        if (fabs(scale - 1.0) > 0.001) [NSGraphicsContext restoreGraphicsState];
    }

    if (self.editMode) {
        [self drawCircleButtonInRect:eyeRect
                                fill:[NSColor colorWithCalibratedWhite:0.10 alpha:0.92]
                              stroke:[NSColor colorWithCalibratedWhite:1.0 alpha:0.10]];
        [self drawEyeIconInRect:NSInsetRect(eyeRect, 7.0, 7.0)
                          color:[NSColor colorWithCalibratedWhite:0.85 alpha:1.0]
                        slashed:(!self.showOutsideEditMode)];
    }
}

- (void)mouseDown:(NSEvent *)event {
    DOLog(@"callbar: mouseDown");
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSArray<NSValue *> *rects = [self buttonRects];
    NSRect pill = [self pillRectForButtonRects:rects];
    NSRect eyeRect = [self eyeRectForPillRect:pill];

    if (self.editMode && !NSIsEmptyRect(eyeRect) && NSPointInRect(p, eyeRect)) {
        if (self.toggleVisibilityHandler) self.toggleVisibilityHandler();
        return;
    }

    if (NSPointInRect(p, rects[0].rectValue)) {
        [self startBounceForButtonIndex:0];
        DOLog(@"callbar: hit toggle_mute");
        [[DODiscordIPCManager shared] toggleMute];
        return;
    }

    if (NSPointInRect(p, rects[1].rectValue)) {
        [self startBounceForButtonIndex:1];
        DOLog(@"callbar: hit toggle_deafen");
        [[DODiscordIPCManager shared] toggleDeafen];
        return;
    }

    if (NSPointInRect(p, rects[2].rectValue)) {
        [self startBounceForButtonIndex:2];
        DOLog(@"callbar: hit more_options");
        [[DODiscordIPCManager shared] handleMoreOptions];
        return;
    }

    if (NSPointInRect(p, rects[3].rectValue)) {
        [self startBounceForButtonIndex:3];
        DOLog(@"callbar: hit disconnect");
        [[DODiscordIPCManager shared] disconnectVoice];
        return;
    }

    if (self.editMode) self.isDragging = YES;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.editMode || !self.isDragging) return;
    NSPoint newOrigin = self.window.frame.origin;
    newOrigin.x += event.deltaX;
    newOrigin.y -= event.deltaY;
    [self.window setFrameOrigin:newOrigin];
}

- (void)mouseUp:(NSEvent *)event {
    if (!self.editMode) return;
    self.isDragging = NO;
}

@end

#pragma mark - Edit Mode HUD

@interface DOEditModeHUDView : NSView
@end

@implementation DOEditModeHUDView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect r = self.bounds;

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:10.0 yRadius:10.0];
    [[NSColor colorWithCalibratedWhite:0.05 alpha:0.72] setFill];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.14] setStroke];
    [bg setLineWidth:1.0];
    [bg stroke];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12.0],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.92]
    };
    NSString *t = @"EDIT MODE";
    NSSize s = [t sizeWithAttributes:attrs];
    [t drawAtPoint:NSMakePoint(NSMidX(r) - s.width/2.0, NSMidY(r) - s.height/2.0 + 1.0)
    withAttributes:attrs];
}
@end

#pragma mark - Message View

@interface DOMessageView : NSView
@property (nonatomic, copy) void (^onSend)(NSString *text);
@end

@implementation DOMessageView {
    NSTextField *_inputField;
    NSButton *_sendButton;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(14.0, 18.0, frame.size.width - 100.0, 24.0)];
    _inputField.bordered = YES;
    _inputField.bezeled = YES;
    _inputField.drawsBackground = NO;
    _inputField.placeholderString = @"Mesaj yaz...";
    _inputField.focusRingType = NSFocusRingTypeNone;
    _inputField.font = [NSFont systemFontOfSize:13.5];
    _inputField.stringValue = @"";

    _sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(frame.size.width - 76.0, 14.0, 62.0, 32.0)];
    _sendButton.title = @"Gönder";
    _sendButton.bezelStyle = NSBezelStyleRounded;
    _sendButton.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
    _sendButton.target = self;
    _sendButton.action = @selector(_onSendTapped:);

    // Return ile göndermek için.
    _inputField.target = self;
    _inputField.action = @selector(_onSendTapped:);

    _inputField.autoresizingMask = NSViewWidthSizable;
    _sendButton.autoresizingMask = NSViewMinXMargin;

    [self addSubview:_inputField];
    [self addSubview:_sendButton];
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect r = self.bounds;

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.0, 0.0)
                                                     xRadius:16.0
                                                     yRadius:16.0];
    [[NSColor colorWithCalibratedWhite:0.05 alpha:0.78] setFill];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.12] setStroke];
    [bg setLineWidth:1.0];
    [bg stroke];
}

- (void)_onSendTapped:(id)sender {
    NSString *text = _inputField.stringValue ?: @"";
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return;

    if (self.onSend) self.onSend(text);
    _inputField.stringValue = @"";
}

@end

#pragma mark - Chat View

@interface DOOverlayChatWindow : NSWindow
@end

@implementation DOOverlayChatWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface DOChatSidebarListDocumentView : NSView
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign) CGFloat rowHeight;
@property (nonatomic, assign) BOOL imageOnly;
@property (nonatomic, copy) NSString *(^titleForItem)(id item);
@property (nonatomic, copy) NSString *(^idForItem)(id item);
@property (nonatomic, copy) NSString *(^imageURLForItem)(id item);
@property (nonatomic, copy) NSString *(^leadingSymbolForItem)(id item);
@property (nonatomic, copy) void (^onItemSelected)(NSString *itemId);
@property (nonatomic, copy) BOOL (^isFolderItem)(id item);
@property (nonatomic, copy) NSColor *(^folderColorForItem)(id item);
@end

@implementation DOChatSidebarListDocumentView {
    NSMutableDictionary<NSString *, NSImage *> *_imageCache;
    NSMutableSet<NSString *> *_loadingImageURLs;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.items = @[];
    self.selectedIndex = -1;
    self.rowHeight = 36.0;
    _imageCache = [NSMutableDictionary dictionary];
    _loadingImageURLs = [NSMutableSet set];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)loadImageURLIfNeeded:(NSString *)urlString {
    if (urlString.length == 0) return;
    if (_imageCache[urlString]) return;
    if ([_loadingImageURLs containsObject:urlString]) return;
    [_loadingImageURLs addObject:urlString];

    DO_WEAK typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSImage *image = DOFetchImageSync(urlString, @"chat guild icon");
        dispatch_async(dispatch_get_main_queue(), ^{
            DOChatSidebarListDocumentView *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf->_loadingImageURLs removeObject:urlString];
            if (image) strongSelf->_imageCache[urlString] = image;
            [strongSelf setNeedsDisplay:YES];
        });
    });
}

- (void)drawImageOnlyItem:(id)item row:(NSRect)row selected:(BOOL)selected {
    NSString *title = self.titleForItem ? self.titleForItem(item) : @"";
    if (!title) title = @"";
    BOOL isFolder = self.isFolderItem ? self.isFolderItem(item) : NO;
    NSString *urlString = self.imageURLForItem ? self.imageURLForItem(item) : nil;
    NSImage *image = urlString.length > 0 ? _imageCache[urlString] : nil;
    if (!image && urlString.length > 0) [self loadImageURLIfNeeded:urlString];

    CGFloat iconSize = 42.0;
    NSRect iconRect = NSMakeRect(NSMidX(row) - iconSize / 2.0,
                                 NSMidY(row) - iconSize / 2.0,
                                 iconSize,
                                 iconSize);
    if (selected) {
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.20] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(iconRect, -5.0, -5.0)
                                         xRadius:14.0
                                         yRadius:14.0] fill];
    }

    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:iconRect xRadius:13.0 yRadius:13.0];
    [NSGraphicsContext saveGraphicsState];
    [clip addClip];
    if (isFolder) {
        NSColor *folderColor = self.folderColorForItem ? self.folderColorForItem(item) : nil;
        if (!folderColor) folderColor = [NSColor colorWithCalibratedWhite:0.20 alpha:1.0];
        [folderColor setFill];
        [clip fill];

        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.18] setFill];
        NSBezierPath *tab = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(iconRect.origin.x + 7.0,
                                                                               iconRect.origin.y + 8.0,
                                                                               16.0,
                                                                               9.0)
                                                           xRadius:4.0
                                                           yRadius:4.0];
        [tab fill];
        NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(iconRect.origin.x + 6.0,
                                                                                iconRect.origin.y + 14.0,
                                                                                iconRect.size.width - 12.0,
                                                                                20.0)
                                                            xRadius:7.0
                                                            yRadius:7.0];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.20] setFill];
        [body fill];
    } else if (image) {
        [image drawInRect:iconRect
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0
           respectFlipped:YES
                    hints:nil];
    } else {
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] setFill];
        [clip fill];
        NSString *initial = title.length > 0 ? [[title substringToIndex:1] uppercaseString] : @"?";
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:17.0],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.86]
        };
        NSSize s = [initial sizeWithAttributes:attrs];
        [initial drawAtPoint:NSMakePoint(NSMidX(iconRect) - s.width / 2.0,
                                         NSMidY(iconRect) - s.height / 2.0)
              withAttributes:attrs];
    }
    [NSGraphicsContext restoreGraphicsState];

    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.30] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:iconRect xRadius:13.0 yRadius:13.0];
    [border setLineWidth:1.0];
    [border stroke];
}

- (void)drawLeadingSymbol:(NSString *)symbol inRect:(NSRect)rect selected:(BOOL)selected {
    if ([symbol isEqualToString:@"text"]) {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:17.0 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.78 alpha:(selected ? 1.0 : 0.82)]
        };
        NSString *hash = @"#";
        NSSize s = [hash sizeWithAttributes:attrs];
        [hash drawAtPoint:NSMakePoint(NSMidX(rect) - s.width / 2.0,
                                      NSMidY(rect) - s.height / 2.0 - 0.5)
           withAttributes:attrs];
        return;
    }

    if ([symbol isEqualToString:@"voice"]) {
        [[NSColor colorWithCalibratedWhite:0.78 alpha:(selected ? 1.0 : 0.82)] setFill];
        [[NSColor colorWithCalibratedWhite:0.78 alpha:(selected ? 1.0 : 0.82)] setStroke];

        CGFloat x = rect.origin.x + 2.0;
        CGFloat y = rect.origin.y + 4.0;
        NSBezierPath *horn = [NSBezierPath bezierPath];
        [horn moveToPoint:NSMakePoint(x + 2.0, y + 6.0)];
        [horn lineToPoint:NSMakePoint(x + 8.0, y + 3.0)];
        [horn lineToPoint:NSMakePoint(x + 8.0, y + 13.0)];
        [horn lineToPoint:NSMakePoint(x + 2.0, y + 10.0)];
        [horn closePath];
        [horn fill];

        NSBezierPath *mouth = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 8.0, y + 2.0, 8.0, 12.0)
                                                              xRadius:2.0
                                                              yRadius:2.0];
        [mouth fill];

        NSBezierPath *handle = [NSBezierPath bezierPath];
        [handle moveToPoint:NSMakePoint(x + 6.0, y + 11.0)];
        [handle lineToPoint:NSMakePoint(x + 9.0, y + 17.0)];
        [handle setLineWidth:2.0];
        [handle stroke];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.96 alpha:1.0]
    };

    NSInteger count = (NSInteger)self.items.count;
    NSInteger max = MIN(count, (NSInteger)ceil(self.bounds.size.height / self.rowHeight) + 2);
    for (NSInteger i = 0; i < max; i++) {
        NSRect row = NSMakeRect(0, i * self.rowHeight, self.bounds.size.width, self.rowHeight);
        BOOL selected = (i == self.selectedIndex);
        id item = self.items[i];
        if (self.imageOnly) {
            [self drawImageOnlyItem:item row:row selected:selected];
            continue;
        }
        if (selected) {
            [[NSColor colorWithCalibratedWhite:0.20 alpha:0.95] setFill];
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(row, 6.0, 6.0) xRadius:10.0 yRadius:10.0];
            [p fill];
        }
        NSString *title = self.titleForItem ? self.titleForItem(item) : @"";
        if (!title) title = @"";
        NSString *symbol = self.leadingSymbolForItem ? self.leadingSymbolForItem(item) : nil;
        CGFloat textX = 12.0;
        if (symbol.length > 0) {
            NSRect symbolRect = NSMakeRect(12.0, row.origin.y + (self.rowHeight - 22.0) / 2.0, 20.0, 22.0);
            [self drawLeadingSymbol:symbol inRect:symbolRect selected:selected];
            textX = 38.0;
        }
        NSPoint textP = NSMakePoint(textX, row.origin.y + (self.rowHeight - 18.0) / 2.0);
        [title drawAtPoint:textP withAttributes:titleAttrs];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = (NSInteger)floor(p.y / self.rowHeight);
    if (idx < 0 || idx >= (NSInteger)self.items.count) return;
    self.selectedIndex = idx;
    [self setNeedsDisplay:YES];
    if (self.onItemSelected) {
        id item = self.items[idx];
        NSString *itemId = self.idForItem ? self.idForItem(item) : nil;
        self.onItemSelected(itemId ?: @"");
    }
}

@end

#pragma mark - Chat Messages View

@interface DOChatMessagesView : NSView
@property (nonatomic, copy) NSArray<DOChatMessage *> *messages;
- (void)reloadLayout;
@end

@implementation DOChatMessagesView {
    NSMutableDictionary<NSString *, NSImage *> *_avatarCache;
    NSMutableSet<NSString *> *_loadingAvatars;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    _avatarCache = [NSMutableDictionary dictionary];
    _loadingAvatars = [NSMutableSet set];
    self.messages = @[];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSString *)avatarCacheKeyForMessage:(DOChatMessage *)m {
    if (!m) return @"";
    NSString *uid = m.authorId ?: @"";
    NSString *hash = m.authorAvatarHash ?: @"";
    if (uid.length == 0 || hash.length == 0) return @"";
    return [NSString stringWithFormat:@"%@:%@", uid, hash];
}

- (void)preloadAvatarsIfNeeded {
    DO_WEAK typeof(self) weakSelf = self;
    for (DOChatMessage *m in self.messages ?: @[]) {
        NSString *key = [self avatarCacheKeyForMessage:m];
        if (key.length == 0) continue;
        if (self->_avatarCache[key]) continue;
        if ([self->_loadingAvatars containsObject:key]) continue;
        [self->_loadingAvatars addObject:key];

        NSString *urlString = DOAvatarURLString(m.authorId ?: @"", m.authorAvatarHash ?: @"");
        if (urlString.length == 0) {
            [self->_loadingAvatars removeObject:key];
            continue;
        }

        NSURL *url = [NSURL URLWithString:urlString];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *imgData = [NSData dataWithContentsOfURL:url];
            DOChatMessagesView *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!imgData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf->_loadingAvatars removeObject:key];
                    [strongSelf setNeedsDisplay:YES];
                });
                return;
            }
            NSImage *img = [[NSImage alloc] initWithData:imgData];
            if (!img) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf->_loadingAvatars removeObject:key];
                    [strongSelf setNeedsDisplay:YES];
                });
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf->_avatarCache[key] = img;
                [strongSelf->_loadingAvatars removeObject:key];
                [strongSelf setNeedsDisplay:YES];
            });
        });
    }
}

- (void)reloadLayout {
    // Document view yüksekliği scroll doğru çalışsın diye.
    CGFloat totalH = 0.0;
    CGFloat paddingX = 12.0;
    CGFloat avatarSize = 30.0;
    CGFloat nameH = 16.0;
    CGFloat spacing = 4.0;
    CGFloat topPad = 10.0;
    CGFloat bottomPad = 10.0;

    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSDictionary *textAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.96 alpha:0.95]
    };

    CGFloat maxW = MAX(1.0, self.bounds.size.width - (paddingX * 2.0) - avatarSize - 10.0);
    for (DOChatMessage *m in self.messages ?: @[]) {
        NSString *author = m.authorName ?: @"Unknown";
        NSString *content = m.content ?: @"";
        (void)author;

        NSRect b = [content boundingRectWithSize:NSMakeSize(maxW, CGFLOAT_MAX)
                                           options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                        attributes:textAttrs
                                           context:nil];
        CGFloat textH = ceil(b.size.height);
        textH = MAX(18.0, textH);

        CGFloat rowH = topPad + nameH + spacing + textH + bottomPad;
        totalH += rowH + 10.0;
    }

    // Min height: boş mesajlarda panel tamamen kaybolmasın.
    totalH = MAX(totalH, 60.0);
    NSRect f = self.frame;
    f.size.height = totalH;
    [self setFrame:f];

    [self preloadAvatarsIfNeeded];
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect r = self.bounds;
    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSDictionary *textAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.96 alpha:0.95]
    };

    CGFloat paddingX = 12.0;
    CGFloat avatarSize = 30.0;
    CGFloat nameH = 16.0;
    CGFloat spacing = 4.0;
    CGFloat topPad = 10.0;
    CGFloat bottomPad = 10.0;

    CGFloat maxW = MAX(1.0, r.size.width - (paddingX * 2.0) - avatarSize - 10.0);
    CGFloat y = 0.0;

    for (DOChatMessage *m in self.messages ?: @[]) {
        NSString *author = m.authorName ?: @"Unknown";
        NSString *content = m.content ?: @"";

        NSRect b = [content boundingRectWithSize:NSMakeSize(maxW, CGFLOAT_MAX)
                                           options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                        attributes:textAttrs
                                           context:nil];
        CGFloat textH = ceil(b.size.height);
        textH = MAX(18.0, textH);

        CGFloat rowH = topPad + nameH + spacing + textH + bottomPad;

        NSRect bg = NSMakeRect(paddingX, y, r.size.width - paddingX * 2.0, rowH);
        NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:bg xRadius:12.0 yRadius:12.0];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.06] setFill];
        [bp fill];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] setStroke];
        [bp setLineWidth:1.0];
        [bp stroke];

        NSRect avatarRect = NSMakeRect(bg.origin.x + 10.0, bg.origin.y + topPad, avatarSize, avatarSize);
        NSString *key = [self avatarCacheKeyForMessage:m];
        NSImage *avatar = (key.length > 0) ? _avatarCache[key] : nil;

        // Avatar circle clip.
        NSBezierPath *clip = [NSBezierPath bezierPathWithOvalInRect:avatarRect];
        [NSGraphicsContext saveGraphicsState];
        [clip addClip];
        if (avatar) {
            [avatar drawInRect:avatarRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
        } else {
            [[NSColor colorWithCalibratedWhite:1.0 alpha:0.08] setFill];
            NSBezierPath *ph = [NSBezierPath bezierPathWithOvalInRect:avatarRect];
            [ph fill];

            NSString *initial = @"?";
            if (author.length > 0) initial = [[author substringToIndex:1] uppercaseString];
            NSDictionary *iAttrs = @{
                NSFontAttributeName: [NSFont boldSystemFontOfSize:12.0],
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.75]
            };
            NSSize is = [initial sizeWithAttributes:iAttrs];
            [initial drawAtPoint:NSMakePoint(NSMidX(avatarRect) - is.width/2.0, NSMidY(avatarRect) - is.height/2.0) withAttributes:iAttrs];
        }
        [NSGraphicsContext restoreGraphicsState];

        CGFloat textX = bg.origin.x + 10.0 + avatarSize + 10.0;
        CGFloat textY = bg.origin.y + topPad + 0.0;
        [author drawAtPoint:NSMakePoint(textX, textY) withAttributes:nameAttrs];

        NSRect textR = NSMakeRect(textX, textY + nameH + spacing, maxW, textH);
        [content drawWithRect:textR options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading) attributes:textAttrs];

        y += rowH + 10.0;
    }
}

@end

@interface DOChatView : NSView
@property (nonatomic, copy) void (^onSelectGuild)(NSString *guildId);
@property (nonatomic, copy) void (^onSelectChannel)(DOChatChannel *channel);
@property (nonatomic, copy) void (^onSendMessage)(NSString *text);

@property (nonatomic, strong) NSArray<DOChatGuild *> *guilds;
@property (nonatomic, strong) NSArray<DOChatChannel *> *channels;
@property (nonatomic, strong) NSArray<DOChatMessage *> *messages;
@property (nonatomic, copy) NSString *selectedGuildId;
@property (nonatomic, copy) NSString *selectedChannelId;

- (void)reloadUI;
@end

@implementation DOChatView {
    NSScrollView *_serversScroll;
    NSScrollView *_channelsScroll;
    NSScrollView *_messagesScroll;

    DOChatSidebarListDocumentView *_serversDoc;
    DOChatSidebarListDocumentView *_channelsDoc;
    NSMutableSet<NSString *> *_collapsedFolderIds;

    NSView *_messagesView;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    _collapsedFolderIds = [NSMutableSet set];

    CGFloat leftW = 72.0;
    CGFloat midW = 226.0;
    CGFloat bottomH = 0.0;
    CGFloat padding = 12.0;

    NSRect content = NSInsetRect(self.bounds, padding, padding);
    CGFloat topH = content.size.height - bottomH - 0.0;

    NSRect serversFrame = NSMakeRect(content.origin.x, content.origin.y, leftW, topH);
    NSRect channelsFrame = NSMakeRect(content.origin.x + leftW, content.origin.y, midW, topH);
    NSRect messagesFrame = NSMakeRect(content.origin.x + leftW + midW, content.origin.y, content.size.width - leftW - midW, topH);

    _serversScroll = [[NSScrollView alloc] initWithFrame:serversFrame];
    _serversScroll.hasVerticalScroller = YES;
    _serversScroll.drawsBackground = NO;
    _serversScroll.autohidesScrollers = YES;
    _serversScroll.borderType = NSNoBorder;

    DO_WEAK typeof(self) weakSelf = self;
    _serversDoc = [[DOChatSidebarListDocumentView alloc] initWithFrame:NSMakeRect(0, 0, serversFrame.size.width, 1)];
    _serversDoc.imageOnly = YES;
    _serversDoc.rowHeight = 58.0;
    _serversDoc.onItemSelected = ^(NSString *gid) {
        DOChatView *strongSelf = weakSelf;
        if (!strongSelf) return;
        DOChatGuild *selected = nil;
        for (DOChatGuild *g in strongSelf->_serversDoc.items ?: @[]) {
            NSString *itemId = g.folder ? g.folderId : g.guildId;
            if ([itemId isEqualToString:gid]) {
                selected = g;
                break;
            }
        }
        if (selected.folder) {
            NSString *folderId = selected.folderId ?: @"";
            if ([strongSelf->_collapsedFolderIds containsObject:folderId]) {
                [strongSelf->_collapsedFolderIds removeObject:folderId];
            } else if (folderId.length > 0) {
                [strongSelf->_collapsedFolderIds addObject:folderId];
            }
            [strongSelf reloadUI];
            return;
        }
        strongSelf.selectedGuildId = selected.guildId ?: gid ?: @"";
        if (strongSelf.onSelectGuild) strongSelf.onSelectGuild(strongSelf.selectedGuildId);
        [strongSelf reloadUI];
    };
    _serversDoc.titleForItem = ^NSString *(id item) {
        DOChatGuild *g = (DOChatGuild *)item;
        return g.name ?: @"";
    };
    _serversDoc.idForItem = ^NSString *(id item) {
        DOChatGuild *g = (DOChatGuild *)item;
        return g.folder ? (g.folderId ?: @"") : (g.guildId ?: @"");
    };
    _serversDoc.imageURLForItem = ^NSString *(id item) {
        DOChatGuild *g = (DOChatGuild *)item;
        if (g.folder) return @"";
        return DOGuildIconURLString(g.guildId ?: @"", g.iconHash ?: @"");
    };
    _serversDoc.isFolderItem = ^BOOL(id item) {
        DOChatGuild *g = (DOChatGuild *)item;
        return g.folder;
    };
    _serversDoc.folderColorForItem = ^NSColor *(id item) {
        DOChatGuild *g = (DOChatGuild *)item;
        return g.folderColor;
    };
    _serversScroll.documentView = _serversDoc;
    [self addSubview:_serversScroll];

    _channelsScroll = [[NSScrollView alloc] initWithFrame:channelsFrame];
    _channelsScroll.hasVerticalScroller = YES;
    _channelsScroll.drawsBackground = NO;
    _channelsScroll.autohidesScrollers = YES;
    _channelsScroll.borderType = NSNoBorder;

    _channelsDoc = [[DOChatSidebarListDocumentView alloc] initWithFrame:NSMakeRect(0, 0, channelsFrame.size.width, 1)];
    _channelsDoc.onItemSelected = ^(NSString *cid) {
        DOChatView *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.selectedChannelId = cid ?: @"";
        DOChatChannel *selected = nil;
        for (DOChatChannel *c in strongSelf.channels ?: @[]) {
            if ([c.channelId isEqualToString:cid]) {
                selected = c;
                break;
            }
        }
        if (strongSelf.onSelectChannel) strongSelf.onSelectChannel(selected);
        [strongSelf reloadUI];
    };
    _channelsDoc.titleForItem = ^NSString *(id item) {
        DOChatChannel *c = (DOChatChannel *)item;
        return c.name ?: @"";
    };
    _channelsDoc.idForItem = ^NSString *(id item) {
        DOChatChannel *c = (DOChatChannel *)item;
        return c.channelId ?: @"";
    };
    _channelsDoc.leadingSymbolForItem = ^NSString *(id item) {
        DOChatChannel *c = (DOChatChannel *)item;
        if (c.type == 2) return @"voice";
        if (c.type == 0) return @"text";
        return @"";
    };
    _channelsScroll.documentView = _channelsDoc;
    [self addSubview:_channelsScroll];

    _messagesScroll = [[NSScrollView alloc] initWithFrame:messagesFrame];
    _messagesScroll.hasVerticalScroller = YES;
    _messagesScroll.drawsBackground = NO;
    _messagesScroll.autohidesScrollers = YES;
    _messagesScroll.borderType = NSNoBorder;

    _messagesView = [[DOChatMessagesView alloc] initWithFrame:NSMakeRect(0, 0, messagesFrame.size.width, topH)];
    _messagesScroll.documentView = _messagesView;
    [self addSubview:_messagesScroll];

    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSArray<DOChatGuild *> *)visibleGuildSidebarItems {
    NSMutableArray<DOChatGuild *> *visible = [NSMutableArray array];
    NSMutableSet<NSString *> *hiddenGuildIds = [NSMutableSet set];

    for (DOChatGuild *g in self.guilds ?: @[]) {
        if (g.folder) {
            [visible addObject:g];
            NSString *folderId = g.folderId ?: @"";
            if (folderId.length > 0 && [_collapsedFolderIds containsObject:folderId]) {
                for (NSString *gid in g.folderGuildIds ?: @[]) {
                    if (gid.length > 0) [hiddenGuildIds addObject:gid];
                }
            }
            continue;
        }

        if (g.guildId.length > 0 && [hiddenGuildIds containsObject:g.guildId]) continue;
        [visible addObject:g];
    }

    return visible;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect r = self.bounds;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:16.0 yRadius:16.0];
    [[NSColor colorWithCalibratedWhite:0.04 alpha:0.88] setFill];
    [bg fill];
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.12] setStroke];
    [bg setLineWidth:1.0];
    [bg stroke];
}

- (void)reloadUI {
    // Update left sidebar
    NSArray<DOChatGuild *> *visibleGuilds = [self visibleGuildSidebarItems];
    NSInteger selectedGuildIndex = -1;
    if (self.selectedGuildId.length > 0) {
        for (NSInteger i = 0; i < (NSInteger)visibleGuilds.count; i++) {
            DOChatGuild *g = visibleGuilds[i];
            if (!g.folder && [g.guildId isEqualToString:self.selectedGuildId]) {
                selectedGuildIndex = i;
                break;
            }
        }
    }
    _serversDoc.items = visibleGuilds ?: @[];
    _serversDoc.selectedIndex = selectedGuildIndex;
    CGFloat serversH = MAX(_serversDoc.rowHeight, (_serversDoc.items.count * _serversDoc.rowHeight));
    NSRect serversDocFrame = _serversDoc.frame;
    serversDocFrame.size.height = serversH;
    _serversDoc.frame = serversDocFrame;
    [_serversDoc setNeedsDisplay:YES];

    // Update channel sidebar
    NSInteger selectedChannelIndex = -1;
    if (self.selectedChannelId.length > 0) {
        for (NSInteger i = 0; i < (NSInteger)self.channels.count; i++) {
            DOChatChannel *c = self.channels[i];
            if ([c.channelId isEqualToString:self.selectedChannelId]) {
                selectedChannelIndex = i;
                break;
            }
        }
    }
    _channelsDoc.items = self.channels ?: @[];
    _channelsDoc.selectedIndex = selectedChannelIndex;
    CGFloat channelsH = MAX(_channelsDoc.rowHeight, (_channelsDoc.items.count * _channelsDoc.rowHeight));
    NSRect channelsDocFrame = _channelsDoc.frame;
    channelsDocFrame.size.height = channelsH;
    _channelsDoc.frame = channelsDocFrame;
    [_channelsDoc setNeedsDisplay:YES];

    if (_messagesView && [_messagesView isKindOfClass:[DOChatMessagesView class]]) {
        DOChatMessagesView *mv = (DOChatMessagesView *)_messagesView;
        mv.messages = self.messages ?: @[];
        [mv reloadLayout];
    }
}

@end

#pragma mark - Notifications View

@interface DONotificationsView : NSView
@property (nonatomic, assign) BOOL editMode;
@property (nonatomic, assign) BOOL showOutsideEditMode;
@property (nonatomic, strong) NSArray<DONotification *> *notifications;
@property (nonatomic, copy) void (^toggleVisibilityHandler)(void);
@property (nonatomic, assign) BOOL isResizing;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) NSPoint dragStartScreen;
@property (nonatomic, assign) NSPoint dragWindowOrigin;
@property (nonatomic, assign) NSSize dragWindowSize;
@end

@implementation DONotificationsView

- (BOOL)isFlipped { return YES; }

- (NSRect)eyeRect {
    if (!self.editMode) return NSZeroRect;
    return NSMakeRect(self.bounds.size.width - 34.0 - 10.0, 10.0, 34.0, 34.0);
}

- (NSRect)resizeHandleRect {
    return NSMakeRect(self.bounds.size.width - 22.0, self.bounds.size.height - 22.0, 22.0, 22.0);
}

- (void)drawEyeIconInRect:(NSRect)rect slashed:(BOOL)slashed {
    NSColor *c = [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];
    [c setStroke];
    [c setFill];
    CGFloat w = rect.size.width, h = rect.size.height;
    NSPoint o = rect.origin;

    NSBezierPath *eye = [NSBezierPath bezierPath];
    [eye moveToPoint:NSMakePoint(o.x + w * 0.14, o.y + h * 0.55)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.74)
        controlPoint1:NSMakePoint(o.x + w * 0.26, o.y + h * 0.78)
        controlPoint2:NSMakePoint(o.x + w * 0.40, o.y + h * 0.86)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.86, o.y + h * 0.55)
        controlPoint1:NSMakePoint(o.x + w * 0.60, o.y + h * 0.86)
        controlPoint2:NSMakePoint(o.x + w * 0.74, o.y + h * 0.78)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.50, o.y + h * 0.36)
        controlPoint1:NSMakePoint(o.x + w * 0.74, o.y + h * 0.32)
        controlPoint2:NSMakePoint(o.x + w * 0.60, o.y + h * 0.24)];
    [eye curveToPoint:NSMakePoint(o.x + w * 0.14, o.y + h * 0.55)
        controlPoint1:NSMakePoint(o.x + w * 0.40, o.y + h * 0.24)
        controlPoint2:NSMakePoint(o.x + w * 0.26, o.y + h * 0.32)];
    [eye closePath];
    [eye setLineWidth:1.9];
    [eye stroke];

    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(o.x + w * 0.44, o.y + h * 0.48, w * 0.12, h * 0.12)] fill];

    if (slashed) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.33 blue:0.33 alpha:1.0] setStroke];
        NSBezierPath *slash = [NSBezierPath bezierPath];
        [slash moveToPoint:NSMakePoint(o.x + w * 0.18, o.y + h * 0.25)];
        [slash lineToPoint:NSMakePoint(o.x + w * 0.88, o.y + h * 0.84)];
        [slash setLineWidth:2.2];
        [slash stroke];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    BOOL shouldDraw = self.editMode || self.showOutsideEditMode;
    if (!shouldDraw) return;

    if (self.editMode) {
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2.0, 2.0)
                                                               xRadius:18.0 yRadius:18.0];
        CGFloat dash[2] = { 6.0, 4.0 };
        [border setLineDash:dash count:2 phase:0];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.28] setStroke];
        [border setLineWidth:2.0];
        [border stroke];

        NSRect eyeR = [self eyeRect];
        NSBezierPath *eyeBg = [NSBezierPath bezierPathWithOvalInRect:eyeR];
        [[NSColor colorWithCalibratedWhite:0.10 alpha:0.90] setFill];
        [eyeBg fill];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] setStroke];
        [eyeBg setLineWidth:1.0];
        [eyeBg stroke];
        [self drawEyeIconInRect:NSInsetRect(eyeR, 7.0, 7.0) slashed:(!self.showOutsideEditMode)];

        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.12] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect([self resizeHandleRect], 4.0, 4.0) xRadius:6.0 yRadius:6.0] fill];
    }

    NSArray<DONotification *> *notifs = self.notifications ?: @[];
    if (!self.showOutsideEditMode && !self.editMode) return;
    if (notifs.count == 0) return;

    CGFloat x = 10.0, y = 10.0, maxW = self.bounds.size.width - 20.0;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1.0 alpha:0.95]
    };

    NSInteger shown = 0;
    for (DONotification *n in notifs) {
        if (shown >= 4) break;
        NSString *t = n.text ?: @"";
        if (t.length == 0) continue;

        NSSize ts = [t sizeWithAttributes:attrs];
        CGFloat h = MAX(28.0, ts.height + 12.0);
        NSRect pill = NSMakeRect(x, y, MIN(maxW, ts.width + 18.0), h);

        NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:14.0 yRadius:14.0];
        [[NSColor colorWithCalibratedWhite:0.05 alpha:0.82] setFill];
        [bg fill];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.10] setStroke];
        [bg setLineWidth:1.0];
        [bg stroke];

        [t drawAtPoint:NSMakePoint(pill.origin.x + 9.0, pill.origin.y + (h - ts.height) / 2.0 - 1.0)
        withAttributes:attrs];

        y += h + 8.0;
        shown++;
        if (y > self.bounds.size.height - 34.0) break;
    }
}

- (void)mouseDown:(NSEvent *)event {
    if (!self.editMode) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

    if (NSPointInRect(p, [self eyeRect])) {
        if (self.toggleVisibilityHandler) self.toggleVisibilityHandler();
        return;
    }

    if (NSPointInRect(p, [self resizeHandleRect])) {
        self.isResizing = YES;
        self.dragStartScreen = [NSEvent mouseLocation];
        self.dragWindowOrigin = self.window.frame.origin;
        self.dragWindowSize = self.window.frame.size;
        return;
    }

    self.isDragging = YES;
    self.dragStartScreen = [NSEvent mouseLocation];
    self.dragWindowOrigin = self.window.frame.origin;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.editMode) return;
    NSPoint now = [NSEvent mouseLocation];
    CGFloat dx = now.x - self.dragStartScreen.x;
    CGFloat dy = now.y - self.dragStartScreen.y;

    if (self.isResizing) {
        NSRect f = self.window.frame;
        f.size.width = MAX(220.0, self.dragWindowSize.width + dx);
        f.size.height = MAX(120.0, self.dragWindowSize.height - dy);
        f.origin.y = self.dragWindowOrigin.y + dy;
        [self.window setFrame:f display:YES];
        [self setFrame:NSMakeRect(0, 0, f.size.width, f.size.height)];
        [self setNeedsDisplay:YES];
        return;
    }

    if (self.isDragging) {
        NSPoint o = self.dragWindowOrigin;
        o.x += dx;
        o.y += dy;
        [self.window setFrameOrigin:o];
    }
}

- (void)mouseUp:(NSEvent *)event {
    self.isDragging = NO;
    self.isResizing = NO;
}

@end

#pragma mark - Controller

@interface DOOverlayController : NSObject
@property (nonatomic, strong) NSWindow *voiceWindow;
@property (nonatomic, strong) NSWindow *controlsWindow;
@property (nonatomic, strong) DOVoiceView *voiceView;
@property (nonatomic, strong) DOCallBarView *callBarView;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *avatarCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *loadingAvatars;
@property (nonatomic, assign) BOOL editMode;
@property (nonatomic, assign) BOOL voiceVisible;
@property (nonatomic, assign) BOOL controlsVisible;
@property (nonatomic, strong) NSTimer *hotkeyPollTimer;
@property (nonatomic, assign) BOOL hotkeyWasDown;
@property (nonatomic, strong) NSWindow *hudWindow;
@property (nonatomic, assign) BOOL voiceCustomPosition;
@property (nonatomic, assign) BOOL controlsCustomPosition;
@property (nonatomic, strong) NSWindow *notificationsWindow;
@property (nonatomic, strong) NSView *notificationsView;
@property (nonatomic, assign) BOOL notificationsVisible;
@property (nonatomic, assign) BOOL notificationsCustomFrame;
@property (nonatomic, strong) NSMutableArray<DONotification *> *notifications;
@property (nonatomic, copy) NSString *hostBundleIdentifier;
@property (nonatomic, strong) NSWindow *messageWindow;
@property (nonatomic, strong) NSView *messageView;
@end

@implementation DOOverlayController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.avatarCache = [NSMutableDictionary dictionary];
    self.loadingAvatars = [NSMutableSet set];
    self.voiceVisible = YES;
    self.controlsVisible = YES;
    self.notificationsVisible = YES;
    self.notifications = [NSMutableArray array];

    self.hostBundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";

    [self createVoiceWindow];
    [self createControlsWindow];
    [self createHUDWindow];
    [self createNotificationsWindow];
    [self createMessageWindow];
    [self startHotkeyPolling];

    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(activeSpaceDidChange:)
                                                               name:NSWorkspaceActiveSpaceDidChangeNotification
                                                             object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidResignActive:)
                                                 name:NSApplicationDidResignActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];

    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                      target:self
                                                    selector:@selector(tick)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];

    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.pollTimer invalidate];
    [self.hotkeyPollTimer invalidate];
    DO_SUPER_DEALLOC();
}

- (void)tick {
    [self reloadStateFromSharedMemory];
    [self reloadChatStateFromSharedMemory];
    [self reloadNotificationsFromSharedMemory];
    [self pruneNotifications];
}

- (BOOL)isHostAppFrontmost {
    NSRunningApplication *frontmost = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (!frontmost) return NO;

    if (self.hostBundleIdentifier.length > 0) {
        NSString *frontmostBundleId = frontmost.bundleIdentifier ?: @"";
        if (frontmostBundleId.length == 0) return NO;
        return [frontmostBundleId isEqualToString:self.hostBundleIdentifier];
    }

    // Fallback: bundleIdentifier güvenilir değilse PID'den eşle.
    return frontmost.processIdentifier == getpid();
}

- (BOOL)shouldShowOverlayNow {
    if (self.voiceView.users.count == 0) return NO;
    return [self isHostAppFrontmost];
}

- (void)appDidResignActive:(NSNotification *)note {
    // Not: Search/modal gibi durumlarda `NSApplicationDidResignActiveNotification`
    // tetiklenebiliyor ve bu sırada overlay pencerelerini `orderOut` yapmak,
    // bazen tekrar görünmesini zorlaştırıyor. Bu yüzden görünürlük kontrolünü
    // tamamen `reloadStateFromSharedMemory` + `tick` üzerine bırakıyoruz.
}

- (void)appDidBecomeActive:(NSNotification *)note {
    if (![self shouldShowOverlayNow]) return;
    [self updateVoiceWindowVisibility];
    [self updateControlsWindowVisibility];
    [self updateNotificationsWindowVisibility];
    [self updateMessageWindowVisibility];
    if (self.editMode) {
        [self repositionHUDToTopRight];
        [self.hudWindow orderFrontRegardless];
    }
}

#pragma mark - Layout

- (void)repositionVoiceWindowToLeftMiddle {
    if (self.editMode || self.voiceCustomPosition) return;
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen || !self.voiceWindow) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = self.voiceWindow.frame;
    frame.origin.x = NSMinX(visible) + 18.0;
    frame.origin.y = NSMidY(visible) - (frame.size.height / 2.0);
    [self.voiceWindow setFrameOrigin:frame.origin];
}

- (void)repositionControlsWindowToTopCenter {
    if (self.editMode || self.controlsCustomPosition) return;
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen || !self.controlsWindow) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = self.controlsWindow.frame;
    frame.origin.x = NSMidX(visible) - (frame.size.width / 2.0);
    frame.origin.y = NSMaxY(visible) - frame.size.height - 18.0;
    [self.controlsWindow setFrameOrigin:frame.origin];
}

- (void)repositionNotificationsWindowToTopLeft {
    if (self.editMode || self.notificationsCustomFrame) return;
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen || !self.notificationsWindow) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = self.notificationsWindow.frame;
    frame.origin.x = NSMinX(visible) + 18.0;
    frame.origin.y = NSMaxY(visible) - frame.size.height - 18.0;
    [self.notificationsWindow setFrameOrigin:frame.origin];
}

#pragma mark - Window Create

- (void)createVoiceWindow {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = NSMakeRect(NSMinX(visible) + 18.0, NSMidY(visible) - 70.0, 290.0, 140.0);

    self.voiceWindow = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskBorderless
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    self.voiceWindow.opaque = NO;
    self.voiceWindow.backgroundColor = NSColor.clearColor;
    self.voiceWindow.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
    self.voiceWindow.ignoresMouseEvents = YES;
    self.voiceWindow.hasShadow = NO;
    self.voiceWindow.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    self.voiceView = [[DOVoiceView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    self.voiceView.users = @[];
    self.voiceView.channelName = @"Voice";
    self.voiceView.hostWindow = self.voiceWindow;
    self.voiceView.showOutsideEditMode = self.voiceVisible;
    DO_WEAK typeof(self) weakSelf = self;
    self.voiceView.toggleVisibilityHandler = ^{ [weakSelf toggleVoiceVisibility]; };
    self.voiceWindow.contentView = self.voiceView;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidMove:)
                                                 name:NSWindowDidMoveNotification object:self.voiceWindow];

    [self.voiceWindow orderOut:nil];
}

- (void)createControlsWindow {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = NSMakeRect(NSMidX(visible) - 236.0, NSMaxY(visible) - 96.0, 472.0, 78.0);

    self.controlsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    self.controlsWindow.opaque = NO;
    self.controlsWindow.backgroundColor = NSColor.clearColor;
    self.controlsWindow.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
    self.controlsWindow.hasShadow = NO;
    self.controlsWindow.ignoresMouseEvents = NO;
    self.controlsWindow.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    self.callBarView = [[DOCallBarView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    DO_WEAK typeof(self) weakSelf = self;
    self.callBarView.toggleVisibilityHandler = ^{ [weakSelf toggleControlsVisibility]; };
    self.callBarView.showOutsideEditMode = self.controlsVisible;
    self.controlsWindow.contentView = self.callBarView;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidMove:)
                                                 name:NSWindowDidMoveNotification object:self.controlsWindow];

    [self.controlsWindow orderOut:nil];
}

- (void)createNotificationsWindow {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = NSMakeRect(NSMinX(visible) + 18.0, NSMaxY(visible) - 198.0, 320.0, 180.0);

    self.notificationsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                           styleMask:NSWindowStyleMaskBorderless
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
    self.notificationsWindow.opaque = NO;
    self.notificationsWindow.backgroundColor = NSColor.clearColor;
    self.notificationsWindow.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
    self.notificationsWindow.hasShadow = NO;
    self.notificationsWindow.ignoresMouseEvents = YES;
    self.notificationsWindow.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    DONotificationsView *view = [[DONotificationsView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    view.editMode = self.editMode;
    view.showOutsideEditMode = self.notificationsVisible;
    DO_WEAK typeof(self) weakSelf = self;
    view.toggleVisibilityHandler = ^{ [weakSelf toggleNotificationsVisibility]; };

    self.notificationsView = view;
    self.notificationsWindow.contentView = view;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidMove:)
                                                 name:NSWindowDidMoveNotification object:self.notificationsWindow];

    [self.notificationsWindow orderOut:nil];
}

- (void)createMessageWindow {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = NSMakeRect(NSMidX(visible) - 450.0, NSMidY(visible) - 260.0, 900.0, 520.0);

    self.messageWindow = [[DOOverlayChatWindow alloc] initWithContentRect:frame
                                                      styleMask:NSWindowStyleMaskBorderless
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
    self.messageWindow.opaque = NO;
    self.messageWindow.backgroundColor = NSColor.clearColor;
    self.messageWindow.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
    self.messageWindow.hasShadow = NO;
    self.messageWindow.ignoresMouseEvents = NO;
    self.messageWindow.movable = NO; // sürüklenmesin.
    self.messageWindow.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    DOChatView *chatView = [[DOChatView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    chatView.onSelectGuild = ^(NSString *gid) {
        if (gid.length == 0) return;
        [[DODiscordIPCManager shared] selectTextGuildId:gid];
    };
    chatView.onSelectChannel = ^(DOChatChannel *channel) {
        if (channel.channelId.length == 0) return;
        if (channel.type == 2) {
            [[DODiscordIPCManager shared] joinVoiceChannelId:channel.channelId];
        } else {
            [[DODiscordIPCManager shared] selectTextChannelId:channel.channelId];
        }
    };
    chatView.onSendMessage = ^(NSString *text) {
        (void)text;
        DOLog(@"Text send isn't implemented via Discord RPC in this overlay.");
    };
    self.messageView = chatView;

    self.messageWindow.contentView = self.messageView;
    [self.messageWindow orderOut:nil];
}

- (void)createHUDWindow {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = NSMakeRect(NSMaxX(visible) - 138.0, NSMaxY(visible) - 52.0, 120.0, 34.0);

    self.hudWindow = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    self.hudWindow.opaque = NO;
    self.hudWindow.backgroundColor = NSColor.clearColor;
    self.hudWindow.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
    self.hudWindow.hasShadow = NO;
    self.hudWindow.ignoresMouseEvents = YES;
    self.hudWindow.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorIgnoresCycle;

    self.hudWindow.contentView = [[DOEditModeHUDView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    [self.hudWindow orderOut:nil];
}

- (void)repositionHUDToTopRight {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen || !self.hudWindow) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = self.hudWindow.frame;
    frame.origin.x = NSMaxX(visible) - frame.size.width - 18.0;
    frame.origin.y = NSMaxY(visible) - frame.size.height - 18.0;
    [self.hudWindow setFrameOrigin:frame.origin];
}

- (void)repositionMessageWindowToCenter {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen || !self.messageWindow) return;

    NSRect visible = screen.visibleFrame;
    NSRect frame = self.messageWindow.frame;
    frame.origin.x = NSMidX(visible) - frame.size.width / 2.0;
    frame.origin.y = NSMidY(visible) - frame.size.height / 2.0;
    [self.messageWindow setFrameOrigin:frame.origin];
}

- (void)updateMessageWindowVisibility {
    BOOL shouldShow = self.editMode && [self isHostAppFrontmost];
    if (shouldShow) {
        [self repositionMessageWindowToCenter];
        [self.messageWindow orderFrontRegardless];
    } else {
        [self.messageWindow orderOut:nil];
    }
}

#pragma mark - Edit Mode

- (void)setEditMode:(BOOL)editMode {
    _editMode = editMode;
    self.voiceView.editMode = editMode;
    self.voiceView.showOutsideEditMode = self.voiceVisible;
    self.callBarView.editMode = editMode;
    self.callBarView.showOutsideEditMode = self.controlsVisible;
    self.voiceWindow.ignoresMouseEvents = !editMode;
    self.notificationsWindow.ignoresMouseEvents = !editMode;

    if ([self.notificationsView isKindOfClass:[DONotificationsView class]]) {
        DONotificationsView *v = (DONotificationsView *)self.notificationsView;
        v.editMode = editMode;
        v.showOutsideEditMode = self.notificationsVisible;
        v.notifications = self.notifications;
        [v setNeedsDisplay:YES];
    }

    [self.voiceView setNeedsDisplay:YES];
    [self.callBarView setNeedsDisplay:YES];
    [self updateVoiceWindowVisibility];
    [self updateControlsWindowVisibility];
    [self updateNotificationsWindowVisibility];
    [self updateMessageWindowVisibility];

    if (editMode) {
        if ([self shouldShowOverlayNow]) {
            [self repositionHUDToTopRight];
            [self.hudWindow orderFrontRegardless];
        } else {
            [self.hudWindow orderOut:nil];
        }
    } else {
        [self.hudWindow orderOut:nil];
    }
}

- (void)toggleEditMode { self.editMode = !self.editMode; }

#pragma mark - Space / Fullscreen

- (void)activeSpaceDidChange:(NSNotification *)note {
    if (![self shouldShowOverlayNow]) return;

    [self updateVoiceWindowVisibility];
    [self updateControlsWindowVisibility];
    if (!self.editMode) {
        [self repositionVoiceWindowToLeftMiddle];
        [self repositionControlsWindowToTopCenter];
        [self repositionNotificationsWindowToTopLeft];
    }
    if (self.editMode) {
        [self repositionHUDToTopRight];
        [self.hudWindow orderFrontRegardless];
    }
    [self updateNotificationsWindowVisibility];
    [self updateMessageWindowVisibility];
}

- (void)windowDidMove:(NSNotification *)note {
    if (!self.editMode) return;
    if (note.object == self.voiceWindow) self.voiceCustomPosition = YES;
    else if (note.object == self.controlsWindow) self.controlsCustomPosition = YES;
    else if (note.object == self.notificationsWindow) self.notificationsCustomFrame = YES;
}

#pragma mark - Controls Visibility

- (void)showOverlayWindow:(NSWindow *)window {
    if (!window) return;
    NSInteger overlayLevel = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
    if (window.level != overlayLevel) window.level = overlayLevel;
    if (!window.isVisible) [window orderFrontRegardless];
}

- (void)hideOverlayWindow:(NSWindow *)window {
    if (!window) return;
    if (!window.isVisible && window.level == NSNormalWindowLevel && window.ignoresMouseEvents) return;
    if (!window.ignoresMouseEvents) window.ignoresMouseEvents = YES;
    if (window.level != NSNormalWindowLevel) window.level = NSNormalWindowLevel;
    if (window.isKeyWindow) [window resignKeyWindow];
    if (window.isVisible) {
        [window orderBack:nil];
        [window orderOut:nil];
    }
}

- (void)updateVoiceWindowVisibility {
    BOOL hasUsers = (self.voiceView.users.count > 0);
    if (!hasUsers || ![self isHostAppFrontmost]) {
        [self hideOverlayWindow:self.voiceWindow];
        return;
    }

    if (self.editMode || self.voiceVisible) {
        self.voiceWindow.ignoresMouseEvents = !self.editMode;
        [self showOverlayWindow:self.voiceWindow];
        if (!self.editMode) [self repositionVoiceWindowToLeftMiddle];
    } else {
        [self hideOverlayWindow:self.voiceWindow];
    }
}

- (void)toggleVoiceVisibility {
    if (!self.editMode) return;
    self.voiceVisible = !self.voiceVisible;
    self.voiceView.showOutsideEditMode = self.voiceVisible;
    [self.voiceView setNeedsDisplay:YES];
    [self updateVoiceWindowVisibility];
}

- (void)updateControlsWindowVisibility {
    BOOL hasUsers = (self.voiceView.users.count > 0);
    if (!hasUsers || ![self isHostAppFrontmost]) {
        [self hideOverlayWindow:self.controlsWindow];
        return;
    }
    BOOL shouldShow = hasUsers && (self.editMode || self.controlsVisible);

    if (shouldShow) {
        self.controlsWindow.ignoresMouseEvents = NO;
        [self showOverlayWindow:self.controlsWindow];
        if (!self.editMode) [self repositionControlsWindowToTopCenter];
    } else {
        [self hideOverlayWindow:self.controlsWindow];
    }
}

- (void)toggleControlsVisibility {
    if (!self.editMode) return;
    self.controlsVisible = !self.controlsVisible;
    self.callBarView.showOutsideEditMode = self.controlsVisible;
    [self.callBarView setNeedsDisplay:YES];
    [self updateControlsWindowVisibility];
}

#pragma mark - Notifications

- (void)updateNotificationsWindowVisibility {
    BOOL hasUsers = (self.voiceView.users.count > 0);
    BOOL hasNotifs = (self.notifications.count > 0);
    if (!hasUsers || ![self isHostAppFrontmost]) {
        [self hideOverlayWindow:self.notificationsWindow];
        return;
    }
    BOOL shouldShow = hasUsers && (self.editMode || (self.notificationsVisible && hasNotifs));

    if (shouldShow) {
        self.notificationsWindow.ignoresMouseEvents = !self.editMode;
        [self showOverlayWindow:self.notificationsWindow];
        if (!self.editMode) [self repositionNotificationsWindowToTopLeft];
    } else {
        [self hideOverlayWindow:self.notificationsWindow];
    }
}

- (void)toggleNotificationsVisibility {
    if (!self.editMode) return;
    self.notificationsVisible = !self.notificationsVisible;
    if ([self.notificationsView isKindOfClass:[DONotificationsView class]]) {
        DONotificationsView *v = (DONotificationsView *)self.notificationsView;
        v.showOutsideEditMode = self.notificationsVisible;
        [v setNeedsDisplay:YES];
    }
    [self updateNotificationsWindowVisibility];
}

- (void)pruneNotifications {
    if (self.notifications.count == 0) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    NSIndexSet *dead = [self.notifications indexesOfObjectsPassingTest:^BOOL(DONotification *obj, NSUInteger idx, BOOL *stop) {
        return (obj.ttl > 0 && (now - obj.createdAt) > obj.ttl);
    }];

    if (dead.count > 0) {
        [self.notifications removeObjectsAtIndexes:dead];
        [self.notificationsView setNeedsDisplay:YES];
        [self updateNotificationsWindowVisibility];
    }
}

- (void)reloadNotificationsFromSharedMemory {
    NSArray<DONotification *> *snap = [[DOSharedState shared] notificationsSnapshot];
    [self.notifications removeAllObjects];
    [self.notifications addObjectsFromArray:snap];

    if ([self.notificationsView isKindOfClass:[DONotificationsView class]]) {
        DONotificationsView *v = (DONotificationsView *)self.notificationsView;
        v.notifications = self.notifications;
        v.showOutsideEditMode = self.notificationsVisible;
        [v setNeedsDisplay:YES];
    }

    [self updateNotificationsWindowVisibility];
}

#pragma mark - Avatar

- (void)fetchAvatarForUser:(DOUser *)user cacheKey:(NSString *)cacheKey {
    if (cacheKey.length == 0) return;
    NSString *urlString = DOAvatarURLString(user.userId, user.avatarHash);
    if (urlString.length == 0) return;

    if (self.avatarCache[cacheKey]) {
        user.avatarImage = self.avatarCache[cacheKey];
        return;
    }

    if ([self.loadingAvatars containsObject:cacheKey]) return;
    [self.loadingAvatars addObject:cacheKey];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlString]];
        if (!imgData) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self.loadingAvatars removeObject:cacheKey]; });
            return;
        }

        NSImage *img = [[NSImage alloc] initWithData:imgData];
        if (!img) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self.loadingAvatars removeObject:cacheKey]; });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.avatarCache[cacheKey] = img;
            [self.loadingAvatars removeObject:cacheKey];

            for (DOUser *existing in self.voiceView.users) {
                if ([existing.userId isEqualToString:user.userId] &&
                    ((!existing.avatarHash && !user.avatarHash) ||
                     [existing.avatarHash isEqualToString:user.avatarHash])) {
                    existing.avatarImage = img;
                }
            }
            [self.voiceView setNeedsDisplay:YES];
        });
    });
}

- (void)fetchPrimaryGuildBadgeForUser:(DOUser *)user cacheKey:(NSString *)cacheKey {
    if (cacheKey.length == 0) return;
    NSString *urlString = DOGuildTagBadgeURLString(user.primaryGuildId ?: @"", user.primaryGuildBadgeHash ?: @"");
    if (urlString.length == 0) return;

    if (self.avatarCache[cacheKey]) {
        user.primaryGuildBadgeImage = self.avatarCache[cacheKey];
        return;
    }

    if ([self.loadingAvatars containsObject:cacheKey]) return;
    [self.loadingAvatars addObject:cacheKey];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSImage *img = DOFetchImageSync(urlString, @"voice primary guild badge");
        if (!img) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self.loadingAvatars removeObject:cacheKey]; });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.avatarCache[cacheKey] = img;
            [self.loadingAvatars removeObject:cacheKey];

            for (DOUser *existing in self.voiceView.users) {
                if ([existing.primaryGuildId isEqualToString:user.primaryGuildId] &&
                    [existing.primaryGuildBadgeHash isEqualToString:user.primaryGuildBadgeHash]) {
                    existing.primaryGuildBadgeImage = img;
                }
            }
            [self.voiceView setNeedsDisplay:YES];
        });
    });
}

#pragma mark - Resize

- (void)resizeVoiceWindowToFitUsers {
    CGFloat targetWidth = 290.0;
    CGFloat targetHeight = [self.voiceView panelHeight];

    NSRect frame = self.voiceWindow.frame;
    CGFloat delta = targetHeight - frame.size.height;

    frame.size.width = targetWidth;
    frame.size.height = targetHeight;
    frame.origin.y -= self.editMode ? delta : (delta / 2.0);

    [self.voiceWindow setFrame:frame display:YES animate:NO];
    [self.voiceView setFrame:NSMakeRect(0, 0, targetWidth, targetHeight)];

    if (!self.editMode) [self repositionVoiceWindowToLeftMiddle];
}

#pragma mark - Shared State → UI

- (void)reloadStateFromSharedMemory {
    DOSharedState *shared = [DOSharedState shared];
    NSArray<DOUser *> *snap = [shared usersSnapshot];
    NSString *channel = shared.channelName ?: @"Voice";
    DOLog(@"UI reload: users=%lu channel=%@ editMode=%d controlsVisible=%d", (unsigned long)snap.count, channel, self.editMode, self.controlsVisible);

    for (DOUser *user in snap) {
        NSString *cacheKey = (user.userId.length > 0 && user.avatarHash.length > 0)
            ? [NSString stringWithFormat:@"%@:%@", user.userId, user.avatarHash] : nil;

        if (cacheKey.length > 0) {
            NSImage *cached = self.avatarCache[cacheKey];
            if (cached) user.avatarImage = cached;
            else [self fetchAvatarForUser:user cacheKey:cacheKey];
        }

        NSString *primaryGuildBadgeKey = (user.primaryGuildId.length > 0 && user.primaryGuildBadgeHash.length > 0)
            ? [NSString stringWithFormat:@"primary-guild:%@:%@", user.primaryGuildId, user.primaryGuildBadgeHash] : nil;
        if (primaryGuildBadgeKey.length > 0) {
            NSImage *cachedBadge = self.avatarCache[primaryGuildBadgeKey];
            if (cachedBadge) user.primaryGuildBadgeImage = cachedBadge;
            else [self fetchPrimaryGuildBadgeForUser:user cacheKey:primaryGuildBadgeKey];
        }
    }

    self.voiceView.channelName = channel;
    self.voiceView.users = snap;
    self.voiceView.showOutsideEditMode = self.voiceVisible;
    [self resizeVoiceWindowToFitUsers];
    [self.voiceView setNeedsDisplay:YES];

    BOOL shouldShow = (snap.count > 0) && [self isHostAppFrontmost];
    if (shouldShow) {
        [self updateVoiceWindowVisibility];
        [self updateControlsWindowVisibility];
        [self updateNotificationsWindowVisibility];
        [self updateMessageWindowVisibility];

        if (self.editMode) {
            [self repositionHUDToTopRight];
            [self.hudWindow orderFrontRegardless];
        } else {
            [self repositionVoiceWindowToLeftMiddle];
            [self repositionControlsWindowToTopCenter];
            [self repositionNotificationsWindowToTopLeft];
            [self.hudWindow orderOut:nil];
        }
    } else {
        [self hideOverlayWindow:self.voiceWindow];
        [self hideOverlayWindow:self.controlsWindow];
        [self.hudWindow orderOut:nil];
        [self hideOverlayWindow:self.notificationsWindow];
    }

    [self updateMessageWindowVisibility];
}

- (void)reloadChatStateFromSharedMemory {
    if (!self.editMode) return;
    if (![self isHostAppFrontmost]) return;
    if (![self.messageView isKindOfClass:[DOChatView class]]) return;

    DOChatView *chatView = (DOChatView *)self.messageView;
    DOSharedState *shared = [DOSharedState shared];

    chatView.guilds = [shared guildsSnapshot];
    chatView.channels = [shared channelsSnapshot];
    chatView.messages = [shared messagesSnapshot];
    chatView.selectedGuildId = shared.selectedGuildId ?: @"";
    chatView.selectedChannelId = shared.selectedChannelId ?: @"";

    [chatView reloadUI];
}

#pragma mark - Hotkey

- (void)startHotkeyPolling {
    self.hotkeyWasDown = NO;
    self.hotkeyPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.03
                                                           target:self
                                                         selector:@selector(pollHotkey)
                                                         userInfo:nil
                                                          repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.hotkeyPollTimer forMode:NSRunLoopCommonModes];
}

- (void)pollHotkey {
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
    BOOL optionDown = ((flags & kCGEventFlagMaskAlternate) != 0);

    BOOL oDown = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, (CGKeyCode)kVK_ANSI_O);
    BOOL f8Down = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, (CGKeyCode)kVK_F8);

    BOOL hotDown = (f8Down || (optionDown && oDown));
    if (hotDown && !self.hotkeyWasDown) [self toggleEditMode];
    self.hotkeyWasDown = hotDown;
}

@end

#pragma mark - Bootstrap

static DOOverlayController *gController = nil;

static void DOEnsureCocoaLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *frameworks[] = {
            "/System/Library/Frameworks/Foundation.framework/Foundation",
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            "/System/Library/Frameworks/Cocoa.framework/Cocoa",
        };

        for (size_t i = 0; i < sizeof(frameworks) / sizeof(frameworks[0]); i++) {
            void *handle = dlopen(frameworks[i], RTLD_NOW | RTLD_GLOBAL);
            if (!handle) {
                const char *error = dlerror();
                fprintf(stderr, "[overlay] dlopen failed for %s: %s\n", frameworks[i], error ? error : "unknown");
            }
        }
    });
}

__attribute__((constructor))
static void DOOverlayStart(void) {
    DOEnsureCocoaLoaded();

    dispatch_async(dispatch_get_main_queue(), ^{
        NSApplication *app = [NSApplication sharedApplication];
        if (!app) {
            DOLog(@"constructor: NSApplication unavailable");
            return;
        }

        DOLog(@"constructor: started. pid=%d bundle=%@", getpid(), NSBundle.mainBundle.bundleIdentifier);
        [DODiscordIPCManager.shared start];
        DOLog(@"constructor: DODiscordIPCManager.start called");

        if (!gController) {
            gController = [DOOverlayController new];
            NSLog(@"[overlay] overlay + ipc started");
            DOLog(@"constructor: overlay controller created");
        }
    });
}
