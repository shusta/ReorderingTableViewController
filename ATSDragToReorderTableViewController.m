//
//  ATSDragToReorderTableViewController.m
//
//  Created by Daniel Shusta on 11/28/10.
//  Copyright 2010 Acacia Tree Software. All rights reserved.
//
//  Permission is given to use this source code file, free of charge, in any
//  project, commercial or otherwise, entirely at your risk, with the condition
//  that any redistribution (in part or whole) of source code must retain
//  this copyright and permission notice. Attribution in compiled projects is
//  appreciated but not required.
//
//  THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//	INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
//	PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//	HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
//	OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//	SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


/*

	Implementation Overview

		Press-and-drag-to-reorder is really just two UIGestureRecognizers
		working in concert. First a UILongPressGestureRecognizer decides that
		you're not merely tapping a tableView cell but pressing and holding,
		then a UIPanGestureRecognizer tracks the touch and moves the touched
		cell accordingly.

		The cell following the touch is not the original cell highlighted but an
		imposter. The actual cell is hidden. While the imposter	cell follows the
		touch, the tableView's dataSource is asked to "move" the hidden cell to
		follow the imposter, thus "shuffling" the other cells out of the way.
		
		This allows us to not have any information about the data model and
		prevents against data loss due to crashes or interruptions -- at worst,
		the actual cell is still there, only hidden.

		In addition to dragging a cell, ATSDragToReorderTableViewController will
		autoscroll when the top or bottom is approached. This is done by a
		CADisplayLink, which fires just before rendering a frame, every 1/60th
		of a second. The method it calls will adjust the contentOffset of
		the tableView and the cell accordingly to move the tableview without
		moving the visible position of the cell.


	A little bit more detail:

		There are 5 main states:
		Dormant, long press has activated, dragGesture moves cell,
		autoscroll moves cell, and touch has ended.


		-> Dormant
		
		Nothing happens until a long press occurs on the UITableView. When
		that happens, UILongPressGestureRecognizer calls -longPressRecognized.


		-> Long press occurs
		-longPressRecognized

		At that point, conditions are checked to make sure we can legitimately
		allow dragging. If so, we ask for a cell and set it to self.draggedCell.


		-> From here on out, if touch ends…
		-completeGesturesForTranslationPoint:
		-fastCompleteGesturesWithTranslationPoint:

		If we release a touch or the app resigns active after this point, the
		cell slides back to the proper position and the legitimate cell is made
		visible.


		-> meanwhile, if touch moves…
		-dragGestureRecognized

		UIPanGestureRecognizer calls -dragGestureRecognized whenever any touch
		movement occurs, but normally short-circuits if self.draggedCell == nil.
		Now that self.draggedCell is established, the translation data of the
		UIPanGestureRecognizer is used to update draggedCell’s position.

		After updating the position it checks whether the tableview needs to
		shuffle cells out of the way of the blank cell and checks whether
		autoscrolling should begin or end.


		-> autoscrolling
		-fireAutoscrollTimer:
		
		Autoscrolling needs to be on a timer because UIPanGestureRecognizer only
		responds to movement. The timer calculates the distance the tableView
		should scroll based on proximity of the cell to the tableView bounds and
		adjusts the tableview and the cell so it appears that the cell doesn't
		move. It then checks whether the tableview should reorder cells out of
		the way of the blank cell.

		To clarify, autoscrolling happens simulatneously with
		UIPanGestureRecognizer. Autoscrolling only moves the cell enough so it
		looks like it isn't moving. UIPanGestureRecognizer continues to move
		the cell in response to touch movement.
 */


#import "ATSDragToReorderTableViewController.h"


#define TAG_FOR_ABOVE_SHADOW_VIEW_WHEN_DRAGGING 100
#define TAG_FOR_BELOW_SHADOW_VIEW_WHEN_DRAGGING 200


@interface ATSDragToReorderTableViewController ()

typedef enum {
	AutoscrollStatusCellInBetween,
	AutoscrollStatusCellAtTop,
	AutoscrollStatusCellAtBottom
} AutoscrollStatus;

/*
 *	Not a real interface. Just forward declarations to get the compiler to shut up.
 */
- (void)establishGestures;
- (void)longPressRecognized;
- (void)dragGestureRecognized;
- (void)shuffleCellsOutOfWayOfDraggedCellIfNeeded;
- (void)keepDraggedCellVisible;
- (void)fastCompleteGesturesWithTranslationPoint:(CGPoint)translation;
- (BOOL)touchCanceledAfterDragGestureEstablishedButBeforeDragging;
- (void)completeGesturesForTranslationPoint:(CGPoint)translationPoint;
- (NSIndexPath *)anyIndexPathFromLongPressGesture;
- (NSIndexPath *)indexPathOfSomeRowThatIsNotIndexPath:(NSIndexPath *)selectedIndexPath;
- (void)disableInterferingAspectsOfTableViewAndNavBar;
- (UITableViewCell *)cellPreparedToAnimateAroundAtIndexPath:(NSIndexPath *)indexPath;
- (void)updateDraggedCellWithTranslationPoint:(CGPoint)translation;
- (CGFloat)distanceOfCellCenterFromEdge;
- (CGFloat)autoscrollDistanceForProximityToEdge:(CGFloat)proximity;
- (AutoscrollStatus)locationOfCellGivenSignedAutoscrollDistance:(CGFloat)signedAutoscrollDistance;
- (void)resetDragIVars;
- (void)resetTableViewAndNavBarToTypical;

@property (strong) UITableViewCell *draggedCell;
@property (strong) NSIndexPath *indexPathBelowDraggedCell;
@property (strong) CADisplayLink *timerToAutoscroll;

@end


#pragma mark -


@implementation ATSDragToReorderTableViewController
@synthesize dragDelegate, indicatorDelegate;
@synthesize reorderingEnabled=_reorderingEnabled;
@synthesize draggedCell, indexPathBelowDraggedCell, timerToAutoscroll;


- (void)dealloc {

	[[NSNotificationCenter defaultCenter] removeObserver:resignActiveObserver];
	resignActiveObserver = nil;
}

- (void)commonInit {
	_reorderingEnabled = YES;
	distanceThresholdToAutoscroll = -1.0;
	
	self.indicatorDelegate = self;
	
	// tableView's dataSource _must_ implement moving rows
	// bug: calling self.view (or self.tableview) in -init causes -viewDidLoad to be called twice
//	NSAssert(self.tableView.dataSource && [self.tableView.dataSource respondsToSelector:@selector(tableView:moveRowAtIndexPath:toIndexPath:)], @"tableview's dataSource must implement moving rows");
}


- (id)initWithStyle:(UITableViewStyle)style {
	self = [super initWithStyle:style];
	if (self)
		[self commonInit];
	
	return self;
}

- (id)init {
	self = [super init];
	if (self)
		[self commonInit];
	
	return self;
}

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
	self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
	if (self)
		[self commonInit];
	
	return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
	self = [super initWithCoder:aDecoder];
	if (self)
		[self commonInit];
	
	return self;
}


- (void)viewDidLoad {
    [super viewDidLoad];

	if ( self.reorderingEnabled )
		[self establishGestures];


	/*
	 *	If app resigns active while we're dragging, safely complete the drag.
	 */
	__weak ATSDragToReorderTableViewController *blockSelf = self;
	if ( resignActiveObserver == nil )
		resignActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *arg1) {
			if ( [blockSelf isDraggingCell] ) {
				ATSDragToReorderTableViewController *strongBlockSelf = blockSelf;
				CGPoint currentPoint = [strongBlockSelf->dragGestureRecognizer translationInView:blockSelf.tableView];
				[strongBlockSelf fastCompleteGesturesWithTranslationPoint:currentPoint];
			}
		}];
}


#pragma mark -
#pragma mark Setters and getters

/*
 *	Initializes gesture recognizers and adds them to self.tableView
 */
- (void)establishGestures {
	if (self.tableView == nil)
		return;
	
	if (longPressGestureRecognizer == nil || [self.tableView.gestureRecognizers containsObject:longPressGestureRecognizer] == NO) {
		longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRecognized)];
		longPressGestureRecognizer.delegate = self;
		
		[self.tableView addGestureRecognizer:longPressGestureRecognizer];
		
		/*
		 *	Default allowable movement is greater than that for cell highlighting.
		 *	That is, you can move your finger far enough to cancel highlight of a cell but still trigger the long press.
		 *	Number was decided on by a rigorous application of trial and error.
		 */
		longPressGestureRecognizer.allowableMovement = 5.0;
	}
	
	if (dragGestureRecognizer == nil || [self.tableView.gestureRecognizers containsObject:dragGestureRecognizer] ) {
		dragGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragGestureRecognized)];
		dragGestureRecognizer.delegate = self;

		[self.tableView addGestureRecognizer:dragGestureRecognizer];
	}
}


/*
 *	Currently completely releases the gesture recognizers. Might consider merely disabling them.
 */
- (void)removeGestures {
	if ( [self isDraggingCell] ) {
		CGPoint currentPoint = [dragGestureRecognizer translationInView:self.tableView];
		[self fastCompleteGesturesWithTranslationPoint:currentPoint];
	}
	
	[self.tableView removeGestureRecognizer:longPressGestureRecognizer];
	longPressGestureRecognizer = nil;
	
	[self.tableView removeGestureRecognizer:dragGestureRecognizer];
	dragGestureRecognizer = nil;
}


- (void)setReorderingEnabled:(BOOL)newEnabledStatus {
	if (_reorderingEnabled == newEnabledStatus)
		return;
	
	_reorderingEnabled = newEnabledStatus;
	
	if ( _reorderingEnabled )
		[self establishGestures];
	else
		[self removeGestures];
}


/*
 *	Getters, because of some stupid compiler bug about not mixing synthesize with hand-made setters. Feel free to remove if that goes away.
 */
- (BOOL)reorderingEnabled {
	return _reorderingEnabled;
}

- (BOOL)isReorderingEnabled {
	return [self reorderingEnabled];
}


- (BOOL)isDraggingCell {
	return (self.draggedCell != nil);
}


#pragma mark -
#pragma mark UIGestureRecognizerDelegate methods


/*
 *	Defaults to NO, needs to be YES for press and drag to be one continuous action.
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
	return (gestureRecognizer == dragGestureRecognizer || otherGestureRecognizer == dragGestureRecognizer);
}


/*
 *	Insure that only one touch and only the same touch reaches both gesture recognizers.
 */
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
	if( gestureRecognizer == longPressGestureRecognizer || gestureRecognizer == dragGestureRecognizer ) {
		static UITouch *longPressTouch = nil;
		
		if ( gestureRecognizer == longPressGestureRecognizer && longPressGestureRecognizer.state == UIGestureRecognizerStatePossible ) {
			longPressTouch = touch; // never retain a UITouch
			veryInitialTouchPoint = [touch locationInView:self.tableView];
		}

		/*
		 *	Only allow either gesture to receive that longPressTouch
		 */
		return ( touch == longPressTouch );
	}

	return YES;
}


#pragma mark -
#pragma mark UIGestureRecognizer targets and CADisplayLink target


/*
 *	Description:
 *		Target for longPress.
 *		If conditions are proper, establishes data that allows dragGesture to do work.
 *
 *		UILongPressGestureRecognizer calls this after a certain about of time if the touch doesn't move too far, and then calls it every frame (1/60th sec).
 */
- (void)longPressRecognized {
	/*
	 *	****************************
	 *	Find reasons to return early.
	 *	****************************
	 */
	
	
	/*
	 *	One potential reason: this was called because dragGesture never activated despite being allowed by former longPressGesture.
	 *	If this is true, undo state and data established by said former longPressGesture.
	 */
	if ([self touchCanceledAfterDragGestureEstablishedButBeforeDragging]) {
		[self completeGesturesForTranslationPoint:CGPointZero];
		return;
	}
	
	/*
	 *	Not a reason to return early.
	 *	Instead, it prevents touches from going to the tableview.
	 *
	 *	Has to occur after state == UIGestureRecognizerStateBegan else the touched cell will be "stuck" highlighted
	 */
	if ( self.draggedCell && longPressGestureRecognizer.state == UIGestureRecognizerStateChanged && self.tableView.allowsSelection )
		self.tableView.allowsSelection = NO;
	
	
	/*
	 *	Another potential reason to return early is because the state isn't appropriate.
	 *	This method is called whenever longPressGesture's state is changed, including when the state ends and when your finger moves.
	 *	So we only want to actually do anything when the longPress first begins, or we'll quickly have dozens, hundreds of fake cells and only one we can get rid of.
	 */
	if (longPressGestureRecognizer.state != UIGestureRecognizerStateBegan)
		return;
	
	/*
	 *	Get a valid indexPath to work with from the longPressGesture
	 *	Reason to end -- longPressGesture isn't actually touching a tableView row.
	 */
	NSIndexPath *indexPathOfRow = [self anyIndexPathFromLongPressGesture];
	if ( !indexPathOfRow )
		return;


	/*
	 *	If touch has moved across the boundaries to act on a different cell than the one selected, use the original selection.
	 */
	NSIndexPath *selectedPath = [self.tableView indexPathForRowAtPoint:veryInitialTouchPoint];
	if ( !(indexPathOfRow.section == selectedPath.section && indexPathOfRow.row == selectedPath.row) )
		indexPathOfRow = selectedPath;

	/*
	 *	For some other reason the cell isn't highlighed
	 */
	UITableViewCell *highlightedCell = [self.tableView cellForRowAtIndexPath:indexPathOfRow];
	if ( ![highlightedCell isHighlighted] )
		return;

	/*
	 *	Check to see if the tableView's data source will let us move this cell.
	 *	Return if the data source says NO.
	 *
	 *	This will likely look weird because UILongPressGestureRecognizer will still cancel the highlight touch.
	 */
	if ([self.tableView.dataSource respondsToSelector:@selector(tableView:canMoveRowAtIndexPath:)]) {
		if (![self.tableView.dataSource tableView:self.tableView canMoveRowAtIndexPath:indexPathOfRow])
			return;
	}


	/*
	 *	****************************
	 *	Situtation is good. Go ahead and allow dragGesture.
	 *	****************************
	 *
	 *	Establish state and data for dragGesture to work properly
	 */


	[self disableInterferingAspectsOfTableViewAndNavBar];


	/*
	 *	Create a cell to move with finger for drag gesture.
	 *	This dragged cell is not actually the cell selected, but a copy on on top of the real cell. Actual cell is hidden.
	 *
	 *	Important: (draggedCell != nil) is the flag that allows dragGesture to proceed.
	 */

	/*
	 *	If -tableView:cellForRowAtIndexPath: (in -cellPreparedToAnimateAroundAtIndexPath) has to create a new cell, the separator style wiil be set to the default.
	 *	This might cause a distratcting 1 px line at the bottom of the cell if the style is not the default.
	 *
	 *	In what has to be a bug, -reloadRowsAtIndexPaths:withRowAnimation: will cause a new cell to be created, so we do that first.
	 *	Then the separatorStyle will be set properly.
	 *
	 *	In what has to be another bug, -reloadRowsAtIndexPaths:withRowAnimation: will cause the row to stay highlighted if you chose the selected row.
	 *	Pick a non-selected row, which is one reason it is recommended to disable reordering on tableviews with <= 1 rows.
	 *
	 *	Why not just [self.draggedCell setSeparatorStyle:self.tableView.separatorStyle] ourselves? That's a private method.
	 */


	NSIndexPath *indexPathOfSomeOtherRow = [self indexPathOfSomeRowThatIsNotIndexPath:indexPathOfRow];

	if (indexPathOfSomeOtherRow != nil)
		[self.tableView reloadRowsAtIndexPaths:@[indexPathOfSomeOtherRow] withRowAnimation:UITableViewRowAnimationNone];

	self.draggedCell = [self cellPreparedToAnimateAroundAtIndexPath:indexPathOfRow];

	[self.draggedCell setHighlighted:YES animated:NO];
	[UIView animateWithDuration:0.23 delay:0 options:(UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionCurveEaseInOut) animations:^{
		[self.indicatorDelegate dragTableViewController:self addDraggableIndicatorsToCell:self.draggedCell forIndexPath:indexPathOfRow];
	} completion:^(BOOL finished) {
		/*
		 *	 We're not changing the cell after this so go ahead and rasterize.
		 *	Rasterization scale seems to default to 1 if layer is rasterized offscreen or something.
		 *
		 *	If it didn't complete, it was likely interrupted by another animation. Don't rasterize the cell on it.
		 */

		if (finished) {
			self.draggedCell.layer.rasterizationScale = [[UIScreen mainScreen] scale];
			self.draggedCell.layer.shouldRasterize = YES;
		}
	}];

	/*
	 *	Save initial y offset so that we can move it with the dragGesture.
	 *	Drag gesture gives translation data, not so much points relative to screen.
	 *	Though it *does* give points, and we could consider translating them to [self.tableView superview] for absolute on screen position.
	 *	(would need to save touchIndex for gesture's -locationOfTouch:inView:)
	 */
	initialYOffsetOfDraggedCellCenter = self.draggedCell.center.y - self.tableView.contentOffset.y;

	/*
	 *	Set needed threshold to autoscroll to be the distance from the center of the cell to just beyond an edge
	 *	This way we reflect official drag behavior where it hits maximum speed at the center and starts scrolling just before the edge.
	 */
	distanceThresholdToAutoscroll = self.draggedCell.frame.size.height / 2.0 + 6;

	/*
	 *	Grab index path of selected cell.
	 *	To be used for moving the blank cell around to create illusion that cells are shuffling out of the way of the draggedCell.
	 *	And finally, tell the delegate we're going to start dragging
	 */
	self.indexPathBelowDraggedCell = indexPathOfRow;

	if ([self.dragDelegate respondsToSelector:@selector(dragTableViewController:didBeginDraggingAtRow:)])
		[self.dragDelegate dragTableViewController:self didBeginDraggingAtRow:indexPathOfRow];

	UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString(@"Now dragging.", @"Voiceover annoucement"));
}


/*
 *	Description:
 *		target for dragGesture.
 *		Requires longPressRecognized to set up data first.
 *
 *		UIPanGestureRecognizer calls this when position changes.
 *		Remember that on retina displays these are 0.5 pixel increments.
 */
- (void)dragGestureRecognized {
	/*
	 *	If no draggedCell, nothing to drag.
	 *	Also means that longPress probably hasn't fired.
	 */
	if ( !self.draggedCell )
		return;

	/*
	 *	If dragGesture has ended (finger has lifted), clean up data and put cell "back" into tableview.
	 *	Otherwise use translation to update position of cell.
	 */
	CGPoint translation = [dragGestureRecognizer translationInView:self.tableView];

	if (dragGestureRecognizer.state == UIGestureRecognizerStateEnded || dragGestureRecognizer.state == UIGestureRecognizerStateCancelled)
		[self completeGesturesForTranslationPoint:translation];
	else
		[self updateDraggedCellWithTranslationPoint:translation];
}


/*
 *	Description:
 *		Determines whether and how much to scroll the tableView due to proximity of draggedCell to the edge.
 *		Updates the contentOffset and the draggedCell with the same value so that the "visible location" of dragged cell isn't changed by scrolling.
 *		DraggedCell continues to follow touch elsewhere, not here.
 */
- (void)fireAutoscrollTimer:(CADisplayLink *)sender {
	/*
	 *	Ensure blank cell is actually blank. There are some legit cases where this might not be so, particularly with large row heights.
	 */
	UITableViewCell *blankCell = [self.tableView cellForRowAtIndexPath:self.indexPathBelowDraggedCell];
	if (blankCell != nil && blankCell.hidden == NO)
		blankCell.hidden = YES;

	/*****
	 *
	 *	Determine how far to autoscroll based on current position.
	 *
	 *****/

	// Signed distance has negative values if near the top.
	CGFloat signedDistance = [self distanceOfCellCenterFromEdge];

	CGFloat absoluteDistance = fabs(signedDistance);

	CGFloat autoscrollDistance = [self autoscrollDistanceForProximityToEdge:absoluteDistance];
	// negative values means going up
	if (signedDistance < 0)
		autoscrollDistance *= -1;



	/*****
	 *
	 *	Move tableView and dragged cell
	 *
	 *****/

	AutoscrollStatus autoscrollOption = [self locationOfCellGivenSignedAutoscrollDistance:autoscrollDistance];

	CGPoint tableViewContentOffset = self.tableView.contentOffset;

	if ( autoscrollOption == AutoscrollStatusCellAtTop ) {
		/*
		 *	In this case, set the tableview content offset y to 0.
		 *	The change in autoscroll is only how far it is to 0.
		 */
		CGFloat scrollDistance = tableViewContentOffset.y;
		tableViewContentOffset.y = 0;

		draggedCell.center = CGPointMake(draggedCell.center.x, draggedCell.center.y - scrollDistance);

		/*
		 *	Can't move any further up, and if we start moving down it'll create a new timer anyway.
		 * 	Leave as != nil so we aren't constantly creating and releasing CADisplayLinks.
		 *	It'll be nil'ed when we move out of distanceThresholdToAutoscroll.
		 */
		[self.timerToAutoscroll invalidate];
	} else if ( autoscrollOption == AutoscrollStatusCellAtBottom ) {
		/*
		 *	Similarly, set the tableview content offset y to the full offset.
		 *	Set to 0 if full offset is less than the tableview bounds.
		 *	Scroll distance is the change in content offset.
		 */

		CGFloat yOffsetForBottomOfTableViewContent = MAX(0, (self.tableView.contentSize.height - self.tableView.frame.size.height));

		CGFloat scrollDistance = yOffsetForBottomOfTableViewContent - tableViewContentOffset.y;
		tableViewContentOffset.y = yOffsetForBottomOfTableViewContent;

		draggedCell.center = CGPointMake(draggedCell.center.x, draggedCell.center.y + scrollDistance);

		/*
		 *	Can't move any further down, and if we start moving up it'll create a new timer anyway.
		 *	Leave as != nil so we aren't constantly creating and releasing CADisplayLinks.
		 *	It'll be nil'ed when we move out of distanceThresholdToAutoscroll.
		 */
		[self.timerToAutoscroll invalidate];
	} else {
		/*
		 *	Neither at the top of the contentOffset nor the bottom so we just
		 *		update the content offset with the needed change and
		 *		update the dragged cell with the same value so that it maintains the same visible location.
		 */
		tableViewContentOffset.y += autoscrollDistance;
		draggedCell.center = CGPointMake(draggedCell.center.x, draggedCell.center.y + autoscrollDistance);
	}

	self.tableView.contentOffset = tableViewContentOffset;

	[self keepDraggedCellVisible];

	[self shuffleCellsOutOfWayOfDraggedCellIfNeeded];
}


#pragma mark -
#pragma mark longPressRecognized helper methods


/*
 *	Description:
 *		Can happen if you press down for a while but don't drag in a direction.
 *	Returns:
 *		If YES, you should undo changes maded by -longPressRecognized.
 */
- (BOOL)touchCanceledAfterDragGestureEstablishedButBeforeDragging {
	return (self.draggedCell != nil && longPressGestureRecognizer.state == UIGestureRecognizerStateEnded && dragGestureRecognizer.state == UIGestureRecognizerStateFailed);
}


///*
//	Description:
//		Crash to prevent potential data corruption.
//		Called before establishing new draggedCell and indexPathOfBlankItem
// */
//- (void)assertPreviousDraggingEndedProperly {
//	NSAssert(self.draggedCell == nil, @"Dragged cell overlap");
//	NSAssert(self.indexPathOfBlankItem == nil, @"Index path wasn't properly whatevered");
//}


/*
	Description:
		Return a valid indexPath from longPressGesture.
		There might be multiple touches, some of which aren't actually touching valid indexPath rows.
		…Though I'm not sure UILongPressGestureRecognizer will ever trigger if there are more than 1 touches.
		And in any case, how would we know which one UIPanGestureRecognizer is following?
	Returns:
		An NSIndexPath of a touched row or nil if none of the touches are on rows.
 */
- (NSIndexPath *)anyIndexPathFromLongPressGesture {
	/*
		Iterate through touches. A little bit roundabout because there's no simple array of points.
	 */
	for (NSUInteger pointIndex = 0; pointIndex < [longPressGestureRecognizer numberOfTouches]; ++pointIndex) {
		CGPoint touchPoint = [longPressGestureRecognizer locationOfTouch:pointIndex inView:self.tableView];

		/*
			See if tableView thinks that point is a real row. If it is, return that.
		 */
		NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:touchPoint];
		if (indexPath != nil)
			return indexPath;
	}

	/*
		No indexPaths were found, return nil.
	 */
	return nil;
}


/*
	Description:
		Create a cell on top of the actual cell at indexPath.
		Used for creating the illusion that cell is moving independantly of tableView.
		Needed for use of deleteRowAtIndexPath and insertRowAtIndexPath without affecting moving cell.
	Parameter:
		indexPath of cell to replicate.
	Return:
		A cell generated by tableView's dataSource without being specifically connected to the tableView.
 */
- (UITableViewCell *)cellPreparedToAnimateAroundAtIndexPath:(NSIndexPath *)indexPath {
	/*
		Get a new cell and put it on top of actual cell for that index path.
	 */
	UITableViewCell *cellCopy;
	if ( [self.indicatorDelegate respondsToSelector:@selector(cellIdenticalToCellAtIndexPath:forDragTableViewController:)])
		cellCopy = [self.indicatorDelegate cellIdenticalToCellAtIndexPath:indexPath forDragTableViewController:self];
	else
		cellCopy = [self.tableView.dataSource tableView:self.tableView cellForRowAtIndexPath:indexPath];
	cellCopy.frame = [self.tableView rectForRowAtIndexPath:indexPath];

	[self.tableView addSubview:cellCopy];
	[self.tableView bringSubviewToFront:cellCopy];

	/*
		Adjust actual cell so it is blank when cell copy moves off of it
		Hidden is set back to NO when reused.
	 */
	UITableViewCell *actualCell = [self.tableView cellForRowAtIndexPath:indexPath];
	if (actualCell != nil)
		actualCell.hidden = YES;

	return cellCopy;
}

/*
	Description:
		Gives us some other index path to work around a stupid bug.
		Perhaps more complicated that it needs to be because we're avoiding assumptions about how the tableview works.
 */
- (NSIndexPath *)indexPathOfSomeRowThatIsNotIndexPath:(NSIndexPath *)selectedIndexPath {
	NSArray *arrayOfVisibleIndexPaths = [self.tableView indexPathsForVisibleRows];

	/*
		if there's only one cell, then return nil.
		Remember you can't insert nil into an array.
	 */
	if (arrayOfVisibleIndexPaths.count <= 1)
		return nil;

	NSIndexPath *indexPathOfSomeOtherRow = [arrayOfVisibleIndexPaths lastObject];

	/*
		Check if they're the same
	 */
	if (indexPathOfSomeOtherRow.row == selectedIndexPath.row && indexPathOfSomeOtherRow.section == selectedIndexPath.section)
		indexPathOfSomeOtherRow = [arrayOfVisibleIndexPaths objectAtIndex:0];

	return indexPathOfSomeOtherRow;
}


#pragma mark -
#pragma mark dragGestureRecognized helper methods


/*
	Description:
		Stop the cell from going off tableview content frame. Instead stops flush with top or bottom of tableview.
		Matches behavior of editing's drag control.
 */
- (void)keepDraggedCellVisible {
	/*
		Prevent it from going above the top.
	 */
	if (draggedCell.frame.origin.y <= 0) {
		CGRect newDraggedCellFrame = draggedCell.frame;
		newDraggedCellFrame.origin.y = 0;
		draggedCell.frame = newDraggedCellFrame;

		/*
			Return early. Flush with the top is exclusive with flush with the bottom, short of odd coincidence.
		 */
		return;
	}


	/*
		Prevent it from going off the bottom.
		Make a content rect which is a frame of the entire content.
	 */
	CGRect contentRect = {
		.origin = self.tableView.contentOffset,
		.size = self.tableView.contentSize
	};

	/*
		Height of content minus height of cell. Means the bottom of the cell is flush with the bottom of the tableview.
	 */
	CGFloat maxYOffsetOfDraggedCell = contentRect.origin.x + contentRect.size.height - draggedCell.frame.size.height;

	if (draggedCell.frame.origin.y >= maxYOffsetOfDraggedCell) {
		CGRect newDraggedCellFrame = draggedCell.frame;
		newDraggedCellFrame.origin.y = maxYOffsetOfDraggedCell;
		draggedCell.frame = newDraggedCellFrame;
	}

}

/*
	Description:
		Set frame for dragged cell based on translation.
		Translation point is distance from original press down.

		Official drag control keeps the cell's center visible at all times.
 */
- (void)updateFrameOfDraggedCellForTranlationPoint:(CGPoint)translation {
	CGFloat newYCenter = initialYOffsetOfDraggedCellCenter + translation.y + self.tableView.contentOffset.y;

	/*
		draggedCell.center shouldn't go offscreen.
		Check that it's at least the contentOffset and no further than the contentoffset plus the contentsize.
	 */
	newYCenter = MAX(newYCenter, self.tableView.contentOffset.y);
	newYCenter = MIN(newYCenter, self.tableView.contentOffset.y + self.tableView.bounds.size.height);

	CGPoint newDraggedCellCenter = {
		.x = draggedCell.center.x,
		.y = newYCenter
	};

	draggedCell.center = newDraggedCellCenter;

	/*
		Don't let the cell go off of the tableview
	 */
	[self keepDraggedCellVisible];
}

/*
	Description:
		Checks if the draggedCell is close to an edge and makes tableView autoscroll or not depending.
 */
- (void)setTableViewToAutoscrollIfNeeded {
	/*
		Get absolute distance from edge.
	 */
	CGFloat absoluteDistance = [self distanceOfCellCenterFromEdge];
	if (absoluteDistance < 0)
		absoluteDistance *= -1;

	/*
		If cell is close enough, create a timer to autoscroll.
	 */
	if (absoluteDistance < distanceThresholdToAutoscroll) {
		/*
			dragged cell is close to the top or bottom edge, so create an autoscroll timer if needed.
		 */
		if (self.timerToAutoscroll == nil) {
			/*
				Timer is actually a CADisplayLink, which fires everytime Core Animation wants to draw, aka, every frame.
				Using an NSTimer with 1/60th of a second hurts frame rate because it might update in between drawing and force it to try to draw again.
			 */
			self.timerToAutoscroll = [CADisplayLink displayLinkWithTarget:self selector:@selector(fireAutoscrollTimer:)];
			[self.timerToAutoscroll addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
		}
	} else {
		/*
			If we move our cell out of the autoscroll threshold, remove the timer and stop autoscrolling.
		 */
		if (self.timerToAutoscroll != nil) {
			[timerToAutoscroll invalidate];
			self.timerToAutoscroll = nil;
		}
	}
}

/*
	Description:
		Animates the dragged cell sliding back into the tableview.
		Tells the data model to update as appropriate.
 */
- (void)endedDragGestureWithTranslationPoint:(CGPoint)translation {
	/*
		Get final frame of cell.
	 */
	[self updateFrameOfDraggedCellForTranlationPoint:translation];
	/*
		If the row changes at the last minute, update so we don't put it away in the wrong spot
	 */
	[self shuffleCellsOutOfWayOfDraggedCellIfNeeded];

	/*
		Notify the delegate that we're about to finish
	 */
	if ([self.dragDelegate respondsToSelector:@selector(dragTableViewController:willEndDraggingToRow:)])
		[self.dragDelegate dragTableViewController:self willEndDraggingToRow:self.indexPathBelowDraggedCell];


	/*
		Save pointer to dragged cell so we can remove it from superview later. Same with blank item index path.
		By the time the completion block is called, self.draggedCell == nil, which is proper behavior to prevent overlapping drags or whatnot.

		Probably not necessary to retain, because the superview retains it.
		But I'm going to be safe, and modifying retainCount is trivial anyway.
	 */
	UITableViewCell *oldDraggedCell = self.draggedCell;
	NSIndexPath *blankIndexPath = self.indexPathBelowDraggedCell;

	CGRect rectForIndexPath = [self.tableView rectForRowAtIndexPath:self.indexPathBelowDraggedCell];

	BOOL hideDragIndicator = YES;
	if( [self.dragDelegate respondsToSelector:@selector(dragTableViewController:shouldHideDraggableIndicatorForDraggingToRow:)] )
		hideDragIndicator = [self.dragDelegate dragTableViewController:self shouldHideDraggableIndicatorForDraggingToRow:blankIndexPath];

	/*
	 Dehighlight the cell while moving it to the expected location for that indexPath's cell.
	 */
	self.draggedCell.layer.shouldRasterize = NO;
	if( hideDragIndicator )
		[(UITableViewCell *)self.draggedCell setHighlighted:NO animated:YES];

	[UIView animateWithDuration:0.25 delay:0 options:(UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionBeginFromCurrentState) animations:^{
		oldDraggedCell.frame = rectForIndexPath;

		/*
			Hides the draggable appearance.
		 */
		if( hideDragIndicator )
			[self.indicatorDelegate dragTableViewController:self hideDraggableIndicatorsOfCell:oldDraggedCell];
	} completion:^(BOOL finished) {
		/*
		 Update tableView to show the real cell. Reload to reflect any changes caused by dragDelegate.
		 */
		[self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:blankIndexPath] withRowAnimation:UITableViewRowAnimationNone];

		/*
		 Removes the draggable appearance so cell can be reused.
		 */
		[self.indicatorDelegate dragTableViewController:self removeDraggableIndicatorsFromCell:oldDraggedCell];

		[oldDraggedCell removeFromSuperview];

		if( [self.dragDelegate respondsToSelector:@selector(dragTableViewController:didEndDraggingToRow:)] )
			[self.dragDelegate dragTableViewController:self didEndDraggingToRow:blankIndexPath];

		UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString(@"Drag completed.", @"Voiceover annoucement"));
	}];

	/*
		If the cell is at the top or bottom of the view, bring that location visible.
	 */
	[self.tableView scrollRectToVisible:rectForIndexPath animated:YES];
}


/*
	Description:
		Cleanup and complete data from gestures.
		Do the same thing as -completeGesturesForTranslationPoint:, but for when we can't wait for animations.
		Largely copied from -endedDragGestureWithTranslationPoint:
 */
- (void)fastCompleteGesturesWithTranslationPoint:(CGPoint) translation {
	[self updateFrameOfDraggedCellForTranlationPoint:translation];
	/*
		If it happens to change at the last minute we don't put it away in the wrong spot
	 */
	[self shuffleCellsOutOfWayOfDraggedCellIfNeeded];

	/*
		Reset tableView and delegate back to normal
	 */
	if ([self.dragDelegate respondsToSelector:@selector(dragTableViewController:willEndDraggingToRow:)])
		[self.dragDelegate dragTableViewController:self willEndDraggingToRow:self.indexPathBelowDraggedCell];

	[self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:self.indexPathBelowDraggedCell] withRowAnimation:UITableViewRowAnimationNone];

	/*
		Revert dragged cell selection color to normal
	 */
	self.draggedCell.layer.shouldRasterize = NO;

	[self.indicatorDelegate dragTableViewController:self removeDraggableIndicatorsFromCell:self.draggedCell];

	[self.draggedCell removeFromSuperview];

	/*
		Remaining cleanup.
	 */
	[self resetDragIVars];
	[self resetTableViewAndNavBarToTypical];
}


/*
	Description:
		Should be called when gestures have ended.
		Cleanup ivars and return tableView to former state.
 */
- (void)completeGesturesForTranslationPoint:(CGPoint)translation {
	/*
		Put dragged cell back into proper place.
		Should probably short circuit if translation.y is zero.
	 */
	[self endedDragGestureWithTranslationPoint:translation];

	/*
		Make certain everything is released and nil'ed for next press and drag gesture.
	 */
	[self resetDragIVars];
	[self resetTableViewAndNavBarToTypical];

}


/*
	Description:
		If necessary, move blank cell so that it appears that the tableview's cells are shuffling out of the way of the draggedCell
 */
- (void)shuffleCellsOutOfWayOfDraggedCellIfNeeded {
	/*
		This used to be easy until we started dealing with variable row sizes.

		Now we compare the dragged cell's center with the center of the whole covered rect to determine whether to shuffle.
	 */
	NSArray *arrayOfCoveredIndexPaths = [self.tableView indexPathsForRowsInRect:self.draggedCell.frame];

	/*
		Use blank rect instead of the cell itself. The cell might be offscreen and thus nil.
		Blank cell might not be covered either, if the dragged cell is smaller than the nearby cell.
	 */
	CGRect blankCellFrame = [self.tableView rectForRowAtIndexPath:self.indexPathBelowDraggedCell];
	CGPoint blankCellCenter = {
		.x = CGRectGetMidX(blankCellFrame),
		.y = CGRectGetMidY(blankCellFrame)
	};

	CGRect rectOfCoveredCells = blankCellFrame;
	for (NSIndexPath *row in arrayOfCoveredIndexPaths) {
		CGRect newRect = CGRectUnion(rectOfCoveredCells, [self.tableView rectForRowAtIndexPath:row]);
		rectOfCoveredCells = newRect;
	}

	/*
		nil unless we actually are going to move cells.
	 */
	NSIndexPath *rowToMoveTo = nil;

	/*
		So we've ended up with a rect of all the covered cells.
		Compare its center with the dragged cell to determine whether the dragged cell is approaching the top or bottom.
	 */
	if (draggedCell.center.y < CGRectGetMidY(rectOfCoveredCells)) {
		/*
			Dragged cell is in the upper portion.
		 */

		CGRect upperHalf = {
			.origin = rectOfCoveredCells.origin,
			.size.width = rectOfCoveredCells.size.width,
			.size.height = rectOfCoveredCells.size.height / 2
		};

		/*
			If upper portion does not contain blank index path, mark that it should
		 */
		if (!CGRectContainsPoint(upperHalf, blankCellCenter)) {
			/*
				Get the row before the blank cell
			 */
			NSUInteger blankCellIndex = [arrayOfCoveredIndexPaths indexOfObject:self.indexPathBelowDraggedCell];

			if (blankCellIndex != NSNotFound && blankCellIndex != 0 && (blankCellIndex - 1) > 0)
				rowToMoveTo = [arrayOfCoveredIndexPaths objectAtIndex:(blankCellIndex - 1)];
			else if (arrayOfCoveredIndexPaths.count > 0)
				rowToMoveTo = [arrayOfCoveredIndexPaths objectAtIndex:0];
		}

	} else {
		/*
			Dragged cell is in lower portion
		 */

		CGRect lowerHalf ={
			.origin.x = rectOfCoveredCells.origin.x,
			.origin.y = rectOfCoveredCells.origin.y + rectOfCoveredCells.size.height / 2,
			.size.width = rectOfCoveredCells.size.width,
			.size.height = rectOfCoveredCells.size.height / 2
		};

		/*
			If lower portion does not contain the blank index path, mark that it should
		 */
		if (!CGRectContainsPoint(lowerHalf, blankCellCenter)) {
			/*
				Get the row after the blank cell
			 */
			NSUInteger blankCellIndex = [arrayOfCoveredIndexPaths indexOfObject:self.indexPathBelowDraggedCell];

			if (blankCellIndex != NSNotFound && (blankCellIndex + 1) < arrayOfCoveredIndexPaths.count)
				rowToMoveTo = [arrayOfCoveredIndexPaths objectAtIndex:(blankCellIndex + 1)];
			else
				rowToMoveTo = [arrayOfCoveredIndexPaths lastObject];
		}
	}


	/*
		If the dragged cell is covering a new row that isn't the one with the blank item, move the blank item to that new row.
	 */
	if (rowToMoveTo != nil && !(rowToMoveTo.section == self.indexPathBelowDraggedCell.section && rowToMoveTo.row == self.indexPathBelowDraggedCell.row)) {
		/*
			Tableview's dataSource must update before we ask the tableview to update rows.
		 */
		[self.tableView.dataSource tableView:self.tableView moveRowAtIndexPath:self.indexPathBelowDraggedCell toIndexPath:rowToMoveTo];

		/*
			Update the blank index path
		 */
		NSIndexPath *formerBlankIndexPath = self.indexPathBelowDraggedCell;
		self.indexPathBelowDraggedCell = rowToMoveTo;

		/*
			Then animate the row updates.
		 */
		if ( [self.tableView respondsToSelector:@selector(moveRowAtIndexPath:toIndexPath:)] )
			[self.tableView moveRowAtIndexPath:formerBlankIndexPath toIndexPath:rowToMoveTo];
		else {
			[self.tableView beginUpdates];
			[self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:formerBlankIndexPath] withRowAnimation:UITableViewRowAnimationNone];
			[self.tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:self.indexPathBelowDraggedCell] withRowAnimation:UITableViewRowAnimationNone];
			[self.tableView endUpdates];
		}


		/*
			Keep the cell under the dragged cell hidden.
			This is a crucial line of code. Otherwise we get all kinds of graphical weirdness
		 */
		UITableViewCell *cellToHide = [self.tableView cellForRowAtIndexPath:self.indexPathBelowDraggedCell];
		cellToHide.hidden = YES;

	}
}


/*
	Description:
		Update the dragged cell to its new position and updates the tableView to shuffle cells out of the way.
 */
- (void)updateDraggedCellWithTranslationPoint:(CGPoint)translation {
	/*
		Set new frame of dragged cell,
		then use this new frame to check if the tableview needs to autoscroll or shuffle cells out of the way or both.
	 */
	[self updateFrameOfDraggedCellForTranlationPoint:translation];
	[self setTableViewToAutoscrollIfNeeded];
	[self shuffleCellsOutOfWayOfDraggedCellIfNeeded];
}


#pragma mark -
#pragma mark fireAutoscrollTimer helper methods

/*
	Description:
		Calculates how far from the top or bottom edge of the tableview the cell's visible center is.
	Returns:
		A positive number if close to the bottom, negative if close to top.
		Will not return zero.
 */
- (CGFloat)distanceOfCellCenterFromEdge {

	/*
		Use translation data to get absolute position of touch insted of cell. Cell is bound by tableview content offset and contentsize, touch is not.
	 */
	CGPoint translation = [dragGestureRecognizer translationInView:self.tableView];
	
	CGFloat yOffsetOfDraggedCellCenter = initialYOffsetOfDraggedCellCenter + translation.y;
	
	CGFloat heightOfTableView = self.tableView.bounds.size.height;
	
	if (yOffsetOfDraggedCellCenter > heightOfTableView/2.0) {
		/*
			The subtraction from the height is to make it faster to autoscroll down.
			Scrolling up is easy because there's a navigation bar to cover. No such luck when scrolling down.
			So the "bottom" of the tableView is considered to be higher than it is.

			Todo: make this more generic by checking for existance of toolbar or navbar, but even that might not be generic enough.
			Could check position in UIWindow, perhaps.
		 */

		/*
			Return positive because going down.
		 */
		CGFloat paddingAgainstBottom = 8.0;

		return MAX((1.0 / [UIScreen mainScreen].scale), (heightOfTableView - paddingAgainstBottom) - yOffsetOfDraggedCellCenter);
	} else
		/*
			Return negative because going up.
		 */
		return -1 * MAX((1.0 / [UIScreen mainScreen].scale), yOffsetOfDraggedCellCenter);
}



/*
	Description:
		Figures out how much to scroll the tableView depending on how close it is to the edge.
	Parameter:
		The distance
	Returns:
		Distance in pixels to move the tableView. None of this velocity stuff.
 */
- (CGFloat)autoscrollDistanceForProximityToEdge:(CGFloat)proximity {
    /*
		To scroll more smoothly on Retina Displays, we multiply by scale, ceilf the result, and then divide by scale again.
		This will allow us to round to 0.5 pixel increments on retina displays instead of rounding up to 1.0.
	 */
	/*
		To support variable row heights. We want speed at the center of a cell to be the same no matter what size cell it is.
		Mimics behavior of built-in drag control.

		Higher max distance traveled means faster autoscrolling.
	 */
    CGFloat maxAutoscrollDistance = 5.0;
    if ( [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad )
        maxAutoscrollDistance = 9.0;

#if CGFLOAT_IS_DOUBLE
	return ceil((distanceThresholdToAutoscroll - proximity)/distanceThresholdToAutoscroll * maxAutoscrollDistance * [UIScreen mainScreen].scale) / [UIScreen mainScreen].scale;
#else
	return ceilf((distanceThresholdToAutoscroll - proximity)/distanceThresholdToAutoscroll * maxAutoscrollDistance * [UIScreen mainScreen].scale) / [UIScreen mainScreen].scale;
#endif
}




- (AutoscrollStatus)locationOfCellGivenSignedAutoscrollDistance:(CGFloat)signedAutoscrollDistance {

	if ( signedAutoscrollDistance < 0 && self.tableView.contentOffset.y + signedAutoscrollDistance <= 0 )
		return AutoscrollStatusCellAtTop;

	if ( signedAutoscrollDistance > 0 && self.tableView.contentOffset.y + signedAutoscrollDistance >= self.tableView.contentSize.height - self.tableView.frame.size.height )
		return AutoscrollStatusCellAtBottom;

	return AutoscrollStatusCellInBetween;

}



#pragma mark -
#pragma mark miscellaneous helper methods


/*
	Description:
		Disable or enable status bar and nav bar elements.
	Parameter:
		new enabled state.
 */
- (void)setInterferingElementsToEnabled:(BOOL)enabled {
	/*
		Enable or disable navigation controller elements.
	 */
	if (self.navigationController != nil) {
		self.navigationController.navigationBar.userInteractionEnabled = enabled;
		self.navigationController.toolbar.userInteractionEnabled = enabled;
	}

	/*
		Disable or enable tab bar.
		Might throw an exception, according to the documentation. I seriously doubt it, though.
	 */
	if (self.tabBarController != nil)
		self.tabBarController.tabBar.userInteractionEnabled = enabled;

	/*
		No reason we couldn't scroll to top while dragging but that involves math and let's just not make this any more confusing.
	 */
	self.tableView.scrollsToTop = enabled;
}


/*
	Description:
		Allows normal operation of tableView and navigation.
		Should only be called when dragged item has been place back into the data model.
 */
- (void)resetTableViewAndNavBarToTypical {
	[self setInterferingElementsToEnabled:YES];

	/*
		Counterpart near the start of -longPressRecognized
	 */
	self.tableView.allowsSelection = YES;

}


/*
	Description:
		Prevent against status bar and nav bar button presses while dragging.
		Nav bar buttons in particular could delete dragged item because it isn't placed back into the data model.
 */
- (void)disableInterferingAspectsOfTableViewAndNavBar {
	[self setInterferingElementsToEnabled:NO];
}


/*
	Reset ivars used by dragGesture and longPressGesture.
 */
- (void)resetDragIVars {
	self.draggedCell = nil;
	self.indexPathBelowDraggedCell = nil;
	[self.timerToAutoscroll invalidate];
	self.timerToAutoscroll = nil;
	distanceThresholdToAutoscroll = -1.0;
}


#pragma mark -
#pragma mark add and remove indications of draggability methods


/*
	Description:
		Creates a view that contains a shadow and clips the parts we don't want out.
		Helper function for -addShadowViewsToCell:
 */
- (UIView *)shadowViewWithFrame:(CGRect)frame andShadowPath:(CGPathRef)shadowPath {
	UIView *shadowView = [[UIView alloc] initWithFrame:frame];

	/*
		Shadow attributes common to both views.
	 */
	CGFloat commonShadowOpacity = 0.8;
	CGSize commonShadowOffset = {
		.width = 0,
		.height = 1
	};
	CGFloat commonShadowRadius = 4;

	/*
		The whole point of the shadow view is that it clips the shadow to hide the part of the shadow that appears under the cell.
		Thus it's invisible and it clips to bounds.
	 */
	shadowView.backgroundColor = [UIColor clearColor];
	shadowView.opaque = NO;
	shadowView.clipsToBounds = YES;

	/*
		Set shadow attributes to the layer
	 */
	shadowView.layer.shadowPath = shadowPath;
	shadowView.layer.shadowOpacity = commonShadowOpacity;
	shadowView.layer.shadowOffset = commonShadowOffset;
	shadowView.layer.shadowRadius = commonShadowRadius;

	return shadowView;
}


/*
	Description:
		Adds shadows to the cell to give it an appearance of being raised off the tableview.
	Note:
		Will add subviews for clipping the shadows. This code was written with transparent selectedBackgroundViews in mind.
		Subviews have tags #defined at top of file
	Parameter:
		a cell with a non-nil selectedBackgroundView
	Returns:
		An array of the added shadowViews.
		Top shadow is index 0, bottom shadow is index 1.
		Returns nil if not successful.
 */
- (NSArray *)addShadowViewsToCell:(UITableViewCell *)selectedCell {
	/*
		We're going to create shadow paths, which is the rect of the cell.
		Then we'll create two views on top and bottom of the cell that clip to bounds.

		We're really going to use the same shadow (a shadow the size of the cell itself) represented in two different views.
	 */

	/*
		If selectedBackgroundView is nil, return.
	 */
	if (selectedCell.selectedBackgroundView == nil)
		return nil;

	/*
		Rects for views.

		Rects are in "offscreen" space. They'll be subviews of cells but outside it.
		These views are to prevent the shadow from appearing under the cell.

		ShadowPath rects have to be defined from the shadow views' prespectives. This is kinda annoying.

		I suspect a better approach would use -convertRect:fromView: to convert a common shadowpath rect to the shadowViews, but I already wrote this, and it works fine.
	 */

	CGFloat heightOfViews = 10; // make it enough space to show whole shadow
	CGRect shadowPathFrame = selectedCell.selectedBackgroundView.frame;


	/*
		aboveShadowView rects
	 */
	CGRect aboveShadowViewFrame = {
		.origin.x = 0,
		.origin.y = -heightOfViews,
		.size.width = shadowPathFrame.size.width,
		.size.height = heightOfViews
	};

	/*
		Shadow path is offset back down, has the size of the cell.
	 */
	CGRect shadowPathRectFromAbovePerspective = {
		.origin.x = 0,
		.origin.y = -aboveShadowViewFrame.origin.y,
		.size = shadowPathFrame.size
	};

	UIBezierPath *aboveShadowPath = [UIBezierPath bezierPathWithRect:shadowPathRectFromAbovePerspective];


	/*
		belowShadowView rects
	 */
	CGRect belowShadowViewFrame = {
		.origin.x = 0,
		.origin.y = shadowPathFrame.size.height,
		.size.width = shadowPathFrame.size.width,
		.size.height = heightOfViews
	};

	/*
		Shadow path is offset back up, has the size of the cell
	 */
	CGRect shadowPathRectFromBelowPerspective = {
		.origin.x = 0,
		.origin.y = -belowShadowViewFrame.origin.y,
		.size = shadowPathFrame.size
	};

	UIBezierPath *belowShadowPath = [UIBezierPath bezierPathWithRect:shadowPathRectFromBelowPerspective];


	/*
		Make views. Add a tag so we can manipulate and remove them later.
	 */
	UIView *aboveShadowView = [self shadowViewWithFrame:aboveShadowViewFrame andShadowPath:aboveShadowPath.CGPath];
	aboveShadowView.tag = TAG_FOR_ABOVE_SHADOW_VIEW_WHEN_DRAGGING;
	aboveShadowView.alpha = 0; // set to 0 before adding as subview

	UIView *belowShadowView = [self shadowViewWithFrame:belowShadowViewFrame andShadowPath:belowShadowPath.CGPath];
	belowShadowView.tag = TAG_FOR_BELOW_SHADOW_VIEW_WHEN_DRAGGING;
	belowShadowView.alpha = 0;

	/*
		Add them to the cell itself.
		This way they're above the separator style view.
	 */
	[selectedCell addSubview:aboveShadowView];
	[selectedCell addSubview:belowShadowView];
	[selectedCell bringSubviewToFront:belowShadowView];

	return [NSArray arrayWithObjects:aboveShadowView, belowShadowView, nil];
}


/*
	Description:
		Makes a cell appear draggable.
			Adds shadows,
			Bumps up the alpha of the selectedBackgroundView
	Parameters:
		cell -- Almost certainly will be self.draggedCell
		indexPath -- path of cell, provided for subclasses
 */
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController addDraggableIndicatorsToCell:(UITableViewCell *)cell forIndexPath:(NSIndexPath *)indexPath {

	 NSArray *arrayOfShadowViews = [self addShadowViewsToCell:cell];

	for (UIView *shadowView in arrayOfShadowViews)
		shadowView.alpha = 1;
}


/*
	Description:
		 Sets the draggable indicators to alpha = 0, effectively.
		 Intented to be used in an animation block.
	
		 cell.layer.shouldRasterize is expected to be NO before this method is called.
		 Doesn't actually remove the draggable changes (that is, the shadow views). Thus, expectation is -removeDraggableIndicatorsFromCell: is called when animation is completed.
		 
		 If you don't want to animate, just use -removeDraggableIndicatorsFromCell: directly.
 */
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController hideDraggableIndicatorsOfCell:(UITableViewCell *)cell {
	UIView *aboveShadowView = [cell viewWithTag:TAG_FOR_ABOVE_SHADOW_VIEW_WHEN_DRAGGING];
	aboveShadowView.alpha = 0;
	
	UIView *belowShadowView = [cell viewWithTag:TAG_FOR_BELOW_SHADOW_VIEW_WHEN_DRAGGING];
	belowShadowView.alpha = 0;
}


/*
	Description:
		Removes all draggable indicators from the cell.
		Cell should be perfectly safe for reuse when this is complete.
 
		not meant to be animated. Use -hideDraggableIndicatorsOfCell: for that and call this in the animation's completion block.
 */
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController removeDraggableIndicatorsFromCell:(UITableViewCell *)cell {
	UIView *aboveShadowView = [cell viewWithTag:TAG_FOR_ABOVE_SHADOW_VIEW_WHEN_DRAGGING];
	[aboveShadowView removeFromSuperview];
	
	UIView *belowShadowView = [cell viewWithTag:TAG_FOR_BELOW_SHADOW_VIEW_WHEN_DRAGGING];
	[belowShadowView removeFromSuperview];
}


@end
