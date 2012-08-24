
//  ATSDragToReorderTableViewController.h
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

	Interface Overview:

		ATSDragToReorderTableViewController is a UITableViewController subclass
		that incorporates a press-and-drag-to-reorder functionality into the
		tableView.

		Because it subclasses from UITableViewController, you can use existing
		classes that subclass from UITableViewController and subclass from
		ATSDragToReorderTableViewController instead. You only need to make a few
		changes (listed below).

		ATSDragToReorderTableViewControllerDelegate notifies upon change in
		dragging state. This could be useful if the destination or source of the
		reorder	could change the content of the cell.

		ATSDragToReorderTableViewControllerDraggableIndicators defines how to
		customize the dragged cell to make it appear more "draggable". By
		default this indicatorDelegate is self and the default implementation
		adds shadows above and below the cell.

		Requires iOS 4.0 or greater.


	Steps for use:

		0. If you aren't already, link against the QuartzCore framework.
		In Xcode 3.2, right-click the group tree (sidebar thingy),
		Add -> Existing Frameworks… -> QuartzCore.framework
		In Xcode 4.0, go to the project file -> Build Phases and add to
		Link Binary With Libraries.

		1. Subclass from this instead of UITableViewController

		2. UITableViewDataSource (almost certainly your subclass) should
 		implement -tableView:moveRowAtIndexPath:toIndexPath:


	Other recommendations:

		It is recommended that the tableView's dataSource -setReorderingEnabled:
		to NO if there is only one row.

		Rotation while dragging a cell is screwy and it's not clear to me how to
		handle that situation. For now, recommendation is to not allow rotations
		while dragging, maybe not at all.


	Assumptions made by this code:

		Subclass doesn't conform to UIGestureRecognizerDelegate. If it does,
		you're going to have to figure out how to orchastrate it all. It's
		likely not that difficult.

		self.tableView is of type UITableViewStylePlain. It will technically
		work with UITableViewStyleGrouped but it'll look ugly.

		This code totally ignores self.tableView.delegate's
		-tableView:targetIndexPathForMoveFromRowAtIndexPath:toProposedIndexPath:
		I have no idea what I would do with that.

		The tableview's contents won't change while dragging. I'm pretty sure if
		you do this, it will crash.

 */


#import <UIKit/UIKit.h>
#import <QuartzCore/CADisplayLink.h>
#import <QuartzCore/CALayer.h>

@class ATSDragToReorderTableViewController;

@protocol ATSDragToReorderTableViewControllerDelegate
@optional

- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController didBeginDraggingAtRow:(NSIndexPath *)dragRow;
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController willEndDraggingToRow:(NSIndexPath *)destinationIndexPath;
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController didEndDraggingToRow:(NSIndexPath *)destinationIndexPath;
- (BOOL)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController shouldHideDraggableIndicatorForDraggingToRow:(NSIndexPath *)destinationIndexPath;

@end


@protocol ATSDragToReorderTableViewControllerDraggableIndicators
@optional
// hate this, required to fix an iOS 6 bug where cell is hidden when going through normal paths to get a cell
// you must make a new cell to return this (use reuseIdent == nil), do not use dequeueResable
- (UITableViewCell *)cellIdenticalToCellAtIndexPath:(NSIndexPath *)indexPath forDragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController;

@required
/*******
 *
 *	-addDraggableIndicatorsToCell:forIndexPath and -removeDraggableIndicatorsFromCell: are guaranteed to be called.
 *	-hideDraggableIndicatorsOfCell: is usually called, but might not be.
 *
 *	These work in tandem, so if your subclass overrides any of them it should override the others as well.
 *
 *******/

//	Customize cell to appear draggable. Will be called inside an animation block.
//	Cell will have highlighted set to YES, animated NO. (changes are to the selectedBackgroundView if it exists)
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController addDraggableIndicatorsToCell:(UITableViewCell *)cell forIndexPath:(NSIndexPath *)indexPath;
//	You should set alpha of adjustments to 0 and similar. Will be called inside an animation block.
//	This should make the cell look like a normal cell, but is not expected to actually be one.
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController hideDraggableIndicatorsOfCell:(UITableViewCell *)cell;
//	Removes all adjustments to prepare cell for reuse. Will not be animated.
//	-hideDraggableIndicatorsOfCell: will probably be called before this, but not necessarily.
- (void)dragTableViewController:(ATSDragToReorderTableViewController *)dragTableViewController removeDraggableIndicatorsFromCell:(UITableViewCell *)cell;

@end


@interface ATSDragToReorderTableViewController : UITableViewController <UIGestureRecognizerDelegate, ATSDragToReorderTableViewControllerDraggableIndicators>  {
@protected
	UIPanGestureRecognizer *dragGestureRecognizer;
	UILongPressGestureRecognizer *longPressGestureRecognizer;

@private
	// Use setter/getter, not even subclasses should adjust this directly.
	CADisplayLink *timerToAutoscroll;
	CGFloat distanceThresholdToAutoscroll;

	CGFloat initialYOffsetOfDraggedCellCenter;
	CGPoint veryInitialTouchPoint;

	UITableViewCell *draggedCell;
	NSIndexPath *indexPathBelowDraggedCell;

	__weak id resignActiveObserver;
}

// default is YES. Removes or adds gesture recognizers to self.tableView.
@property (assign, getter=isReorderingEnabled) BOOL reorderingEnabled;

- (BOOL)isDraggingCell;

@property (weak) NSObject <ATSDragToReorderTableViewControllerDelegate> *dragDelegate; // nil by default
@property (weak) NSObject <ATSDragToReorderTableViewControllerDraggableIndicators> *indicatorDelegate; // self by default

@end

