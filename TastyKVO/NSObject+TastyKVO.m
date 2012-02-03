//
// TastyKVO adds two categories to the NSObject class that remove the hassle
// from and add convenience to dealing with the key-value observing mechanism.
//
// The code in this file is in the public domain.
//
// Originally created by Alexei Sholik in February 2012.
// https://github.com/alco/TastyKVO
//
// Inspired by Andy Matuschak's NSObject+BlockObservation implementation
// https://gist.github.com/153676
//

#import "NSObject+TastyKVO.h"
#import <objc/runtime.h>


@interface TastyObserverTrampoline: NSObject {
    __weak id _observer;
    __weak id _target;
    NSString *_keyPath;
    TastyBlock _block;
    SEL _selector;
    dispatch_once_t _cancellationPredicate;
}

@property (nonatomic, copy) TastyBlock block;
@property (nonatomic, assign) SEL selector;

- (id)initWithObserver:(id)observer
                target:(id)target
               keyPath:(NSString *)keyPath;

- (void)stopObserving;

@end

static NSString *const TastyObserverTrampolineContext = @"TastyObserverTrampolineContext";

@implementation TastyObserverTrampoline

@synthesize block = _block, selector = _selector;

- (id)initWithObserver:(id)observer target:(id)target keyPath:(NSString *)keyPath
{
    if ((self = [super init])) {
        _observer = observer;
        _target = target;
        _keyPath = [keyPath copy];
        [target addObserver:self forKeyPath:keyPath options:0 context:TastyObserverTrampolineContext];
    }
    return self;
}

- (void)dealloc
{
    [self stopObserving];
    [_keyPath release];
    [_block release];
    [super dealloc];
}

- (void)observeValueForKeyPath:(NSString *)aKeyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    NSAssert(context == TastyObserverTrampolineContext, @"TastyObserverTrampoline got assigned as an observer without the context."
                                                         " This must be some hack on part of the user");
    if (_block)
        _block(_observer, _target, change);
    else if (_selector)
        [_observer performSelector:_selector withObject:_target withObject:change];
    else
        NSAssert(0, @"No block nor selector provided for TastyObserverTrampoline.");
}

- (void)stopObserving
{
    dispatch_once(&_cancellationPredicate, ^{
        [_target removeObserver:self forKeyPath:_keyPath];
        _target = nil;
    });
}

@end


static NSString *const TastyObserverKey = @"org.tastyobserver.associatedDictKey";

static dispatch_queue_t _mutation_queue()
{
    static dispatch_queue_t mutation_queue = NULL;
    static dispatch_once_t queue_predicate = 0;
    dispatch_once(&queue_predicate, ^{
        mutation_queue = dispatch_queue_create("org.tastyobserver.observerMutationQueue", 0);
    });
    return mutation_queue;
}

@implementation NSObject(TastyKVOExtension)

/**
 * This method must be used inside the dispatch_sync invocation
**/
- (TastyObserverTrampoline *)_trampolineForObserver:(id)observer keyPath:(NSString *)keyPath
{
    NSMutableDictionary *dict = objc_getAssociatedObject(self, TastyObserverKey);
    if (dict == nil) {
        dict = [[NSMutableDictionary alloc] init];
        objc_setAssociatedObject(self, TastyObserverKey, dict, OBJC_ASSOCIATION_RETAIN);
        [dict release];
    }
    NSValue *ptr = [NSValue valueWithPointer:observer];
    NSMutableDictionary *paths = [dict objectForKey:ptr];
    if (paths == nil) {
        paths = [[NSMutableDictionary alloc] init];
        [dict setObject:paths forKey:ptr];
        [paths release];
    }
    TastyObserverTrampoline *trampoline =
        [[TastyObserverTrampoline alloc] initWithObserver:observer
                                                   target:self
                                                  keyPath:keyPath];
    [paths setObject:trampoline forKey:keyPath];
    [trampoline release];

    return trampoline;
}

- (void)addTastyObserver:(id)observer forKeyPath:(NSString *)multiKeyPath withSelector:(SEL)selector
{
    dispatch_sync(_mutation_queue(), ^{
        NSArray *keys = [multiKeyPath componentsSeparatedByString:@"|"];
        for (NSString *key in keys) {
            TastyObserverTrampoline *trampoline = [self _trampolineForObserver:observer
                                                                       keyPath:key];
            trampoline.selector = selector;
        }
    });
}

- (void)addTastyObserver:(id)observer forKeyPath:(NSString *)multiKeyPath withBlock:(TastyBlock)block
{
    dispatch_sync(_mutation_queue(), ^{
        NSArray *keys = [multiKeyPath componentsSeparatedByString:@"|"];
        for (NSString *key in keys) {
            TastyObserverTrampoline *trampoline = [self _trampolineForObserver:observer
                                                                       keyPath:key];
            trampoline.block = block;
        }
    });
}

- (void)_addTastyObserver:(id)observer
              forFirstKey:(NSString *)firstKey
                     rest:(va_list)args
{
    NSString *multiKey = firstKey;
    while (multiKey) {
        unichar typeChar = [multiKey characterAtIndex:0];
        NSAssert(typeChar == ':' || typeChar == '?', @"Each multi-key must have a type encoding");

        NSArray *keys = [[multiKey substringFromIndex:1] componentsSeparatedByString:@"|"];
        BOOL isBlock = (typeChar == '?');
        if (isBlock) {
            TastyBlock block = va_arg(args, typeof(block));
            NSAssert([block isKindOfClass:[NSObject class]], @"This is not actually a block. Did you mean to use '?' instead of ':'?");
            for (NSString *key in keys)
                [self addTastyObserver:observer forKeyPath:key withBlock:block];
        } else {
            SEL selector = va_arg(args, typeof(selector));
            NSAssert(NSStringFromSelector(selector), @"This is not actually a selector. Did you mean to use ':' instead of '?'?");
            for (NSString *key in keys)
                [self addTastyObserver:observer forKeyPath:key withSelector:selector];
        }
        multiKey = va_arg(args, typeof(multiKey));
    }
}

- (void)addTastyObserver:(id)observer
             forKeyPaths:(NSString *)firstKey, ...
{
    va_list args;
    va_start(args, firstKey);
    [self _addTastyObserver:observer forFirstKey:firstKey rest:args];
    va_end(args);
}

#pragma mark


- (NSMutableDictionary *)_observerDict:(id)observer
{
    NSMutableDictionary *observerDict = objc_getAssociatedObject(self, TastyObserverKey);
    NSValue *ptr = [NSValue valueWithPointer:observer];
    return [observerDict objectForKey:ptr];
}

- (void)removeTastyObserver:(id)observer
{
    dispatch_sync(_mutation_queue(), ^{
        NSMutableDictionary *observerDict = objc_getAssociatedObject(self, TastyObserverKey);

        NSValue *ptr = [NSValue valueWithPointer:observer];
        NSMutableDictionary *dict = [observerDict objectForKey:ptr];
        NSArray *keys = [dict allKeys];
        for (NSString *key in keys) {
            TastyObserverTrampoline *trampoline = [dict objectForKey:key];
            if (trampoline == nil) {
                NSLog(@"%@: Ignoring attempt to remove non-existent observer on %@ for token %@.", NSStringFromSelector(_cmd), self, observer);
                return;
            }
            [trampoline stopObserving];
            [dict removeObjectForKey:key];
        }
        [observerDict removeObjectForKey:ptr];

        NSLog(@"observerDict: %@", observerDict);

        // Due to a bug in the obj-c runtime, this dictionary does not get cleaned up on release when running without GC.
        if ([observerDict count] == 0)
            objc_setAssociatedObject(self, TastyObserverKey, nil, OBJC_ASSOCIATION_RETAIN);
    });
}

- (void)removeTastyObserver:(id)observer forKeyPath:(NSString *)multiKeyPath
{
    if ([multiKeyPath isEqualToString:@"*"]) {
        [self removeTastyObserver:observer];
        return;
    }

    dispatch_sync(_mutation_queue(), ^{
        NSMutableDictionary *dict = [self _observerDict:observer];
        NSArray *keys = [multiKeyPath componentsSeparatedByString:@"|"];
        for (NSString *key in keys) {
            TastyObserverTrampoline *trampoline = [dict objectForKey:key];
            if (trampoline == nil) {
                NSLog(@"%@: Ignoring attempt to remove non-existent observer %@ on %@.", NSStringFromSelector(_cmd), self, observer);
                return;
            }
            [trampoline stopObserving];
            [dict removeObjectForKey:key];
        }
    });
}

@end


static NSString *const TastyObserverTargetKey = @"org.tastyobservertarget.associatedDictKey";

@implementation NSObject(TastyKVOObserver)

- (void)_addObservationTarget:(id)target
{
    dispatch_sync(_mutation_queue(), ^{
        NSMutableSet *set = objc_getAssociatedObject(self, TastyObserverTargetKey);
        if (set == nil) {
            set = [[NSMutableSet alloc] init];
            objc_setAssociatedObject(self, TastyObserverTargetKey, set, OBJC_ASSOCIATION_RETAIN);
            [set release];
        }
        [set addObject:[NSValue valueWithNonretainedObject:target]];
    });
}

- (void)_removeObservationTarget:(id)target
{
    dispatch_sync(_mutation_queue(), ^{
        NSMutableSet *set = objc_getAssociatedObject(self, TastyObserverTargetKey);
        if (set) {
            [set removeObject:[NSValue valueWithNonretainedObject:target]];

            if ([set count] == 0)
                objc_setAssociatedObject(self, TastyObserverTargetKey, nil, OBJC_ASSOCIATION_RETAIN);
        }
    });
}

- (void)observeChangesIn:(id)target ofKeyPath:(NSString *)multiKeyPath withSelector:(SEL)selector
{
    [self _addObservationTarget:target];
    [target addTastyObserver:self forKeyPath:multiKeyPath withSelector:selector];
}

- (void)observeChangesIn:(id)target ofKeyPath:(NSString *)multiKeyPath withBlock:(TastyBlock)block
{
    [self _addObservationTarget:target];
    [target addTastyObserver:self forKeyPath:multiKeyPath withBlock:block];
}

- (void)observeChangesIn:(id)target
              ofKeyPaths:(NSString *)firstKey, ...
{
    [self _addObservationTarget:target];
    va_list args;
    va_start(args, firstKey);
    [target _addTastyObserver:self forFirstKey:firstKey rest:args];
    va_end(args);
}

- (void)stopObserving
{
    dispatch_sync(_mutation_queue(), ^{
        NSMutableSet *set = objc_getAssociatedObject(self, TastyObserverTargetKey);
        if (set) {
            [set removeAllObjects];
            objc_setAssociatedObject(self, TastyObserverTargetKey, nil, OBJC_ASSOCIATION_RETAIN);
        }
    });
}

- (void)stopObservingTarget:(id)target
{
    [self _removeObservationTarget:target];
    [target removeTastyObserver:self];
}

@end
