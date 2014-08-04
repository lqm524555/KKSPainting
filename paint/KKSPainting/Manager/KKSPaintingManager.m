//
//  KKSPaintingManager.m
//  Drawing Demo
//
//  Created by kukushi on 4/2/14.
//  Copyright (c) 2014 Xing He. All rights reserved.
//

#import "KKSPaintingManager.h"

#import "KKSPaintingPen.h"
#import "KKSShapePainting.h"
#import "KKSPaintingTool.h"


#import "KKSPaintingView.h"

// #import "NSMutableArray+KKSValueSupport.h"
#import "KKSPointExtend.h"
#import "KKSLog.h"

static NSString * const KKSPaintingUndoKeyPainting = @"KKSPaintingUndoKeyPainting";
static NSString * const KKSPaintingUndoKeyTranslation = @"KKSPaintingUndoKeyTranslation";
static NSString * const KKSPaintingUndoKeyDegree = @"KKSPaintingUndoKeyDegree";
static NSString * const KKSPaintingUndoKeyZoomScale = @"KKSPaintingUndoKeyZoomScale";
static NSString * const KKSPaintingUndoKeyShouldFill = @"KKSPaintingUndoKeyShouldFill";
static NSString * const KKSPaintingUndoKeyFillColor = @"KKSPaintingUndoKeyFillColor";


@interface KKSPaintingManager () <KKSPaintingDelegate>

@property (nonatomic, strong) KKSPaintingBase *painting;
@property (nonatomic, strong) UIImage *cachedImage;

@property (nonatomic, strong) NSMutableArray *usedPaintings;

@property (nonatomic, weak) KKSPaintingBase *selectedPainting;

@property (nonatomic, weak) KKSPaintingBase *paintingToFill;

@property (nonatomic) CGPoint firstTouchLocation;
@property (nonatomic) CGPoint previousLocation;

@property (nonatomic, strong) UILabel *indicatorLabel;


@property (nonatomic) BOOL isActive;

@property (nonatomic) CGSize originalContentSize;
@property (nonatomic) BOOL canChangeContentSize;

@property (nonatomic, strong) NSUndoManager *undoManager;

@end

@implementation KKSPaintingManager

#pragma mark - Init

void KKSViewBeginImageContext(UIScrollView *view) {
    CGSize imageSize;
    if (CGSizeEqualToSize(CGSizeZero, view.contentSize)) {
        imageSize = view.bounds.size;
    }
    else {
        imageSize = view.contentSize;
    }
    UIGraphicsBeginImageContextWithOptions(imageSize, NO, 0.f);
}

- (id)init {
    if (self = [super init]) {
        _lineWidth = 5.f;
        _alpha = 1.f;
        _color = [UIColor blackColor];
        
        _usedPaintings = [[NSMutableArray alloc] init];
        _undoManager = [[NSUndoManager alloc] init];
    }
    return self;
}

#pragma mark - Selected Painting

- (BOOL)hasSelectedPainting {
    return self.selectedPainting != nil;
}

- (void)updateSelectedPaintingWithPoint:(CGPoint)point {
    BOOL didSelectedPainting = [self hasSelectedPainting];
    self.selectedPainting = nil;
    
    BOOL willSelectPainting = NO;
    for (KKSPaintingBase *painting in self.usedPaintings) {
        if ([painting pathContainsPoint:point]) {
            self.selectedPainting = painting;
            willSelectPainting = YES;
        }
    }
    if (willSelectPainting) {
        if ([self.paintingDelegate respondsToSelector:@selector(patntingManagerDidSelectedPainting)]) {
            [self.paintingDelegate patntingManagerDidSelectedPainting];
        }
    }
    else if (didSelectedPainting) {
        if ([self.paintingDelegate respondsToSelector:@selector(paintingManagerDidLeftSelection)]) {
            [self.paintingDelegate paintingManagerDidLeftSelection];
        }
    }
    
    KKSDLog("Mode %td Hit on %@", self.paintingMode, self.selectedPainting);
}

- (KKSPaintingBase *)paintingContainedInAreaWithPoint:(CGPoint)point {
    __block KKSPaintingBase* containedPainting = nil;
    [self.usedPaintings enumerateObjectsWithOptions:NSEnumerationReverse
                                         usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                                             KKSPaintingBase *painting = (KKSPaintingBase *)obj;
                                             if ([painting areaContainsPoint:point]) {
                                                 containedPainting = painting;
                                                 *stop = YES;
                                             }
                                         }];
    return containedPainting;
}

#pragma mark - Touches

- (void)paintingBeginWithTouch:(UITouch *)touch {
    KKSPaintingMode paintingMode = self.paintingMode;
    CGPoint touchedLocation = [touch locationInView:self.paintingView];
    
    if (paintingMode == KKSPaintingModePainting) {
        if (!self.isActive) {
            self.isActive = YES;
            [self renewPainting];
            
            if ([self.paintingDelegate respondsToSelector:@selector(paintingManagerWillBeginPainting)]) {
                [self.paintingDelegate paintingManagerWillBeginPainting];
            }
            [self registerUndoForPaintingWithPaintings:[self.usedPaintings copy]];
        }
        [self.painting recordingBeganWithTouch:touch];
        
    }
    else if (paintingMode == KKSPaintingModeFillColor) {
        self.paintingToFill = [self paintingContainedInAreaWithPoint:touchedLocation];
        if (self.paintingToFill) {
            self.isActive = YES;
            [self registerUndoForFillColorWithPainting:self.paintingToFill];
            [self.paintingToFill setFill:YES color:self.color.CGColor];
        }
    }
    else {
        
        if (paintingMode == KKSPaintingModeSelection) {
            BOOL needRedraw = NO;
            
            if (self.selectedPainting.shouldStrokePath) {
                // reset the previous selection state
                self.selectedPainting.shouldStrokePath = NO;
                needRedraw = YES;
            }
            
            [self updateSelectedPaintingWithPoint:touchedLocation];
            
            self.selectedPainting.shouldStrokePath = YES;
            
            if (!self.selectedPainting && needRedraw) {
                [self redrawViewWithPaintings:self.usedPaintings];
            }
        }
        
        if (self.selectedPainting) {
            if (paintingMode == KKSPaintingModeSelection ||
                paintingMode == KKSPaintingModeRotate ||
                paintingMode == KKSPaintingModeZoom) {
                
                self.cachedImage = [self imageBeforePaintingComplete:self.selectedPainting];
                self.isActive = YES;
                self.previousLocation = touchedLocation;
                self.firstTouchLocation = touchedLocation;
                
                if (paintingMode == KKSPaintingModeSelection) {
                    [self registerUndoForMovingWithPainting:self.selectedPainting];
                }
                else if (paintingMode == KKSPaintingModeRotate) {
                    [self registerUndoForRotatingWithPainting:self.selectedPainting];
                }
                else if (paintingMode == KKSPaintingModeZoom) {
                    [self registerUndoForZoomingWithPainting:self.selectedPainting];
                }
                
            }
            else if (paintingMode == KKSPaintingModeRemove) {
                [self registerUndoForPaintingWithPaintings:[self.usedPaintings copy]];
                [self.usedPaintings removeObject:self.selectedPainting];
                
                [self redrawViewWithPaintings:self.usedPaintings];
            }
            else if (paintingMode == KKSPaintingModeCopy) {
                self.firstTouchLocation = touchedLocation;
            }
            else if (paintingMode == KKSPaintingModePaste) {
                [self registerUndoForPaintingWithPaintings:[self.usedPaintings copy]];
                
                KKSPaintingBase *painting = [self.selectedPainting copy];
                CGPoint translation = translationBetweenPoints(self.firstTouchLocation, touchedLocation);
                [painting moveByIncreasingTranslation:translation];
                [self.usedPaintings addObject:painting];
                [self updateCachedImageWithPainting:painting cachedImage:self.cachedImage];
                [self.paintingView setNeedsDisplay];
            }
        }
    }
}

- (void)paintingMovedWithTouch:(UITouch *)touch {
    CGPoint touchedLocation = [touch locationInView:self.paintingView];
    KKSPaintingMode paintingMode = self.paintingMode;
    
    if (paintingMode == KKSPaintingModePainting) {
        [self.painting recordingContinueWithTouchMoved:touch];
    }
    else if (self.selectedPainting) {
        if (paintingMode == KKSPaintingModeSelection) {
            CGPoint translation = translationBetweenPoints(self.previousLocation, touchedLocation);
            [self.selectedPainting moveByIncreasingTranslation:translation];
            
            [self.paintingView setNeedsDisplay];
        }
        else if (paintingMode == KKSPaintingModeRotate) {
            CGPoint origin = [self.selectedPainting pathCenterPoint];
            CGPoint initialPosition = self.previousLocation;
            CGPoint touchedPosition = [touch locationInView:self.paintingView];
            
            CGFloat degree = degreeWithPoints(origin, initialPosition, touchedPosition);
            self.previousLocation = touchedPosition;
            
            [self.selectedPainting rotateByIncreasingDegree:degree];
            
            [self.paintingView setNeedsDisplay];
        }
        else if (self.paintingMode == KKSPaintingModeZoom) {
            CGPoint currentLocation = [touch locationInView:self.paintingView];
            CGPoint centerPoint = [self.selectedPainting pathCenterPoint];
            CGPoint basicPoint = self.firstTouchLocation;
            CGPoint previousPoint = self.previousLocation;
            CGFloat scale = scaleChangeBetweenPoints(centerPoint,
                                                     basicPoint,
                                                     previousPoint,
                                                     currentLocation);
            self.previousLocation = currentLocation;
            
            [self.selectedPainting zoomByMultipleCurrentScale:scale];
            
            [self.paintingView setNeedsDisplay];
        }
    }
    self.previousLocation = touchedLocation;
}

- (void)paintingEndWithTouch:(UITouch *)touch {
    if (self.paintingMode == KKSPaintingModePainting) {
        [self paintingMovedWithTouch:touch];
        // make sure at least one point is recorded
        
        self.cachedImage = [self.painting recordingEndedWithTouch:touch cachedImage:self.cachedImage];
        
        if (self.painting.isDrawingFinished) {
            
            [self.usedPaintings addObject:self.painting];
            
            self.isActive = NO;
            
            if ([self.paintingDelegate respondsToSelector:@selector(paintingManagerDidEndedPainting)]) {
                [self.paintingDelegate paintingManagerDidEndedPainting];
            }
        }
    }
    else if (self.paintingMode == KKSPaintingModeSelection||
             self.paintingMode == KKSPaintingModeRotate ||
             self.paintingMode == KKSPaintingModeZoom) {
        if (self.selectedPainting) {
            
            [self updateCachedImageWithPaintingsAfterPainting:self.selectedPainting];
            
            [self.paintingView setNeedsDisplay];
            
            self.isActive = NO;
        }
    }
    else if (self.paintingMode == KKSPaintingModeFillColor) {
        if (self.paintingToFill) {
            [self updateCachedImageWithPainting:self.paintingToFill
                                    cachedImage:self.cachedImage];
            [self.paintingView setNeedsDisplay];
            self.isActive = NO;
            self.paintingToFill = nil;
        }
    }
    else if (self.paintingMode == KKSPaintingModeRemove) {
        [self.paintingView setNeedsDisplay];
    }
}

#pragma mark - Painting 

- (void)renewPainting {
    switch (self.paintingType) {
        case KKSPaintingTypePen: {
            self.painting = [[KKSPaintingPen alloc] initWithView:self.paintingView];
        }
            break;
            
        case KKSPaintingTypeLine: {
            self.painting = [[KKSPaintingLine alloc] initWithView:self.paintingView];
        }
            break;
            
        case KKSPaintingTypeRectangle: {
            self.painting = [[KKSPaintingRectangle alloc] initWithView:self.paintingView];
        }
            break;
            
        case KKSPaintingTypeEllipse: {
            self.painting = [[KKSPaintingEllipse alloc] initWithView:self.paintingView];
        }
            break;
            
        case KKSPaintingTypeSegments: {
            self.painting = [[KKSPaintingSegments alloc] initWithView:self.paintingView];
        }
            break;
            
        case KKSPaintingTypeBezier: {
            self.painting = [[KKSPaintingBezier alloc] initWithView:self.paintingView];
        }
            break;
            
        case KKSPaintingTypePolygon: {
            self.painting = [[KKSPaintingPolygon alloc] initWithView:self.paintingView];
        }
            break;
            
        default:
            break;
    }
    
    self.painting.delegate = self;
    [self.painting setLineWidth:self.lineWidth
                          color:self.color.CGColor
                          alpha:self.alpha];
}

#pragma mark - Zoom

- (void)zoomAllPaintingsByScale:(CGFloat)scale {
    for (KKSPaintingBase *painting in self.usedPaintings) {
        [painting zoomByMultipleCurrentScale:scale];
    }
}

- (void)zoomByScale:(CGFloat)scale {
    if (self.canZoom) {
        CGSize contentSize = self.paintingView.contentSize;
        contentSize = CGSizeMake(contentSize.width * scale, contentSize.height * scale);
        self.paintingView.contentSize = contentSize;
        
        [self zoomAllPaintingsByScale:scale];
        for (KKSPaintingBase *painting in self.usedPaintings) {
            [painting zoomByMultipleCurrentScale:scale];
        }
        [self redrawViewWithPaintings:self.usedPaintings];
    }
}

#pragma mark - Undo & Redo & Clear

- (BOOL)canUndo {
    return ([self.undoManager canUndo] && !self.isActive);
}

- (BOOL)canClear {
    return !self.isActive;
}

- (BOOL)canRedo {
    return ([self.undoManager canRedo] && !self.isActive);
}

- (void)undo {
    [self.undoManager undo];
}

- (void)undoPainting:(id)object {
    
    [self registerUndoForPaintingWithPaintings:[self.usedPaintings copy]];
    
    NSArray *paintings = (NSArray *)object;
    
    self.usedPaintings = [NSMutableArray arrayWithArray:object];
    
    [self redrawViewWithPaintings:paintings];
}

- (void)registerUndoForPaintingWithPaintings:(NSArray *)paintings {
    [self.undoManager registerUndoWithTarget:self
                                    selector:@selector(undoPainting:)
                                      object:paintings];
}

- (void)undoMoving:(id)object {
    KKSPaintingBase *painting = object[KKSPaintingUndoKeyPainting];
    [self registerUndoForMovingWithPainting:painting];
    
    NSValue *newValue = object[KKSPaintingUndoKeyTranslation];
    CGPoint newTranslation = [newValue CGPointValue];
    
    [painting moveBySetingTranslation:newTranslation];
    
    [self redrawViewWithPaintings:self.usedPaintings];
    
}

- (void)registerUndoForMovingWithPainting:(KKSPaintingBase *)painting {
    CGPoint translation = [painting currentTranslation];
    NSValue *value = [NSValue valueWithCGPoint:translation];
    
    NSDictionary *dict = @{KKSPaintingUndoKeyPainting: painting,
                           KKSPaintingUndoKeyTranslation: value};
    [self.undoManager registerUndoWithTarget:self
                                    selector:@selector(undoMoving:)
                                      object:dict];
}


- (void)undoRotating:(id)object {
    
    KKSPaintingBase *painting = object[KKSPaintingUndoKeyPainting];
    [self registerUndoForRotatingWithPainting:painting];
    
    NSValue *newValue = object[KKSPaintingUndoKeyDegree];
    CGFloat newDegree;
    [newValue getValue:&newDegree];
    
    [painting rotateBySettingDegree:newDegree];
    
    [self redrawViewWithPaintings:self.usedPaintings];
}

- (void)registerUndoForRotatingWithPainting:(KKSPaintingBase *)painting {
    CGFloat degree = [painting currentRotateDegree];
    NSValue *value = [NSValue value:&degree withObjCType:@encode(CGFloat)];
    
    NSDictionary *dict = @{KKSPaintingUndoKeyPainting: painting,
                           KKSPaintingUndoKeyDegree: value};
    
    [self.undoManager registerUndoWithTarget:self
                                    selector:@selector(undoRotating:)
                                      object:dict];
}

- (void)undoZooming:(id)object {
    
    KKSPaintingBase *painting = object[KKSPaintingUndoKeyPainting];
    [self registerUndoForZoomingWithPainting:painting];
    
    NSValue *newValue = object[KKSPaintingUndoKeyZoomScale];
    CGFloat newScale;
    [newValue getValue:&newScale];
    
    [painting zoomBySettingScale:newScale];
    
    [self redrawViewWithPaintings:self.usedPaintings];
}

- (void)registerUndoForZoomingWithPainting:(KKSPaintingBase *)painting {
    CGFloat scale = [painting currentZoomScale];
    NSValue *value = [NSValue value:&scale withObjCType:@encode(CGFloat)];
    
    NSDictionary *dict = @{KKSPaintingUndoKeyPainting: painting,
                           KKSPaintingUndoKeyZoomScale: value};
    
    [self.undoManager registerUndoWithTarget:self
                                    selector:@selector(undoZooming:)
                                      object:dict];
}

- (void)undoFillColor:(id)object {
    KKSPaintingBase *painting = object[KKSPaintingUndoKeyPainting];
    [self registerUndoForFillColorWithPainting:painting];
    
    NSNumber *shouldFillValue = object[KKSPaintingUndoKeyShouldFill];
    BOOL shouldFill = [shouldFillValue boolValue];
    
    NSValue *fillColorValue = object[KKSPaintingUndoKeyFillColor];
    CGColorRef fillColor = [fillColorValue pointerValue];
    
    [painting setFill:shouldFill color:fillColor];
    
    [self redrawViewWithPaintings:self.usedPaintings];
}

- (void)registerUndoForFillColorWithPainting:(KKSPaintingBase *)painting {
    BOOL shouldFill = painting.shouldFill;
    NSNumber *shouldFillValue = @(shouldFill);
    NSValue *colorValue = [NSValue valueWithPointer:painting.fillColor];
    
    NSDictionary *dict = @{KKSPaintingUndoKeyPainting: painting,
                           KKSPaintingUndoKeyShouldFill: shouldFillValue,
                           KKSPaintingUndoKeyFillColor: colorValue};
    
    [self.undoManager registerUndoWithTarget:self
                                    selector:@selector(undoFillColor:)
                                      object:dict];
}

- (void)redo {
    [self.undoManager redo];
}



- (void)clear {
    if ([self canClear]) {
        [self.usedPaintings removeAllObjects];
        [self.undoManager removeAllActions];
        self.cachedImage = nil;
        [self.paintingView setNeedsDisplay];
    }
}

- (BOOL)canChangePaintingState {
    return !self.isActive;
}

#pragma mark - KKSPaintingDelegate

- (void)drawingWillEndAutomatically {
    [self paintingFinish];
}

- (void)drawingDidEndNormally {
    [self.paintingView showIndicatorLabelWithText:@"绘制结束"];
}

- (void)paintingFinish {
    if (self.paintingMode == KKSPaintingModePainting &&
        !self.painting.isDrawingFinished &&
        ([self.painting isKindOfClass:[KKSPaintingSegments class]]
         || [self.painting isKindOfClass:[KKSPaintingPolygon class]]) &&
        self.isActive) {
        
        self.cachedImage = [self.painting endDrawingWithCacheImage:self.cachedImage];
        
        self.painting.isDrawingFinished = YES;
        
        [self.usedPaintings addObject:self.painting];
        
        self.isActive = NO;
        
        if (self.paintingType == KKSPaintingTypePolygon ||
            self.paintingType == KKSPaintingTypeSegments) {
            [self.paintingView showIndicatorLabelWithText:@"绘制结束!"];
        }
        
        if ([self.paintingDelegate respondsToSelector:@selector(paintingManagerDidEndedPainting)]) {
            [self.paintingDelegate paintingManagerDidEndedPainting];
        }
    }
}

#pragma mark - drawing & Image Caching


- (void)redrawPaintingsFromSelectedPainting {
    NSInteger startIndex = [self.usedPaintings indexOfObject:self.selectedPainting];
    NSInteger count = [self.usedPaintings count];
    for (NSInteger index = startIndex; index<count; ++index) {
        KKSPaintingBase *painting = self.usedPaintings[index];
        [painting drawPath];
    }
}

- (UIImage *)imageBeforePaintingComplete:(KKSPaintingBase *)painting {
    NSInteger endIndex = [self.usedPaintings indexOfObject:painting];
    
    KKSViewBeginImageContext(self.paintingView);
    for (NSInteger index = 0; index<endIndex; ++index) {
        KKSPaintingBase *usedPainting = self.usedPaintings[index];
        [usedPainting drawPath];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    return image;
}

- (void)updateCachedImageWithPaintingsAfterPainting:(KKSPaintingBase *)painting {
    NSInteger startIndex = [self.usedPaintings indexOfObject:painting];
    NSInteger count = [self.usedPaintings count];
    
    KKSViewBeginImageContext(self.paintingView);
    [self.cachedImage drawAtPoint:CGPointZero];
    for (NSInteger index = startIndex; index<count; ++index) {
        KKSPaintingBase *usedPainting = self.usedPaintings[index];
        [usedPainting drawPath];
    }
    
    self.cachedImage = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
    
}

- (void)redrawViewWithPaintings:(NSArray *)paintings {
    KKSViewBeginImageContext(self.paintingView);
    
    for (KKSPaintingBase *painting in paintings) {
        [painting drawPath];
    }
    
    self.cachedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    [self.paintingView setNeedsDisplay];
}

- (void)updateCachedImageWithPainting:(KKSPaintingBase *)painting
                          cachedImage:(UIImage *)cachedImage {
    KKSViewBeginImageContext(self.paintingView);
    
    [cachedImage drawAtPoint:CGPointZero];
    
    [painting drawPath];
    
    self.cachedImage = UIGraphicsGetImageFromCurrentImageContext();
    
    UIGraphicsEndImageContext();
}

- (UIImage *)currentImage {
    return nil;
}

#pragma mark -

void KKSViewBeginImageContext(UIScrollView *view);


#pragma mark - Accessor & Setter

- (void)paintingViewDidChangeState {
    [self paintingFinish];
    
    if (self.paintingView.scrollEnabled) {
        self.paintingView.scrollEnabled = NO;
    }
}

- (void)setPaintingType:(KKSPaintingType)paintingType {
    [self paintingViewDidChangeState];
    _paintingType = paintingType;
}

- (void)setPaintingMode:(KKSPaintingMode)paintingMode {
    
    if (_paintingMode == KKSPaintingModeNone) {
        self.paintingView.scrollEnabled = (paintingMode == KKSPaintingModeNone);
    }
    else if (_paintingMode == KKSPaintingModeSelection &&
            paintingMode != KKSPaintingModeSelection) {
        self.selectedPainting.shouldStrokePath = NO;
        [self redrawViewWithPaintings:self.usedPaintings];
    }
    else {
        [self paintingViewDidChangeState];
    }
    _paintingMode = paintingMode;
}

- (void)setColor:(UIColor *)color {
    [self paintingViewDidChangeState];
    _color = color;
}

- (void)setAlpha:(CGFloat)alpha {
    [self paintingViewDidChangeState];
    _alpha = alpha;
}

- (void)setLineWidth:(CGFloat)lineWidth {
    [self paintingViewDidChangeState];
    _lineWidth = lineWidth;
}

- (void)drawAllPaintings {
    [self.cachedImage drawAtPoint:CGPointZero];
    
    if (self.isActive) {
        if (self.paintingMode == KKSPaintingModePainting) {
            [self.painting drawPath];
        }
        else if (self.paintingMode == KKSPaintingModeSelection ||
                 self.paintingMode == KKSPaintingModeRotate ||
                 self.paintingMode == KKSPaintingModeZoom) {
            [self redrawPaintingsFromSelectedPainting];
        }
    }
}

#pragma mark - NSCoding

- (id)initWithCoder:(NSCoder *)decoder {
    if (self = [super init]) {
        _lineWidth = [decoder decodeFloatForKey:@"lineWidth"];
        _color = [decoder decodeObjectForKey:@"color"];
        _alpha = [decoder decodeFloatForKey:@"alpha"];
        _canZoom = [decoder decodeBoolForKey:@"canZoom"];
        _paintingType = (KKSPaintingType)[decoder decodeIntegerForKey:@"paintingType"];
        _paintingMode = (KKSPaintingMode)[decoder decodeIntegerForKey:@"paintingMode"];
        _painting = [decoder decodeObjectForKey:@"painting"];
        _cachedImage = [decoder decodeObjectForKey:@"cachedImage"];
        _usedPaintings = [decoder decodeObjectForKey:@"usedPaintings"];
        _selectedPainting = [decoder decodeObjectForKey:@"selectedPainting"];
        _firstTouchLocation = [decoder decodeCGPointForKey:@"firstTouchLocation"];
        _previousLocation = [decoder decodeCGPointForKey:@"previousLocation"];
        _indicatorLabel = [decoder decodeObjectForKey:@"indicatorLabel"];
        _isActive = [decoder decodeBoolForKey:@"isActive"];
        _originalContentSize = [decoder decodeCGSizeForKey:@"originalContentSize"];
        _canChangeContentSize = [decoder decodeBoolForKey:@"canChangeContentSize"];
        _undoManager = [decoder decodeObjectForKey:@"undoManager"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)encoder {
    [encoder encodeFloat:self.lineWidth forKey:@"lineWidth"];
    if (self.color) {
        [encoder encodeObject:self.color forKey:@"color"];
    }
    [encoder encodeFloat:self.alpha forKey:@"alpha"];
    [encoder encodeBool:self.canZoom forKey:@"canZoom"];
    if (self.paintingView) {
        [encoder encodeObject:self.paintingView forKey:@"paintingView"];
    }
    [encoder encodeInteger:self.paintingType forKey:@"paintingType"];
    [encoder encodeInteger:self.paintingMode forKey:@"paintingMode"];
    if (self.painting) {
        [encoder encodeObject:self.painting forKey:@"painting"];
    }
    if (self.cachedImage) {
        [encoder encodeObject:self.cachedImage forKey:@"cachedImage"];
    }
    if (self.usedPaintings) {
        [encoder encodeObject:self.usedPaintings forKey:@"usedPaintings"];
    }
    if (self.selectedPainting) {
        [encoder encodeObject:self.selectedPainting forKey:@"selectedPainting"];
    }
    [encoder encodeCGPoint:self.firstTouchLocation forKey:@"firstTouchLocation"];
    [encoder encodeCGPoint:self.previousLocation forKey:@"previousLocation"];
    if (self.indicatorLabel) {
        [encoder encodeObject:self.indicatorLabel forKey:@"indicatorLabel"];
    }
    [encoder encodeBool:self.isActive forKey:@"isActive"];
    [encoder encodeCGSize:self.originalContentSize forKey:@"originalContentSize"];
    [encoder encodeBool:self.canChangeContentSize forKey:@"canChangeContentSize"];
    if (self.undoManager) {
        [encoder encodeObject:self.undoManager forKey:@"undoManager"];
    }
}

@end