//
//  ReorderingAppDelegate.h
//  Reordering
//
//  Created by Daniel Shusta on 12/31/10.
//  Copyright 2010 Acacia Tree Software. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface ReorderingAppDelegate : NSObject <UIApplicationDelegate> {
    
    UIWindow *window;
    UINavigationController *navigationController;
}

@property (nonatomic, strong) IBOutlet UIWindow *window;
@property (nonatomic, strong) IBOutlet UINavigationController *navigationController;

@end

