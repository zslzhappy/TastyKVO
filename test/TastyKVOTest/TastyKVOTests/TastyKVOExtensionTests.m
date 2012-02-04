#import "TastyKVOExtensionTests.h"

#import "NSObject+TastyKVO.h"
#import <objc/runtime.h>


@interface TargetObject: NSObject {
@private
    BOOL _boolVar;
    int _intVar;
    float _floatVar;
    NSString *_message;

}
@property (nonatomic) BOOL boolVar;
@property (nonatomic) int intVar;
@property (nonatomic) float floatVar;
@property (nonatomic, copy) NSString *message;
@end

@implementation TargetObject
@synthesize
boolVar = _boolVar,
intVar = _intVar,
floatVar = _floatVar,
message = _message;
- (void)dealloc
{
    [_message release];
    [super dealloc];
}
@end

#pragma mark -

@interface ObserverObject: NSObject {
@private
    BOOL _flag;
    int _counter;
}
@property (nonatomic) BOOL flag;
@property (nonatomic) int counter;
@end

@implementation ObserverObject
@synthesize
flag = _flag,
counter = _counter;
- (void)flipFlag
{
    _flag = !_flag;
}
- (void)increment
{
    ++_counter;
}
@end

#pragma mark -

@implementation TastyKVOExtensionTests

- (void)setUp
{
    [super setUp];

    _target = [[TargetObject alloc] init];
    _observer = [[ObserverObject alloc] init];
}

- (void)tearDown
{
    [_observer release];
    [_target release];

    [super tearDown];
}

#pragma mark -

- (void)testAddTastyObserver_forKeyPath_withSelector
{
    [_target addTastyObserver:_observer forKeyPath:@"intVar" withSelector:@selector(flipFlag)];

    _target.intVar = 1;
    STAssertTrue([_observer flag], @"-[_observer flipFlag] did not get called");

    _target.intVar = 1;
    STAssertFalse([_observer flag], @"-[_observer flipFlag] did not get called the second time");

    [_target removeTastyObserver:_observer forKeyPath:@"intVar"];

    _target.intVar = 1;
    STAssertFalse([_observer flag], @"-[_observer flipFlag] got called after the observer has been removed.");
}

- (void)testAddTastyObserver_forKeyPath_withBlock
{
    [_target addTastyObserver:_observer
                   forKeyPath:@"boolVar"
                    withBlock:^(id self, id target, NSDictionary *change) {
                        [self flipFlag];
                    }];

    _target.boolVar = YES;
    STAssertTrue([_observer flag], @"-[_observer flipFlag] did not get called from inside the block");

    _target.boolVar = YES;
    STAssertFalse([_observer flag], @"-[_observer flipFlag] did not get called from inside the block the second time");

    [_target removeTastyObserver:_observer forKeyPath:@"boolVar"];

    _target.boolVar = NO;
    STAssertFalse([_observer flag], @"-[_observer flipFlag] got called after the observer has been removed.");
}

- (void)testAddTastyObserver_forKeyPaths_allSelectors
{
    STAssertThrowsSpecificNamed(([_target addTastyObserver:_observer
                                              forKeyPaths:@"intVar", @selector(whatever), nil]),
                                NSException,
                                NSInternalInconsistencyException,
                                @"Did not catch the missing type specifier in the keyPath");
    /*
     * The following test is plausible, however it will most likely crash the whole testing environment.
     *
     * The problem is that is a user passes a selector, but indicates in the multi-key that he's passing
     * a block, we cannot safely verify the user's claim. Sending any message to a selector or trying to
     * dereference it will cause a crash.
     *
     * On the other hand, if we don't crash early, the app will crash anyway when the observed property
     * changes, because the system will try to execute a block which is actually a selector.
     *
     * So the method does actually crash early, but it's impossible to verify this behaviour in a unit-test.
    **/
//    STAssertThrowsSpecificNamed(([_target addTastyObserver:_observer
//                                               forKeyPaths:@"?intVar", @selector(whatever), nil]),
//                                NSException,
//                                NSInternalInconsistencyException,
//                                @"The fact that the supposed block turned out to be a selector was not caught.");

    [_target addTastyObserver:_observer
                  forKeyPaths:@":intVar", @selector(whatever),
                              @":boolVar", @selector(however), nil];
    STAssertThrowsSpecificNamed((_target.intVar = 0),
                                NSException,
                                NSInvalidArgumentException,
                                @"Non-existant selector turned out to exist after all?");
    STAssertThrowsSpecificNamed((_target.boolVar = NO),
                                NSException,
                                NSInvalidArgumentException,
                                @"Non-existant selector turned out to exist after all?");
    [_target removeTastyObserver:_observer];
    _target.intVar = 1;
    _target.boolVar = YES;
}

- (void)testAddTastyObserver_forKeyPaths_allBlocks
{
    TastyBlock aBlock = ^(id self, id target, NSDictionary *change) {
        NSLog(@"blah");
    };

    STAssertThrowsSpecificNamed(([_target addTastyObserver:_observer
                                               forKeyPaths:@"message", aBlock, nil]),
                                NSException,
                                NSInternalInconsistencyException,
                                @"Did not catch the missing type specifier in the keyPath");
    STAssertThrowsSpecificNamed(([_target addTastyObserver:_observer
                                               forKeyPaths:@":message", aBlock, nil]),
                                NSException,
                                NSInternalInconsistencyException,
                                @"The fact that the supposed selector turned out to be a block was not caught.");

    __block int firstBlockVar = 0;
    __block int secondBlockVar = 0;
    [_target addTastyObserver:_observer
                  forKeyPaths:
        @"?message",
        ^(id self, id target, NSDictionary *change) {
            firstBlockVar += 13;
        },

        @"?boolVar",
        ^(id self, id target, NSDictionary *change) {
            secondBlockVar += 256;
        },
    nil];

    _target.message = @"Hello!";
    STAssertEquals(firstBlockVar, 13, @"The block hooked to the 'message' property was not triggered");

    _target.boolVar = YES;
    STAssertEquals(secondBlockVar, 256, @"The block hooked to the 'boolVar' property was not triggered");

    [_target removeTastyObserver:_observer];

    _target.message = @"";
    STAssertEquals(firstBlockVar, 13, @"The first block got triggered after the observer had been removed");

    _target.boolVar = NO;
    STAssertEquals(secondBlockVar, 256, @"The second block got triggered after the observer had been removed");
}

- (void)testAddTastyObserver_forKeyPaths_interleaved
{
    TastyBlock aBlock = ^(ObserverObject *self, id target, NSDictionary *change) {
        [self increment];
    };

    [_target addTastyObserver:_observer
                  forKeyPaths:@":intVar", @selector(whatever),
                              @"?floatVar", aBlock, nil];

    STAssertThrowsSpecificNamed((_target.intVar = 0),
                                NSException,
                                NSInvalidArgumentException,
                                @"Non-existant selector turned out to exist after all?");

    _target.floatVar = .1f;
    _target.floatVar = .2f;
    _target.floatVar = .3f;
    STAssertEquals([_observer counter], 3, @"aBlock was supposed to be called three times");

    [_target removeTastyObserver:_observer];

    _target.floatVar = 0;
    STAssertEquals([_observer counter], 3, @"aBlock was triggered after the observer had been removed");
}

#pragma mark -

- (void)testMultiKeyPath
{
    [_target addTastyObserver:_observer
                   forKeyPath:@"boolVar|intVar|floatVar|message"
                 withSelector:@selector(increment)];
    _target.boolVar = YES;
    _target.intVar = 1;
    _target.floatVar = .1f;
    _target.message = @"nice";
    STAssertEquals([_observer counter], 4, @"Selector was not triggered for every observable property");
    [_target removeTastyObserver:_observer];
}

#pragma mark -

- (void)testRemoveTastyObserver
{
    [_target addTastyObserver:_observer
                   forKeyPath:@"boolVar|intVar|floatVar|message"
                 withSelector:@selector(increment)];
    [_target removeTastyObserver:_observer];

    STAssertNil(objc_getAssociatedObject(_target, @"org.tastykvo.associatedDictKey"),
                @"Observer dict was not removed after the observer had been removed");

    _target.boolVar = YES;
    _target.intVar = 1;
    _target.floatVar = .1f;
    _target.message = @"nice";
    STAssertEquals([_observer counter], 0, @"-[_observer increment] was triggered after the observer had been removed");
}

- (void)testRemoveTastyObserver_forKeyPath_wildcard
{
    [_target addTastyObserver:_observer
                   forKeyPath:@"boolVar|intVar|floatVar|message"
                 withSelector:@selector(increment)];
    [_target removeTastyObserver:_observer forKeyPath:@"*"];
    _target.boolVar = YES;
    _target.intVar = 1;
    _target.floatVar = .1f;
    _target.message = @"nice";
    STAssertEquals([_observer counter], 0, @"-[_observer increment] was triggered after the observer had been removed");
}

- (void)testRemoveTastyObserver_forKeyPath
{
    [_target addTastyObserver:_observer
                   forKeyPath:@"boolVar|intVar|floatVar|message"
                 withSelector:@selector(increment)];
    _target.message = @"and now...";
    STAssertEquals([_observer counter], 1, @"-[_observer increment] was not triggered");

    [_target removeTastyObserver:_observer forKeyPath:@"message"];
    _target.message = @"...";
    STAssertEquals([_observer counter], 1, @"-[observer increment] was triggered after the observation of 'message' had been stopped");

    _target.boolVar = YES;
    STAssertEquals([_observer counter], 2, @"-[_observer increment] was not triggered");

    [_target removeTastyObserver:_observer forKeyPath:@"boolVar"];
    STAssertEquals([_observer counter], 2, @"-[observer increment] was triggered after the observation of 'boolVar' had been stopped");

    [_target removeTastyObserver:_observer forKeyPath:@"floatVar"];
    _target.floatVar = .1f;
    STAssertEquals([_observer counter], 2, @"-[observer increment] was triggered after the observation of 'floatVar' had been stopped");

    _target.intVar = 16;
    STAssertEquals([_observer counter], 3, @"-[_observer increment] was not triggered");

    [_target removeTastyObserver:_observer forKeyPath:@"intVar"];
    _target.intVar = 0;
    STAssertEquals([_observer counter], 3, @"-[observer increment] was triggered after the observation of 'intVar' had been stopped");

    STAssertNil(objc_getAssociatedObject(_target, @"org.tastykvo.associatedDictKey"),
                @"Observer dict was not removed after the observer had been removed");
}

@end