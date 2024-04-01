#include <tiny3d.h>

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <CoreVideo/CVDisplayLink.h>

#include <AudioToolbox/AudioQueue.h>
#define FENSTER_SAMPLE_RATE 44100
#define FENSTER_AUDIO_BUFSZ 8192
struct fenster_audio {
	AudioQueueRef queue;
	size_t pos;
	signed short buf[FENSTER_AUDIO_BUFSZ*2];
	dispatch_semaphore_t drained;
	dispatch_semaphore_t full;
} audioState;
static void fenster_audio_cb(void *p, AudioQueueRef q, AudioQueueBufferRef b) {
	struct fenster_audio *fa = (struct fenster_audio *)p;
	dispatch_semaphore_wait(fa->full, DISPATCH_TIME_FOREVER);
	memmove(b->mAudioData, fa->buf, sizeof(fa->buf));
	dispatch_semaphore_signal(fa->drained);
	AudioQueueEnqueueBuffer(q, b, 0, NULL);
}
int fenster_audio_open(struct fenster_audio *fa) {
	AudioStreamBasicDescription fmt = {0};
	fmt.mSampleRate = FENSTER_SAMPLE_RATE;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
    fmt.mBytesPerFrame = (16 * 2) / 8;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = fmt.mFramesPerPacket * fmt.mBytesPerFrame;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 16;
    fmt.mReserved = 0;
	fa->drained = dispatch_semaphore_create(1);
	fa->full = dispatch_semaphore_create(0);
	AudioQueueNewOutput(&fmt, fenster_audio_cb, fa, NULL, NULL, 0, &fa->queue);
	for (int i = 0; i < 2; i++) {
		AudioQueueBufferRef buffer = NULL;
		AudioQueueAllocateBuffer(fa->queue, sizeof(fa->buf), &buffer);
		buffer->mAudioDataByteSize = sizeof(fa->buf);
		memset(buffer->mAudioData, 0, buffer->mAudioDataByteSize);
		AudioQueueEnqueueBuffer(fa->queue, buffer, 0, NULL);
	}
	AudioQueueStart(fa->queue, NULL);
	return 0;
}
void fenster_audio_close(struct fenster_audio *fa) {
	AudioQueueStop(fa->queue, false);
	AudioQueueDispose(fa->queue, false);
}
int fenster_audio_available(struct fenster_audio *fa) {
	if (dispatch_semaphore_wait(fa->drained, DISPATCH_TIME_NOW))
		return 0;
	return FENSTER_AUDIO_BUFSZ - fa->pos;
}

#include <time.h>
uint64_t get_time(void){
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t) ts.tv_sec * 1000000000 + (uint64_t) ts.tv_nsec;
}

#if defined(MAC_OS_X_VERSION_10_12) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_12
   static const NSAlertStyle kInformationalStyle = NSAlertStyleInformational;
   static const NSAlertStyle kWarningStyle = NSAlertStyleWarning;
   static const NSAlertStyle kCriticalStyle = NSAlertStyleCritical;
#else
   static const NSAlertStyle kInformationalStyle = NSInformationalAlertStyle;
   static const NSAlertStyle kWarningStyle = NSWarningAlertStyle;
   static const NSAlertStyle kCriticalStyle = NSCriticalAlertStyle;
#endif
void error_box(char *msg){
   NSAlert* alert = [[NSAlert alloc] init];

   [alert setMessageText:[NSString stringWithUTF8String:"Error"]];
   [alert setInformativeText:[NSString stringWithUTF8String:msg]];

   [alert setAlertStyle:kCriticalStyle];
   [alert addButtonWithTitle:@"Ok"];

   // Force the alert to appear on top of any other windows
   [[alert window] setLevel:NSModalPanelWindowLevel];

   [alert runModal];
   [alert release];
}

@interface MyOpenGLView : NSOpenGLView
@end
@implementation MyOpenGLView
- (void)drawRect:(NSRect)dirtyRect {
	static uint64_t tstart, t0, t1;
	static int timeSet = 0;
	if (!timeSet){
		tstart = get_time();
		t0 = tstart;
		timeSet = 1;
	}

	//https://stackoverflow.com/questions/2440089/nsopenglview-resize-on-window-resize
	int width = (int)[[self superview] bounds].size.width;
	int height = (int)[[self superview] bounds].size.height;

	t1 = get_time();

	int nSamples = fenster_audio_available(&audioState);
	#if USE_GL
		update((double)(t1-tstart) / 1000000000.0, (double)(t1-t0) / 1000000000.0, width, height, nSamples, audioState.buf+audioState.pos);
	#else
		update((double)(t1-tstart) / 1000000000.0, (double)(t1-t0) / 1000000000.0, nSamples, audioState.buf+audioState.pos);

		glViewport(0,0,width,height);

		glClearColor(0.0f,0.0f,1.0f,1.0f);
		glClear(GL_COLOR_BUFFER_BIT);

		static GLuint texture = 0;
		if (!texture){
			glGenTextures(1,&texture);
			glBindTexture(GL_TEXTURE_2D,texture);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		}
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, SCREEN_WIDTH, SCREEN_HEIGHT, 0, GL_BGRA, GL_UNSIGNED_BYTE, screen);
		int scale = 1;
		while (SCREEN_WIDTH*scale <= width && SCREEN_HEIGHT*scale <= height){
			scale++;
		}
		scale--;
		int scaledWidth = scale * SCREEN_WIDTH;
		int scaledHeight = scale * SCREEN_HEIGHT;
		int x = width/2-scaledWidth/2;
		int y = height/2-scaledHeight/2;
		glViewport(x,y,scaledWidth,scaledHeight);
		glEnable(GL_TEXTURE_2D);
		glBegin(GL_QUADS);
		glTexCoord2f(0,0); glVertex2f(-1,-1);
		glTexCoord2f(1,0); glVertex2f(1,-1);
		glTexCoord2f(1,1); glVertex2f(1,1);
		glTexCoord2f(0,1); glVertex2f(-1,1);
		glEnd();
	#endif

	audioState.pos += nSamples;
	if (audioState.pos >= FENSTER_AUDIO_BUFSZ){
		audioState.pos = 0;
		dispatch_semaphore_signal(audioState.full);
	}
	
	t0 = t1;

	[[self openGLContext] flushBuffer];
}
- (BOOL)acceptsFirstResponder {
	return YES;
}

- (void)mouseMoved:(NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Mouse pos: %lf, %lf", point.x, point.y);
	
}

- (void) mouseDragged: (NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Mouse pos: %lf, %lf", point.x, point.y);
	
}

- (void)scrollWheel: (NSEvent*) event  {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Mouse wheel at: %lf, %lf. Delta: %lf", point.x, point.y, [event deltaY]);
	
}

- (void) mouseDown: (NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Left mouse down: %lf, %lf", point.x, point.y);
	
}

- (void) mouseUp: (NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Left mouse up: %lf, %lf", point.x, point.y);
	
}

- (void) rightMouseDown: (NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Right mouse down: %lf, %lf", point.x, point.y);
	
}

- (void) rightMouseUp: (NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Right mouse up: %lf, %lf", point.x, point.y);
	
}

- (void)otherMouseDown: (NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Middle mouse down: %lf, %lf", point.x, point.y);
	
}

- (void)otherMouseUp: (NSEvent*) event {
	
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSLog(@"Middle mouse up: %lf, %lf", point.x, point.y);
	
}

- (void) mouseEntered: (NSEvent*)event {
	
	NSLog(@"Mouse entered");
	
}

- (void) mouseExited: (NSEvent*)event {
	
	NSLog(@"Mouse left");
	
}

- (void) keyDown: (NSEvent*) event {
	
	if ([event isARepeat] == NO) {
		NSLog(@"Key down: %d", [event keyCode]);
	}
	
}

- (void) keyUp: (NSEvent*) event {
	
	NSLog(@"Key up: %d", [event keyCode]);
	
}
@end

CVReturn displayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime, CVOptionFlags flagsIn, CVOptionFlags *flagsOut, void *displayLinkContext)
{
	[(MyOpenGLView *)displayLinkContext setNeedsDisplay:YES];
	return kCVReturnSuccess;
}

static int swidth, sheight;

@interface AppDelegate : NSObject <NSApplicationDelegate> {
   NSWindow* window;
   MyOpenGLView* glView;
}
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
   // Create the window
   window = [[NSWindow alloc]
	  initWithContentRect:NSMakeRect(0, 0, swidth, sheight)
	  styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
	  backing:NSBackingStoreBuffered
	  defer:NO];
   [window setTitle:@"OpenGL Window"];
   [window setAcceptsMouseMovedEvents:YES];

   // Create the OpenGL view
   NSOpenGLPixelFormatAttribute attrs[] = {
	  NSOpenGLPFADoubleBuffer,
	  NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
	  NSOpenGLPFAColorSize, 24,
	  NSOpenGLPFAAlphaSize, 8,
	  NSOpenGLPFADepthSize, 24,
	  NSOpenGLPFAStencilSize, 8,
	  0
   };
   NSOpenGLPixelFormat* pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
   glView = [[MyOpenGLView alloc] initWithFrame:NSMakeRect(0, 0, swidth, sheight) pixelFormat:pixelFormat];
   [window setContentView:glView];

   // Show the window
   [window makeKeyAndOrderFront:nil];
   [window center];

   GLint swapInt = 1;
   CVDisplayLinkRef displayLink;
   [[glView openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval]; 
   CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
   CVDisplayLinkSetOutputCallback(displayLink, &displayLinkCallback, glView);
   CGLContextObj cglContext = [[glView openGLContext] CGLContextObj];
   CGLPixelFormatObj cglPixelFormat = [[NSOpenGLView defaultPixelFormat] CGLPixelFormatObj];
   CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(displayLink, cglContext, cglPixelFormat);
   CVDisplayLinkStart(displayLink);

   //audio:
   fenster_audio_open(&audioState);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
   return YES;
}
@end

#if USE_GL
void open_window(int width, int height){
	swidth = width;
	sheight = height;
#else
void open_window(int scale){
	swidth = SCREEN_WIDTH * scale;
	sheight = SCREEN_HEIGHT * scale;
#endif
	[NSAutoreleasePool new];
	NSApplication* app = [NSApplication sharedApplication];
	[app setActivationPolicy:NSApplicationActivationPolicyRegular];
	[app activateIgnoringOtherApps:YES];
	AppDelegate* appDelegate = [[AppDelegate alloc] init];
	[app setDelegate:appDelegate];
	[app activateIgnoringOtherApps:true];
	[app run];
}